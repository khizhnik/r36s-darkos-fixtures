#!/bin/bash
set -euo pipefail

MOUNTPOINT_DEFAULT="/mnt/usbdrive"
LOG_PREFIX="[usb-drive-unmount]"

FINDMNT_CMD="${USB_DRIVE_MOUNT_FINDMNT:-findmnt}"
UMOUNT_CMD="${USB_DRIVE_MOUNT_UMOUNT:-umount}"
SYNC_CMD="${USB_DRIVE_MOUNT_SYNC:-sync}"
FUSER_CMD="${USB_DRIVE_MOUNT_FUSER:-fuser}"
LSOF_CMD="${USB_DRIVE_MOUNT_LSOF:-lsof}"
ID_CMD="${USB_DRIVE_MOUNT_ID:-id}"
SUDO_CMD="${USB_DRIVE_MOUNT_SUDO:-sudo}"
MOUNTPOINT="$MOUNTPOINT_DEFAULT"
VERBOSE=0

log() {
  printf '%s %s\n' "$LOG_PREFIX" "$*" >&2
}

die() {
  log "$1"
  exit "${2:-1}"
}

run_root() {
  if [ "$("$ID_CMD" -u)" -eq 0 ]; then
    "$@"
  else
    "$SUDO_CMD" -- "$@"
  fi
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

mounted_source_for_target() {
  "$FINDMNT_CMD" -rn -o SOURCE --target "$MOUNTPOINT" 2>/dev/null | head -n1 | tr -d '\n' || true
}

busy_report() {
  if have_cmd "$FUSER_CMD"; then
    run_root "$FUSER_CMD" -mv "$MOUNTPOINT" || true
  fi
  if have_cmd "$LSOF_CMD"; then
    run_root "$LSOF_CMD" +f -- "$MOUNTPOINT" || true
  fi
}

main() {
  local arg current_source

  while [ "$#" -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
      --mountpoint)
        [ "$#" -gt 0 ] || die "--mountpoint requires a value" 2
        MOUNTPOINT="$1"
        shift
        ;;
      --verbose)
        VERBOSE=1
        ;;
      --help|-h)
        cat <<'EOF'
Usage: r36s-usb-drive-unmount.sh [--mountpoint PATH] [--verbose]
EOF
        exit 0
        ;;
      *)
        die "unknown argument: $arg" 2
        ;;
    esac
  done

  current_source="$(mounted_source_for_target)"
  if [ -z "$current_source" ]; then
    printf 'USB drive already unmounted\n'
    exit 0
  fi

  if [ "$VERBOSE" -eq 1 ]; then
    log "unmounting source $current_source from $MOUNTPOINT"
  fi

  "$SYNC_CMD"

  if ! run_root "$UMOUNT_CMD" "$MOUNTPOINT"; then
    printf 'USB drive busy\n'
    busy_report
    exit 12
  fi

  if [ -n "$(mounted_source_for_target)" ]; then
    die "mountpoint still mounted: $MOUNTPOINT" 13
  fi

  printf 'USB drive unmounted\n'
}

main "$@"
