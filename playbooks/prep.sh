#!/bin/bash
set -euo pipefail

# ============================================================================
# Arch Linux Installation Prep Script
# ============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly LOG_FILE="/tmp/prep_$(date '+%Y%m%d_%H%M%S').log"
readonly VALID_HOSTS=("ASTER" "THEMIS" "HEPHAESTUS" "YUGEN")

# F2FS constants
readonly F2FS_MOUNT_OPTS='compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge,lazytime'
readonly F2FS_MKFS_OPTS='extra_attr,inode_checksum,sb_checksum,compression'

# Host-specific variables (populated by set_host_config)
declare -a arr_drives=()
declare -a arr_partitions=()
declare -a arr_mkfs=()
declare -a arr_filesystems=()
lbaf=0
ses=1
kernel=''
mcode=''
host=''

# ============================================================================
# Utility Functions
# ============================================================================

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

error() {
    log "ERROR: $*" >&2
    exit 1
}

usage() {
    cat << EOF
Usage: $SCRIPT_NAME <hostname>

Arch Linux installation preparation script.

Supported hosts:
    ASTER       - Laptop with single NVMe
    THEMIS      - Server with dual NVMe + sda (BOOT/ROOT)  
    HEPHAESTUS  - Workstation with SDA + RAID
    YUGEN       - Workstation with triple NVMe

Options:
    -h, --help  Show this help message

Example:
    $SCRIPT_NAME YUGEN

EOF
    exit 0
}

confirm_destructive() {
    local action="$1"
    echo ""
    echo "+--------------------------------------------------------+"
    echo "|  WARNING: DESTRUCTIVE OPERATION                         |"
    echo "+--------------------------------------------------------+"
    echo "|  Action: $action"
    echo "|  Host:   $host"
    echo "|  Drives: ${arr_drives[*]}"
    echo "+--------------------------------------------------------+"
    echo ""
    read -rp "Type 'YES' to continue: " confirm
    if [[ "$confirm" != "YES" ]]; then
        log "Operation cancelled by user."
        exit 1
    fi
}

connect_wifi() {
    log "TRYING TO CONNECT TO WIFI..."
    local max_attempts=6
    local attempt=1
    while (( attempt <= max_attempts )); do
        if /usr/bin/iwctl station wlan0 connect esher; then
            log "WiFi connection initiated (attempt $attempt/$max_attempts)."
            log "Waiting a few seconds for DHCP and routing..."
            sleep 5
            return 0
        fi
        log "WiFi attempt $attempt/$max_attempts failed, retrying in 5s..."
        (( attempt++ ))
        sleep 5
    done
    log "WARNING: WiFi connection failed after $max_attempts attempts. Continuing; wait_for_network may fail."
}

wait_for_network() {
    local max_attempts="${1:-30}"
    local attempt=0

    log "Waiting for network connectivity..."
    while (( attempt < max_attempts )); do
        if ping -c 1 -W 2 1.1.1.1 &>/dev/null; then
            log "Network is up."
            return 0
        fi
        (( attempt++ ))
        sleep 2
    done
    error "No network connectivity after $max_attempts attempts. Check your connection."
}

validate_host() {
    local input_host="$1"
    for valid in "${VALID_HOSTS[@]}"; do
        if [[ "$input_host" == "$valid" ]]; then
            return 0
        fi
    done
    return 1
}

# ============================================================================
# Host Configuration
# ============================================================================

set_host_config() {
    case "$host" in
        ASTER)
            arr_drives=('nvme0')
            arr_partitions=('nvme0n1')
            arr_mkfs=('nvme0n1p1' 'nvme0n1p2')
            arr_filesystems=('nvme0n1p2' 'nvme0n1p1')
            lbaf=0
            ses=1
            kernel='-tkg-aster'
            mcode='lib32-mesa vulkan-intel lib32-vulkan-intel lib32-opencl-nvidia lib32-vulkan-icd-loader lib32-nvidia-utils nvidia-open-dkms-tkg nvidia-settings-tkg opencl-nvidia-tkg vulkan-icd-loader nvidia-utils-tkg sound-theme-smooth schedtoold pikaur sof-firmware laptop-mode-tools-git upd72020x-fw wd719x-firmware ast-firmware aic94xx-firmware blesh-git'
            connect_wifi
            wait_for_network
            post_pacmanconf
            ;;
        THEMIS)
            arr_drives=('nvme0' 'nvme1' 'sda') # 'sdb'
            arr_partitions=('nvme0n1' 'nvme1n1' 'sda') # 'sdb'
            arr_mkfs=('nvme0n1p1' 'nvme1n1p1' 'nvme1n1p2' 'sda1' 'sda2') # 'sdb1'
            arr_filesystems=('sda2' 'sda1' 'nvme1n1p1' 'nvme1n1p2' 'nvme0n1p1') # 'sdb1'
            lbaf=0
            ses=1
            kernel='linux'
            mcode='mesa lib32-mesa vulkan-intel lib32-vulkan-intel'
            wait_for_network
            post_pacmanconf
            ;;
        YUGEN)
            arr_drives=('nvme0' 'nvme1' 'nvme2')
            arr_partitions=('nvme0n1' 'nvme1n1' 'nvme2n1')
            arr_mkfs=('nvme0n1p1' 'nvme0n1p2' 'nvme1n1p1' 'nvme2n1p1')
            arr_filesystems=('nvme0n1p2' 'nvme0n1p1' 'nvme1n1p1' 'nvme2n1p1')
            lbaf=1
            ses=2
            kernel='-tkg-yugen'
            mcode='lib32-opencl-nvidia lib32-vulkan-icd-loader lib32-nvidia-utils nvidia-open-dkms-tkg nvidia-settings-tkg opencl-nvidia-tkg vulkan-icd-loader nvidia-utils-tkg sound-theme-smooth upd72020x-fw wd719x-firmware ast-firmware aic94xx-firmware blesh-git pikaur'
            # YUGEN has no WiFi - requires Ethernet
            wait_for_network
            post_pacmanconf
            ;;
        *)
            error "Unknown host: '$host'. Valid hosts: ${VALID_HOSTS[*]}"
            ;;
    esac
    log "Host configuration loaded for: $host"
}

# ============================================================================
# Pacman Configuration
# ============================================================================

post_pacmanconf() {
    log "Configuring pacman.conf..."
    
    cat << 'EOF' > /etc/pacman.conf
[options]
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional
HoldPkg     = pacman glibc
ParallelDownloads = 100
Architecture = auto
DownloadUser = alpm
VerbosePkgLists
DisableSandbox
CheckSpace
UseSyslog
Color
# IgnorePkg   =
# IgnoreGroup =
# NoUpgrade   =
# NoExtract   =
# NoProgressBar
# CleanMethod = KeepInstalled
# XferCommand = /usr/bin/curl -L -C - -f -o %o %u
# XferCommand = /usr/bin/wget --passive-ftp -c -O %o %u

[core]
Include = /etc/pacman.d/mirrorlist

# [core-testing]
# Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF

    if [[ "$host" != 'THEMIS' ]]; then
        cat << 'EOF' >> /etc/pacman.conf

[tekne]
SigLevel = Optional TrustAll
Server = http://repo.tekne.sv
EOF
    fi
    
    log "pacman.conf configured."

/usr/bin/reflector --country 'United States' --latest 100 --sort rate --protocol 'https,ftp' --age 168 --save /etc/pacman.d/mirrorlist
}

# ============================================================================
# Drive Formatting
# ============================================================================

post_format() {
    if [[ "$host" == 'HEPHAESTUS' ]]; then
        log "Skipping NVMe format for HEPHAESTUS (uses SDA/RAID)."
        return 0
    fi

    confirm_destructive "FORMAT ALL NVME DRIVES"

    for drive in "${arr_drives[@]}"; do
        [[ "$drive" == nvme* ]] || continue
        log "Formatting NVMe drive: /dev/$drive"
        if nvme format /dev/"$drive" --namespace-id=1 --lbaf="$lbaf" --ses="$ses" --ms=1 --reset --force; then
            partprobe
            log "Drive $drive has been formatted successfully."
        else
            error "Failed to format drive: $drive"
        fi
    done
}

# ============================================================================
# Partitioning
# ============================================================================

post_partition() {
    log "Starting drive partitioning..."
    
    confirm_destructive "PARTITION ALL DRIVES"

    # Partition drives
    for partition in "${arr_partitions[@]}"; do
        local parameters=""
        
        case "$partition" in
            nvme0n1)
                if [[ "$host" == 'THEMIS' ]]; then
                    parameters="mklabel gpt mkpart xfs 0% 100% name 1 'libvirt-img' p free"
                else
                    parameters="mklabel gpt mkpart esp 0% 1% name 1 'BOOT' mkpart f2fs 1% 100% name 2 'ROOT' set 1 esp on p free"
                fi
                ;;
            sda)
                if [[ "$host" == 'THEMIS' ]]; then
                    parameters="mklabel gpt mkpart esp 0% 10% name 1 'BOOT' mkpart ext4 10% 100% name 2 'ROOT' set 1 esp on p free"
                else
                    parameters="mklabel gpt mkpart esp 0% 1% name 1 'BOOT' mkpart f2fs 1% 100% name 2 'ROOT' set 1 esp on p free"
                fi
                ;;
            sdb)
                if [[ "$host" == 'THEMIS' ]]; then
                    parameters="mklabel gpt mkpart primary xfs 0% 100% name 1 'GERBERA' p free"
                else
                    error "PARTITION FAILED: sdb only used on THEMIS"
                fi
                ;;
            nvme1n1)
                if [[ "$host" == 'THEMIS' ]]; then
                    parameters="mklabel gpt mkpart xfs 0% 96% name 1 'docker' p free mkpart f2fs 96% 100% name 2 'code' p free"
                else
                    local partition_name
                    partition_name='HOME'
                    parameters="mklabel gpt mkpart f2fs 1% 100% name 1 '$partition_name' p free"
                fi
                ;;
            nvme2n1|md126)
                parameters="mklabel gpt mkpart f2fs 1% 100% name 1 'VAR' p free"
                ;;
            *)
                error "PARTITION FAILED: Unknown drive '$partition'"
                ;;
        esac

        log "Partitioning /dev/$partition..."
        if /usr/bin/parted /dev/"$partition" -a optimal -- $parameters; then
            /usr/bin/partprobe
            log "Drive /dev/$partition has been partitioned."
        else
            error "Failed to partition /dev/$partition"
        fi

        if [[ "$host" == 'ASTER' ]]; then
            log "Partitions for $host are done."
            break
        fi
    done

    # Create filesystems
    log "Creating filesystems..."
    
    for filesystem in "${arr_mkfs[@]}"; do
        case "$filesystem" in
            nvme0n1p1)
                if [[ "$host" == 'THEMIS' ]]; then
                    log "Creating XFS filesystem (libvirt-img) on /dev/$filesystem..."
                    /usr/bin/mkfs.xfs -f -m reflink=1,crc=1 -L 'libvirt-img' /dev/"$filesystem"
                else
                    log "Creating FAT32 filesystem on /dev/$filesystem..."
                    /usr/bin/mkfs.vfat -F32 -n 'BOOT' /dev/"$filesystem"
                fi
                ;;
            sda1)
                log "Creating FAT32 filesystem on /dev/$filesystem..."
                /usr/bin/mkfs.vfat -F32 -n 'BOOT' /dev/"$filesystem"
                ;;
            nvme0n1p2)
                log "Creating F2FS filesystem (ROOT) on /dev/$filesystem..."
                /usr/bin/mkfs.f2fs -l 'ROOT' -i -O "$F2FS_MKFS_OPTS" /dev/"$filesystem"
                ;;
            sda2)
                if [[ "$host" == 'THEMIS' ]]; then
                    log "Creating ext4 filesystem (ROOT) on /dev/$filesystem..."
                    /usr/bin/mkfs.ext4 -F -L 'ROOT' /dev/"$filesystem"
                else
                    log "Creating F2FS filesystem (ROOT) on /dev/$filesystem..."
                    /usr/bin/mkfs.f2fs -l 'ROOT' -i -O "$F2FS_MKFS_OPTS" /dev/"$filesystem"
                fi
                ;;
            nvme1n1p1)
                if [[ "$host" == 'THEMIS' ]]; then
                    log "Creating XFS filesystem (docker) on /dev/$filesystem..."
                    /usr/bin/mkfs.xfs -f -n ftype=1 -L 'docker' /dev/"$filesystem"
                else
                    log "Creating F2FS filesystem (HOME) on /dev/$filesystem..."
                    /usr/bin/mkfs.f2fs -l 'HOME' -i -O "$F2FS_MKFS_OPTS" /dev/"$filesystem"
                fi
                ;;
            nvme1n1p2)
                if [[ "$host" == 'THEMIS' ]]; then
                    log "Creating F2FS filesystem (code) on /dev/$filesystem..."
                    /usr/bin/mkfs.f2fs -l 'code' -i -O extra_attr,inode_checksum,sb_checksum,compression /dev/"$filesystem"
                else
                    error "FILESYSTEM FAILED: nvme1n1p2 only used on THEMIS"
                fi
                ;;
            sdb1)
                if [[ "$host" == 'THEMIS' ]]; then
                    log "Creating XFS filesystem (GERBERA) on /dev/$filesystem..."
                    /usr/bin/mkfs.xfs -f -L 'GERBERA' /dev/"$filesystem"
                else
                    error "FILESYSTEM FAILED: sdb1 only used on THEMIS"
                fi
                ;;
            nvme2n1p1|md126p1)
                log "Creating F2FS filesystem (VAR) on /dev/$filesystem..."
                /usr/bin/mkfs.f2fs -l 'VAR' -i -O "$F2FS_MKFS_OPTS" /dev/"$filesystem"
                ;;
            *)
                error "FILESYSTEM FAILED: Unknown partition '$filesystem'"
                ;;
        esac
        /usr/bin/partprobe

        if [[ "$host" == 'ASTER' ]] && [[ "$filesystem" == 'nvme0n1p2' ]]; then
            log "Filesystems created for $host."
            break
        fi
    done
    
    log "Partitioning and filesystem creation complete."
}

# ============================================================================
# Mount Filesystems
# ============================================================================

post_mount() {
    log "Mounting filesystems..."

    for filesystem in "${arr_filesystems[@]}"; do
        case "$filesystem" in
            nvme0n1p2)
                log "Mounting ROOT filesystem: /dev/$filesystem -> /mnt"
                /usr/bin/mount -o "$F2FS_MOUNT_OPTS" /dev/"$filesystem" /mnt
                /usr/bin/mkdir -p /mnt/{boot,home,media,var}
                ;;
            sda2)
                log "Mounting ROOT filesystem: /dev/$filesystem -> /mnt"
                /usr/bin/mount -o noatime,lazytime,commit=120 /dev/"$filesystem" /mnt
                /usr/bin/mkdir -p /mnt/{boot,home,media,var}
                ;;
            nvme0n1p1)
                if [[ "$host" == 'THEMIS' ]]; then
                    log "Mounting libvirt images: /dev/$filesystem -> /mnt/var/lib/libvirt/images"
                    /usr/bin/mkdir -p /mnt/var/lib/libvirt/images
                    /usr/bin/mount -o noatime,nodiratime,attr2,inode64 /dev/"$filesystem" /mnt/var/lib/libvirt/images
                else
                    log "Mounting BOOT filesystem: /dev/$filesystem -> /mnt/boot"
                    /usr/bin/mount /dev/"$filesystem" /mnt/boot
                fi
                ;;
            sda1)
                log "Mounting BOOT filesystem: /dev/$filesystem -> /mnt/boot"
                /usr/bin/mount -o umask=0077 /dev/"$filesystem" /mnt/boot
                ;;
            nvme1n1p1)
                if [[ "$host" == 'THEMIS' ]]; then
                    log "Mounting docker: /dev/$filesystem -> /mnt/var/lib/docker"
                    /usr/bin/mkdir -p /mnt/var/lib/docker
                    /usr/bin/mount -o noatime,nodiratime,attr2,inode64 /dev/"$filesystem" /mnt/var/lib/docker
                else
                    log "Mounting home filesystem: /dev/$filesystem -> /mnt/home"
                    /usr/bin/mount -o "$F2FS_MOUNT_OPTS" /dev/"$filesystem" /mnt/home
                fi
                ;;
            nvme1n1p2)
                if [[ "$host" == 'THEMIS' ]]; then
                    log "Mounting code: /dev/$filesystem -> /mnt/srv/code"
                    /usr/bin/mkdir -p /mnt/srv/code
                    /usr/bin/mount -o noatime,lazytime,compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge /dev/"$filesystem" /mnt/srv/code
                else
                    error "MOUNT FAILED: nvme1n1p2 only used on THEMIS"
                fi
                ;;
            sdb1)
                if [[ "$host" == 'THEMIS' ]]; then
                    log "Mounting GERBERA: /dev/$filesystem -> /mnt/srv/docker/gerbera"
                    /usr/bin/mkdir -p /mnt/srv/docker/gerbera
                    /usr/bin/mount -o noatime,lazytime /dev/"$filesystem" /mnt/srv/docker/gerbera
                else
                    error "MOUNT FAILED: sdb1 only used on THEMIS"
                fi
                ;;
            nvme2n1p1|md126p1)
                log "Mounting VAR filesystem: /dev/$filesystem -> /mnt/var"
                /usr/bin/mount -o "$F2FS_MOUNT_OPTS" /dev/"$filesystem" /mnt/var
                ;;
            *)
                error "MOUNT FAILED: Unknown partition '$filesystem'"
                ;;
        esac
        partprobe
    done
    
    log "All filesystems mounted."
}

# ============================================================================
# Chroot Configuration
# ============================================================================

post_chroot_config() {
    log "Configuring system inside chroot..."

    # Ensure chroot uses our pacman.conf (mirrorlist, [themis], etc.)
    cp /etc/pacman.conf /mnt/etc/pacman.conf
    chown root:users /mnt/etc/pacman.conf

    # Determine boot disk based on host
    local boot_disk
    case "$host" in
        ASTER|YUGEN) boot_disk="/dev/nvme0n1" ;;
        THEMIS|HEPHAESTUS) boot_disk="/dev/sda" ;;
    esac

    # ASTER only: ensure mkinitcpio loads WiFi (mt7925e) and Bluetooth (btusb) before generating initramfs
    if [[ "$host" == 'ASTER' ]]; then
        log "Ensuring MODULES=(mt7925e btusb) in /mnt/etc/mkinitcpio.conf for ASTER..."
        sed -i 's/^MODULES=.*/MODULES=(mt7925e btusb)/' /mnt/etc/mkinitcpio.conf
        grep -q 'MODULES=(mt7925e btusb)' /mnt/etc/mkinitcpio.conf || echo 'MODULES=(mt7925e btusb)' >> /mnt/etc/mkinitcpio.conf
    fi

    arch-chroot /mnt /bin/bash <<CHROOT_EOF
set -euo pipefail

# Timezone & clock
ln -sf /usr/share/zoneinfo/America/El_Salvador /etc/localtime
hwclock --systohc

# Locale
sed -i 's|#en_US.UTF-8 UTF-8|en_US.UTF-8 UTF-8|g' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo 'KEYMAP=us' > /etc/vconsole.conf

# EFI boot entry (remove old entry if it exists)
/usr/bin/efibootmgr -B -b 0 2>/dev/null || true

/usr/bin/efibootmgr \
    --disk ${boot_disk} \
    --part 1 \
    --create \
    --label BOOT \
    --loader /vmlinuz-linux${kernel} \
    --unicode " root=LABEL=ROOT rw initrd=\intel-ucode.img initrd=\initramfs-linux${kernel}.img enable_guc=3 intel_pstate=passive kernel.split_lock_mitigate=0 split_lock_detect=off nowatchdog mitigations=off quiet loglevel=2 systemd.show_status=false rd.udev.log_level=2 mt7925e.disable_aspm=1"

# Generate initramfs
mkinitcpio -p linux${kernel}

echo "Automated chroot configuration complete."
CHROOT_EOF

    log "Running ansible for $host..."
    # Task 1: Install collections and overall requirements for ansible-playbook to run
    log "Installing Ansible community.general collection in chroot (required by ansible-role-xfce4)..."
    arch-chroot /mnt ansible-galaxy collection install community.general --force
    arch-chroot /mnt ansible-galaxy collection install -r /media/ansible-playbooks/requirements.yml -p /media/ansible-playbooks/collections
    arch-chroot /mnt ansible-galaxy collection install -r /media/ansible-playbooks/requirements.yml
    log "Installing Ansible community.general and requirements... completed"
    
    # Task 2: Run ansible-role-user, ansible-role-gpu, for all hosts
    log "Ansible roles user and gpu running..."
    arch-chroot /mnt ansible-playbook /media/ansible-playbooks/playbooks/main.yml --tags user --ask-vault-pass -e@/media/ansible-playbooks/group_vars_all/vault
    log "Ansible roles user and gpu completed."

    # Task 3: Run ansible-role-xfce4 for ASTER and YUGEN only
    if [[ "$host" == "ASTER" || "$host" == "YUGEN" ]]; then
        log "Running ansible roles xfce4 for $host..."
        arch-chroot /mnt ansible-playbook /media/ansible-playbooks/playbooks/main.yml --tags xfce4 --ask-vault-pass -e@/media/ansible-playbooks/group_vars_all/vault
        log "Ansible roles xfce4 completed for $host."
    fi
    log "Running ansible for $host... completed."

    # log "Entering interactive chroot for password setup..."
    # arch-chroot /mnt
}

# ============================================================================
# System Installation
# ============================================================================

post_start() {
    log "Starting system installation..."
    
    sed -i 's|#en_US.UTF-8 UTF-8|en_US.UTF-8 UTF-8|g' /etc/locale.gen

    post_pacmanconf

    # Re-check internet before downloading packages
    wait_for_network
    
    # Set NTP after network is confirmed up
    /usr/bin/timedatectl set-ntp true

    log "Synchronizing package databases..."
    pacman -Syy

    log "Installing base system with pacstrap..."
    /usr/bin/pacstrap -K /mnt base base-devel \
        intel-ucode $mcode linux${kernel} "linux${kernel}-headers" \
        linux-firmware linux-firmware-broadcom linux-firmware-liquidio linux-firmware-mellanox \
        linux-firmware-nfp linux-firmware-qlogic \
        dosfstools f2fs-tools exfatprogs exfat-utils \
        ansible-core ansible-lint ansible \
        python python-pip python-pipx python-passlib \
        vim vim-vital vim-tagbar vim-tabular vim-syntastic vim-supertab vim-spell-es vim-spell-en \
        vim-nerdtree vim-nerdcommenter vim-indent-object vim-gitgutter vim-devicons vim-ansible \
        mlocate bash-completion pkgfile efibootmgr acpi acpid iwd wpa_supplicant \
        wireless-regdb rsync git wget reflector iptables-nft less usb_modeswitch libsecret gzip tar zlib xz \
        nvme-cli openssh openssl screen sudo gnupg bind cronie inetutils whois zip unzip p7zip sed fuse \
	    mdadm jq curl make pkg-config dbus openbsd-netcat irqbalance schedtool shfmt \
        gsmartcontrol shellcheck bats cpupower devtools fakechroot fakeroot tcpdump parted xfsprogs \
        libsmbios fwupd pipewire pipewire-audio pipewire-libcamera pipewire-jack pipewire-alsa \
        pipewire-pulse lib32-pipewire lib32-pipewire-jack wireplumber wmctrl man

    log "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
    cp /mnt/etc/fstab /mnt/etc/fstab.origin
    sed -i 's|relatime|noatime|g' /mnt/etc/fstab

    ln -sf /usr/bin/vim /mnt/usr/bin/vi
    ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

    mv /mnt/etc/pacman.conf /mnt/etc/pacman.bak
    cp /etc/pacman.conf /mnt/etc/pacman.conf
    chown root:users /mnt/etc/pacman.conf

    echo "127.0.0.1 localhost $host.tekne.sv $host" >> /mnt/etc/hosts
    echo "$host" > /mnt/etc/hostname

    # Mount media partition only on hosts that have /dev/sda3
    if [[ "$host" == 'ASTER' || "$host" == 'HEPHAESTUS' ]]; then
        if [[ -b /dev/sda3 ]]; then
            log "Mounting media partition /dev/sda3 -> /mnt/media"
            mount /dev/sda3 /mnt/media
        else
            log "WARNING: /dev/sda3 not found, skipping media mount."
        fi
    fi

    if [[ "$host" == 'HEPHAESTUS' ]]; then
        log "Configuring mdadm for RAID..."
        mdadm --detail --scan >> /mnt/etc/mdadm.conf
    fi

    log "Installation complete. Configuring chroot..."
    log "Log file saved to: $LOG_FILE"
    
    post_chroot_config
}

# ============================================================================
# Main
# ============================================================================

main() {
    # Check for help flag
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
    fi

    # Check root privileges
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root."
    fi

    # Validate hostname argument
    if [[ -z "${1:-}" ]]; then
        echo "ERROR: Hostname argument required."
        echo ""
        usage
    fi

    host="$1"

    if ! validate_host "$host"; then
        error "Invalid host: '$host'. Valid hosts: ${VALID_HOSTS[*]}"
    fi

    log "============================================================"
    log "Arch Linux Installation Script Started"
    log "Host: $host"
    log "Log file: $LOG_FILE"
    log "============================================================"

    # Load host configuration
    set_host_config

    # Execute installation steps
    post_format
    post_partition
    post_mount
    post_start
}

main "$@"
