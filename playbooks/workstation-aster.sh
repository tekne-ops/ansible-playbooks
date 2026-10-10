#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
args=(
    --tags "network-host,os,gpu,pipewire,gaming,onedrive,xfce4,bootstrap,nftables"
)
if [[ $# -eq 0 ]]; then
    args+=(--ask-vault-pass)
else
    args+=("$@")
fi
exec sudo ansible-playbook playbooks/workstation.yml \
    -i inventories/workstation/hosts.yml \
    "${args[@]}"
