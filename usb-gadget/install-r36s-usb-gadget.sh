#!/bin/bash
set -euo pipefail

SRC_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
TARGET_BIN_DIR="/home/ark/bin"
TARGET_BIN="${TARGET_BIN_DIR}/r36s-usb-gadget.sh"
TARGET_UNIT="/etc/systemd/system/r36s-usb-gadget.service"

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

if [ "$(uname -m)" != "aarch64" ]; then
  echo "Warning: this installer expects to run on an R36S-class aarch64 system." >&2
  echo "Current machine: $(uname -m)" >&2
  exit 1
fi

mkdir -p "$TARGET_BIN_DIR"
cp "$SRC_DIR/r36s-usb-gadget.sh" "$TARGET_BIN"
chmod +x "$TARGET_BIN"

run_root cp "$SRC_DIR/r36s-usb-gadget.service" "$TARGET_UNIT"
run_root systemctl daemon-reload
run_root systemctl enable --now r36s-usb-gadget.service
run_root systemctl status --no-pager r36s-usb-gadget.service || true
