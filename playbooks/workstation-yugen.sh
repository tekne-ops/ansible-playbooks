#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$(tr '[:lower:]' '[:upper:]' </etc/hostname | tr -d '[:space:]')"
if [[ "$HOST" != YUGEN ]]; then
    echo "workstation-yugen.sh: this playbook is for YUGEN (current host: ${HOST})" >&2
    exit 1
fi

exec "$ROOT/playbooks/workstation.sh" "$@"
