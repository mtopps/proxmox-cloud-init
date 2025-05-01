# Proxmox Cloud-Init Template Creation Script

This script automates the creation of cloud-init ready VM templates in Proxmox. It supports multiple operating systems and provides extensive customization options.

## Features

- Supports multiple operating systems:
  - Alpine Linux 3.21
  - Debian 12 (Bookworm) and 13 (Testing)
  - Fedora 41
  - OpenSUSE Leap 15.6
  - Oracle Linux 8.10 and 9.5
  - Rocky Linux 9.5
  - Ubuntu 22.04 LTS and 24.04 LTS
- Customizable VM specifications (CPU, memory, disk size)
- Cloud-init configuration with custom user data support
- Automatic QEMU guest agent installation
- Configurable DNS and timezone settings
- Support for first-boot and template customization scripts
- Flexible storage backend selection

## Prerequisites

- Proxmox VE installed and configured
- `libguestfs-tools` package (will be automatically installed if missing)
- Root access to the Proxmox host

## Usage

1. Make the script executable:
   ```bash
   chmod +x ci-template.sh
   ```

2. Run the script with root privileges:
   ```bash
   ./ci-template.sh {os} [options]
   ```

### Required Parameters

- `{os}`: Operating system identifier. Available options:
  - `alpine_3`
  - `debian_12`, `debian_13`
  - `fedora_41`
  - `opensuse_leap_15`
  - `oracle_8`, `oracle_9`
  - `rocky_9`
  - `ubuntu_22`, `ubuntu_24`

### Optional Parameters

VM Configuration:
- `cores=number` - Number of CPU cores (default: 2)
- `memory=number` - RAM in MB (default: 4096)
- `disksize=size` - Disk size (default: 30G)
- `storage=volume` - Proxmox storage volume (default: storage)

Network Configuration:
- `nameserver=servers` - DNS servers, comma-separated (default: 1.1.1.1,1.0.0.1)
- `searchdomain=domain` - DNS search domain (default: local.mtopps.com)
- `ntp_servers=servers` - NTP servers (default: time.cloudflare.com,time.google.com)

System Configuration:
- `timezone=Zone/City` - System timezone (default: Pacific/Auckland)
- `ciupgrade=yes|no` - Enable automatic updates (default: no)
- `template_id=number` - Specific template ID (default: auto-assigned from 90000-99999)
- `cicustom=path` - Path to custom cloud-init config (relative to snippets/)

Script Customization:
- `firstboot_script=cmd` - Command to run on first VM boot
- `template_script=cmd` - Command to bake into the template

### Examples

Basic Ubuntu 22.04 template:
```bash
./ci-template.sh ubuntu_22
```

Customized Debian 12 template:
```bash
./ci-template.sh debian_12 \
  key=/home/user/.ssh/id_rsa.pub \
  username=admin \
  storage=local-zfs \
  cores=4 \
  memory=8192 \
  disksize=50G \
  nameserver=8.8.8.8,8.8.4.4 \
  searchdomain=example.com
```

Rocky Linux with custom cloud-init config:
```bash
./ci-template.sh rocky_9 cicustom=custom-config.yaml
```

## Template IDs

Templates are automatically assigned IDs in the range 90000-99999, unless specified using `template_id=`. The script will check for conflicts and prompt before overwriting existing templates.

## Cloud-Init Configuration

The script supports both default and custom cloud-init configurations:
- Default: Uses built-in templates based on the OS family (debian.yaml, rhel.yaml, suse.yaml, alpine.yaml)
- Custom: Specify your own configuration using the `cicustom` parameter

## Notes

- The script automatically cleans up downloaded image files after template creation
- All templates use SCSI for the boot disk and virtio for network interfaces
- Templates are configured with DHCP by default
- IPv6 is enabled with automatic configuration
