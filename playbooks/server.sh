#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOST="$(tr '[:lower:]' '[:upper:]' </etc/hostname | tr -d '[:space:]')"
if [[ "$HOST" != THEMIS ]]; then
    echo "server.sh: this playbook is for THEMIS (current host: ${HOST})" >&2
    exit 1
fi

exec sudo ansible-playbook playbooks/server.yml \
    -i inventories/server/hosts.yml \
    --tags os,nftables,libvirt,docker-host,haproxy,repotekne,gerbera \
    --ask-vault-pass
