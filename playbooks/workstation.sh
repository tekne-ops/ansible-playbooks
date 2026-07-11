#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOST="$(tr '[:lower:]' '[:upper:]' < /etc/hostname | tr -d '[:space:]')"

case "$HOST" in
  ASTER)
    exec "$ROOT/playbooks/workstation-aster.sh" "$@"
    ;;
  YUGEN)
    exec "$ROOT/playbooks/workstation-yugen.sh" "$@"
    ;;
  *)
    echo "workstation.sh: unknown host '$HOST' (expected ASTER or YUGEN)" >&2
    echo "Run workstation-aster.sh or workstation-yugen.sh directly." >&2
    exit 1
    ;;
esac
