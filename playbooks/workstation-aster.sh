#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$(tr '[:lower:]' '[:upper:]' </etc/hostname | tr -d '[:space:]')"
if [[ "$HOST" != ASTER ]]; then
    echo "workstation-aster.sh: this playbook is for ASTER (current host: ${HOST})" >&2
    exit 1
fi

exec "$ROOT/playbooks/workstation.sh" "$@"
