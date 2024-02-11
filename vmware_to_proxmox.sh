#!/bin/bash
# To-do:
#      - Add ability to choose between local-lvm and local-zfs
#      - Find way to carry over MAC
#      - Attempt to find way to fix networking post-migration automatically
#      - Get script to pull specs of ESXi VM and use them when creating Proxmox VM
#      - Add functionality to remove old .ova files from local machine

### PREREQUISITES ###
# - Install ovftool on the Proxmox host
# - Ensure you have key-based authentication configured for any remote connections needed
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
    echo "Error: virtu-customize is not installed or not found in PATH. Please install libguestfs-tools and try again"
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
STORAGE_TYPE=$(get_input "Enter the storage type (local-lvm or local-zfs)" "local-lvm")

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
    local ova_file="/var/vm-migration/$VM_NAME.ova"
    if [ -f "$ova_file" ]; then
        read -p "File $ova_file already exists. Overwrite? (y/n) [y]: " choice
        choice=${choice:-y}
        if [ "$choice" != "y" ]; then
            echo "Export cancelled."
            exit 1
        fi
        rm -f "$ova_file"
    fi
    echo "Exporting VM from VMware directly to Proxmox..."
    echo $ESXI_PASSWORD | ovftool --sourceType=VI --acceptAllEulas --noSSLVerify --skipManifestCheck --diskMode=thin --name=$VM_NAME vi://$ESXI_USERNAME@$ESXI_SERVER/$VM_NAME $ova_file
}

# Create VM in Proxmox and attach the disk
function create_proxmox_vm() {

    # Extract OVF from OVA
    echo "Extracting OVF from OVA..."
    tar -xvf /var/vm-migration/$VM_NAME.ova -C /var/vm-migration/

    # Find the OVF file
    local ovf_file=$(find /var/vm-migration -name '*.ovf')
    echo "Found OVF file: $ovf_file"

    # Find the VMDK file
    echo "Finding .vmdk file..."
    local vmdk_file=$(find /var/vm-migration -name "$VM_NAME-disk*.vmdk")
    echo "Found .vmdk file: $vmdk_file"

    # Ensure that only one .vmdk file is found
    if [[ $(echo "$vmdk_file" | wc -l) -ne 1 ]]; then
       echo "Error: Multiple or no .vmdk files found."
       exit 1
    fi

    # Convert the VMDK file to raw format
    #local raw_file="$VM_NAME.raw"
    #local raw_path="/var/tmp/$raw_file"
    #echo "Converting .vmdk file to raw format..."
    #qemu-img convert -f vmdk -O raw "$vmdk_file" "$raw_path"

    # Convert the VMDK file to raw format
    local raw_file="$VM_NAME.raw"
    local raw_path="/var/tmp/$raw_file"
    echo "Converting .vmdk file to raw format..."
    qemu-img convert -f vmdk -O raw "$vmdk_file" "$raw_path"

    # Install qemu-guest-agent using virt-customize
    echo "Installing qemu-guest-agent using virt-customize..."
    virt-customize -a "$raw_path" --install qemu-guest-agent || {
        echo "Failed to install qemu-guest-agent."
    exit 1
    }

    # Create the VM with UEFI BIOS, VLAN tag, and specify the SCSI hardware
    echo "Creating VM in Proxmox with UEFI, VLAN tag, and SCSI hardware..."
    echo "VM ID is: $VM_ID"
    qm create $VM_ID --name $VM_NAME --memory 2048 --cores 2 --net0 virtio,bridge=vmbr69,tag=$VLAN_TAG --bios ovmf --scsihw virtio-scsi-pci

    # Import the disk to the selected storage
    echo "Importing disk to $STORAGE_TYPE storage..."
    qm importdisk $VM_ID $raw_path $STORAGE_TYPE

    # Attach the disk to the VM and set it as the first boot device
    local disk_name="vm-$VM_ID-disk-0"
    echo "Attaching disk to VM and setting it as the first boot device..."
    qm set $VM_ID --scsi0 $STORAGE_TYPE:$disk_name --boot c --bootdisk scsi0
}

# Clear out temp files from /var/vm-migrations
function cleanup_migration_directory() {
    echo "Cleaning up /var/vm-migration directory..."
    rm -rf /var/vm-migration/*
}

# Add an EFI disk to the VM after all other operations have concluded
function add_efi_disk_to_vm() {
    echo "Adding EFI disk to the VM..."
    local vg_name="pve" # The actual LVM volume group name
    local efi_disk_size="4M"
    local efi_disk="vm-$VM_ID-disk-1"
    
    # Create the EFI disk as a logical volume
    echo "Creating EFI disk as a logical volume..."
    lvcreate -L $efi_disk_size -n $efi_disk $vg_name || {
        echo "Failed to create EFI disk logical volume."
        exit 1
    }

    # Attach the EFI disk to the VM
    echo "Attaching EFI disk to VM..."
    qm set $VM_ID --efidisk0 $STORAGE_TYPE:$efi_disk,size=$efi_disk_size,efitype=4m,pre-enrolled-keys=1 || {
        echo "Failed to add EFI disk to VM."
        exit 1
    }
}

echo "Migration completed"
echo ""
echo "You will likely need to update your network interace name on the VM.  This can be done by"
echo "running ip ad to grab the new interface name and then updating what is stored in /etc/netplan/00-installer-config.yaml"

#function update_netplan_config() {
#    
#}

# Main process
export_vmware_vm
create_proxmox_vm
cleanup_migration_directory
add_efi_disk_to_vm
#update_netplan_config