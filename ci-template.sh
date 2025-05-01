#!/bin/bash

if ! command -v virt-customize &>/dev/null; then
    echo "Error: virt-customize is not installed. Installing libguestfs-tools."
    apt install libguestfs-tools
fi

# Default vars
storage="storage"
cores="2"
memory="4096"
disksize="20G"
nameserver="1.1.1.1,1.0.0.1" # Cloudflare: Default DNS servers
searchdomain=""              # Default empty
ciupgrade="no"               # Enable automatic package upgrades by default
timezone="Pacific/Auckland"  # Default timezone
firstboot_script=""          # Default empty
template_id=""               # Allow manual template ID specification
template_name=""             # Allow override of template name
template=""                  # For cloud-init template selection (docker, k8s, etc)
ntp_servers="time.cloudflare.com,time.google.com"
disable_swap="yes"
download_only=0


# Print script usage
usage() {
    echo "Usage: $0 {os} [storage=storage_volume] [cores=number] [memory=number] [disksize=size]"
    echo
    echo "Available OS options:"
    for key in "${!os_configs[@]}"; do
        echo "  $key"
    done
    echo
    echo "Available Ubuntu templates:"
    for key in "${!ubuntu_templates[@]}"; do
        echo "  $key"
    done
    echo
    echo "Current default options:"
    echo "  Storage: $storage"
    echo "  Cores: $cores"
    echo "  Memory: $memory"
    echo "  DNS: $nameserver"
    echo "  Package Upgrade: $ciupgrade"
    echo "  Timezone: $timezone"
    echo "  Firstboot Script: $firstboot_script"
    echo "  Disk Size: $disksize"
    echo
    echo "Additional options:"
    echo "  nameserver=dns_servers    Comma-separated DNS servers (default: 1.1.1.3,1.0.0.1)"
    echo "  searchdomain=domain      DNS search domain"
    echo "  ciupgrade=yes|no         Enable/disable automatic package upgrades (default: yes)"
    echo "  timezone=Zone/City       Set timezone (default: UTC)"
    echo "  firstboot_script=cmd     Command to run when VMs are first created from template"
    echo "  name=string             Override template name (default: tmpl-{os-name})"
    echo "  template_script=cmd      Command to bake into the template itself"
    echo "  template_id=number       Specify template ID (default: auto-assigned)"
}

# OS images
declare -A os_configs=(
    [alpine_3]="tmpl-alpine-3.21 nocloud_alpine-3.21.1-x86_64-bios-cloudinit-r0.qcow2 https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/cloud/nocloud_alpine-3.21.1-x86_64-bios-cloudinit-r0.qcow2"
    [debian_12]="tmpl-debian-12 debian-12-genericcloud-amd64.qcow2 https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
    [debian_13]="tmpl-debian-13-daily debian-13-genericcloud-amd64-daily.qcow2 https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-genericcloud-amd64-daily.qcow2"
    [fedora_41]="tmpl-fedora-41 Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2 https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-41-1.4.x86_64.qcow2"
    [opensuse_leap_15]="tmpl-opensuse-leap-15.6 openSUSE-Leap-15.6.x86_64-NoCloud.qcow2 https://download.opensuse.org/repositories/Cloud:/Images:/Leap_15.6/images/openSUSE-Leap-15.6.x86_64-NoCloud.qcow2"
    [oracle_8]="tmpl-oracle-8.10 OL8U10_x86_64-kvm-b237.qcow2 https://yum.oracle.com/templates/OracleLinux/OL8/u10/x86_64/OL8U10_x86_64-kvm-b237.qcow2"
    [oracle_9]="tmpl-oracle-9.5 OL9U5_x86_64-kvm-b253.qcow2 https://yum.oracle.com/templates/OracleLinux/OL9/u5/x86_64/OL9U5_x86_64-kvm-b253.qcow2"
    [rocky_9]="tmpl-rocky-9.5 Rocky-9-GenericCloud.latest.x86_64.qcow2 http://dl.rockylinux.org/pub/rocky/9.5/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2"
    [ubuntu_22]="tmpl-ubuntu-22.04 ubuntu-22.04-server-cloudimg-amd64.img https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img"
    [ubuntu_24]="tmpl-ubuntu-24.04 ubuntu-24.04-server-cloudimg-amd64.img https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
)

# Add after the os_configs declaration
declare -A ubuntu_templates=(
    [docker]="templates/ubuntu-docker.yaml"
    [base]="templates/debian.yaml"
    [k8s]="templates/ubuntu-k8s.yaml"
)

# Find next available template ID
find_next_template_id() {
    if [ -n "$template_id" ]; then
        if ! [[ "$template_id" =~ ^[0-9]+$ ]]; then
            echo "Error: template_id must be a number" >&2
            exit 1
        fi
        echo "$template_id"
        return
    fi

    # If no template_id specified, auto-select from 90000-99999
    local start_id=90000
    local end_id=99999

    for ((id = start_id; id <= end_id; id++)); do
        if ! qm list | grep -q "^[[:space:]]*$id[[:space:]]"; then
            echo "$id"
            return
        fi
    done

    echo "No available template IDs found in range $start_id-$end_id" >&2
    return 1
}

check_template() {
    local template_id=$1
    if qm list | grep -q " $template_id "; then
        echo "Template $template_id already exists in Proxmox."
        read -r -p "Do you want to delete it and continue? (yes/no): " response
        case $response in
        [Yy]*)
            echo "Deleting template $template_id..."
            qm destroy "$template_id"
            ;;
        [Nn]*)
            echo "Exiting script."
            exit 1
            ;;
        *)
            echo "Invalid response. Exiting script."
            exit 1
            ;;
        esac
    fi
}

download_image() {
    local image_file=$1
    local link=$2

    if [ ! -f "$image_file" ]; then
        echo "Downloading image to $image_file" >&2
        if ! wget "$link" -O "$image_file"; then
            echo "Error: Failed to download image from $link" >&2
            rm -f "$image_file" # Clean up partial download
            exit 1
        fi
    else
        echo "Using existing image: $image_file" >&2
    fi

    printf "%s" "$image_file"
}

install_qemu_guest_agent() {
    local image_file=$1

    echo "Installing QEMU guest agent..." >&2
    virt-customize -a "$image_file" \
        --selinux-relabel \
        --install qemu-guest-agent \
        --run-command "truncate -s 0 /etc/machine-id /var/lib/dbus/machine-id"

    if [ -n "$template_script" ]; then
        echo "Running template customization..." >&2
        virt-customize -a "$image_file" --run-command "$template_script"
    fi
}

# Create vendor config
create_vendor_config() {
    local template_id=$1
    local os_type="${os:-}"
    local output_file="/var/lib/vz/snippets/${template_id}-civendor.yaml"
    local template_file=""
    local template_dir="$(pwd)/templates"
    if [[ "$os_type" == *"ubuntu"* ]] && [ -n "$template" ]; then
        if [ -n "${ubuntu_templates[$template]}" ]; then
            template_file="${ubuntu_templates[$template]}"
            if [ -f "$template_file" ]; then
                cp "$template_file" "$output_file"
                echo "Created vendor config at $output_file using Ubuntu template: $template" >&2
                return
            else
                echo "Error: Template file $template_file not found" >&2
                exit 1
            fi
        else
            echo "Error: Unknown Ubuntu template: $template" >&2
            echo "Available templates: ${!ubuntu_templates[*]}" >&2
            exit 1
        fi
    fi

    case "$os_type" in
    *ubuntu* | *debian*)
        template_file="${template_dir}/debian.yaml"
        ;;
    *fedora* | *rocky* | *oracle*)
        template_file="${template_dir}/rhel.yaml"
        ;;
    *suse*)
        template_file="${template_dir}/suse.yaml"
        ;;
    *alpine*)
        template_file="${template_dir}/alpine.yaml"
        ;;
    *)
        echo "Error: Unsupported OS type: $os_type" >&2
        exit 1
        ;;
    esac

    if [ -f "$template_file" ]; then
        cp "$template_file" "$output_file"
        echo "Created vendor config at $output_file using template $template_file" >&2
    else
        echo "Error: Template file $template_file not found" >&2
        exit 1
    fi
}

# Create template
create_template() {
    local template_id=$1
    local template_name=$2
    local image_file=$3

    echo "Creating template $template_name ($template_id)" >&2

    # Create the VM
    qm create "$template_id" --name "$template_name" --ostype l26

    # Import the disk
    echo "Importing disk from $image_file..." >&2
    qm importdisk "$template_id" "$image_file" "$storage" --format raw

    # Wait for import to complete
    echo "Waiting for disk import to complete..." >&2
    sleep 5

    # Configure the imported disk
    echo "Configuring disk..." >&2
    if [[ "$storage" == "storage" ]]; then
        # LVM storage
        qm set "$template_id" --scsi0 "$storage:vm-$template_id-disk-0"
    else
        # Directory-based storage
        qm set "$template_id" --scsi0 "$storage:$template_id/vm-$template_id-disk-0.raw"
    fi

    # Resize the disk
    echo "Resizing disk to $disksize..." >&2
    qm resize "$template_id" scsi0 "$disksize"

    # Configure VM settings
    qm set "$template_id" --net0 virtio,bridge=vmbr0
    qm set "$template_id" --serial0 socket --vga serial0
    qm set "$template_id" --memory "$memory" --cores "$cores" --cpu host
    qm set "$template_id" --boot order=scsi0 --scsihw virtio-scsi-single
    qm set "$template_id" --agent enabled=1

    # Add Cloud-Init Drive
    qm set "$template_id" --ide2 "${storage}:cloudinit"

    # Configure Cloud-Init Settings (only DHCP)
    qm set "$template_id" --ipconfig0 "ip=dhcp"

    # Create and apply vendor config first (this contains the user configuration)
    create_vendor_config "$template_id"
    qm set "$template_id" --cicustom "user=local:snippets/${template_id}-civendor.yaml"

    # Convert to template
    echo "Converting to template..." >&2
    qm template "$template_id"
}

# Handle OS
handle_os() {
    local os=$1
    IFS=' ' read -r -a config <<<"${os_configs[$os]}"
    local default_name=${config[0]}
    local image_file=${config[1]}
    local link=${config[2]}

    local final_name=${template_name:-$default_name}

    local assigned_id=$(find_next_template_id)
    echo "Using template ID: $assigned_id"

    check_template "$assigned_id"
    image_file=$(download_image "$image_file" "$link")
    install_qemu_guest_agent "$image_file"

    create_template "$assigned_id" "$final_name" "$image_file"
}

if [ $# -eq 0 ]; then
    usage
    exit 0
fi

os=$1
shift

while [[ $# -gt 0 ]]; do
    case $1 in
    storage=*)
        storage="${1#*=}"
        ;;
    cores=*)
        if ! [[ "${1#*=}" =~ ^[0-9]+$ ]]; then
            echo "Error: cores must be a number" >&2
            exit 1
        fi
        cores="${1#*=}"
        ;;
    memory=*)
        if ! [[ "${1#*=}" =~ ^[0-9]+$ ]]; then
            echo "Error: memory must be a number" >&2
            exit 1
        fi
        memory="${1#*=}"
        ;;
    disksize=*)
        if ! [[ "${1#*=}" =~ ^[0-9]+[GgMm]$ ]]; then
            echo "Error: disksize must be a number followed by G or M" >&2
            exit 1
        fi
        disksize="${1#*=}"
        ;;
    nameserver=*)
        nameserver="${1#*=}"
        ;;
    searchdomain=*)
        searchdomain="${1#*=}"
        ;;
    ciupgrade=*)
        ciupgrade="${1#*=}"
        ;;
    timezone=*)
        timezone="${1#*=}"
        ;;
    firstboot_script=*)
        firstboot_script="${1#*=}"
        ;;
    template_script=*)
        template_script="${1#*=}"
        ;;
    template_id=*)
        template_id="${1#*=}"
        if ! [[ "$template_id" =~ ^[0-9]+$ ]]; then
            echo "Error: template_id must be a number"
            exit 1
        fi
        ;;
    download_only)
        download_only=1
        ;;
    template=*)
        template="${1#*=}" # For selecting cloud-init template
        ;;
    name=*)
        template_name="${1#*=}" # For Proxmox VM name
        ;;
    *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
    shift
done

if [[ -z "${os_configs[$os]}" ]]; then
    echo "Invalid OS option: $os"
    usage
    exit 1
fi

if [ "$download_only" -eq 1 ]; then
    if [[ "$os" == https://* ]]; then
        image_link="$os"
        image_file=$(basename "$image_link")
        echo "Downloading direct URL..."
    else
        if ! os_config="${os_configs[$os]}"; then
            echo "Error: Invalid OS type '$os'" >&2
            usage
            exit 1
        fi
        image_link=$(echo "$os_config" | awk '{print $3}')
        image_file=$(echo "$os_config" | awk '{print $2}')
        echo "Downloading image for $os..."
    fi

    echo "Image file: $image_file"
    echo "Image link: $image_link"
    download_image "$image_file" "$image_link"
    echo "Download complete: $image_file"
    exit 0
fi

handle_os "$os"
