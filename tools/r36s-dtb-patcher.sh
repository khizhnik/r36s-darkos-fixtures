#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

BOOT_DIR="${R36S_DTB_PATCHER_BOOT_DIR:-/boot}"
TARGET_DTB="${R36S_DTB_PATCHER_TARGET:-$BOOT_DIR/rk3326-r36s-linux.dtb}"
BACKUP_ROOT="${R36S_DTB_PATCHER_BACKUP_ROOT:-$BOOT_DIR/r36s-dtb-patcher-backups}"
PC_RECOVERY_COPY="${R36S_DTB_PATCHER_PC_RECOVERY_COPY:-$BOOT_DIR/rk3326-r36s-linux.dtb.pre-r36s-devkit}"
USB_GADGET_TARGET_BIN_DIR="/home/ark/bin"
USB_GADGET_TARGET_BIN="$USB_GADGET_TARGET_BIN_DIR/r36s-usb-gadget.sh"
USB_GADGET_TARGET_UNIT="/etc/systemd/system/r36s-usb-gadget.service"

TMP_DIR=""
LOG_FILE=""
BACKUP_DIR=""
TARGET_BASENAME="$(basename -- "$TARGET_DTB")"
CONTROLLER_MAPPER_PID=""
MENU_FALLBACK_LOG="$SCRIPT_DIR/r36s-dtb-patcher.log"
LAUNCH_DEBUG_LOG="/tmp/r36s-dtb-patcher-launch.log"
MENU_TITLE="R36S DTB Patcher"

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

have_cmd() {
  command -v "$1" >/dev/null 2>&1
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

dialog_available() {
  have_cmd dialog
}

write_launch_debug_log() {
  {
    printf 'date=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'whoami=%s\n' "$(whoami 2>/dev/null || printf unknown)"
    printf 'tty=%s\n' "$(tty 2>/dev/null || printf notty)"
    printf 'TERM=%s\n' "${TERM:-}"
    if have_cmd fgconsole; then
      printf 'fgconsole=%s\n' "$(fgconsole 2>/dev/null || printf failed)"
    else
      printf 'fgconsole=%s\n' "missing"
    fi
    printf 'dialog=%s\n' "$(command -v dialog 2>/dev/null || printf missing)"
    printf 'args=%s\n' "${*:-}"
  } >> "$LAUNCH_DEBUG_LOG" 2>/dev/null || true
}

append_launch_warning() {
  printf '%s\n' "$1" >> "$LAUNCH_DEBUG_LOG" 2>/dev/null || true
}

start_controller_mapping() {
  local mapper="/opt/inttools/gptokeyb"
  local keymap="/opt/inttools/keys.gptk"
  local status_file="/tmp/r36s-dtb-patcher-mapper.status"

  if [ ! -x "$mapper" ]; then
    append_launch_warning "Controller mapper missing: $mapper"
    return 1
  fi

  if [ ! -f "$keymap" ]; then
    append_launch_warning "Controller keymap missing: $keymap"
    return 1
  fi

  if [ -e /dev/uinput ]; then
    sudo chmod 666 /dev/uinput >/dev/null 2>&1 || true
    append_launch_warning "uinput perms: $(ls -l /dev/uinput 2>/dev/null || printf missing)"
  else
    append_launch_warning "uinput device missing"
  fi

  if [ -f /opt/inttools/gamecontrollerdb.txt ]; then
    export SDL_GAMECONTROLLERCONFIG_FILE="/opt/inttools/gamecontrollerdb.txt"
  fi

  : > "$status_file"
  "$mapper" -1 "$0" -c "$keymap" >/dev/null 2>"$status_file" &
  CONTROLLER_MAPPER_PID=$!
  sleep 0.1

  if kill -0 "$CONTROLLER_MAPPER_PID" 2>/dev/null; then
    append_launch_warning "Controller mapper started: pid=$CONTROLLER_MAPPER_PID"
    return 0
  fi

  append_launch_warning "Controller mapper failed to start: pid=$CONTROLLER_MAPPER_PID"
  if [ -s "$status_file" ]; then
    while IFS= read -r line; do
      append_launch_warning "gptokeyb: $line"
    done < "$status_file"
  fi
  rm -f "$status_file"
  CONTROLLER_MAPPER_PID=""
  return 0
}

stop_controller_mapping() {
  if [ -n "${CONTROLLER_MAPPER_PID:-}" ]; then
    kill "$CONTROLLER_MAPPER_PID" 2>/dev/null || true
    CONTROLLER_MAPPER_PID=""
  fi
}

run_with_capture() {
  local output_file="$1"
  shift

  (
    "$@"
  ) >"$output_file" 2>&1
}

record_technical_output() {
  local output_file="$1"

  if [ -n "${LOG_FILE:-}" ] && [ -w "$(dirname -- "$LOG_FILE")" ]; then
    cat "$output_file" >> "$LOG_FILE" 2>/dev/null || true
    return 0
  fi

  cat "$output_file" >> "$LAUNCH_DEBUG_LOG" 2>/dev/null || true
}

filter_dialog_output() {
  local input_file="$1"
  local output_file="$2"

  awk '
    !($0 ~ /Warning \(/ || $0 ~ /: Warning \(/)
  ' "$input_file" > "$output_file"
}

show_textbox_file() {
  local title="$1"
  local file="$2"
  local height="${3:-22}"
  local width="${4:-78}"

  dialog --backtitle "$MENU_TITLE" --title "$title" --textbox "$file" "$height" "$width" || true
}

show_result_textbox() {
  local title="$1"
  local file="$2"
  local height="${3:-22}"
  local width="${4:-78}"

  show_textbox_file "$title" "$file" "$height" "$width" || true
}

show_doctor_dialog() {
  local tmp_out ui_out

  tmp_out="$(mktemp)"
  ui_out="$(mktemp)"
  if run_with_capture "$tmp_out" doctor_only; then
    record_technical_output "$tmp_out"
    filter_dialog_output "$tmp_out" "$ui_out"
    show_result_textbox "$MENU_TITLE - Status" "$ui_out" 24 78
  else
    record_technical_output "$tmp_out"
    filter_dialog_output "$tmp_out" "$ui_out"
    show_result_textbox "$MENU_TITLE - Status (failed)" "$ui_out" 24 78
  fi
  rm -f "$tmp_out"
  rm -f "$ui_out"
}

show_action_dialog() {
  local title="$1"
  local action="$2"
  local tmp_out ui_out

  tmp_out="$(mktemp)"
  ui_out="$(mktemp)"
  if run_with_capture "$tmp_out" "$action"; then
    record_technical_output "$tmp_out"
    filter_dialog_output "$tmp_out" "$ui_out"
    show_result_textbox "$title" "$ui_out" 24 78
  else
    record_technical_output "$tmp_out"
    filter_dialog_output "$tmp_out" "$ui_out"
    show_result_textbox "$title (failed)" "$ui_out" 24 78
  fi
  rm -f "$tmp_out"
  rm -f "$ui_out"
}

dialog_confirm_action() {
  local prompt="$1"

  dialog --backtitle "$MENU_TITLE" --yes-label "Yes" --no-label "No" --yesno "$prompt" 10 54
}

dialog_menu() {
  while true; do
    local choice_file choice rc
    choice_file="$(mktemp)"
    if dialog --cancel-label "Exit" --backtitle "$MENU_TITLE" --title " [ Main Menu ] " --menu "Use arrows to move, A to select, B to exit." 15 60 5 \
      1 "Check status" \
      2 "Apply DTB patch" \
      3 "Rollback DTB" \
      4 "Remove USB gadget service" \
      5 "Exit" 2> "$choice_file"; then
      choice="$(<"$choice_file")"
      rm -f "$choice_file"
      case "$choice" in
        1)
          show_doctor_dialog
          ;;
        2)
          if dialog_confirm_action "Apply DTB patch?"; then
            show_action_dialog "$MENU_TITLE - Apply" apply_mode
          fi
          ;;
        3)
          if dialog_confirm_action "Rollback DTB?"; then
            show_action_dialog "$MENU_TITLE - Rollback" rollback_mode
          fi
          ;;
        4)
          if dialog_confirm_action "Remove USB gadget service?"; then
            show_action_dialog "$MENU_TITLE - Remove service" remove_service_mode
          fi
          ;;
        5)
          return 0
          ;;
      esac
      continue
    fi

    rc=$?
    rm -f "$choice_file"
    case "$rc" in
      1|255)
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  done
}

prepare_console_ui() {
  local console_num tty_path

  [ -z "${TERM:-}" ] && export TERM=linux

  console_num=1
  if have_cmd fgconsole; then
    console_num="$(fgconsole 2>/dev/null || printf '1')"
  fi
  case "$console_num" in
    ''|*[!0-9]*)
      console_num=1
      ;;
  esac

  tty_path="/dev/tty${console_num}"
  [ -e "$tty_path" ] || tty_path="/dev/tty1"

  if [ -e "$tty_path" ]; then
    if exec <"$tty_path" >"$tty_path" 2>&1; then
      printf '\033c' > "$tty_path" || true
      return 0
    fi
  fi

  return 1
}

cleanup_launcher() {
  stop_controller_mapping
  cleanup
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

  need_cmd systemctl
  need_cmd chmod
  need_cmd cat
  need_cmd mkdir
  need_cmd cp

  maybe_sudo mkdir -p "$USB_GADGET_TARGET_BIN_DIR"
  local gadget_script_tmp="$TMP_DIR/r36s-usb-gadget.sh"
  local gadget_service_tmp="$TMP_DIR/r36s-usb-gadget.service"

  cat > "$gadget_script_tmp" <<'EOF'
#!/bin/bash
set +e

LOG="/home/ark/r36s-usb-gadget.log"

{
echo "=== R36S USB GADGET START ==="
date

modprobe -r g_ether 2>/dev/null || true
modprobe g_ether dev_addr=02:36:36:00:00:02 host_addr=02:36:36:00:00:01

sleep 2

ip link set usb0 up
ip addr flush dev usb0
ip addr add 192.168.7.2/24 dev usb0

systemctl start ssh 2>/dev/null || true
systemctl start sshd 2>/dev/null || true

echo "--- ip addr usb0 ---"
ip addr show usb0 2>&1

echo "--- modules ---"
lsmod | grep -Ei "g_ether|u_ether|usb_f|libcomposite|dwc2" || true

echo "--- dmesg ---"
dmesg | grep -Ei "g_ether|rndis|ether|usb0|dwc2|gadget" | tail -80

echo "=== R36S USB GADGET END ==="
date
} >> "$LOG" 2>&1
EOF
  cat > "$gadget_service_tmp" <<'EOF'
[Unit]
Description=R36S USB Ethernet Gadget
After=local-fs.target systemd-modules-load.service ssh.service
Wants=ssh.service

[Service]
Type=oneshot
ExecStart=/home/ark/bin/r36s-usb-gadget.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  maybe_sudo cp "$gadget_script_tmp" "$USB_GADGET_TARGET_BIN"
  maybe_sudo chmod 755 "$USB_GADGET_TARGET_BIN"
  maybe_sudo cp "$gadget_service_tmp" "$USB_GADGET_TARGET_UNIT"
  maybe_sudo systemctl daemon-reload
  maybe_sudo systemctl enable --now r36s-usb-gadget.service
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

pause_for_enter() {
  printf '\nPress Enter to continue...'
  read -r _
}

confirm_dangerous_action() {
  local prompt="$1"
  local answer

  printf '%s\n' "$prompt"
  printf 'Type YES to continue: '
  read -r answer

  if [ "$answer" != "YES" ]; then
    printf 'Operation cancelled.\n'
    return 1
  fi

  return 0
}

interactive_menu() {
  while true; do
    printf 'R36S DTB Patcher\n\n'
    printf '1) Check status\n'
    printf '2) Apply DTB patch\n'
    printf '3) Rollback DTB\n'
    printf '4) Remove USB gadget service\n'
    printf '5) Exit\n'
    printf '\nSelect an option: '

    local choice
    read -r choice || return 1

    case "$choice" in
      1)
        doctor_only
        pause_for_enter
        ;;
      2)
        if confirm_dangerous_action 'Apply DTB patch?'; then
          apply_mode
        fi
        pause_for_enter
        ;;
      3)
        if confirm_dangerous_action 'Rollback DTB?'; then
          rollback_mode
        fi
        pause_for_enter
        ;;
      4)
        if confirm_dangerous_action 'Remove USB gadget service?'; then
          remove_service_mode
        fi
        pause_for_enter
        ;;
      5)
        return 0
        ;;
      *)
        printf 'Invalid selection.\n'
        pause_for_enter
        ;;
    esac
  done
}

text_menu_entry() {
  interactive_menu
}

log_menu_fallback() {
  local reason="$1"

  {
    printf '%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$reason"
  } >> "$MENU_FALLBACK_LOG" 2>/dev/null || true
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
  if [ "$#" -eq 0 ]; then
    write_launch_debug_log "$@"
    if prepare_console_ui; then
      start_controller_mapping || true
      trap cleanup_launcher EXIT INT TERM
      if dialog_available; then
        dialog_menu
      else
        text_menu_entry
      fi
      cleanup_launcher
    else
      log_menu_fallback 'No interactive tty available, printed usage.'
      usage
      cleanup_launcher
    fi
    return 0
  fi

  case "$1" in
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
    -h|--help)
      usage
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
}

main "$@"
