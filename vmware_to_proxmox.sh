#!/bin/bash
# To-do:
#      - Add ability to choose between local-lvm and local-zfs - currently defaults to local-lvm
#      - Find way to carry over MAC
#      - Attempt to find way to fix networking post-migration automatically
#      - Get script to pull specs of ESXi VM and use them when creating Proxmox VM

### PREREQUISITES ###
# - Install ovftool on the machine you are running the script on
# - This script assumes you have key-based authentication already configured on your Proxmox host. If you do not, add your public key
# - You must hardcode the variables for your esxi and proxmox IP, user, etc.  I previously had the script prompt the user for input every time but that isn't efficient when migrating multiple VMs in quick succession

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

### Set the following variables to their respective values
echo "Using hardcoded details for VM migration"
ESXI_SERVER="default_esxi_server" # Set your ESXi server hostname/IP
ESXI_USERNAME="root" # Set your ESXi server username
ESXI_PASSWORD="your_esxi_password" # Set your ESXi server password,
PROXMOX_SERVER="default_proxmox_server" # Set your Proxmox server hostname/IP
PROXMOX_USERNAME="root" # Set your Proxmox server username

VM_NAME=$(get_input "Enter the name of the VM to migrate")
VLAN_TAG=$(get_input "Enter the VLAN tag" "80")
VM_ID=$(get_input "Enter the VM ID you would like to use in Proxmox")

# Export VM from VMware
function export_vmware_vm() {
    local ova_file="$VM_NAME.ova"
    if [ -f "$ova_file" ]; then
        read -p "File $ova_file already exists. Overwrite? (y/n): " choice
        if [ "$choice" != "y" ]; then
            echo "Export cancelled."
            exit 1
        fi
        rm -f "$ova_file"
    fi
    echo "Exporting VM from VMware..."
    echo $ESXI_PASSWORD | ovftool --sourceType=VI --acceptAllEulas --noSSLVerify --skipManifestCheck --diskMode=thin --name=$VM_NAME vi://$ESXI_USERNAME@$ESXI_SERVER/$VM_NAME $VM_NAME.ova
}

# Transfer VM to Proxmox
function transfer_vm() {
    echo "Transferring VM to Proxmox..."
    scp $VM_NAME.ova $PROXMOX_USERNAME@$PROXMOX_SERVER:/var/vm-migration/
}

# Create VM in Proxmox and attach the disk
function create_proxmox_vm() {
    echo "Creating VM in Proxmox..."
    if ! [[ $VM_ID =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid VM ID '$VM_ID'. Please enter a numeric value."
        exit 1
    fi
    # Check for VM that already exists with provided VM ID
    if ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "qm status $VM_ID" &> /dev/null; then
        echo "Error: VM with ID '$VM_ID' already exists. Please enter a different ID."
        exit 1
    fi

    echo "Extracting OVF from OVA..."
    ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "tar -xvf /var/vm-migration/$VM_NAME.ova -C /var/vm-migration/"

    local ovf_file=$(ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "find /var/vm-migration -name '*.ovf'")
    echo "Found OVF file: $ovf_file"

    echo "Finding .vmdk file..."
    local vmdk_file=$(ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "find /var/vm-migration -name '$VM_NAME-disk*.vmdk'")
    echo "Found .vmdk file: $vmdk_file"

    # Check for ensuring only one .vmdk file is found
    if [[ $(echo "$vmdk_file" | wc -l) -ne 1 ]]; then
       echo "Error: Multiple or no .vmdk files found."
       exit 1
    fi

    # Convert .vmdk file to raw format
    local raw_file="$VM_NAME.raw"
    local raw_path="/var/tmp/$raw_file"
    echo "Converting .vmdk file to raw format..."
    ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "qemu-img convert -f vmdk -O raw '$vmdk_file' '$raw_path'"

    # Create the VM
    echo "Creating VM in Proxmox with UEFI, VLAN tag, and SCSI hardware..."
    echo "VM ID is: $VM_ID"
    ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "qm create $VM_ID --name $VM_NAME --memory 2048 --cores 2 --net0 virtio,bridge=vmbr69,tag=$VLAN_TAG --bios ovmf --scsihw virtio-scsi-pci"

    # Import disk to local-lvm storage
    echo "Importing disk to local-lvm storage..."
    ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "qm importdisk $VM_ID $raw_path local-lvm"

    # Attach disk to VM and set it as first boot device
    local disk_name="vm-$VM_ID-disk-0"
    echo "Attaching disk to VM and setting it as the first boot device..."
    ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "qm set $VM_ID --scsi0 local-lvm:$disk_name --boot c --bootdisk scsi0"

}

# Clean up files from /var/vm-migrations on proxmox host
function cleanup_migration_directory() {
    echo "Cleaning up /var/vm-migration directory..."
    ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "rm -rf /var/vm-migration/*"
}

# Clean up .ova files from local
function cleanup_local_ova_files() {
    echo "Removing local .ova files..."
    rm -f "$VM_NAME.ova"
}

# Add an EFI disk to the VM
function add_efi_disk_to_vm() {
    echo "Adding EFI disk to the VM..."
    local vg_name="pve" #LVM volume group name - should be this by default
    local efi_disk_size="4M"
    local efi_disk="vm-$VM_ID-disk-1"
    
    # Create EFI disk as a LV
    echo "Creating EFI disk as a logical volume..."
    ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "lvcreate -L $efi_disk_size -n $efi_disk $vg_name" || {
        echo "Failed to create EFI disk logical volume."
        exit 1
    }

    # Attach EFI disk to VM
    echo "Attaching EFI disk to VM..."
    ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "qm set $VM_ID --efidisk0 local-lvm:$efi_disk,size=$efi_disk_size,efitype=4m,pre-enrolled-keys=1" || {
        echo "Failed to add EFI disk to VM."
        exit 1
    }
}

# Main process
export_vmware_vm
transfer_vm
create_proxmox_vm
cleanup_migration_directory
cleanup_local_ova_files
add_efi_disk_to_vm