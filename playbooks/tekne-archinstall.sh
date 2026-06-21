#!/usr/bin/env bash
# tekne-archinstall.sh — archinstall + Tekne Ansible post-install (arch-install.sh task 9)
#
# Uses archinstall guided mode with a generated config.json per host profile,
# then runs the same Ansible + UKI boot steps as arch-install.sh task 9.
#
# Reference:
#   https://archinstall.archlinux.page/installing/guided.html
#   https://github.com/archlinux/archinstall/blob/master/archinstall/scripts/guided.py
#
# Usage (from Arch live ISO):
#   ./tekne-archinstall.sh
#   ./tekne-archinstall.sh ASTER
#   ./tekne-archinstall.sh --dry-run KVM
#   ./tekne-archinstall.sh --vault-password-file ~/.vault_pass THEMIS
#   ./tekne-archinstall.sh --disk0 /dev/nvme0n1 --disk1 /dev/nvme1n1 ASTER
#   ./tekne-archinstall.sh --disk0 /dev/vda --disk1 /dev/vdb KVM
#
# Environment:
#   TEKNE_INSTALL_ROOT       Install mount (default: /mnt; pass to archinstall --mountpoint)
#   ARCH_INSTALL_VAULT_PASS_FILE  Same as --vault-password-file
#   TEKNE_WIFI_SSID          ASTER WiFi SSID (default: esher)
#   TEKNE_WIFI_PASSPHRASE    ASTER WiFi passphrase (or use --vault-password-file)
#   SKIP_NETWORK_WAIT=1      Skip connectivity wait (same as --skip-network-wait)
#
# Note: connect WiFi/Ethernet on the live ISO before running, or let the script
#       try ASTER WiFi (iwctl) when no link is detected.

set -euo pipefail

SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATOR="${SCRIPT_DIR}/lib/generate_archinstall_config.py"
ARCH_INSTALL_LIB="${SCRIPT_DIR}/arch-install.sh"
ARCHINSTALL_MOUNT="${TEKNE_INSTALL_ROOT:-/mnt}"

HOST=""
DISK0=""
DISK1=""
DRY_RUN=0
INTERACTIVE=0
SKIP_NETWORK_WAIT=${SKIP_NETWORK_WAIT:-0}
VAULT_PASS_FILE="${ARCH_INSTALL_VAULT_PASS_FILE:-}"
ROOT_PASSWORD=""
CONFIG_DIR=""

usage() {
  cat <<EOF
$SCRIPT_NAME — archinstall with Tekne host profiles + Ansible task 9

Usage:
  $SCRIPT_NAME [OPTIONS] [HOST]

Options:
  -n, --dry-run                 Print actions without executing archinstall/Ansible
  --skip-network-wait           Do not wait for network (offline / manual mirror setup)
  --vault-password-file PATH    Ansible vault password (required for task 9)
  --root-password PASS          Root password for archinstall --creds (prompt if omitted)
  --disk0 DEV                   Disk0 block device (default: auto from profile)
  --disk1 DEV                   Disk1 block device (default: auto from profile)
  --config-dir DIR              Where to write config.json (default: /tmp/tekne-archinstall-<host>)
  --interactive                 Run archinstall with silent=false (TUI prompts)
  -h, --help                    Show this help

Hosts (profiles from arch-install.sh):
  ASTER    laptop  (nvme0 BOOT/ROOT, nvme1 HOME)
  YUGEN    pc      (nvme0 BOOT/ROOT, nvme1 DOCKER)
  THEMIS   server  (nvme0 BOOT/ROOT, nvme1 DOCKER; stages local-repo)
  KVM      vm      (vda BOOT/ROOT, vdb HOME; headless, no xfce4)

Steps:
  1. Generate archinstall config.json (+ creds.json) for the host profile
  2. Run: archinstall --config config.json --creds creds.json --mountpoint $ARCHINSTALL_MOUNT
  3. Run arch-install.sh task 9: post-archinstall labels, Ansible chroot, UKI boot

After reboot see the post-install banner (print_post_install_steps from arch-install.sh).
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

prompt_hostname() {
  local choice
  if [[ -n "$HOST" ]]; then
    return 0
  fi
  echo
  echo "Select host profile:"
  echo "  1) ASTER   — laptop"
  echo "  2) YUGEN   — workstation"
  echo "  3) THEMIS  — server"
  echo "  4) KVM     — VM (headless)"
  echo
  read -r -p "Enter hostname or number [1-4]: " choice
  case "$choice" in
    1|ASTER|aster) HOST=ASTER ;;
    2|YUGEN|yugen) HOST=YUGEN ;;
    3|THEMIS|themis) HOST=THEMIS ;;
    4|KVM|kvm) HOST=KVM ;;
    *) die "Invalid selection: $choice" ;;
  esac
}

validate_host() {
  local h="$1" valid
  for valid in "${VALID_HOSTS[@]}"; do
    [[ "$h" == "$valid" ]] && return 0
  done
  die "Unknown host '$h'. Valid: ${VALID_HOSTS[*]}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run) DRY_RUN=1 ;;
      --skip-network-wait) SKIP_NETWORK_WAIT=1 ;;
      --interactive) INTERACTIVE=1 ;;
      --vault-password-file)
        shift
        [[ $# -gt 0 ]] || die "--vault-password-file requires a path"
        VAULT_PASS_FILE=$1
        ;;
      --root-password)
        shift
        [[ $# -gt 0 ]] || die "--root-password requires a value"
        ROOT_PASSWORD=$1
        ;;
      --disk0)
        shift
        [[ $# -gt 0 ]] || die "--disk0 requires a device path"
        DISK0=$1
        ;;
      --disk1)
        shift
        [[ $# -gt 0 ]] || die "--disk1 requires a device path"
        DISK1=$1
        ;;
      --config-dir)
        shift
        [[ $# -gt 0 ]] || die "--config-dir requires a path"
        CONFIG_DIR=$1
        ;;
      -h|--help) usage; exit 0 ;;
      ASTER|YUGEN|THEMIS|KVM) HOST="$1" ;;
      *) die "Unknown argument: $1 (try --help)" ;;
    esac
    shift
  done
}

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root from the Arch Linux live ISO."
}

require_tools() {
  local missing=() cmd
  if (( ! DRY_RUN )); then
    command -v archinstall &>/dev/null || missing+=("archinstall")
  fi
  command -v python3 &>/dev/null || missing+=("python3")
  if [[ ! -f "$GENERATOR" ]]; then
    die "Missing ${GENERATOR}. Update your ansible-playbooks checkout (git pull) so playbooks/lib/ is present."
  fi
  (( ${#missing[@]} == 0 )) || die "Missing: ${missing[*]}"
}

resolve_disks() {
  if [[ -z "$DISK0" ]]; then
    DISK0="$(host_disk_path "$HOST" 0)"
  fi
  if [[ -z "$DISK1" ]]; then
    DISK1="$(host_disk_path "$HOST" 1)"
  fi
  if (( DRY_RUN )); then
    log INFO "Using disk0=$DISK0 disk1=$DISK1 (existence check skipped in dry-run)"
    return 0
  fi
  [[ -b "$DISK0" ]] || die "Disk0 not found: $DISK0"
  [[ -b "$DISK1" ]] || die "Disk1 not found: $DISK1"
}

confirm_destroy() {
  echo
  echo "================================================================"
  echo "  DESTRUCTIVE INSTALL — host: $HOST (${HOST_ROLE[$HOST]:-unknown})"
  echo "  archinstall will WIPE and repartition:"
  echo "    Disk0: $DISK0 (BOOT + ROOT)"
  echo "    Disk1: $DISK1 (${HOST_DISK1_LAYOUT[$HOST]:-disk1})"
  echo "  Mountpoint: $ARCHINSTALL_MOUNT"
  echo "================================================================"
  echo
  if (( DRY_RUN )); then
    echo "Dry-run mode — archinstall and Ansible will not run."
    return 0
  fi
  read -r -p "Type the host name ($HOST) to continue: " ans
  [[ "$ans" == "$HOST" ]] || die "Aborted."
}

prompt_root_password() {
  if [[ -n "$ROOT_PASSWORD" ]]; then
    return 0
  fi
  echo
  read -r -s -p "Root password for archinstall (creds.json): " ROOT_PASSWORD
  echo
  [[ -n "$ROOT_PASSWORD" ]] || die "Root password is required for archinstall --creds"
}

prepare_themis_repo() {
  [[ "$HOST" == THEMIS ]] || return 0
  log INFO "THEMIS: staging local-repo before archinstall..."
  themis_stage_local_repo
  append_pacman_repo "$HOST"
}

generate_config() {
  local gen_args=(
    "$GENERATOR"
    "$HOST"
    --disk0 "$DISK0"
    --disk1 "$DISK1"
    --output-dir "$CONFIG_DIR"
    --mountpoint "$ARCHINSTALL_MOUNT"
    --root-password "$ROOT_PASSWORD"
  )
  if (( INTERACTIVE )); then
    gen_args+=(--interactive)
  fi
  if (( DRY_RUN )); then
    log INFO "Would run: python3 ${gen_args[*]}"
    return 0
  fi
  python3 "${gen_args[@]}"
  log INFO "Generated ${CONFIG_DIR}/config.json and ${CONFIG_DIR}/creds.json"
}

run_archinstall() {
  local config="${CONFIG_DIR}/config.json"
  local creds="${CONFIG_DIR}/creds.json"
  local -a cmd=(
    archinstall
    --config "$config"
    --creds "$creds"
    --mountpoint "$ARCHINSTALL_MOUNT"
    --skip-wifi-check
  )
  if (( ! INTERACTIVE )); then
    cmd+=(--silent)
  fi

  log INFO "Running archinstall (guided) for $HOST..."
  if (( DRY_RUN )); then
    log DRY-RUN "${cmd[*]}"
    return 0
  fi

  wait_for_network
  "${cmd[@]}"
  log INFO "archinstall completed."
}

run_post_archinstall() {
  export TEKNE_INSTALL_ROOT="$ARCHINSTALL_MOUNT"
  log INFO "Running Tekne post-archinstall (labels + Ansible task 9 + UKI boot)..."
  if (( DRY_RUN )); then
    log DRY-RUN "tekne_run_post_archinstall $HOST"
    return 0
  fi
  tekne_run_post_archinstall "$HOST"
}

main() {
  parse_args "$@"
  if (( DRY_RUN )); then
    LOG_FILE="/tmp/tekne-archinstall.log"
  fi
  if (( ! DRY_RUN )); then
    require_root
  fi
  require_tools

  [[ -f "$ARCH_INSTALL_LIB" ]] || die "Missing ${ARCH_INSTALL_LIB}"
  # shellcheck source=arch-install.sh
  source "$ARCH_INSTALL_LIB"
  # Re-apply flags after source (arch-install.sh only defaults unset vars)
  DRY_RUN=${DRY_RUN:-0}
  SKIP_NETWORK_WAIT=${SKIP_NETWORK_WAIT:-0}
  VAULT_PASS_FILE="${VAULT_PASS_FILE:-${ARCH_INSTALL_VAULT_PASS_FILE:-}}"

  prompt_hostname
  HOST="${HOST^^}"
  validate_host "$HOST"

  [[ -n "$CONFIG_DIR" ]] || CONFIG_DIR="/tmp/tekne-archinstall-${HOST}"
  mkdir -p "$CONFIG_DIR"

  resolve_disks
  confirm_destroy "$HOST"
  if (( ! DRY_RUN )); then
    prompt_root_password
  else
    ROOT_PASSWORD="${ROOT_PASSWORD:-dry-run-placeholder}"
  fi

  ensure_live_network "$HOST"
  prepare_themis_repo
  prepare_live_pacman_for_archinstall "$HOST"
  generate_config
  run_archinstall
  run_post_archinstall

  log INFO "=== Tekne archinstall complete for $HOST ==="
  if (( ! DRY_RUN )); then
    print_post_install_steps "$HOST"
  else
    log INFO "After reboot: see print_post_install_steps in arch-install.sh for $HOST"
  fi
}

main "$@"
