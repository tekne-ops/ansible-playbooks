#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$(tr '[:lower:]' '[:upper:]' </etc/hostname | tr -d '[:space:]')"
if [[ "$HOST" != THEMIS ]]; then
    echo "server.sh: this playbook is for THEMIS (current host: ${HOST})" >&2
    exit 1
fi

if [[ $# -eq 0 ]]; then
    exec "$ROOT/playbooks/workstation.sh" --ask-vault-pass
fi
exec "$ROOT/playbooks/workstation.sh" "$@"
