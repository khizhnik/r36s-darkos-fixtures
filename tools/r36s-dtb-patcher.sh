#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

BOOT_DIR="${R36S_DTB_PATCHER_BOOT_DIR:-/boot}"
TARGET_DTB="${R36S_DTB_PATCHER_TARGET:-$BOOT_DIR/rk3326-r36s-linux.dtb}"
BACKUP_ROOT="${R36S_DTB_PATCHER_BACKUP_ROOT:-$BOOT_DIR/r36s-dtb-patcher-backups}"
PC_RECOVERY_COPY="${R36S_DTB_PATCHER_PC_RECOVERY_COPY:-$BOOT_DIR/rk3326-r36s-linux.dtb.pre-r36s-devkit}"
USB_GADGET_SRC_DIR="$REPO_ROOT/usb-gadget"
USB_GADGET_SCRIPT_SRC="$USB_GADGET_SRC_DIR/r36s-usb-gadget.sh"
USB_GADGET_SERVICE_SRC="$USB_GADGET_SRC_DIR/r36s-usb-gadget.service"
USB_GADGET_TARGET_BIN_DIR="/home/ark/bin"
USB_GADGET_TARGET_BIN="$USB_GADGET_TARGET_BIN_DIR/r36s-usb-gadget.sh"
USB_GADGET_TARGET_UNIT="/etc/systemd/system/r36s-usb-gadget.service"

TMP_DIR=""
LOG_FILE=""
BACKUP_DIR=""
TARGET_BASENAME="$(basename -- "$TARGET_DTB")"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

maybe_sudo() {
  if [ "${R36S_DTB_PATCHER_NO_SUDO:-0}" = "1" ]; then
    "$@"
    return 0
  fi

  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_dir() {
  local path="$1"
  local parent

  if [ -d "$path" ] && [ -w "$path" ]; then
    return 0
  fi

  parent="$(dirname -- "$path")"
  if [ -w "$parent" ]; then
    mkdir -p "$path"
  else
    maybe_sudo mkdir -p "$path"
  fi
}

copy_file() {
  local src="$1"
  local dst="$2"
  local parent

  parent="$(dirname -- "$dst")"
  if [ -w "$parent" ]; then
    cp "$src" "$dst"
  else
    maybe_sudo cp "$src" "$dst"
  fi
}

move_file() {
  local src="$1"
  local dst="$2"
  local parent

  parent="$(dirname -- "$dst")"
  if [ -w "$parent" ]; then
    mv -f "$src" "$dst"
  else
    maybe_sudo mv -f "$src" "$dst"
  fi
}

setup_tmp() {
  TMP_DIR="$(mktemp -d)"
}

cleanup() {
  if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT

setup_logging() {
  if [ -z "${TMP_DIR:-}" ]; then
    return
  fi

  LOG_FILE="$TMP_DIR/patch.log"
  : > "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

human_yes_no() {
  if [ "$1" -eq 1 ]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

inspect_dts() {
  awk '
    function node_name(line,   s) {
      s = line
      sub(/^[[:space:]]*/, "", s)
      sub(/\{[[:space:]]*$/, "", s)
      sub(/^[^[:space:]:]+:[[:space:]]*/, "", s)
      sub(/[[:space:]]*$/, "", s)
      return s
    }
    function top() {
      return sp > 0 ? stack[sp] : ""
    }
    function parent() {
      return sp > 1 ? stack[sp - 1] : ""
    }
    function push(name) {
      stack[++sp] = name
    }
    function pop() {
      if (sp > 0) {
        delete stack[sp]
        sp--
      }
    }
    {
      line = $0

      if (line ~ /\{$/) {
        name = node_name(line)
        push(name)

        if (name == "dwmmc@ff380000") {
          have_dw = 1
        } else if (name == "usb2-phy@100") {
          have_phy = 1
        } else if (name == "otg-port" && parent() == "usb2-phy@100") {
          have_otg = 1
        } else if (name == "usb@ff300000") {
          have_usb = 1
        }

        next
      }

      current = top()
      if (current == "dwmmc@ff380000") {
        if (line ~ /^[[:space:]]*max-frequency = <(50000000|0x2faf080)>;/) {
          dw_max = 1
        }
        if (line ~ /^[[:space:]]*max-frequency = <[^>]+>;/) {
          dw_has_max = 1
        }
        if (line ~ /^[[:space:]]*sd-uhs-sdr(12|25|50|104);[[:space:]]*$/) {
          dw_has_uhs = 1
        }
      } else if (current == "otg-port" && parent() == "usb2-phy@100") {
        if (line ~ /^[[:space:]]*status = "okay";/) {
          otg_ok = 1
        }
        if (line ~ /^[[:space:]]*status = /) {
          otg_has_status = 1
        }
      } else if (current == "usb@ff300000") {
        if (line ~ /^[[:space:]]*dr_mode = "peripheral";/) {
          usb_periph = 1
        }
        if (line ~ /^[[:space:]]*dr_mode = /) {
          usb_has_mode = 1
        }
      }

      if (line ~ /^[[:space:]]*\};[[:space:]]*$/) {
        pop()
      }
    }
    END {
      print "have_dw=" (have_dw ? 1 : 0)
      print "dw_max=" (dw_max ? 1 : 0)
      print "dw_has_max=" (dw_has_max ? 1 : 0)
      print "dw_has_uhs=" (dw_has_uhs ? 1 : 0)
      print "have_phy=" (have_phy ? 1 : 0)
      print "have_otg=" (have_otg ? 1 : 0)
      print "otg_ok=" (otg_ok ? 1 : 0)
      print "otg_has_status=" (otg_has_status ? 1 : 0)
      print "have_usb=" (have_usb ? 1 : 0)
      print "usb_periph=" (usb_periph ? 1 : 0)
      print "usb_has_mode=" (usb_has_mode ? 1 : 0)
    }
  ' "$1"
}

print_doctor_report() {
  local have_dw="$1"
  local dw_max="$2"
  local dw_has_uhs="$3"
  local have_phy="$4"
  local have_otg="$5"
  local otg_ok="$6"
  local have_usb="$7"
  local usb_periph="$8"
  local gadget_installed="$9"

  printf 'R36S DTB Doctor\n\n'
  printf 'DTB: found\n'
  printf 'Target: %s\n\n' "$TARGET_DTB"

  printf 'dwmmc@ff380000: %s\n' "$(human_yes_no "$have_dw")"
  printf 'usb2-phy@100: %s\n' "$(human_yes_no "$have_phy")"
  printf 'otg-port: %s\n' "$(human_yes_no "$have_otg")"
  printf 'usb@ff300000: %s\n\n' "$(human_yes_no "$have_usb")"

  if [ "$have_dw" -eq 1 ] && [ "$dw_max" -eq 1 ] && [ "$dw_has_uhs" -eq 0 ]; then
    printf 'SD2: patched\n'
  else
    printf 'SD2: not patched\n'
  fi

  if [ "$have_phy" -eq 1 ] && [ "$have_otg" -eq 1 ] && [ "$otg_ok" -eq 1 ]; then
    printf 'OTG: enabled\n'
  else
    printf 'OTG: disabled\n'
  fi

  if [ "$have_usb" -eq 1 ] && [ "$usb_periph" -eq 1 ]; then
    printf 'USB gadget: peripheral\n'
  else
    printf 'USB gadget: missing\n'
  fi

  printf 'USB gadget service: %s\n' "$(human_yes_no "$gadget_installed")"
}

detect_usb_gadget_service() {
  if [ -f "$USB_GADGET_TARGET_UNIT" ] && [ -f "$USB_GADGET_TARGET_BIN" ]; then
    return 0
  fi

  return 1
}

print_patch_summary() {
  if current_patched "$1"; then
    printf 'R36S DevKit DTB patches: present\n'
  else
    printf 'R36S DevKit DTB patches: absent\n'
  fi
}

doctor_only() {
  need_cmd awk
  need_cmd sed
  need_cmd sha256sum
  need_cmd cp
  need_cmd mv
  need_cmd sync

  if [ "${R36S_DTB_PATCHER_SKIP_ARCH:-0}" != "1" ]; then
    [ "$(uname -m)" = "aarch64" ] || die "This tool must run on aarch64."
  fi
  [ -d "$BOOT_DIR" ] || die "Missing /boot directory: $BOOT_DIR"
  [ -f "$TARGET_DTB" ] || die "Missing target DTB: $TARGET_DTB"
  need_cmd dtc

  setup_tmp
  local src_dts="$TMP_DIR/current.dts"
  dtc -I dtb -O dts -o "$src_dts" "$TARGET_DTB"

  local parsed
  parsed="$(inspect_dts "$src_dts")"

  eval "$parsed"
  local gadget_installed=0
  if detect_usb_gadget_service; then
    gadget_installed=1
  fi

  print_patch_summary "$src_dts"
  printf '\n'
  print_doctor_report \
    "$have_dw" \
    "$dw_max" \
    "$dw_has_uhs" \
    "$have_phy" \
    "$have_otg" \
    "$otg_ok" \
    "$have_usb" \
    "$usb_periph" \
    "$gadget_installed"
}

current_patched() {
  local src_dts="$1"
  local parsed
  parsed="$(inspect_dts "$src_dts")"
  eval "$parsed"

  if [ "${have_dw:-0}" -eq 1 ] && [ "${dw_max:-0}" -eq 1 ] && [ "${dw_has_uhs:-0}" -eq 0 ] \
    && [ "${have_phy:-0}" -eq 1 ] && [ "${have_otg:-0}" -eq 1 ] && [ "${otg_ok:-0}" -eq 1 ] \
    && [ "${have_usb:-0}" -eq 1 ] && [ "${usb_periph:-0}" -eq 1 ]; then
    return 0
  fi

  return 1
}

patch_dts() {
  local input_dts="$1"
  local output_dts="$2"

  awk '
    function node_name(line,   s) {
      s = line
      sub(/^[[:space:]]*/, "", s)
      sub(/\{[[:space:]]*$/, "", s)
      sub(/^[^[:space:]:]+:[[:space:]]*/, "", s)
      sub(/[[:space:]]*$/, "", s)
      return s
    }
    function top() {
      return sp > 0 ? stack[sp] : ""
    }
    function parent() {
      return sp > 1 ? stack[sp - 1] : ""
    }
    function push(name) {
      stack[++sp] = name
    }
    function pop() {
      if (sp > 0) {
        delete stack[sp]
        sp--
      }
    }
    {
      line = $0

      if (line ~ /\{$/) {
        name = node_name(line)
        push(name)
        print line
        next
      }

      current = top()
      if (current == "dwmmc@ff380000") {
        if (line ~ /^[[:space:]]*sd-uhs-sdr(12|25|50|104);[[:space:]]*$/) {
          next
        }
        if (line ~ /^[[:space:]]*max-frequency = <[^>]+>;/) {
          print "\t\tmax-frequency = <50000000>;"
          dw_max = 1
          next
        }
      } else if (current == "otg-port" && parent() == "usb2-phy@100") {
        if (line ~ /^[[:space:]]*status = /) {
          print "\t\tstatus = \"okay\";"
          otg_ok = 1
          next
        }
      } else if (current == "usb@ff300000") {
        if (line ~ /^[[:space:]]*dr_mode = /) {
          print "\t\tdr_mode = \"peripheral\";"
          usb_periph = 1
          next
        }
      }

      if (line ~ /^[[:space:]]*\};[[:space:]]*$/) {
        if (current == "dwmmc@ff380000" && !dw_max) {
          print "\t\tmax-frequency = <50000000>;"
        } else if (current == "otg-port" && parent() == "usb2-phy@100" && !otg_ok) {
          print "\t\tstatus = \"okay\";"
        } else if (current == "usb@ff300000" && !usb_periph) {
          print "\t\tdr_mode = \"peripheral\";"
        }
        print line
        pop()
        next
      }

      print line
    }
  ' "$input_dts" > "$output_dts"
}

install_usb_gadget_service() {
  if [ "${R36S_DTB_PATCHER_SKIP_SERVICE:-0}" = "1" ]; then
    return 0
  fi

  [ -f "$USB_GADGET_SCRIPT_SRC" ] || die "Missing usb gadget script source: $USB_GADGET_SCRIPT_SRC"
  [ -f "$USB_GADGET_SERVICE_SRC" ] || die "Missing usb gadget service source: $USB_GADGET_SERVICE_SRC"
  need_cmd systemctl
  need_cmd chmod

  mkdir -p "$USB_GADGET_TARGET_BIN_DIR"
  cp "$USB_GADGET_SCRIPT_SRC" "$USB_GADGET_TARGET_BIN"
  chmod 755 "$USB_GADGET_TARGET_BIN"
  copy_file "$USB_GADGET_SERVICE_SRC" "$USB_GADGET_TARGET_UNIT"
  maybe_sudo systemctl daemon-reload
  maybe_sudo systemctl enable r36s-usb-gadget.service
}

remove_usb_gadget_service() {
  if [ "${R36S_DTB_PATCHER_SKIP_SERVICE:-0}" = "1" ]; then
    return 0
  fi

  if [ ! -f "$USB_GADGET_TARGET_UNIT" ] && [ ! -f "$USB_GADGET_TARGET_BIN" ]; then
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    maybe_sudo systemctl disable --now r36s-usb-gadget.service >/dev/null 2>&1 || true
  fi

  maybe_sudo rm -f "$USB_GADGET_TARGET_UNIT" "$USB_GADGET_TARGET_BIN"
  if command -v systemctl >/dev/null 2>&1; then
    maybe_sudo systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

make_backup() {
  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"
  BACKUP_DIR="$BACKUP_ROOT/$timestamp"

  ensure_dir "$BACKUP_DIR"
  setup_logging

  copy_file "$TARGET_DTB" "$BACKUP_DIR/$TARGET_BASENAME"
  copy_file "$TARGET_DTB" "$PC_RECOVERY_COPY"
  local checksum_file="$TMP_DIR/original.sha256"
  local manifest_file="$TMP_DIR/manifest.txt"

  sha256sum "$TARGET_DTB" > "$checksum_file"
  {
    printf 'target=%s\n' "$TARGET_DTB"
    printf 'backup=%s\n' "$BACKUP_DIR/$TARGET_BASENAME"
    printf 'pc_recovery_copy=%s\n' "$PC_RECOVERY_COPY"
    printf 'created=%s\n' "$timestamp"
    printf 'source_sha256='
    sha256sum "$TARGET_DTB" | awk '{print $1}'
    printf '\n'
  } > "$manifest_file"

  copy_file "$checksum_file" "$BACKUP_DIR/original.sha256"
  copy_file "$manifest_file" "$BACKUP_DIR/manifest.txt"
}

find_latest_backup() {
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
    | sort -n \
    | tail -n1 \
    | cut -d' ' -f2-
}

verify_checksum() {
  local backup_dir="$1"
  (cd "$backup_dir" && sha256sum -c original.sha256)
}

write_temp_replacement() {
  local new_dtb="$1"
  local staged="$TMP_DIR/target.new"
  local target_tmp="$BOOT_DIR/.r36s-dtb-patcher.tmp"

  cp "$new_dtb" "$staged"
  sync
  copy_file "$staged" "$target_tmp"
  sync
  move_file "$target_tmp" "$TARGET_DTB"
  sync
}

mirror_log_if_possible() {
  [ -n "${LOG_FILE:-}" ] || return 0

  local mirror
  for mirror in /roms2 /roms /opt/system/Tools /home/ark; do
    if [ -d "$mirror" ] && [ -w "$mirror" ]; then
      cp "$LOG_FILE" "$mirror/r36s-dtb-patcher.log" >/dev/null 2>&1 || true
      return 0
    fi
  done
}

apply_mode() {
  need_cmd awk
  need_cmd sed
  need_cmd sha256sum
  need_cmd cp
  need_cmd mv
  need_cmd sync
  need_cmd dtc
  if [ "${R36S_DTB_PATCHER_SKIP_SERVICE:-0}" != "1" ]; then
    need_cmd systemctl
  fi

  if [ "${R36S_DTB_PATCHER_SKIP_ARCH:-0}" != "1" ]; then
    [ "$(uname -m)" = "aarch64" ] || die "This tool must run on aarch64."
  fi
  [ -d "$BOOT_DIR" ] || die "Missing /boot directory: $BOOT_DIR"
  [ -f "$TARGET_DTB" ] || die "Missing target DTB: $TARGET_DTB"

  setup_tmp

  local doctor_dts="$TMP_DIR/doctor.dts"
  dtc -I dtb -O dts -o "$doctor_dts" "$TARGET_DTB"

  local parsed
  parsed="$(inspect_dts "$doctor_dts")"
  eval "$parsed"

  if [ "$have_dw" -ne 1 ] || [ "$have_phy" -ne 1 ] || [ "$have_otg" -ne 1 ] || [ "$have_usb" -ne 1 ]; then
    die "Target DTS layout is missing required nodes."
  fi

  if current_patched "$doctor_dts"; then
    printf 'Already patched. Nothing to do.\n'
    return 0
  fi

  make_backup

  local input_dts="$TMP_DIR/input.dts"
  local patched_dts="$TMP_DIR/patched.dts"
  local rebuilt_dtb="$TMP_DIR/rebuilt.dtb"
  local verify_dts="$TMP_DIR/verify.dts"
  local original_size new_size
  local rebuilt_sha target_sha

  cp "$doctor_dts" "$input_dts"
  patch_dts "$input_dts" "$patched_dts"
  dtc -I dts -O dtb -o "$rebuilt_dtb" "$patched_dts"

  [ -s "$rebuilt_dtb" ] || die "dtc produced an empty DTB."
  original_size="$(stat -c '%s' "$TARGET_DTB")"
  new_size="$(stat -c '%s' "$rebuilt_dtb")"

  if [ "$new_size" -lt 1024 ]; then
    die "Rebuilt DTB is too small."
  fi

  if [ "$new_size" -gt $((original_size * 3)) ] || [ "$new_size" -lt $((original_size / 3)) ]; then
    die "Rebuilt DTB size looks unreasonable."
  fi

  rebuilt_sha="$(sha256sum "$rebuilt_dtb" | awk '{print $1}')"
  dtc -I dtb -O dts -o "$verify_dts" "$rebuilt_dtb"
  parsed="$(inspect_dts "$verify_dts")"
  eval "$parsed"

  if [ "$dw_max" -ne 1 ] || [ "$dw_has_uhs" -ne 0 ] || [ "$otg_ok" -ne 1 ] || [ "$usb_periph" -ne 1 ]; then
    die "Verification failed after rebuild."
  fi

  write_temp_replacement "$rebuilt_dtb"
  sync
  target_sha="$(sha256sum "$TARGET_DTB" | awk '{print $1}')"
  [ "$target_sha" = "$rebuilt_sha" ] || die "Target DTB hash mismatch after replacement."

  if [ "${R36S_DTB_PATCHER_SKIP_SERVICE:-0}" != "1" ]; then
    if ! install_usb_gadget_service; then
      printf 'Warning: usb gadget service install failed.\n' >&2
    fi
  fi

  copy_file "$LOG_FILE" "$BACKUP_DIR/patch.log"
  mirror_log_if_possible
  printf 'Patch applied. Please reboot.\n'
}

rollback_mode() {
  need_cmd awk
  need_cmd sha256sum
  need_cmd cp
  need_cmd sync

  if [ "${R36S_DTB_PATCHER_SKIP_ARCH:-0}" != "1" ]; then
    [ "$(uname -m)" = "aarch64" ] || die "This tool must run on aarch64."
  fi
  [ -d "$BOOT_DIR" ] || die "Missing /boot directory: $BOOT_DIR"
  [ -f "$TARGET_DTB" ] || die "Missing target DTB: $TARGET_DTB"

  setup_tmp

  local backup_dir
  backup_dir="$(find_latest_backup)"
  [ -n "$backup_dir" ] || die "No backups found under $BACKUP_ROOT"
  [ -f "$backup_dir/$TARGET_BASENAME" ] || die "Latest backup is incomplete: $backup_dir"
  [ -f "$backup_dir/original.sha256" ] || die "Latest backup is missing checksum: $backup_dir"

  local backup_sha target_sha target_tmp
  backup_sha="$(awk '{print $1}' "$backup_dir/original.sha256" | head -n1)"
  target_tmp="$BOOT_DIR/.r36s-dtb-rollback.tmp"
  copy_file "$backup_dir/$TARGET_BASENAME" "$target_tmp"
  sync
  move_file "$target_tmp" "$TARGET_DTB"
  copy_file "$backup_dir/$TARGET_BASENAME" "$PC_RECOVERY_COPY"
  target_sha="$(sha256sum "$TARGET_DTB" | awk '{print $1}')"
  [ "$target_sha" = "$backup_sha" ] || die "Restored DTB hash mismatch."
  verify_checksum "$backup_dir"
  sync
  mirror_log_if_possible
  printf 'Rollback complete. Please reboot.\n'
}

remove_service_mode() {
  need_cmd sync

  if [ "${R36S_DTB_PATCHER_SKIP_ARCH:-0}" != "1" ]; then
    [ "$(uname -m)" = "aarch64" ] || die "This tool must run on aarch64."
  fi

  remove_usb_gadget_service
  sync
  printf 'USB gadget service removed.\n'
}

usage() {
  cat <<'EOF'
Usage:
  r36s-dtb-patcher.sh --doctor
  r36s-dtb-patcher.sh --apply
  r36s-dtb-patcher.sh --rollback
  r36s-dtb-patcher.sh --remove-service
EOF
}

main() {
  case "${1:-}" in
    --doctor)
      doctor_only
      ;;
    --apply)
      apply_mode
      ;;
    --rollback)
      rollback_mode
      ;;
    --remove-service)
      remove_service_mode
      ;;
    -h|--help|"")
      usage
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
}

main "$@"
