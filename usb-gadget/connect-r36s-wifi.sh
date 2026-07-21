#!/usr/bin/env bash
set -euo pipefail

R36S_HOST="${R36S_WIFI_HOST:-192.168.0.45}"
R36S_USER="${R36S_USER:-ark}"
R36S_PASSWORD="${R36S_PASSWORD:-ark}"

SSH_OPTIONS=(
  -o ConnectTimeout=5
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=accept-new
)

if ! command -v sshpass >/dev/null 2>&1; then
  printf 'Error: sshpass is not installed.\n' >&2
  exit 1
fi

exec sshpass -p "$R36S_PASSWORD" \
  ssh "${SSH_OPTIONS[@]}" \
  "$R36S_USER@$R36S_HOST" \
  "$@"