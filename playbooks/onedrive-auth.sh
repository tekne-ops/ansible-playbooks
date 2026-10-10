#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

args=(--ask-vault-pass)
if [[ "$(id -u)" -ne 0 ]]; then
    args+=(--ask-become-pass)
fi

exec ansible-playbook playbooks/onedrive-auth.yml \
    -i inventories/workstation/hosts.yml \
    "${args[@]}" \
    "$@"
