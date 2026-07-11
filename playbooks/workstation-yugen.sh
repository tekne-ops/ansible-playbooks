#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
exec sudo ansible-playbook playbooks/main.yml \
  --tags network-host,os,gpu,pipewire,gaming,xfce4,docker-host,libvirt,bootstrap,nftables \
  --ask-vault-pass
