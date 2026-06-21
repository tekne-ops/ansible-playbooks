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
# Hosts: THEMIS (server), ASTER (laptop), YUGEN (pc), KVM (VM: vda BOOT/ROOT, vdb HOME)

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly VERSION="1.1.0"

readonly INSTALL_ROOT="${TEKNE_INSTALL_ROOT:-/mnt}"
readonly ANSIBLE_ROOT=/media/ansible-playbooks
readonly ANSIBLE_COLLECTIONS_ROOT=/media/ansible-collections
readonly CHROOT_VAULT_PASS=/root/.ansible_vault_pass
readonly VALID_HOSTS=(THEMIS ASTER YUGEN KVM)

DRY_RUN=${DRY_RUN:-0}
FORCE_HOST="${FORCE_HOST:-}"
FROM_TASK=${FROM_TASK:-0}
SKIP_NETWORK_WAIT=${SKIP_NETWORK_WAIT:-0}
VAULT_PASS_FILE="${VAULT_PASS_FILE:-${ARCH_INSTALL_VAULT_PASS_FILE:-}}"
LOG_FILE="${LOG_FILE:-/var/log/arch-install.log}"

# Pipeline task indices (must match run_pipeline order)
readonly -a PIPELINE=(
  set_ntp
  format_nvme
  partition
  mkfs
  mount
  configure_pacman
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
  [KVM]=vm
)

# Disk0 = BOOT + ROOT; disk1 layout in HOST_DISK1_LAYOUT
declare -A HOST_DISK0=(
  [THEMIS]=/dev/nvme0
  [ASTER]=/dev/nvme0
  [YUGEN]=/dev/nvme0
  [KVM]=/dev/vda
)
declare -A HOST_DISK1=(
  [THEMIS]=/dev/nvme1
  [ASTER]=/dev/nvme1
  [YUGEN]=/dev/nvme1
  [KVM]=/dev/vdb
)

# nvme = namespace disk (nvme0n1); virt = whole virtio disk (vda)
declare -A HOST_STORAGE_KIND=(
  [THEMIS]=nvme
  [ASTER]=nvme
  [YUGEN]=nvme
  [KVM]=virt
)

# Second disk: docker (/var/lib/docker) or home (/home) — ASTER/KVM use home
declare -A HOST_DISK1_LAYOUT=(
  [THEMIS]=docker
  [ASTER]=home
  [YUGEN]=docker
  [KVM]=home
)

declare -A HOST_KERNEL=(
  [THEMIS]=-tkg-themis
  [ASTER]=-tkg-aster
  [YUGEN]=-tkg-yugen
  [KVM]=-tkg-themis
)

declare -A HOST_MCODE=(
  [THEMIS]='mesa lib32-mesa vulkan-intel lib32-vulkan-intel'
  [KVM]='mesa lib32-mesa vulkan-intel lib32-vulkan-intel'
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
  [KVM]=''
)

# Intel-specific EFI params (omit on pure-NVIDIA profiles)
declare -A HOST_EFI_INTEL=(
  [THEMIS]=' enable_guc=3 intel_pstate=passive'
  [ASTER]=''
  [YUGEN]=''
  [KVM]=''
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
  wmctrl man udisks2 restic noto-fonts noto-fonts-emoji ttf-dejavu ttf-liberation
  ttf-ms-win10-auto systemd ukify
)

# F2FS mount options (all three share the same layout for now)
readonly F2FS_MNT_OPTS="compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge,lazytime"
readonly F2FS_MKFS_OPTS="-O extra_attr,inode_checksum,sb_checksum,compression"
# Fixed ESP size — UKI embeds kernel + initramfs + microcode (~100–200 MiB per image).
readonly ESP_SIZE_MIB=1024
readonly TIMEZONE="America/El_Salvador"

# THEMIS: offline pacman repo from git + LFS (live ISO, not chroot)
readonly THEMIS_BINARIES_REPO=https://github.com/tekne-ops/binaries.git
readonly THEMIS_BINARIES_ROOT=/tmp/binaries

# ---------------------------------------------------------------------------
# Logging / execution helpers
# ---------------------------------------------------------------------------
log() {
  local level="$1"
  local msg
  shift
  msg="[$(date -Iseconds)] [$level] $*"
  # stderr so command substitution (e.g. host=$(detect_host KVM)) stays clean
  echo "$msg" | tee -a "$LOG_FILE" >&2
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

# Arch has no /usr/bin/command (coreutils); lookup must run in bash, not via arch-chroot CMD.
chroot_has_cmd() {
  local mnt="$1" cmd="$2"
  if (( DRY_RUN )); then
    return 0
  fi
  chroot_bash "$mnt" "command -v '$cmd' >/dev/null 2>&1"
}

require_chroot_cmds() {
  local mnt="${1:-$INSTALL_ROOT}"
  local missing=() cmd
  if (( DRY_RUN )); then
    return 0
  fi
  for cmd in git ansible-playbook ansible-galaxy ansible-vault mkinitcpio locale-gen; do
    chroot_has_cmd "$mnt" "$cmd" || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || die "Missing commands in chroot: ${missing[*]}"
}

_arch_install_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

network_is_up() {
  local target
  for target in 1.1.1.1 9.9.9.9 8.8.8.8; do
    if ping -c1 -W3 "$target" &>/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

live_bring_up_network() {
  log INFO "Starting live ISO network services (systemd-networkd, iwd)..."
  systemctl start systemd-networkd.service 2>/dev/null || true
  systemctl start systemd-resolved.service 2>/dev/null || true
  systemctl start iwd.service 2>/dev/null || true
  sleep 3
}

log_network_diagnostics() {
  local line
  log ERROR "Network diagnostics (connect WiFi/Ethernet on the live ISO):"
  while IFS= read -r line; do
    log ERROR "  ${line}"
  done < <(ip -br link 2>/dev/null || true)
  while IFS= read -r line; do
    log ERROR "  route: ${line}"
  done < <(ip route 2>/dev/null || true)
  if command -v resolvectl &>/dev/null; then
    while IFS= read -r line; do
      log ERROR "  ${line}"
    done < <(resolvectl status 2>/dev/null | head -15 || true)
  fi
  log ERROR "  Try: iwctl station <iface> connect esher --passphrase '<pass>'"
  log ERROR "  Or re-run with --skip-network-wait after connecting manually."
}

live_wifi_iface() {
  ls /sys/class/net 2>/dev/null | grep -E '^wl' | head -1 || true
}

live_has_ethernet_carrier() {
  local iface carrier
  for iface in $(ls /sys/class/net 2>/dev/null | grep -E '^en|^eth' || true); do
    carrier="$(cat "/sys/class/net/${iface}/carrier" 2>/dev/null || echo 0)"
    [[ "$carrier" == "1" ]] && return 0
  done
  return 1
}

resolve_wifi_passphrase() {
  local ssid="${TEKNE_WIFI_SSID:-esher}"
  local vault_file pass

  if [[ -n "${TEKNE_WIFI_PASSPHRASE:-}" ]]; then
    printf '%s' "$TEKNE_WIFI_PASSPHRASE"
    return 0
  fi

  vault_file="$(_arch_install_dir)/../group_vars_all/vault"
  if [[ -n "$VAULT_PASS_FILE" && -r "$VAULT_PASS_FILE" && -f "$vault_file" ]] \
    && command -v ansible-vault &>/dev/null; then
    pass="$(ansible-vault view "$vault_file" --vault-password-file "$VAULT_PASS_FILE" 2>/dev/null \
      | awk -F: '/^os_wifi_passphrase:/ {
          sub(/^[^:]*:[[:space:]]*/, "")
          gsub(/^["'\''"]|["'\''"]$/, "")
          print
          exit
        }')" || true
    if [[ -n "$pass" ]]; then
      printf '%s' "$pass"
      return 0
    fi
  fi

  if [[ -t 0 ]]; then
    read -rs -p "WiFi passphrase for ${ssid}: " pass
    echo >&2
    if [[ -n "$pass" ]]; then
      printf '%s' "$pass"
      return 0
    fi
  fi
  return 1
}

connect_wifi_live() {
  local host="$1"
  local ssid iface pass attempt max_attempts=6

  [[ "$host" == ASTER ]] || return 0
  network_is_up && return 0

  ssid="${TEKNE_WIFI_SSID:-esher}"
  iface="$(live_wifi_iface)"
  if live_has_ethernet_carrier; then
    log INFO "Ethernet link up; skipping WiFi connect (waiting for DHCP/routing)."
    return 0
  fi
  if [[ -z "$iface" ]]; then
    log WARN "ASTER: no WiFi interface (wl*) found — connect Ethernet or WiFi manually (nmtui/iwctl)."
    return 0
  fi
  command -v iwctl &>/dev/null || {
    log WARN "iwctl not found — connect WiFi manually before continuing."
    return 0
  }

  log INFO "ASTER: bringing up WiFi (${ssid} on ${iface})..."
  systemctl is-active --quiet iwd 2>/dev/null || systemctl start iwd 2>/dev/null || true
  sleep 2

  pass="$(resolve_wifi_passphrase)" || pass=""
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if [[ -n "$pass" ]]; then
      if iwctl station "$iface" connect "$ssid" --passphrase "$pass" &>/dev/null; then
        log INFO "WiFi connect initiated (attempt ${attempt}/${max_attempts})."
        sleep 5
        network_is_up && return 0
      fi
    elif iwctl station "$iface" connect "$ssid" &>/dev/null; then
      log INFO "WiFi connect initiated without passphrase (attempt ${attempt}/${max_attempts})."
      sleep 5
      network_is_up && return 0
    fi
    log INFO "  WiFi attempt ${attempt}/${max_attempts} failed, retrying in 5s..."
    sleep 5
  done
  log WARN "WiFi connect failed after ${max_attempts} attempts; wait_for_network may still fail."
}

ensure_live_network() {
  local host="$1"

  if (( DRY_RUN || SKIP_NETWORK_WAIT )); then
    log DRY-RUN "ensure_live_network (skipped)"
    return 0
  fi
  if network_is_up; then
    log INFO "Network already up."
    export TEKNE_NETWORK_LIVE_OK=1
    return 0
  fi
  live_bring_up_network
  connect_wifi_live "$host"
  wait_for_network
  export TEKNE_NETWORK_LIVE_OK=1
}

wait_for_network() {
  local tries="${NETWORK_WAIT_ATTEMPTS:-30}" i
  if (( DRY_RUN || SKIP_NETWORK_WAIT )); then
    log DRY-RUN "wait_for_network (skipped)"
    return 0
  fi
  if [[ "${TEKNE_NETWORK_LIVE_OK:-0}" == 1 ]] && network_is_up; then
    return 0
  fi
  log INFO "Waiting for network connectivity..."
  for ((i = 1; i <= tries; i++)); do
    if network_is_up; then
      log INFO "Network is up (attempt ${i}/${tries})."
      export TEKNE_NETWORK_LIVE_OK=1
      return 0
    fi
    log INFO "  attempt ${i}/${tries}: no IP connectivity yet (check WiFi/Ethernet)..."
    sleep 2
  done
  log_network_diagnostics
  die "Network unavailable after ${tries} attempts (~$((tries * 2))s). Connect on the live ISO, or re-run with --skip-network-wait."
}

prepare_live_pacman_for_archinstall() {
  local host="$1"

  if (( DRY_RUN )); then
    log DRY-RUN "prepare_live_pacman_for_archinstall $host"
    return 0
  fi

  log INFO "=== Live ISO pacman (repos + mirrorlist) before archinstall ==="
  append_pacman_repo "$host"

  log INFO "Updating live mirrorlist with reflector..."
  run /usr/bin/reflector \
    --country 'United States' \
    --latest 100 \
    --sort rate \
    --protocol 'https,ftp' \
    --age 168 \
    --save /etc/pacman.d/mirrorlist

  log INFO "Synchronizing live package databases..."
  run pacman -Syy
}

# Copy vault password file into chroot (live-ISO paths are not visible in arch-chroot).
chroot_stage_vault_pass() {
  local mnt="$1"
  if [[ -z "$VAULT_PASS_FILE" ]]; then
    return 0
  fi
  log INFO "Staging vault password file at ${CHROOT_VAULT_PASS} in chroot..."
  run mkdir -p "$mnt/root"
  run chmod 700 "$mnt/root"
  run cp "$VAULT_PASS_FILE" "$mnt${CHROOT_VAULT_PASS}"
  run chmod 600 "$mnt${CHROOT_VAULT_PASS}"
}

chroot_cleanup_vault_pass() {
  local mnt="$1"
  if [[ -z "$VAULT_PASS_FILE" ]]; then
    return 0
  fi
  run rm -f "$mnt${CHROOT_VAULT_PASS}"
}

# efibootmgr needs host NVRAM inside the install chroot (Arch wiki install guide).
chroot_mount_efivars() {
  local mnt="$1"
  if (( DRY_RUN )); then
    log DRY-RUN "mount --bind /sys/firmware/efi/efivars ${mnt}/sys/firmware/efi/efivars"
    return 0
  fi
  [[ -d /sys/firmware/efi/efivars ]] || {
    log WARN "Host efivars not available; efibootmgr may not persist boot entries"
    return 0
  }
  run mkdir -p "$mnt/sys/firmware/efi/efivars"
  if mountpoint -q "$mnt/sys/firmware/efi/efivars"; then
    return 0
  fi
  run mount --bind /sys/firmware/efi/efivars "$mnt/sys/firmware/efi/efivars"
}

chroot_umount_efivars() {
  local mnt="$1"
  if (( DRY_RUN )); then
    log DRY-RUN "umount ${mnt}/sys/firmware/efi/efivars (if mounted)"
    return 0
  fi
  if mountpoint -q "$mnt/sys/firmware/efi/efivars"; then
    run umount "$mnt/sys/firmware/efi/efivars"
  fi
}

# Regenerate UKI + EFI boot entry. Must run after Ansible: pacman installs in chroot
# (e.g. xfce4 on ASTER) trigger mkinitcpio hooks and leave the UKI/ESP out of sync
# if boot was configured earlier in the pipeline.
configure_uki_boot() {
  local host="$1"
  local mnt="$2"
  local kernel="${HOST_KERNEL[$host]}"
  local kernel_pkg boot_disk uki_efi params_line

  kernel_pkg="linux${kernel}"
  uki_efi="arch-${kernel_pkg}.efi"
  boot_disk="$(host_disk_path "$host" 0)"
  params_line="kernel.split_lock_mitigate=0 split_lock_detect=off nowatchdog mitigations=off quiet loglevel=2 systemd.show_status=false rd.udev.log_level=2${HOST_EFI_INTEL[$host]}${HOST_EFI_EXTRA[$host]}"

  log INFO "=== Finalize UKI boot (post-Ansible): boot_disk=$boot_disk kernel=${kernel_pkg} uki=${uki_efi} ==="

  if [[ "$host" == ASTER ]]; then
    log INFO "Ensuring MODULES=(mt7925e btusb) in mkinitcpio.conf for ASTER..."
    if (( DRY_RUN )); then
      log DRY-RUN "update mkinitcpio.conf MODULES=(mt7925e btusb) in chroot"
    else
      chroot_run "$mnt" sed -i 's/^MODULES=.*/MODULES=(mt7925e btusb)/' /etc/mkinitcpio.conf
      chroot_bash "$mnt" "grep -q 'MODULES=(mt7925e btusb)' /etc/mkinitcpio.conf || echo 'MODULES=(mt7925e btusb)' >> /etc/mkinitcpio.conf"
    fi
  fi

  if (( DRY_RUN )); then
    log DRY-RUN "mkdir -p $mnt/etc/cmdline.d $mnt/boot/EFI/Linux"
    log DRY-RUN "write $mnt/etc/cmdline.d/params.conf"
    log DRY-RUN "write $mnt/etc/cmdline.d/root.conf"
    log DRY-RUN "write $mnt/etc/mkinitcpio.d/${kernel_pkg}.preset"
    log DRY-RUN "mkinitcpio -p ${kernel_pkg} (in chroot)"
    log DRY-RUN "efibootmgr --disk $boot_disk --part 1 --create --label BOOT --loader \\EFI\\Linux\\${uki_efi} --unicode"
    return 0
  fi

  run mkdir -p "$mnt/etc/cmdline.d" "$mnt/boot/EFI/Linux"

  cat > "$mnt/etc/cmdline.d/params.conf" <<EOF
${params_line}
EOF

  cat > "$mnt/etc/cmdline.d/root.conf" <<EOF
root=LABEL=ROOT rw initrd=\\intel-ucode.img initrd=\\initramfs-${kernel_pkg}.img
EOF

  cat > "$mnt/etc/mkinitcpio.d/${kernel_pkg}.preset" <<EOF
ALL_kver="/boot/vmlinuz-${kernel_pkg}"
PRESETS=('default')
default_uki="/boot/EFI/Linux/${uki_efi}"
EOF

  chroot_run "$mnt" mkinitcpio -p "${kernel_pkg}"

  chroot_mount_efivars "$mnt"
  chroot_bash "$mnt" '
    bootnum=""
    while IFS= read -r line; do
      case "$line" in
        Boot[0-9]*\ *BOOT\ *)
          bootnum="${line#Boot}"
          bootnum="${bootnum%%*}"
          efibootmgr -B -b "$bootnum" 2>/dev/null || true
          ;;
      esac
    done < <(efibootmgr 2>/dev/null || true)
  '
  chroot_run "$mnt" efibootmgr \
    --create \
    --disk "$boot_disk" \
    --part 1 \
    --label BOOT \
    --loader "\\EFI\\Linux\\${uki_efi}" \
    --unicode
  chroot_umount_efivars "$mnt"
}

# Clone or fast-forward ansible-playbooks + ansible-collections under /media in chroot.
ensure_ansible_repos() {
  local mnt="$1"
  local path url

  chroot_run "$mnt" mkdir -p /media

  path="$ANSIBLE_ROOT"
  url=https://github.com/tekne-ops/ansible-playbooks
  if [[ -d "${mnt}${path}/.git" ]]; then
    log INFO "Refreshing ansible-playbooks (git pull --ff-only)..."
    chroot_run "$mnt" git -C "$path" pull --ff-only
  elif [[ -e "${mnt}${path}" ]]; then
    log WARN "Removing incomplete ${path} before clone"
    run rm -rf "${mnt}${path}"
    chroot_run "$mnt" git clone "$url" "$path"
  else
    log INFO "Cloning ansible-playbooks into ${path}..."
    chroot_run "$mnt" git clone "$url" "$path"
  fi

  path="$ANSIBLE_COLLECTIONS_ROOT"
  url=https://github.com/tekne-ops/ansible-collections
  if [[ -d "${mnt}${path}/.git" ]]; then
    log INFO "Refreshing ansible-collections (git pull --ff-only)..."
    chroot_run "$mnt" git -C "$path" pull --ff-only
  elif [[ -e "${mnt}${path}" ]]; then
    log WARN "Removing incomplete ${path} before clone"
    run rm -rf "${mnt}${path}"
    chroot_run "$mnt" git clone "$url" "$path"
  else
    log INFO "Cloning ansible-collections into ${path}..."
    chroot_run "$mnt" git clone "$url" "$path"
  fi
}

# Decrypt vault and verify keys required for this host (needs staged vault password file).
require_vault_vars() {
  local host="$1"
  local mnt="$2"
  local vault_file="${ANSIBLE_ROOT}/group_vars_all/vault"
  local content

  if (( DRY_RUN )); then
    log DRY-RUN "require_vault_vars: decrypt ${vault_file} and check user_password$(
      [[ "$host" == THEMIS ]] && printf ' + git_token'
    )"
    return 0
  fi

  if [[ -z "$VAULT_PASS_FILE" ]]; then
    log WARN "Vault preflight skipped (--ask-vault-pass); use --vault-password-file to validate secrets before ansible runs"
    return 0
  fi

  log INFO "Preflight: validating vault secrets for ${host}..."
  if ! content="$(arch-chroot "$mnt" ansible-vault view "$vault_file" \
      --vault-password-file "$CHROOT_VAULT_PASS" 2>&1)"; then
    die "Vault decrypt failed: ${content}"
  fi

  if ! grep -qE '^user_password:' <<< "$content"; then
    die "Vault missing user_password (required for --tags user)"
  fi
  if ! grep -qE '^user_password: +[^[:space:]]' <<< "$content"; then
    die "Vault user_password is empty (required for --tags user)"
  fi

  if [[ "$host" == THEMIS ]]; then
    if ! grep -qE '^git_token:' <<< "$content"; then
      die "Vault missing git_token (required for THEMIS --tags os)"
    fi
    if ! grep -qE '^git_token: +[^[:space:]]' <<< "$content"; then
      die "Vault git_token is empty (required for THEMIS --tags os)"
    fi
  fi

  log INFO "Vault preflight OK"
}

ansible_chroot_playbook() {
  local mnt="$1" tags="$2"
  shift 2
  chroot_run "$mnt" env ANSIBLE_CONFIG="${ANSIBLE_ROOT}/playbooks/ansible.cfg" \
    ansible-playbook "${ANSIBLE_ROOT}/playbooks/main.yml" \
    --tags "$tags" \
    "${vault_args[@]}" \
    "$@"
}

partprobe_host() {
  local host="$1"
  run partprobe "$(host_disk_path "$host" 0)" "$(host_disk_path "$host" 1)" 2>/dev/null || true
}

host_slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
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
  [[ -n "${HOST_ROLE[$host]:-}" ]] || die "Unknown host '$host'. Valid: ${VALID_HOSTS[*]}"
}

host_banner() {
  local host="$1"
  log INFO "Profile: $host (${HOST_ROLE[$host]})"
  log INFO "Disk0 (BOOT/ROOT): $(host_disk_path "$host" 0)  Disk1 (${HOST_DISK1_LAYOUT[$host]}): $(host_disk_path "$host" 1)"
  log INFO "Storage: ${HOST_STORAGE_KIND[$host]} | Kernel: linux${HOST_KERNEL[$host]}"
}

# NVMe namespace device (e.g. /dev/nvme0 -> /dev/nvme0n1)
nvme_ns() {
  local ctrl="$1"
  echo "${ctrl}n1"
}

# Controller path is a char device (/dev/nvme0); namespace is block (/dev/nvme0n1).
nvme_ctrl_exists() {
  local ctrl="$1"
  [[ -c "$ctrl" || -b "$ctrl" ]] && return 0
  [[ -b "$(nvme_ns "$ctrl")" ]] && return 0
  return 1
}

# Whole disk path for parted (nvme namespace or virtio disk)
host_disk_path() {
  local host="$1" disk_idx="$2"
  local ctrl
  if [[ "$disk_idx" == 0 ]]; then
    ctrl="${HOST_DISK0[$host]}"
  else
    ctrl="${HOST_DISK1[$host]}"
  fi
  if [[ "${HOST_STORAGE_KIND[$host]}" == nvme ]]; then
    nvme_ns "$ctrl"
  else
    echo "$ctrl"
  fi
}

# Partition path (e.g. nvme0n1p1 or vda1)
host_part_path() {
  local host="$1" disk_idx="$2" partnum="$3"
  local disk
  disk="$(host_disk_path "$host" "$disk_idx")"
  if [[ "${HOST_STORAGE_KIND[$host]}" == nvme ]]; then
    echo "${disk}p${partnum}"
  else
    echo "${disk}${partnum}"
  fi
}

confirm_destroy() {
  local host="$1"
  echo
  echo "================================================================"
  echo "  DESTRUCTIVE INSTALL — host: $host (${HOST_ROLE[$host]})"
  echo "  This will SECURE-ERASE (NVMe only) and repartition ALL data on:"
  echo "    Disk0: $(host_disk_path "$host" 0) (BOOT + ROOT)"
  echo "    Disk1: $(host_disk_path "$host" 1) (${HOST_DISK1_LAYOUT[$host]})"
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
  local ctrl0="${HOST_DISK0[$host]}"
  local ctrl1="${HOST_DISK1[$host]}"

  if [[ "${HOST_STORAGE_KIND[$host]}" == virt ]]; then
    log INFO "=== Task 1: skip NVMe secure erase (virtio: ${ctrl0}, ${ctrl1}) ==="
    partprobe_host "$host"
    return 0
  fi

  log INFO "=== Task 1: NVMe format (ses=2 secure erase) ==="

  for ctrl in "$ctrl0" "$ctrl1"; do
    if (( ! DRY_RUN )); then
      nvme_ctrl_exists "$ctrl" || die "NVMe controller not found: $ctrl (expected char device; namespace: $(nvme_ns "$ctrl"))"
    fi
    run nvme format "$ctrl" \
      --namespace-id=1 \
      --lbaf=1 \
      --ses=1 \
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
  local disk0 disk1 layout
  disk0="$(host_disk_path "$host" 0)"
  disk1="$(host_disk_path "$host" 1)"
  layout="${HOST_DISK1_LAYOUT[$host]}"

  log INFO "=== Task 2: Partition (GPT) ==="
  log INFO "disk0=$disk0 (BOOT+ROOT) disk1=$disk1 ($layout)"

  if (( ! DRY_RUN )); then
    [[ -b "$disk0" ]] || die "Disk not found: $disk0"
    [[ -b "$disk1" ]] || die "Disk not found: $disk1"
  fi

  # disk0: ESP (fixed ${ESP_SIZE_MIB} MiB for UKI), ROOT f2fs remainder
  run parted -a optimal "$disk0" --script \
    mklabel gpt \
    mkpart esp 1MiB "${ESP_SIZE_MIB}MiB" \
    mkpart f2fs "${ESP_SIZE_MIB}MiB" 100% \
    name 1 BOOT \
    name 2 ROOT \
    set 1 esp on \
    print free

  # disk1: HOME (ASTER, KVM) or DOCKER (THEMIS, YUGEN)
  if [[ "$layout" == home ]]; then
    run parted -a optimal "$disk1" --script \
      mklabel gpt \
      mkpart f2fs 1% 100% \
      name 1 HOME \
      print free
  else
    run parted -a optimal "$disk1" --script \
      mklabel gpt \
      mkpart f2fs 0% 100% \
      name 1 DOCKER \
      print free
  fi
  partprobe_host "$host"
}

# ---------------------------------------------------------------------------
# Task 3 — Create filesystems
# ---------------------------------------------------------------------------
task_mkfs() {
  local host="$1"
  local boot part_root part_disk1 layout label_disk1

  boot="$(host_part_path "$host" 0 1)"
  part_root="$(host_part_path "$host" 0 2)"
  part_disk1="$(host_part_path "$host" 1 1)"
  layout="${HOST_DISK1_LAYOUT[$host]}"
  if [[ "$layout" == home ]]; then
    label_disk1=HOME
  else
    label_disk1=DOCKER
  fi

  log INFO "=== Task 3: Create filesystems ==="
  log INFO "BOOT=$boot ROOT=$part_root ${label_disk1}=$part_disk1"

  run /usr/bin/mkfs.vfat -F32 -n BOOT "$boot"
  # shellcheck disable=SC2086
  run /usr/bin/mkfs.f2fs -l ROOT -i $F2FS_MKFS_OPTS "$part_root"
  # shellcheck disable=SC2086
  run /usr/bin/mkfs.f2fs -l "$label_disk1" -i $F2FS_MKFS_OPTS "$part_disk1"
}

# ---------------------------------------------------------------------------
# Task 4 — Mount filesystems
# ---------------------------------------------------------------------------
task_mount() {
  local host="$1"
  local boot part_root part_disk1 mnt_root mnt_disk1 layout

  boot="$(host_part_path "$host" 0 1)"
  part_root="$(host_part_path "$host" 0 2)"
  part_disk1="$(host_part_path "$host" 1 1)"
  layout="${HOST_DISK1_LAYOUT[$host]}"
  mnt_root="$INSTALL_ROOT"
  if [[ "$layout" == home ]]; then
    mnt_disk1="${INSTALL_ROOT}/home"
  else
    mnt_disk1="${INSTALL_ROOT}/var/lib/docker"
  fi

  log INFO "=== Task 4: Mount filesystems ==="
  log INFO "ROOT=$part_root -> $mnt_root | disk1 ($layout) -> $mnt_disk1"

  run mkdir -p "$mnt_root" "$mnt_disk1"

  run /usr/bin/mount -o "$F2FS_MNT_OPTS" "$part_root" "$mnt_root"
  run mkdir -p "$mnt_root/boot"
  if [[ "$layout" == home ]]; then
    run mkdir -p "$mnt_root/home"
  else
    run mkdir -p "$mnt_root/var/lib/docker"
  fi
  run /usr/bin/mount "$boot" "$mnt_root/boot"
  run /usr/bin/mount -o "$F2FS_MNT_OPTS" "$part_disk1" "$mnt_disk1"

  log INFO "Mounted:"
  if (( ! DRY_RUN )); then
    findmnt -R "$mnt_root" 2>/dev/null || mount | grep -E '^/dev/(nvme|vd)' || true
  fi
}

# ---------------------------------------------------------------------------
# Task 5 — Live pacman repos (before pacstrap; pacstrap uses host pacman.conf)
# ---------------------------------------------------------------------------
task_configure_pacman() {
  local host="$1"

  log INFO "=== Task 5: configure live pacman (repos + mirrorlist) before pacstrap ==="

  require_mounted "$INSTALL_ROOT"
  wait_for_network

  if [[ "$host" == THEMIS ]]; then
    themis_stage_local_repo
  fi
  append_pacman_repo "$host"

  log INFO "Updating live mirrorlist with reflector..."
  run /usr/bin/reflector \
    --country 'United States' \
    --latest 100 \
    --sort rate \
    --protocol 'https,ftp' \
    --age 168 \
    --save /etc/pacman.d/mirrorlist

  log INFO "Synchronizing live package databases..."
  run pacman -Syy
}

# ---------------------------------------------------------------------------
# Task 6 — Install base system (pacstrap)
# ---------------------------------------------------------------------------
task_pacstrap() {
  local host="$1"
  local kernel="${HOST_KERNEL[$host]}"
  local mcode="${HOST_MCODE[$host]}"
  local mnt="$INSTALL_ROOT"

  log INFO "=== Task 6: pacstrap base system ==="
  log INFO "linux${kernel} + host mcode packages"

  require_mounted "$mnt"

  log INFO "Installing base system with pacstrap..."
  # shellcheck disable=SC2086
  run /usr/bin/pacstrap -K "$mnt" "${PACSTRAP_BASE_PKGS[@]}" \
    $mcode "linux${kernel}" "linux${kernel}-headers"
}

# ---------------------------------------------------------------------------
# Task 7 — fstab, symlinks, hosts (post-pacstrap)
# ---------------------------------------------------------------------------
themis_stage_local_repo() {
  log INFO "THEMIS: staging local-repo from ${THEMIS_BINARIES_REPO}..."

  if (( DRY_RUN )); then
    log DRY-RUN "pacman -Sy --needed git git-lfs"
    log DRY-RUN "git clone ${THEMIS_BINARIES_REPO} ${THEMIS_BINARIES_ROOT}"
    log DRY-RUN "git -C ${THEMIS_BINARIES_ROOT} lfs install"
    log DRY-RUN "git -C ${THEMIS_BINARIES_ROOT} lfs pull"
    log DRY-RUN "repo-add ${THEMIS_BINARIES_ROOT}/themis/local-repo.db.tar.gz ${THEMIS_BINARIES_ROOT}/themis/*.pkg.tar.zst"
    return 0
  fi

  wait_for_network
  run pacman -Sy --needed --noconfirm git git-lfs

  if [[ -d "${THEMIS_BINARIES_ROOT}/.git" ]]; then
    log INFO "THEMIS: refreshing existing clone at ${THEMIS_BINARIES_ROOT}"
    run git -C "${THEMIS_BINARIES_ROOT}" pull --ff-only
  else
    run rm -rf "${THEMIS_BINARIES_ROOT}"
    run git clone "${THEMIS_BINARIES_REPO}" "${THEMIS_BINARIES_ROOT}"
  fi

  run git -C "${THEMIS_BINARIES_ROOT}" lfs install
  run git -C "${THEMIS_BINARIES_ROOT}" lfs pull

  if [[ ! -d "${THEMIS_BINARIES_ROOT}/themis" ]]; then
    log WARN "THEMIS: ${THEMIS_BINARIES_ROOT}/themis missing after git lfs pull; skipping repo-add"
    return 0
  fi

  # shellcheck disable=SC2086
  run bash -c "repo-add ${THEMIS_BINARIES_ROOT}/themis/local-repo.db.tar.gz ${THEMIS_BINARIES_ROOT}/themis/*.pkg.tar.zst"
}

append_pacman_repo() {
  local host="$1"
  # Live ISO config — pacstrap installs using the host's /etc/pacman.conf
  local conf=/etc/pacman.conf
  local section

  case "$host" in
    THEMIS) section=local-repo ;;
    ASTER|YUGEN|KVM) section=tekne ;;
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

[multilib]
Include = /etc/pacman.d/mirrorlist

EOF
      ;;
  esac
}

task_configure_base() {
  local host="$1"
  local mnt="$INSTALL_ROOT"

  log INFO "=== Task 7: post-install base configuration ==="

  require_chroot_ready "$mnt"

  if [[ -f /etc/pacman.conf ]]; then
    run mkdir -p "$mnt/etc"
    if [[ -f "$mnt/etc/pacman.conf" ]]; then
      run cp "$mnt/etc/pacman.conf" "$mnt/etc/pacman.conf.pacstrap.bak"
    fi
    run cp /etc/pacman.conf "$mnt/etc/pacman.conf"
  fi
  if (( ! DRY_RUN )) && [[ -f /etc/pacman.d/mirrorlist ]]; then
    run mkdir -p "$mnt/etc/pacman.d"
    run cp /etc/pacman.d/mirrorlist "$mnt/etc/pacman.d/mirrorlist"
  fi

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
}

# ---------------------------------------------------------------------------
# Task 8 — locale, timezone, hostname (arch-chroot)
# ---------------------------------------------------------------------------
task_configure_chroot() {
  local host="$1"
  local mnt="$INSTALL_ROOT"

  log INFO "=== Task 8: chroot locale, timezone, hostname (UKI boot deferred to post-Ansible) ==="

  require_chroot_ready "$mnt"

  chroot_run "$mnt" ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  chroot_run "$mnt" hwclock --systohc
  chroot_run "$mnt" sed -i 's|#en_US.UTF-8 UTF-8|en_US.UTF-8 UTF-8|g' /etc/locale.gen
  chroot_run "$mnt" locale-gen
  chroot_bash "$mnt" "echo 'LANG=en_US.UTF-8' > /etc/locale.conf"
  chroot_bash "$mnt" "echo 'KEYMAP=us' > /etc/vconsole.conf"
  chroot_bash "$mnt" "grep -qF '${host}.tekne.sv' /etc/hosts || echo '127.0.0.1 localhost ${host}.tekne.sv ${host}' >> /etc/hosts"
  chroot_bash "$mnt" "echo '${host}' > /etc/hostname"

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
# Task 9 — Ansible playbooks in chroot, then UKI boot finalization
# ---------------------------------------------------------------------------
task_run_ansible() {
  local host="$1"
  local mnt="$INSTALL_ROOT"
  local -a vault_args=()

  log INFO "=== Task 9: Ansible (host-specific tags) ==="

  require_chroot_ready "$mnt"
  require_chroot_cmds "$mnt"
  wait_for_network

  if [[ -n "$VAULT_PASS_FILE" ]]; then
    [[ -r "$VAULT_PASS_FILE" ]] || die "Vault password file not readable: $VAULT_PASS_FILE"
    chroot_stage_vault_pass "$mnt"
    vault_args=(--vault-password-file "${CHROOT_VAULT_PASS}")
  else
    vault_args=(--ask-vault-pass)
  fi

  ensure_ansible_repos "$mnt"
  require_vault_vars "$host" "$mnt"

  log INFO "Installing Ansible collections from ${ANSIBLE_ROOT}/requirements.yml..."
  chroot_run "$mnt" ansible-galaxy collection install -r "${ANSIBLE_ROOT}/requirements.yml" --force

  case "$host" in
    THEMIS)
      log INFO "Running ansible-playbook for THEMIS (tags: user, network-host, os)..."
      ansible_chroot_playbook "$mnt" "user,network-host,os" -e install_chroot_phase=true
      ;;
    ASTER)
      log INFO "Running ansible-playbook for ASTER (tags: user, network-host, xfce4; WiFi connect deferred)..."
      ansible_chroot_playbook "$mnt" "user,network-host,xfce4" \
        -e network_connect_wifi=false \
        -e install_chroot_phase=true
      ;;
    YUGEN)
      log INFO "Running ansible-playbook for YUGEN (tags: user, network-host, xfce4)..."
      ansible_chroot_playbook "$mnt" "user,network-host,xfce4" -e install_chroot_phase=true
      ;;
    KVM)
      log INFO "Running ansible-playbook for KVM (tags: user, network-host; headless, no xfce4)..."
      ansible_chroot_playbook "$mnt" "user,network-host" -e install_chroot_phase=true
      ;;
    *)
      die "Unknown host for Ansible: $host"
      ;;
  esac

  configure_uki_boot "$host" "$mnt"

  chroot_cleanup_vault_pass "$mnt"
  log INFO "Ansible configuration and UKI boot finalization completed."
}

# ---------------------------------------------------------------------------
# Post-archinstall — F2FS labels, hosts, cache (archinstall leaves these to tekne)
# ---------------------------------------------------------------------------
task_tekne_post_archinstall() {
  local host="$1"
  local mnt="${TEKNE_INSTALL_ROOT:-/mnt}"
  local layout="${HOST_DISK1_LAYOUT[$host]}"
  local disk1_mnt

  log INFO "=== Post-archinstall tekne adjustments ==="

  require_chroot_ready "$mnt"

  if [[ "$layout" == home ]]; then
    disk1_mnt="${mnt}/home"
  else
    disk1_mnt="${mnt}/var/lib/docker"
  fi

  if (( ! DRY_RUN )); then
    local root_part boot_part disk1_part
    root_part="$(findmnt -no SOURCE "$mnt")"
    boot_part="$(findmnt -no SOURCE "${mnt}/boot")"
    disk1_part="$(findmnt -no SOURCE "$disk1_mnt")"

    if [[ -n "$root_part" ]] && command -v f2fs.fslabel &>/dev/null; then
      log INFO "Setting F2FS label ROOT on $root_part"
      f2fs.fslabel "$root_part" ROOT 2>/dev/null || true
    fi
    if [[ -n "$boot_part" ]] && command -v fatlabel &>/dev/null; then
      log INFO "Setting FAT label BOOT on $boot_part"
      fatlabel "$boot_part" BOOT 2>/dev/null || true
    fi
    if [[ -n "$disk1_part" ]] && command -v f2fs.fslabel &>/dev/null; then
      local disk1_label=DOCKER
      [[ "$layout" == home ]] && disk1_label=HOME
      log INFO "Setting F2FS label ${disk1_label} on $disk1_part"
      f2fs.fslabel "$disk1_part" "$disk1_label" 2>/dev/null || true
    fi
  else
    log DRY-RUN "f2fs.fslabel / fatlabel for ROOT, BOOT, disk1"
  fi

  chroot_bash "$mnt" "grep -qF '${host}.tekne.sv' /etc/hosts || echo '127.0.0.1 localhost ${host}.tekne.sv ${host}' >> /etc/hosts"
  chroot_bash "$mnt" 'mkdir -p /var/cache/{pacman/pkg,docker/build,staging,build}'

  if [[ "$host" == THEMIS ]]; then
    log INFO "THEMIS: cache bind mounts (skipped if /mnt/cache not present)..."
    themis_cache_bind_mounts "$mnt"
  fi
}

# Run tekne post-archinstall steps then task 9 (Ansible + UKI boot).
tekne_run_post_archinstall() {
  local host="$1"
  task_tekne_post_archinstall "$host"
  task_run_ansible "$host"
}

task_summary() {
  local host="$1"
  log INFO "Install summary: $host (${HOST_ROLE[$host]}) on ${INSTALL_ROOT}"
  log INFO "Kernel: linux${HOST_KERNEL[$host]} | log: $LOG_FILE"
}

# Host-specific steps after reboot (chroot task 9 is only the first Ansible phase).
print_post_install_steps() {
  local host="$1"
  local playbook_dir="/media/ansible-playbooks/playbooks"

  echo
  echo "================================================================"
  echo "  NEXT STEPS — complete setup after reboot"
  echo "================================================================"
  echo
  echo "  1. Reboot into the installed system (remove live ISO if needed)."
  echo "  2. Log in locally or over SSH."
  echo "  3. Run the post-install playbook from the installed copy of the repo:"
  echo
  case "$host" in
    ASTER|YUGEN)
      echo "     cd ${playbook_dir}"
      echo "     sudo ./workstation.sh"
      echo
      echo "  workstation.sh runs: network-host (WiFi on ASTER), os, pipewire,"
      echo "  gaming, onedrive, bootstrap, nftables."
      echo
      echo "  Notes:"
      echo "    - ASTER: WiFi connects on this run (deferred during live ISO install)."
      echo "    - bootstrap pauses for OneDrive authentication."
      echo "    - Log in to the desktop before bootstrap if you want XFCE theming applied."
      ;;
    THEMIS)
      echo "     cd ${playbook_dir}"
      echo "     sudo ansible-playbook main.yml \\"
      echo "       --tags os,nftables,libvirt,docker-host,haproxy,repotekne,gerbera \\"
      echo "       --ask-vault-pass"
      echo
      echo "  Or use ./server.sh once it is configured for the full server tag set."
      ;;
    KVM)
      echo "     cd ${playbook_dir}"
      echo "     sudo ansible-playbook main.yml \\"
      echo "       --tags network-host,os,pipewire,nftables \\"
      echo "       --ask-vault-pass"
      echo
      echo "  KVM is headless: do not run workstation.sh (no desktop/gaming/onedrive)."
      ;;
    *)
      echo "     cd ${playbook_dir}"
      echo "     sudo ansible-playbook main.yml --ask-vault-pass"
      ;;
  esac
  echo
  echo "  Vault: use --vault-password-file ~/.vault_pass instead of --ask-vault-pass"
  echo "  when running non-interactively."
  echo
  echo "  If repos are not under ${playbook_dir}, clone ansible-playbooks first or"
  echo "  run from your checkout: cd ~/path/to/ansible-playbooks/playbooks"
  echo "================================================================"
  echo
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
  --skip-network-wait        Skip connectivity wait (offline / manual setup)
  --from-task N              Start at pipeline task N (0-$(( ${#PIPELINE[@]} - 1 )))
  --vault-password-file PATH Ansible vault password file (non-interactive)
  -h, --help                 Show this help

Hosts:
  THEMIS   server (nvme0 BOOT/ROOT, nvme1 DOCKER)
  ASTER    laptop (nvme0 BOOT/ROOT, nvme1 HOME)
  YUGEN    pc     (nvme0 BOOT/ROOT, nvme1 DOCKER)
  KVM      vm     (vda BOOT/ROOT, vdb HOME)

If HOST is omitted, detection uses DMI product/board name or hostname.

Pipeline tasks (use --from-task N):
  0  timedatectl + NTP
  1  nvme secure format
  2  GPT partition
  3  mkfs
  4  mount under $INSTALL_ROOT
  5  live pacman repos (THEMIS local-repo / tekne), reflector, pacman -Syy
  6  pacstrap
  7  fstab, pacman.conf copy, symlinks
  8  chroot locale, timezone, hostname, THEMIS cache binds
  9  ansible-playbooks + UKI boot (mkinitcpio preset, efibootmgr)

After reboot (second Ansible phase):
  ASTER/YUGEN  cd /media/ansible-playbooks/playbooks && sudo ./workstation.sh
  THEMIS       server tags via ./server.sh or ansible-playbook (see post-install banner)
  KVM          network-host,os,pipewire,nftables (not workstation.sh)
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
      --skip-network-wait) SKIP_NETWORK_WAIT=1 ;;
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
      THEMIS|ASTER|YUGEN|KVM) FORCE_HOST="$1" ;;
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

  ensure_live_network "$host"
  run_pipeline "$host"
  task_summary "$host"
  print_post_install_steps "$host"

  log INFO "=== Install pipeline complete for $host ==="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
