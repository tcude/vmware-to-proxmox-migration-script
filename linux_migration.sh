#!/bin/bash

### PREREQUISITES ###
# - Install ovftool on the Proxmox host - https://developer.vmware.com/web/tool/ovf/
# - Hardcode the variables for your ESXi IP, user, etc.

# Function to get user input with a default value
get_input() {
    read -p "$1 [$2]: " input
    echo ${input:-$2}
}

# Check if ovftool is installed
if ! ovftool --version &> /dev/null; then
    echo "Error: ovftool is not installed or not found in PATH. Please install ovftool and try again."
    exit 1
fi

# Check if jq is installed
if ! jq --version &> /dev/null; then
    echo "Error: jq is not installed or not found in PATH. Please install jq and try again."
    exit 1
fi

# Check if libguestfs-tools is installed
if ! virt-customize --version &> /dev/null; then
    echo "Error: virt-customize is not installed or not found in PATH. Please install libguestfs-tools and try again."
    exit 1
fi

### Set the following variables to their respective values
echo "Using hardcoded details for VM migration"
ESXI_SERVER="default_esxi_server" # Set your ESXi server hostname/IP
ESXI_USERNAME="root" # Set your ESXi server username
ESXI_PASSWORD="your_esxi_password" # Set your ESXi server password

VM_NAME=$(get_input "Enter the name of the VM to migrate")
VLAN_TAG=$(get_input "Enter the VLAN tag" "80")
VM_ID=$(get_input "Enter the VM ID you would like to use in Proxmox")
STORAGE_TYPE=$(get_input "Enter the storage name (for example local-lvm or local-zfs)" "local-lvm")
FIRMWARE_TYPE=$(get_input "Does the VM use UEFI firmware? (yes/no)" "no")

# Convert user input for firmware type into a format used by the script
if [ "$FIRMWARE_TYPE" == "yes" ]; then
    FIRMWARE_TYPE="ovmf"  # Correct setting for UEFI firmware in Proxmox
else
    FIRMWARE_TYPE="seabios"  # Default BIOS setting
fi

# Check if a VM with the given ID already exists before proceeding
if qm status $VM_ID &> /dev/null; then
    echo "Error: VM with ID '$VM_ID' already exists. Please enter a different ID."
    exit 1
fi

if ! [[ $VM_ID =~ ^[0-9]+$ ]] || [[ $VM_ID -le 99 ]]; then
    echo "Error: Invalid VM ID '$VM_ID'. Please enter a numeric value greater than 99."
    exit 1
fi

# Export VM from VMware
function export_vmware_vm() {
    local ova_file="/mnt/vm-migration/$VM_NAME.ova"
    if [ -f "$ova_file" ]; then
        read -p "File $ova_file already exists. Overwrite? (y/n) [y]: " choice
        choice=${choice:-y}
        case $choice in
            [Yy]* )
                rm -f "$ova_file"
                do_vmware_vm_export
                ;;
            * )
                read -p "Skip fresh import and re-use existing ova file? (y/n) [n]" reuse
                reuse=${reuse:-n}
                case $reuse in
                    [Yy]* ) return ;;
                    * )
                        echo "Export cancelled."
                        exit 1
                    ;;
                esac
            ;;
        esac
    else
        do_vmware_vm_export
    fi
}

function do_vmware_vm_export() {
    echo "Exporting VM from VMware directly to Proxmox..."
    echo $ESXI_PASSWORD | ovftool --sourceType=VI --acceptAllEulas --noSSLVerify --skipManifestCheck --diskMode=thin --name=$VM_NAME vi://$ESXI_USERNAME@$ESXI_SERVER/$VM_NAME $ova_file
}

function create_proxmox_vm() {

    # Extract OVF from OVA
    echo "Extracting OVF from OVA..."
    tar -xvf /mnt/vm-migration/$VM_NAME.ova -C /mnt/vm-migration/

    # Find the OVF file
    local ovf_file=$(find /mnt/vm-migration -name '*.ovf')
    echo "Found OVF file: $ovf_file"

    # Ensure that at least one .vmdk file exists
    if [[ $(find /mnt/vm-migration -name "$VM_NAME-disk*.vmdk" | wc -l) -eq 0 ]]; then
       echo "Error: No vmdk files found."
       exit 1
    fi

    NUM_DISKS=$(find /mnt/vm-migration -name "$VM_NAME-disk*.vmdk" | wc -l)

    for ((i=1;i<=$NUM_DISKS;i++)); do
        convert_disk $i;
    done

    # Install qemu-guest-agent using virt-customize
    echo "Installing qemu-guest-agent using virt-customize..."
    virt-customize -a "/mnt/vm-migration/$VM_NAME-disk1.raw" --install qemu-guest-agent || {
        echo "Failed to install qemu-guest-agent."
    exit 1
    }

    # Create the VM and set various options such as BIOS type
    echo "Creating VM in Proxmox with $FIRMWARE_TYPE firmware, VLAN tag, and SCSI hardware..."
    qm create $VM_ID --name $VM_NAME --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0,tag=$VLAN_TAG --bios $FIRMWARE_TYPE --scsihw virtio-scsi-pci

    echo "Enabling QEMU Guest Agent..."
    qm set $VM_ID --agent 1

    # Add disks to VM (and assume first disk is the OS/boot disk)
    for ((i=1;i<=$NUM_DISKS;i++)); do
        add_disk $i;
    done
}

function convert_disk() {
    local working_path="/mnt/vm-migration/$VM_NAME-disk$1"
    echo "Converting .vmdk file $i to raw format..."
    qemu-img convert -f vmdk -O raw "$working_path.vmdk" "$working_path.raw"
}

function add_disk() {

    # Import the disk to the selected storage
    echo "Importing disk $1 to $STORAGE_TYPE storage..."
    qm importdisk $VM_ID /mnt/vm-migration/$VM_NAME-disk$1.raw $STORAGE_TYPE

    # Attach the disk to the VM and set it as the first boot device if disk 1
    local disk_name="vm-$VM_ID-disk-$(expr $1 - 1)"
    if [[ $1 -eq 1 ]]; then
        echo "Attaching disk 1 to VM and setting it as the boot device..."
        qm set $VM_ID --scsi$(expr $1 - 1) $STORAGE_TYPE:$disk_name --boot c --bootdisk scsi$(expr $1 - 1)
    else
        echo "Attaching additional disk to VM..."
        qm set $VM_ID --scsi$(expr $1 - 1) $STORAGE_TYPE:$disk_name
    fi

    # Enable discard functionality for the disk
    echo "Enabling discard functionality"
    qm set $VM_ID --scsi$(expr $1 - 1) $STORAGE_TYPE:$disk_name,discard=on
}

# Clear out temp files from /var/vm-migrations
function cleanup_migration_directory() {
    echo "Cleaning up /mnt/vm-migration directory..."
    rm -rf /mnt/vm-migration/*
}

# Retrieve the actual LVM volume group name
vg_name=$(vgdisplay | awk '/VG Name/ {print $3}')

# Add an EFI disk to the VM after all other operations have concluded
function add_efi_disk_to_vm() {
  echo "Adding EFI disk to the VM..."
  local vg_name="nvme" # Adjusted to the correct volume group name if necessary
  local efi_disk_size="4M"
  local efi_disk="vm-$VM_ID-disk-1"

  # Ensure correct volume group name is used
  echo "Creating EFI disk as a logical volume in volume group $vg_name..."
  lvcreate -L $efi_disk_size -n $efi_disk $vg_name || {
    echo "Failed to create EFI disk logical volume."
    exit 1
  }

  # Attach EFI disk
  echo "Attaching EFI disk to VM..."
  qm set $VM_ID --efidisk0 $vg_name:$efi_disk,size=$efi_disk_size,efitype=4m,pre-enrolled-keys=1 || {
    echo "Failed to add EFI disk to VM."
    exit 1
  }
}

# Main process
export_vmware_vm
create_proxmox_vm
cleanup_migration_directory

# Add EFI disk based on the user's input
if [ "$FIRMWARE_TYPE" == "ovmf" ]; then  # Correct check for UEFI firmware
    add_efi_disk_to_vm
else
    echo "Skipping EFI disk creation for non-UEFI firmware type."
fi
