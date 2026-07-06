#!/bin/bash
set -euo pipefail

TARGET_UNIT="/etc/systemd/system/r36s-usb-gadget.service"
TARGET_BIN="/home/ark/bin/r36s-usb-gadget.sh"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

run_root systemctl disable --now r36s-usb-gadget.service || true
run_root rm -f "$TARGET_UNIT"
if ! rm -f "$TARGET_BIN"; then
  run_root rm -f "$TARGET_BIN"
fi
run_root systemctl daemon-reload
