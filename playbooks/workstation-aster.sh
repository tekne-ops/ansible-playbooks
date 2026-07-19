#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
exec sudo ansible-playbook playbooks/main.yml \
  --tags os,gpu,pipewire,gaming,onedrive,bootstrap,nftables \
  --ask-vault-pass
