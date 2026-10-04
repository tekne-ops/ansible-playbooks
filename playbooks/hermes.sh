#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOST="$(tr '[:lower:]' '[:upper:]' </etc/hostname | tr -d '[:space:]')"
case "$HOST" in
    THEMIS)
        playbook="playbooks/server.yml"
        inventory="inventories/server/hosts.yml"
        ;;
    ASTER | YUGEN | KVM)
        playbook="playbooks/workstation.yml"
        inventory="inventories/workstation/hosts.yml"
        ;;
    *)
        echo "hermes.sh: unknown host '$HOST' (expected ASTER, YUGEN, KVM, or THEMIS)" >&2
        exit 1
        ;;
esac

exec ansible-playbook "$playbook" \
    -i "$inventory" \
    --tags hermes \
    --ask-vault-pass
