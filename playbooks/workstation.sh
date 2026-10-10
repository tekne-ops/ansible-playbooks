#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOST="$(tr '[:lower:]' '[:upper:]' </etc/hostname | tr -d '[:space:]')"
PROFILE="${ROOT}/install/profiles/hosts.json"

if ! jq -e --arg host "$HOST" '.hosts[$host].maintenance_playbook' "$PROFILE" >/dev/null; then
    echo "workstation.sh: ${HOST} has no maintenance_playbook in install/profiles/hosts.json" >&2
    exit 1
fi

playbook="$(jq -er --arg host "$HOST" '.hosts[$host].maintenance_playbook' "$PROFILE")"
inventory="$(jq -er --arg host "$HOST" '.hosts[$host].maintenance_inventory' "$PROFILE")"
tags="$(jq -er --arg host "$HOST" '.hosts[$host].maintenance_tags | join(",")' "$PROFILE")"

args=(--tags "$tags")
# dvaliente sudoers requires a password. The playbook used to be started
# through sudo, so become never had to ask. Ask here when the login is not root.
if [[ "$(id -u)" -ne 0 ]]; then
    args+=(--ask-become-pass)
fi
if [[ $# -eq 0 ]]; then
    args+=(--ask-vault-pass)
else
    args+=("$@")
fi

exec ansible-playbook "$playbook" \
    -i "$inventory" \
    "${args[@]}"
