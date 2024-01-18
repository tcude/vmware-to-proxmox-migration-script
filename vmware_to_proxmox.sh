#!/bin/bash
# Function to get user input
get_input() {
    read -p "$1: " input
    echo $input
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

# User inputs
echo "Enter the details for VM migration"
ESXI_SERVER=$(get_input "Enter the ESXi server hostname/IP")
ESXI_USERNAME=$(get_input "Enter the ESXi server username")
read -sp "Enter the ESXi server password: " ESXI_PASSWORD
echo
PROXMOX_SERVER=$(get_input "Enter the Proxmox server hostname/IP")
PROXMOX_USERNAME=$(get_input "Enter the Proxmox server username")
VM_NAME=$(get_input "Enter the name of the VM to migrate")

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
    read -p "Enter the desired VM ID for Proxmox: " VM_ID
    if ! [[ $VM_ID =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid VM ID '$VM_ID'. Please enter a numeric value."
        exit 1
    fi
    # Check if a VM with the given ID already exists
    if ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "qm status $VM_ID" &> /dev/null; then
        echo "Error: VM with ID '$VM_ID' already exists. Please enter a different ID."
        exit 1
    fi

    # Convert the disk before creating the VM
    echo "Converting VM to Proxmox format..."
    ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "tar -xof /var/vm-migration/$VM_NAME.ova -C /var/vm-migration/"
    echo "Finding .vmdk file..."
    local vmdk_file=$(ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "find /var/vm-migration -name '*.vmdk'")
    echo "Found .vmdk file: $vmdk_file"
    local qcow2_file="$VM_NAME.qcow2"
    local qcow2_path="/var/lib/vz/images/$VM_ID/$qcow2_file"
    echo "Creating directory for VM ID $VM_ID..."
    ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "mkdir -p /var/lib/vz/images/$VM_ID"
    echo "Converting .vmdk file to .qcow2 format..."
    ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "qemu-img convert -f vmdk -O qcow2 $vmdk_file $qcow2_path"

    # Create the VM and attach the disk
    ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "qm create $VM_ID --name $VM_NAME --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0"
    echo "Attaching disk to VM..."
    ssh $PROXMOX_USERNAME@$PROXMOX_SERVER "qm set $VM_ID --scsi0 local:$VM_ID/$qcow2_file"
}

# Main process
export_vmware_vm
transfer_vm
create_proxmox_vm