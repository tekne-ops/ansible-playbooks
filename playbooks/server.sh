#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
exec sudo ansible-playbook playbooks/main.yml \
  --tags os,nftables,libvirt,docker-host,haproxy,repotekne,gerbera \
  --ask-vault-pass
