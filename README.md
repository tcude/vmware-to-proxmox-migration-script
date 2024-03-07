# VM Migration from ESXi to Proxmox

For detailed instructions, including how to prepare your Proxmox and ESXi environments for migration, how to address common issues during the migration process, and post-migration steps, please refer to my comprehensive blog post: 

https://tcude.net/migrate-linux-vms-from-esxi-to-proxmox-guide/

## Overview

This collection of scripts facilitates the migration of virtual machines from VMware ESXi to Proxmox VE. Designed with simplicity and efficiency in mind, the scripts aim to streamline the migration process, making it accessible to administrators of varying expertise levels. While primarily focused on Linux VMs, particularly Ubuntu Server VMs, the methodology may be adaptable for other distributions with minor adjustments.

This repo contains a collection of scripts I used to migrate my virtual machines off of VMWare ESXi and onto Proxmox VE.  While my linux migration script is particularly focused on Ubuntu Server VMs, the methodology may be adaptable for other distributions with minor adjustments.

## Getting Started

### Prerequisites

- Ensure you have temporary storage available at `/mnt/vm-migration` on your Proxmox host.
- The Proxmox host should have `ovftool`, `jq`, and `libguestfs-tools` installed.
- Familiarize yourself with the essential variables within the script, such as ESXi server details and VM specifics.

### Usage

1. Download the `linux_migration.sh` script from the repository.
2. Modify the script with your ESXi server details (`ESXI_SERVER`, `ESXI_USERNAME`, `ESXI_PASSWORD`).
3. Make the script executable: `chmod +x linux_migration.sh`.
4. Execute the script: `./linux_migration.sh`. Ensure the target VM in ESXi is powered off before proceeding.

## Support and Contributions

Your feedback and contributions are welcome! If you encounter issues, have suggestions, or would like to contribute improvements to the script, please open an issue or pull request in this repository.

## License

This project is released under the [MIT License](LICENSE).

