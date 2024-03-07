#!/bin/bash

### PREREQUISITES ###
# - Install ovftool on the Proxmox host - https://developer.vmware.com/web/tool/ovf/
# - Hardcode the variables for your ESXi IP, user, etc.

# Function to get user input with a default value
get_input() {
    read -rp "$1 [$2]: " input
    echo "${input:-$2}"
}

# Array of required tools
required_tools=("ovftool" "jq" "virt-customize")

# Check if required tools are installed
for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        echo "Error: $tool is not installed or not found in PATH. Please install $tool and try again."
        exit 1
    fi
done

### Set the following variables to their respective values
echo "Using hardcoded details for VM migration"
ESXI_SERVER="default_esxi_server" # Set your ESXi server hostname/IP
ESXI_USERNAME="root" # Set your ESXi server username
ESXI_PASSWORD="your_esxi_password" # Set your ESXi server password

VM_NAME=$(get_input "Enter the name of the VM to migrate")
VLAN_TAG=$(get_input "Enter the VLAN tag" "80")
VM_ID=$(get_input "Enter the VM ID you would like to use in Proxmox")
STORAGE_TYPE=$(get_input "Enter the storage type (local-lvm or local-zfs)" "local-lvm")
FIRMWARE_TYPE=$(get_input "Does the VM use UEFI firmware? (yes/no)" "no")

# Convert user input for firmware type into a format used by the script
if [ "$FIRMWARE_TYPE" == "yes" ]; then
    FIRMWARE_TYPE="ovmf"  # Correct setting for UEFI firmware in Proxmox
else
    FIRMWARE_TYPE="seabios"  # Default BIOS setting
fi

# Validate VM ID before proceeding
validate_vm_id() {
    # Check if VM with the given ID already exists
    if qm status "$VM_ID" &> /dev/null; then
        echo "Error: VM with ID '$VM_ID' already exists. Please enter a different ID."
        exit 1
    fi

    # Ensure VM ID is numeric and greater than 99
    if ! [[ $VM_ID =~ ^[0-9]+$ ]] || [[ $VM_ID -le 99 ]]; then
        echo "Error: Invalid VM ID '$VM_ID'. Please enter a numeric value greater than 99."
        exit 1
    fi
}

# Function to export VM from VMware
export_vmware_vm() {
    local ova_file="/mnt/vm-migration/$VM_NAME.ova"

    # Check if the OVA file already exists and confirm overwrite
    if [ -f "$ova_file" ]; then
        read -rp "File $ova_file already exists. Overwrite? (y/n) [y]: " choice
        choice=${choice:-y}
        if [ "$choice" != "y" ]; then
            echo "Export cancelled."
            exit 1
        fi
        rm -f "$ova_file"
    fi

    # Export VM from VMware to Proxmox
    echo "Exporting VM from VMware directly to Proxmox..."
    echo "$ESXI_PASSWORD" | ovftool --sourceType=VI --acceptAllEulas --noSSLVerify --skipManifestCheck --diskMode=thin --name="$VM_NAME" "vi://$ESXI_USERNAME@$ESXI_SERVER/$VM_NAME" "$ova_file"
}

create_proxmox_vm() {
    local migration_dir="/mnt/vm-migration"
    local ova_file="${migration_dir}/${VM_NAME}.ova"
    local raw_file="${VM_NAME}.raw"
    local raw_path="${migration_dir}/${raw_file}"

    echo "Extracting OVF and VMDK from OVA..."
    tar -xvf "$ova_file" -C "$migration_dir"

    local ovf_file vmdk_file vmdk_count
    ovf_file=$(find "$migration_dir" -name '*.ovf')
    echo "Found OVF file: $ovf_file"

    vmdk_file=$(find "$migration_dir" -name "${VM_NAME}-disk*.vmdk")
    vmdk_count=$(find "$migration_dir" -name "${VM_NAME}-disk*.vmdk" | wc -l)
    if [ "$vmdk_count" -ne 1 ]; then
        echo "Error: Multiple or no .vmdk files found."
        exit 1
    fi
    echo "Found VMDK file: $vmdk_file"

    echo "Converting VMDK to raw format..."
    if ! qemu-img convert -f vmdk -O raw "$vmdk_file" "$raw_path"; then
        echo "Failed to convert VMDK to raw format."
        exit 1
    fi

    echo "Installing qemu-guest-agent..."
    if ! virt-customize -a "$raw_path" --install qemu-guest-agent; then
        echo "Failed to install qemu-guest-agent."
        exit 1
    fi

    echo "Creating and configuring VM in Proxmox..."
    if ! qm create "$VM_ID" --name "$VM_NAME" --memory 2048 --cores 2 \
        --net0 virtio,bridge=vmbr0,tag="$VLAN_TAG" --bios "$FIRMWARE_TYPE" --scsihw virtio-scsi-pci \
        --agent 1; then
        echo "Failed to create VM."
        exit 1
    fi

    if ! qm importdisk "$VM_ID" "$raw_path" "$STORAGE_TYPE"; then
        echo "Failed to import disk."
        exit 1
    fi

    local disk_name="vm-${VM_ID}-disk-0"
    if ! qm set "$VM_ID" --scsi0 "${STORAGE_TYPE}:${disk_name}" --boot c --bootdisk scsi0 --scsi0 "${STORAGE_TYPE}:${disk_name},discard=on"; then
        echo "Failed to configure VM disk and boot options."
        exit 1
    fi

    echo "VM creation and configuration complete."
}

# Clear out temp files from /var/vm-migrations
cleanup_migration_directory() {
    echo "Cleaning up /mnt/vm-migration directory..."
    rm -rf /mnt/vm-migration/*
}

# Retrieve the actual LVM volume group name
vg_name=$(vgdisplay | awk '/VG Name/ {print $3}')

# Add an EFI disk to the VM after all other operations have concluded
add_efi_disk_to_vm() {
    echo "Adding EFI disk to the VM..."
    local vg_name="nvme"  # Volume group name, adjust if necessary
    local efi_disk_size="4M"
    local efi_disk="vm-$VM_ID-disk-1"

    # Create EFI disk as a logical volume
    if ! lvcreate -L "$efi_disk_size" -n "$efi_disk" "$vg_name"; then
        echo "Failed to create EFI disk logical volume."
        exit 1
    fi

    echo "Attaching EFI disk to VM..."
    if ! qm set "$VM_ID" --efidisk0 "${vg_name}:${efi_disk},size=${efi_disk_size},efitype=4m,pre-enrolled-keys=1"; then
        echo "Failed to add EFI disk to VM."
        exit 1
    fi

    echo "EFI disk successfully added to VM."
}

# Main process
validate_vm_id
export_vmware_vm
create_proxmox_vm
cleanup_migration_directory

# Add EFI disk based on the user's input
if [ "$FIRMWARE_TYPE" == "ovmf" ]; then  # Correct check for UEFI firmware
    add_efi_disk_to_vm
else
    echo "Skipping EFI disk creation for non-UEFI firmware type."
fi
