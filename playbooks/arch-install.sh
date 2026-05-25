#!/usr/bin/env bash
# arch-install.sh — Arch Linux installer with per-host profiles
#
# Usage (from live ISO):
#   ./arch-install.sh                    # auto-detect host
#   ./arch-install.sh THEMIS             # force profile
#   ./arch-install.sh --dry-run ASTER
#   ./arch-install.sh --from-task 5 THEMIS
#   ./arch-install.sh --vault-password-file ~/.vault_pass ASTER
#
# Environment:
#   ARCH_INSTALL_VAULT_PASS_FILE  — same as --vault-password-file
#
# Hosts: THEMIS (server), ASTER (laptop), YUGEN (pc)

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly VERSION="1.1.0"

readonly INSTALL_ROOT=/mnt
readonly ANSIBLE_ROOT=/media/ansible-playbooks
readonly VALID_HOSTS=(THEMIS ASTER YUGEN)

DRY_RUN=0
FORCE_HOST=""
FROM_TASK=0
VAULT_PASS_FILE="${ARCH_INSTALL_VAULT_PASS_FILE:-}"
LOG_FILE="/var/log/arch-install.log"

# Pipeline task indices (must match run_pipeline order)
readonly -a PIPELINE=(
  set_ntp
  format_nvme
  partition
  mkfs
  mount
  pacstrap
  configure_base
  configure_chroot
  run_ansible
)

# ---------------------------------------------------------------------------
# Host registry — extend per-machine overrides here
# ---------------------------------------------------------------------------
declare -A HOST_ROLE=(
  [THEMIS]=server
  [ASTER]=laptop
  [YUGEN]=pc
)

# NVMe devices (override per host if hardware differs)
declare -A HOST_NVME0=(
  [THEMIS]=/dev/nvme0
  [ASTER]=/dev/nvme0
  [YUGEN]=/dev/nvme0
)
declare -A HOST_NVME1=(
  [THEMIS]=/dev/nvme1
  [ASTER]=/dev/nvme1
  [YUGEN]=/dev/nvme1
)

declare -A HOST_KERNEL=(
  [THEMIS]=-tkg-themis
  [ASTER]=-tkg-aster
  [YUGEN]=-tkg-yugen
)

declare -A HOST_MCODE=(
  [THEMIS]='mesa lib32-mesa vulkan-intel lib32-vulkan-intel'
  [ASTER]='mesa lib32-mesa vulkan-intel lib32-vulkan-intel xorg-server '\
'lib32-opencl-nvidia-tkg lib32-vulkan-icd-loader lib32-nvidia-utils-tkg '\
'nvidia-open-dkms-tkg nvidia-settings-tkg opencl-nvidia-tkg vulkan-icd-loader '\
'nvidia-utils-tkg sof-firmware upd72020x-fw wd719x-firmware ast-firmware '\
'aic94xx-firmware brightnessctl libinput thermald tlp tlpui pipewire-audio '\
'libldac libfreeaptx'
  [YUGEN]='lib32-opencl-nvidia lib32-vulkan-icd-loader lib32-nvidia-utils '\
'nvidia-open-dkms-tkg nvidia-settings-tkg opencl-nvidia-tkg vulkan-icd-loader '\
'nvidia-utils-tkg sound-theme-smooth upd72020x-fw wd719x-firmware '\
'ast-firmware aic94xx-firmware'
)

# Extra EFI kernel parameters appended to the base cmdline (per host)
declare -A HOST_EFI_EXTRA=(
  [THEMIS]=''
  [ASTER]=' mt7925e.disable_aspm=1'
  [YUGEN]=''
)

# Intel-specific EFI params (omit on pure-NVIDIA profiles)
declare -A HOST_EFI_INTEL=(
  [THEMIS]=' enable_guc=3 intel_pstate=passive'
  [ASTER]=' enable_guc=3 intel_pstate=passive'
  [YUGEN]=''
)

# Shared pacstrap packages (host kernel, mcode, and headers are added per host)
readonly -a PACSTRAP_BASE_PKGS=(
  base base-devel intel-ucode
  linux-firmware linux-firmware-broadcom linux-firmware-liquidio
  linux-firmware-mellanox linux-firmware-nfp linux-firmware-qlogic
  dosfstools f2fs-tools exfatprogs exfat-utils
  python311 python-pip python-pipx python-passlib python-pipenv
  ansible-core ansible-lint ansible
  blesh-git pikaur schedtoold
  vim vim-tagbar vim-tabular vim-syntastic vim-supertab vim-spell-es vim-spell-en
  vim-nerdtree vim-nerdcommenter vim-devicons vim-ansible
  mlocate bash-completion pkgfile efibootmgr acpi acpid iwd wpa_supplicant
  wireless-regdb rsync git wget reflector iptables-nft less usb_modeswitch
  libsecret gzip tar zlib xz nvme-cli openssh openssl screen sudo gnupg bind
  cronie inetutils whois zip unzip p7zip sed fuse mdadm jq curl make pkg-config
  dbus openbsd-netcat irqbalance schedtool shfmt gsmartcontrol shellcheck bats
  cpupower devtools fakechroot fakeroot tcpdump parted xfsprogs libsmbios fwupd
  pipewire pipewire-alsa pipewire-jack pipewire-pulse wireplumber alsa-utils
  wmctrl man udisks2 restic
)

# F2FS mount options (all three share the same layout for now)
readonly F2FS_MNT_OPTS="compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge,lazytime"
readonly F2FS_MKFS_OPTS="-O extra_attr,inode_checksum,sb_checksum,compression"
readonly TIMEZONE="America/El_Salvador"

# THEMIS: USB media partition with offline pacman packages (live ISO, not chroot)
readonly THEMIS_USB_DEVICE=/dev/sdc3
readonly THEMIS_USB_MOUNT=/tmp/usb
readonly THEMIS_BINARIES_ROOT=/tmp/binaries

# ---------------------------------------------------------------------------
# Logging / execution helpers
# ---------------------------------------------------------------------------
log() {
  local level="$1"
  local msg
  shift
  msg="[$(date -Iseconds)] [$level] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

run() {
  local cmd_str
  printf -v cmd_str '%q ' "$@"
  if (( DRY_RUN )); then
    log DRY-RUN "${cmd_str% }"
  else
    log RUN "${cmd_str% }"
    "$@"
  fi
}

# Run a command in the install root: arch-chroot MNT CMD [ARGS...]
chroot_run() {
  run arch-chroot "$1" "${@:2}"
}

# Run bash -c SCRIPT in the install root (redirects, globs, ||, etc.).
chroot_bash() {
  run arch-chroot "$1" bash -c "$2"
}

die() {
  log ERROR "$*"
  exit 1
}

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root (e.g. from Arch live ISO)."
}

require_live_cmds() {
  local missing=() cmd
  for cmd in nvme parted mkfs.vfat mkfs.f2fs mount pacman pacstrap genfstab reflector \
    arch-chroot efibootmgr timedatectl partprobe curl ping repo-add; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || die "Missing live ISO commands: ${missing[*]}"
}

require_mounted() {
  local mnt="${1:-$INSTALL_ROOT}"
  if (( DRY_RUN )); then
    log DRY-RUN "require_mounted: $mnt (check skipped)"
    return 0
  fi
  mountpoint -q "$mnt" || die "Root not mounted at $mnt — run task_mount first"
}

require_chroot_ready() {
  local mnt="${1:-$INSTALL_ROOT}"
  require_mounted "$mnt"
  if (( DRY_RUN )); then
    log DRY-RUN "require_chroot_ready: $mnt (check skipped)"
    return 0
  fi
  [[ -d "$mnt/etc" ]] || die "Chroot not installed at $mnt — run task_pacstrap first"
}

require_chroot_cmds() {
  local mnt="${1:-$INSTALL_ROOT}"
  local missing=() cmd
  if (( DRY_RUN )); then
    return 0
  fi
  for cmd in git ansible-playbook ansible-galaxy mkinitcpio locale-gen; do
    chroot_run "$mnt" command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || die "Missing commands in chroot: ${missing[*]}"
}

wait_for_network() {
  local tries=30 i
  log INFO "Waiting for network connectivity..."
  if (( DRY_RUN )); then
    log DRY-RUN "wait_for_network (skipped)"
    return 0
  fi
  for ((i = 1; i <= tries; i++)); do
    if ping -c1 -W2 archlinux.org &>/dev/null \
      || curl -fsSL --max-time 5 https://archlinux.org &>/dev/null; then
      log INFO "Network is up."
      return 0
    fi
    sleep 2
  done
  die "Network unavailable after $tries attempts."
}

partprobe_host() {
  local host="$1"
  run partprobe "$(nvme_ns "${HOST_NVME0[$host]}")" "$(nvme_ns "${HOST_NVME1[$host]}")" 2>/dev/null || true
}

efi_cmdline_for_host() {
  local host="$1" kernel="$2"
  local line
  line=" root=LABEL=ROOT rw initrd=\\intel-ucode.img initrd=\\initramfs-linux${kernel}.img"
  line+=" kernel.split_lock_mitigate=0 split_lock_detect=off nowatchdog mitigations=off"
  line+=" quiet loglevel=2 systemd.show_status=false rd.udev.log_level=2"
  line+="${HOST_EFI_INTEL[$host]:-}"
  line+="${HOST_EFI_EXTRA[$host]:-}"
  printf '%s' "$line"
}

themis_cache_bind_mounts() {
  local mnt="$1"
  local -a binds=(
    /mnt/cache/tmp:/tmp
    /mnt/cache/pacman:/var/cache/pacman/pkg
    /mnt/cache/docker-build:/var/cache/docker/build
    /mnt/cache/staging:/var/cache/staging
    /mnt/cache/build:/var/cache/build
  )
  local pair src dst
  for pair in "${binds[@]}"; do
    src="${pair%%:*}"
    dst="${pair##*:}"
    if (( DRY_RUN )); then
      log DRY-RUN "mount --bind $src $dst (in chroot)"
      continue
    fi
    if arch-chroot "$mnt" test -d "$src"; then
      chroot_run "$mnt" mount --bind "$src" "$dst"
    else
      log WARN "THEMIS: $src not found in chroot; skipping bind mount to $dst"
    fi
  done
}

# ---------------------------------------------------------------------------
# Host detection
# ---------------------------------------------------------------------------
detect_host() {
  local hint="${1:-}"

  if [[ -n "$hint" ]]; then
    log INFO "Using forced host profile: $hint"
    echo "$hint"
    return
  fi

  local product board hn name
  product="$(tr '[:lower:]' '[:upper:]' < /sys/class/dmi/id/product_name 2>/dev/null || true)"
  board="$(tr '[:lower:]' '[:upper:]' < /sys/class/dmi/id/board_name 2>/dev/null || true)"
  hn="$(tr '[:lower:]' '[:upper:]' < /etc/hostname 2>/dev/null || hostname 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)"

  for name in "${VALID_HOSTS[@]}"; do
    if [[ "$hn" == "$name" ]]; then
      log INFO "Detected host $name (exact hostname match)"
      echo "$name"
      return
    fi
  done
  for name in "${VALID_HOSTS[@]}"; do
    if [[ "$product" == *"$name"* || "$board" == *"$name"* ]]; then
      log INFO "Detected host $name (DMI product=$product board=$board)"
      echo "$name"
      return
    fi
  done

  log WARN "Could not detect host (product=$product board=$board hostname=$hn)"
  echo ""
}

validate_host() {
  local host="$1"
  [[ -n "${HOST_ROLE[$host]:-}" ]] || die "Unknown host '$host'. Valid: THEMIS, ASTER, YUGEN"
}

host_banner() {
  local host="$1"
  log INFO "Profile: $host (${HOST_ROLE[$host]})"
  log INFO "NVMe0: ${HOST_NVME0[$host]}  NVMe1: ${HOST_NVME1[$host]}"
  log INFO "Kernel: linux${HOST_KERNEL[$host]}"
}

# Resolve block device names after namespace creation
nvme_ns() {
  local ctrl="$1"   # e.g. /dev/nvme0
  echo "${ctrl}n1"
}

nvme_part() {
  local ctrl="$1"
  local partnum="$2"
  echo "$(nvme_ns "$ctrl")p${partnum}"
}

confirm_destroy() {
  local host="$1"
  echo
  echo "================================================================"
  echo "  DESTRUCTIVE INSTALL — host: $host (${HOST_ROLE[$host]})"
  echo "  This will SECURE-ERASE and repartition ALL data on:"
  echo "    ${HOST_NVME0[$host]} ($(nvme_ns "${HOST_NVME0[$host]}"))"
  echo "    ${HOST_NVME1[$host]} ($(nvme_ns "${HOST_NVME1[$host]}"))"
  echo "  Kernel package: linux${HOST_KERNEL[$host]}"
  echo "  Microcode/GPU stack: ${HOST_MCODE[$host]}"
  echo "================================================================"
  echo
  if (( DRY_RUN )); then
    log INFO "Dry-run mode — no changes will be made."
    return 0
  fi
  read -r -p "Type the host name ($host) to continue: " ans
  [[ "$ans" == "$host" ]] || die "Aborted."
}

# ---------------------------------------------------------------------------
# Task 0 — Enable NTP (before destructive disk work)
# ---------------------------------------------------------------------------
task_set_ntp() {
  log INFO "=== Task 0: timedatectl / enable NTP ==="
  run timedatectl
  run timedatectl set-ntp true
}

# ---------------------------------------------------------------------------
# Task 1 — NVMe secure format
# ---------------------------------------------------------------------------
task_format_nvme() {
  local host="$1"
  local ctrl0="${HOST_NVME0[$host]}"
  local ctrl1="${HOST_NVME1[$host]}"

  log INFO "=== Task 1: NVMe format (ses=2 secure erase) ==="

  for ctrl in "$ctrl0" "$ctrl1"; do
    [[ -b "$ctrl" ]] || die "Controller not found: $ctrl"
    run nvme format "$ctrl" \
      --namespace-id=1 \
      --lbaf=0 \
      --ses=2 \
      --ms=1 \
      --reset \
      --force
  done
  partprobe_host "$host"
}

# ---------------------------------------------------------------------------
# Task 2 — Partition disks
# ---------------------------------------------------------------------------
task_partition() {
  local host="$1"
  local disk0
  local disk1
  disk0="$(nvme_ns "${HOST_NVME0[$host]}")"
  disk1="$(nvme_ns "${HOST_NVME1[$host]}")"

  log INFO "=== Task 2: Partition (GPT) ==="

  [[ -b "$disk0" ]] || die "Disk not found: $disk0"
  [[ -b "$disk1" ]] || die "Disk not found: $disk1"

  # nvme0: ESP 0–1%, ROOT f2fs 1–100%
  run parted -a optimal "$disk0" --script \
    mklabel gpt \
    mkpart esp 0% 1% \
    mkpart f2fs 1% 100% \
    name 1 BOOT \
    name 2 ROOT \
    set 1 esp on \
    print free

  # nvme1: single DOCKER f2fs partition
  run parted -a optimal "$disk1" --script \
    mklabel gpt \
    mkpart f2fs 0% 100% \
    name 1 DOCKER \
    print free
  partprobe_host "$host"
}

# ---------------------------------------------------------------------------
# Task 3 — Create filesystems
# ---------------------------------------------------------------------------
task_mkfs() {
  local host="$1"
  local boot part_root part_docker

  boot="$(nvme_part "${HOST_NVME0[$host]}" 1)"
  part_root="$(nvme_part "${HOST_NVME0[$host]}" 2)"
  part_docker="$(nvme_part "${HOST_NVME1[$host]}" 1)"

  log INFO "=== Task 3: Create filesystems ==="
  log INFO "BOOT=$boot ROOT=$part_root DOCKER=$part_docker"

  run /usr/bin/mkfs.vfat -F32 -n BOOT "$boot"
  # shellcheck disable=SC2086
  run /usr/bin/mkfs.f2fs -l ROOT -i $F2FS_MKFS_OPTS "$part_root"
  # shellcheck disable=SC2086
  run /usr/bin/mkfs.f2fs -l DOCKER -i $F2FS_MKFS_OPTS "$part_docker"
}

# ---------------------------------------------------------------------------
# Task 4 — Mount filesystems
# ---------------------------------------------------------------------------
task_mount() {
  local host="$1"
  local boot part_root part_docker mnt_root mnt_docker

  boot="$(nvme_part "${HOST_NVME0[$host]}" 1)"
  part_root="$(nvme_part "${HOST_NVME0[$host]}" 2)"
  part_docker="$(nvme_part "${HOST_NVME1[$host]}" 1)"
  mnt_root="$INSTALL_ROOT"
  mnt_docker="${INSTALL_ROOT}/var/lib/docker"

  log INFO "=== Task 4: Mount filesystems ==="

  run mkdir -p "$mnt_root" "$mnt_docker"

  run /usr/bin/mount -o "$F2FS_MNT_OPTS" "$part_root" "$mnt_root"
  run mkdir -p "$mnt_root/boot"
  run /usr/bin/mount "$boot" "$mnt_root/boot"
  run mkdir -p "$mnt_docker"
  run /usr/bin/mount -o "$F2FS_MNT_OPTS" "$part_docker" "$mnt_docker"

  log INFO "Mounted:"
  if (( ! DRY_RUN )); then
    findmnt -R "$mnt_root" 2>/dev/null || mount | grep -E '^/dev/nvme' || true
  fi
}

# ---------------------------------------------------------------------------
# Task 5 — Install base system (pacstrap)
# ---------------------------------------------------------------------------
task_pacstrap() {
  local host="$1"
  local kernel="${HOST_KERNEL[$host]}"
  local mcode="${HOST_MCODE[$host]}"
  local mnt="$INSTALL_ROOT"

  log INFO "=== Task 5: pacstrap base system ==="
  log INFO "linux${kernel} + host mcode packages"

  require_mounted "$mnt"
  wait_for_network

  log INFO "Synchronizing package databases..."
  run pacman -Syy

  log INFO "Installing base system with pacstrap..."
  # shellcheck disable=SC2086
  run /usr/bin/pacstrap -K "$mnt" "${PACSTRAP_BASE_PKGS[@]}" \
    $mcode "linux${kernel}" "linux${kernel}-headers"
}

# ---------------------------------------------------------------------------
# Task 6 — fstab, symlinks, hosts, reflector, pacman repos
# ---------------------------------------------------------------------------
themis_stage_local_repo() {
  log INFO "THEMIS: staging local-repo from ${THEMIS_USB_DEVICE}..."

  if (( DRY_RUN )); then
    log DRY-RUN "mkdir -p ${THEMIS_USB_MOUNT}"
    log DRY-RUN "mount ${THEMIS_USB_DEVICE} ${THEMIS_USB_MOUNT}"
    log DRY-RUN "cp -ra ${THEMIS_USB_MOUNT}/binaries ${THEMIS_BINARIES_ROOT}"
    log DRY-RUN "repo-add ${THEMIS_BINARIES_ROOT}/themis/local-repo.db.tar.gz ${THEMIS_BINARIES_ROOT}/themis/*.pkg.tar.zst"
    return 0
  fi

  if [[ ! -b "${THEMIS_USB_DEVICE}" ]]; then
    log WARN "THEMIS: ${THEMIS_USB_DEVICE} not found; skipping local repo staging"
    return 0
  fi

  run mkdir -p "${THEMIS_USB_MOUNT}"
  if mountpoint -q "${THEMIS_USB_MOUNT}"; then
    log INFO "THEMIS: ${THEMIS_USB_MOUNT} already mounted"
  else
    run mount "${THEMIS_USB_DEVICE}" "${THEMIS_USB_MOUNT}"
  fi

  if [[ ! -d "${THEMIS_USB_MOUNT}/binaries" ]]; then
    log WARN "THEMIS: ${THEMIS_USB_MOUNT}/binaries not found; skipping repo-add"
    return 0
  fi

  run cp -ra "${THEMIS_USB_MOUNT}/binaries" "${THEMIS_BINARIES_ROOT}"
  if [[ ! -d "${THEMIS_BINARIES_ROOT}/themis" ]]; then
    log WARN "THEMIS: ${THEMIS_BINARIES_ROOT}/themis missing after copy; skipping repo-add"
    return 0
  fi

  # shellcheck disable=SC2086
  run bash -c "repo-add ${THEMIS_BINARIES_ROOT}/themis/local-repo.db.tar.gz ${THEMIS_BINARIES_ROOT}/themis/*.pkg.tar.zst"
}

append_pacman_repo() {
  local host="$1"
  local conf="${INSTALL_ROOT}/etc/pacman.conf"
  local section

  case "$host" in
    THEMIS)
      section=local-repo
      themis_stage_local_repo
      ;;
    ASTER|YUGEN) section=tekne ;;
    *) die "append_pacman_repo: unhandled host '$host'" ;;
  esac

  if (( DRY_RUN )); then
    log DRY-RUN "append [$section] to $conf (if missing)"
    return 0
  fi
  if grep -q "^\[${section}\]" "$conf" 2>/dev/null; then
    log INFO "pacman.conf already has [$section]; skipping append"
    return 0
  fi

  log INFO "Appending [$section] to $conf"
  case "$section" in
    local-repo)
      cat >> "$conf" <<'EOF'

[local-repo]
SigLevel = Optional TrustAll
Server = file:///tmp/binaries/themis
EOF
      ;;
    tekne)
      cat >> "$conf" <<'EOF'

[tekne]
SigLevel = Optional TrustAll
Server = http://repo.tekne.sv
EOF
      ;;
  esac
}

task_configure_base() {
  local host="$1"
  local mnt="$INSTALL_ROOT"

  log INFO "=== Task 6: post-install base configuration ==="

  require_chroot_ready "$mnt"
  wait_for_network

  log INFO "Generating fstab..."
  if (( DRY_RUN )); then
    log DRY-RUN "genfstab -U $mnt >> $mnt/etc/fstab"
    log DRY-RUN "cp $mnt/etc/fstab $mnt/etc/fstab.origin"
    log DRY-RUN "sed -i relatime->noatime on $mnt/etc/fstab"
  elif [[ -f "$mnt/etc/fstab" ]] && grep -q 'LABEL=ROOT' "$mnt/etc/fstab" 2>/dev/null; then
    log INFO "fstab already lists LABEL=ROOT; skipping genfstab"
    cp "$mnt/etc/fstab" "$mnt/etc/fstab.origin"
    sed -i 's|relatime|noatime|g' "$mnt/etc/fstab"
  else
    genfstab -U "$mnt" >> "$mnt/etc/fstab"
    cp "$mnt/etc/fstab" "$mnt/etc/fstab.origin"
    sed -i 's|relatime|noatime|g' "$mnt/etc/fstab"
  fi

  run ln -sf /usr/bin/vim "$mnt/usr/bin/vi"
  if [[ -e /run/systemd/resolve/stub-resolv.conf ]]; then
    run ln -sf /run/systemd/resolve/stub-resolv.conf "$mnt/etc/resolv.conf"
  else
    log WARN "stub-resolv.conf not found on host; skipping resolv.conf symlink"
  fi

  log INFO "Updating mirrorlist with reflector..."
  run /usr/bin/reflector \
    --country 'United States' \
    --latest 100 \
    --sort rate \
    --protocol 'https,ftp' \
    --age 168 \
    --save /etc/pacman.d/mirrorlist
  if (( ! DRY_RUN )) && [[ -f /etc/pacman.d/mirrorlist ]]; then
    run mkdir -p "$mnt/etc/pacman.d"
    run cp /etc/pacman.d/mirrorlist "$mnt/etc/pacman.d/mirrorlist"
  fi

  append_pacman_repo "$host"
}

# ---------------------------------------------------------------------------
# Task 7 — locale, timezone, hostname, EFI boot, initramfs (arch-chroot)
# ---------------------------------------------------------------------------
task_configure_chroot() {
  local host="$1"
  local mnt="$INSTALL_ROOT"
  local kernel="${HOST_KERNEL[$host]}"
  local boot_disk efi_params
  boot_disk="$(nvme_ns "${HOST_NVME0[$host]}")"
  efi_params="$(efi_cmdline_for_host "$host" "$kernel")"

  log INFO "=== Task 7: chroot locale, timezone, hostname, EFI boot ==="
  log INFO "boot_disk=$boot_disk kernel=linux${kernel}"

  require_chroot_ready "$mnt"

  chroot_run "$mnt" ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  chroot_run "$mnt" hwclock --systohc
  chroot_run "$mnt" sed -i 's|#en_US.UTF-8 UTF-8|en_US.UTF-8 UTF-8|g' /etc/locale.gen
  chroot_run "$mnt" locale-gen
  chroot_bash "$mnt" "echo 'LANG=en_US.UTF-8' > /etc/locale.conf"
  chroot_bash "$mnt" "echo 'KEYMAP=us' > /etc/vconsole.conf"
  chroot_bash "$mnt" "echo '127.0.0.1 localhost ${host}.tekne.sv ${host}' >> /etc/hosts"
  chroot_bash "$mnt" "echo '${host}' > /etc/hostname"

  if [[ "$host" == ASTER ]]; then
    log INFO "Ensuring MODULES=(mt7925e btusb) in mkinitcpio.conf for ASTER..."
    if (( DRY_RUN )); then
      log DRY-RUN "update mkinitcpio.conf MODULES=(mt7925e btusb) in chroot"
    else
      chroot_run "$mnt" sed -i 's/^MODULES=.*/MODULES=(mt7925e btusb)/' /etc/mkinitcpio.conf
      chroot_bash "$mnt" "grep -q 'MODULES=(mt7925e btusb)' /etc/mkinitcpio.conf || echo 'MODULES=(mt7925e btusb)' >> /etc/mkinitcpio.conf"
    fi
  fi

  log INFO "Configuring EFI boot entry..."
  chroot_bash "$mnt" 'efibootmgr -B -b 0 2>/dev/null || true'
  chroot_run "$mnt" efibootmgr \
    --disk "$boot_disk" \
    --part 1 \
    --create \
    --label BOOT \
    --loader "/vmlinuz-linux${kernel}" \
    --unicode "$efi_params"

  log INFO "Generating initramfs (linux${kernel})..."
  chroot_run "$mnt" mkinitcpio -p "linux${kernel}"

  log INFO "Reloading systemd units..."
  run systemctl daemon-reload
  chroot_run "$mnt" systemctl daemon-reload

  chroot_bash "$mnt" 'mkdir -p /var/cache/{pacman/pkg,docker/build,staging,build}'

  if [[ "$host" == THEMIS ]]; then
    log INFO "THEMIS: cache bind mounts (skipped if /mnt/cache not present)..."
    themis_cache_bind_mounts "$mnt"
    log INFO "THEMIS-specific chroot configuration completed."
  fi
}

# ---------------------------------------------------------------------------
# Task 8 — Ansible playbooks in chroot
# ---------------------------------------------------------------------------
task_run_ansible() {
  local host="$1"
  local mnt="$INSTALL_ROOT"
  local -a vault_args=()

  log INFO "=== Task 8: Ansible (user, os; xfce4 on ASTER) ==="

  require_chroot_ready "$mnt"
  require_chroot_cmds "$mnt"
  wait_for_network

  if [[ -n "$VAULT_PASS_FILE" ]]; then
    [[ -r "$VAULT_PASS_FILE" ]] || die "Vault password file not readable: $VAULT_PASS_FILE"
    vault_args=(--vault-password-file "$VAULT_PASS_FILE")
  else
    vault_args=(--ask-vault-pass)
  fi

  if [[ -d "${mnt}${ANSIBLE_ROOT}/.git" ]]; then
    log INFO "ansible-playbooks already present at $ANSIBLE_ROOT, skipping clone"
  else
    chroot_run "$mnt" mkdir -p /media
    chroot_run "$mnt" git clone https://github.com/tekne-ops/ansible-playbooks "$ANSIBLE_ROOT"
  fi

  log INFO "Installing Ansible collections..."
  chroot_run "$mnt" ansible-galaxy collection install community.general --force
  chroot_run "$mnt" ansible-galaxy collection install -r "${ANSIBLE_ROOT}/requirements.yml" \
    -p "${ANSIBLE_ROOT}/collections"
  chroot_run "$mnt" ansible-galaxy collection install -r "${ANSIBLE_ROOT}/requirements.yml"

  log INFO "Running ansible-playbook (tags: user, os)..."
  chroot_run "$mnt" ansible-playbook "${ANSIBLE_ROOT}/playbooks/main.yml" \
    --tags user,os \
    "${vault_args[@]}" \
    -e@"${ANSIBLE_ROOT}/group_vars_all/vault"

  if [[ "$host" == ASTER ]]; then
    log INFO "Running ansible-playbook (tags: xfce4) for ASTER..."
    chroot_run "$mnt" ansible-playbook "${ANSIBLE_ROOT}/playbooks/main.yml" \
      --tags xfce4 \
      "${vault_args[@]}" \
      -e@"${ANSIBLE_ROOT}/group_vars_all/vault"
  fi

  log INFO "Ansible configuration completed."
}

task_summary() {
  local host="$1"
  log INFO "Install summary: $host (${HOST_ROLE[$host]}) on ${INSTALL_ROOT}"
  log INFO "Kernel: linux${HOST_KERNEL[$host]} | log: $LOG_FILE"
}

run_pipeline() {
  local host="$1"
  local t name total="${#PIPELINE[@]}"

  if (( FROM_TASK < 0 || FROM_TASK >= total )); then
    die "Invalid --from-task $FROM_TASK (valid: 0-$((total - 1)))"
  fi

  for ((t = FROM_TASK; t < total; t++)); do
    name="${PIPELINE[$t]}"
    log INFO "--- Pipeline [$t/${total}] task_${name} ---"
    "task_${name}" "$host"
  done
}

# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
$SCRIPT_NAME v$VERSION — Arch install with host profiles

Usage:
  $SCRIPT_NAME [OPTIONS] [HOST]

Options:
  -n, --dry-run              Print commands without executing
  --from-task N              Start at pipeline task N (0-$(( ${#PIPELINE[@]} - 1 )))
  --vault-password-file PATH Ansible vault password file (non-interactive)
  -h, --help                 Show this help

Hosts:
  THEMIS   server
  ASTER    laptop
  YUGEN    pc

If HOST is omitted, detection uses DMI product/board name or hostname.

Pipeline tasks (use --from-task N):
  0  timedatectl + NTP
  1  nvme secure format
  2  GPT partition
  3  mkfs
  4  mount under $INSTALL_ROOT
  5  pacstrap
  6  fstab, reflector, pacman repos
  7  chroot locale, EFI, mkinitcpio, THEMIS cache binds
  8  ansible-playbooks (xfce4 on ASTER only)
EOF
}

validate_from_task() {
  local n="${1:-}"
  [[ "$n" =~ ^[0-9]+$ ]] || die "--from-task requires a number (0-$((${#PIPELINE[@]} - 1)))"
  (( n >= 0 && n < ${#PIPELINE[@]} )) || die "Invalid --from-task $n (valid: 0-$((${#PIPELINE[@]} - 1)))"
  FROM_TASK=$n
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run) DRY_RUN=1 ;;
      --from-task)
        shift
        [[ $# -gt 0 ]] || die "--from-task requires a task number"
        validate_from_task "$1"
        ;;
      --vault-password-file)
        shift
        [[ $# -gt 0 ]] || die "--vault-password-file requires a path"
        VAULT_PASS_FILE=$1
        ;;
      -h|--help) usage; exit 0 ;;
      THEMIS|ASTER|YUGEN) FORCE_HOST="$1" ;;
      *) die "Unknown argument: $1 (try --help)" ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"

  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/arch-install.log"

  require_root
  require_live_cmds

  local host
  host="$(detect_host "$FORCE_HOST")"
  [[ -n "$host" ]] || die "Could not detect host. Pass one of: ${VALID_HOSTS[*]}"
  validate_host "$host"
  host_banner "$host"

  if (( FROM_TASK == 0 )); then
    confirm_destroy "$host"
  else
    log INFO "Resuming from task $FROM_TASK (${PIPELINE[$FROM_TASK]}) — skipping destroy confirmation"
  fi

  run_pipeline "$host"
  task_summary "$host"

  log INFO "=== Install pipeline complete for $host ==="
}

main "$@"
