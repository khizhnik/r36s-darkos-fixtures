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
ES_DUMMY_AUDIO_DROPIN_DIR="/etc/systemd/system/emulationstation.service.d"
ES_DUMMY_AUDIO_DROPIN="$ES_DUMMY_AUDIO_DROPIN_DIR/r36s-audio.conf"
ES_HOME_DIR="/home/ark"
ES_GAME_START_DIR="$ES_HOME_DIR/.emulationstation/scripts/game-start"
ES_GAME_END_DIR="$ES_HOME_DIR/.emulationstation/scripts/game-end"
ES_AUDIO_ON_HOOK="$ES_GAME_START_DIR/r36s-audio-on.sh"
ES_AUDIO_OFF_HOOK="$ES_GAME_END_DIR/r36s-audio-off.sh"

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

human_yes_no_partial() {
  case "$1" in
    1|yes|YES)
      printf 'yes'
      ;;
    2|partial|PARTIAL)
      printf 'partial'
      ;;
    *)
      printf 'no'
      ;;
  esac
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
        } else if (name == "codec" && parent() == "pmic@20") {
          have_audio_codec = 1
        } else if (name == "simple-audio-card,codec" && parent() == "rk817-sound") {
          have_audio_card_codec = 1
        } else if (name == "gpio3@ff270000") {
          have_gpio3 = 1
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
      } else if (current == "codec" && parent() == "pmic@20") {
        if (line ~ /^[[:space:]]*spk-ctl-gpios = /) {
          audio_spk_ctl = 1
        }
        if (line ~ /^[[:space:]]*spk-mute-delay-ms = /) {
          audio_spk_mute = 1
        }
      } else if (current == "simple-audio-card,codec" && parent() == "rk817-sound") {
        if (line ~ /^[[:space:]]*spk-con-gpio = /) {
          audio_spk_con = 1
        }
      } else if (current == "gpio3@ff270000") {
        if (line ~ /^[[:space:]]*phandle = <([^>]+)>;/) {
          tmp = line
          sub(/^.*phandle = </, "", tmp)
          sub(/>;[[:space:]]*$/, "", tmp)
          gpio3_phandle = tmp
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
      print "have_audio_codec=" (have_audio_codec ? 1 : 0)
      print "have_audio_card_codec=" (have_audio_card_codec ? 1 : 0)
      print "have_gpio3=" (have_gpio3 ? 1 : 0)
      print "audio_spk_ctl=" (audio_spk_ctl ? 1 : 0)
      print "audio_spk_mute=" (audio_spk_mute ? 1 : 0)
      print "audio_spk_con=" (audio_spk_con ? 1 : 0)
      print "gpio3_phandle=" gpio3_phandle
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
  local audio_noise_present="${10}"
  local es_dummy_audio_present="${11}"

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
  printf 'Audio DTB patch: %s\n' "$(human_yes_no "$audio_noise_present")"
  printf 'ES dummy audio: %s\n' "$(human_yes_no_partial "$es_dummy_audio_present")"
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

dialog_confirm_experimental_action() {
  local prompt="$1"

  dialog --backtitle "$MENU_TITLE" --yes-label "Yes" --no-label "No" --yesno "$prompt" 16 78
}

dialog_menu() {
  while true; do
    local choice_file choice rc
    choice_file="$(mktemp)"
    if dialog --cancel-label "Exit" --backtitle "$MENU_TITLE" --title " [ Main Menu ] " --menu "Use arrows to move, A to select, B to exit." 16 68 6 \
      1 "Check status" \
      2 "Apply DTB patch" \
      3 "Rollback DTB" \
      4 "Remove USB gadget service" \
      5 "Reduce Speaker Noise" \
      6 "Exit" 2> "$choice_file"; then
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
          reduce_speaker_noise_dialog_menu
          ;;
        6)
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

restart_emulationstation_after_confirmation() {
  local prompt="$1"

  if confirm_dangerous_action "$prompt"; then
    maybe_sudo systemctl restart emulationstation
    return 0
  fi

  return 1
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
  local audio_noise_present=0
  if detect_usb_gadget_service; then
    gadget_installed=1
  fi
  if current_audio_noise_patched "$src_dts"; then
    audio_noise_present=1
  fi
  local es_dummy_audio_present
  es_dummy_audio_present="$(es_dummy_audio_state)"

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
    "$gadget_installed" \
    "${audio_noise_present:-0}" \
    "${es_dummy_audio_present:-0}"
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

audio_noise_patched() {
  local src_dts="$1"
  local parsed
  parsed="$(inspect_dts "$src_dts")"
  eval "$parsed"

  if [ "${have_audio_codec:-0}" -eq 1 ] && [ "${have_audio_card_codec:-0}" -eq 1 ] \
    && [ "${audio_spk_ctl:-0}" -eq 1 ] && [ "${audio_spk_con:-0}" -eq 1 ]; then
    return 0
  fi

  return 1
}

current_audio_noise_patched() {
  local src_dts="$1"
  local parsed
  parsed="$(inspect_dts "$src_dts")"
  eval "$parsed"

  if [ "${have_audio_codec:-0}" -eq 1 ] && [ "${have_audio_card_codec:-0}" -eq 1 ] \
    && [ "${audio_spk_ctl:-0}" -eq 1 ] && [ "${audio_spk_mute:-0}" -eq 1 ] \
    && [ "${audio_spk_con:-0}" -eq 1 ] && [ -n "${gpio3_phandle:-}" ]; then
    return 0
  fi

  return 1
}

es_dummy_audio_patched() {
  [ "$(es_dummy_audio_state)" = "yes" ]
}

es_dummy_audio_state() {
  local dropin_ok=0
  local hook_on_ok=0
  local hook_off_ok=0
  local any_ok=0

  if [ -f "$ES_DUMMY_AUDIO_DROPIN" ]; then
    any_ok=1
    if grep -qxF 'Environment=SDL_AUDIODRIVER=dummy' "$ES_DUMMY_AUDIO_DROPIN"; then
      dropin_ok=1
    fi
  fi

  if [ -e "$ES_AUDIO_ON_HOOK" ]; then
    any_ok=1
    if [ -x "$ES_AUDIO_ON_HOOK" ] \
      && grep -qxF "amixer set 'Playback Path' SPK_HP >/dev/null 2>&1 || true" "$ES_AUDIO_ON_HOOK"; then
      hook_on_ok=1
    fi
  fi

  if [ -e "$ES_AUDIO_OFF_HOOK" ]; then
    any_ok=1
    if [ -x "$ES_AUDIO_OFF_HOOK" ] \
      && grep -qxF "amixer set 'Playback Path' OFF >/dev/null 2>&1 || true" "$ES_AUDIO_OFF_HOOK"; then
      hook_off_ok=1
    fi
  fi

  if [ "$dropin_ok" -eq 1 ] && [ "$hook_on_ok" -eq 1 ] && [ "$hook_off_ok" -eq 1 ]; then
    printf 'yes'
  elif [ "$any_ok" -eq 1 ]; then
    printf 'partial'
  else
    printf 'no'
  fi
}

managed_es_dummy_audio_dropin_content() {
  cat <<'EOF'
[Service]
Environment=SDL_AUDIODRIVER=dummy
EOF
}

managed_es_dummy_audio_start_hook_content() {
  cat <<'EOF'
#!/bin/bash
amixer set 'Playback Path' SPK_HP >/dev/null 2>&1 || true
EOF
}

managed_es_dummy_audio_end_hook_content() {
  cat <<'EOF'
#!/bin/bash
amixer set 'Playback Path' OFF >/dev/null 2>&1 || true
EOF
}

replace_managed_file_if_needed() {
  local dest="$1"
  local new_file="$2"
  local bak_prefix="$3"
  local mode="$4"
  local timestamp

  timestamp="$(date +%Y%m%d-%H%M%S)"

  if [ -f "$dest" ]; then
    if cmp -s "$dest" "$new_file"; then
      :
    else
      copy_file "$dest" "$dest.$bak_prefix-$timestamp"
    fi
  fi

  copy_file "$new_file" "$dest"
  maybe_sudo chmod "$mode" "$dest" >/dev/null 2>&1 || true
}

patch_audio_noise_dts() {
  local input_dts="$1"
  local output_dts="$2"
  local gpio3_phandle="$3"
  local audio_spk_ctl_present="$4"
  local audio_spk_mute_present="$5"
  local audio_spk_con_present="$6"

  [ -n "$gpio3_phandle" ] || die "Could not resolve gpio3 phandle from DTS."

  awk \
    -v gpio3_phandle="$gpio3_phandle" \
    -v audio_spk_ctl_present="$audio_spk_ctl_present" \
    -v audio_spk_mute_present="$audio_spk_mute_present" \
    -v audio_spk_con_present="$audio_spk_con_present" '
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
    function print_audio_codec_inserts() {
      if (!audio_ctl_inserted && audio_spk_ctl_present != 1) {
        print "\t\t\tspk-ctl-gpios = <" gpio3_phandle " 0x07 0x00>;"
        audio_ctl_inserted = 1
      }
      if (!audio_mute_inserted && audio_spk_mute_present != 1) {
        print "\t\t\tspk-mute-delay-ms = <0x32>;"
        audio_mute_inserted = 1
      }
    }
    function print_audio_card_inserts() {
      if (!audio_con_inserted && audio_spk_con_present != 1) {
        print "\t\t\tspk-con-gpio = <" gpio3_phandle " 0x07 0x00>;"
        audio_con_inserted = 1
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
      if (current == "codec" && parent() == "pmic@20") {
        if (line ~ /^[[:space:]]*spk-ctl-gpios = /) {
          audio_spk_ctl = 1
        }
        if (line ~ /^[[:space:]]*spk-mute-delay-ms = /) {
          audio_spk_mute = 1
        }
        if (line ~ /^[[:space:]]*pinctrl-0 = /) {
          print line
          print_audio_codec_inserts()
          next
        }
      } else if (current == "simple-audio-card,codec" && parent() == "rk817-sound") {
        if (line ~ /^[[:space:]]*spk-con-gpio = /) {
          audio_spk_con = 1
        }
        if (line ~ /^[[:space:]]*sound-dai = /) {
          print line
          print_audio_card_inserts()
          next
        }
      }

      if (line ~ /^[[:space:]]*\};[[:space:]]*$/) {
        if (current == "codec" && parent() == "pmic@20") {
          print_audio_codec_inserts()
        } else if (current == "simple-audio-card,codec" && parent() == "rk817-sound") {
          print_audio_card_inserts()
        }
        print line
        pop()
        next
      }

      print line
    }
  ' "$input_dts" > "$output_dts"
}

unpatch_audio_noise_dts() {
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
      if (current == "codec" && parent() == "pmic@20") {
        if (line ~ /^[[:space:]]*spk-ctl-gpios = /) {
          next
        }
        if (line ~ /^[[:space:]]*spk-mute-delay-ms = /) {
          next
        }
      } else if (current == "simple-audio-card,codec" && parent() == "rk817-sound") {
        if (line ~ /^[[:space:]]*spk-con-gpio = /) {
          next
        }
      }

      if (line ~ /^[[:space:]]*\};[[:space:]]*$/) {
        print line
        pop()
        next
      }

      print line
    }
  ' "$input_dts" > "$output_dts"
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

patch_audio_noise_mode() {
  need_cmd awk
  need_cmd sed
  need_cmd sha256sum
  need_cmd cp
  need_cmd mv
  need_cmd sync
  need_cmd dtc

  if [ "${R36S_DTB_PATCHER_SKIP_ARCH:-0}" != "1" ]; then
    [ "$(uname -m)" = "aarch64" ] || die "This tool must run on aarch64."
  fi
  [ -d "$BOOT_DIR" ] || die "Missing /boot directory: $BOOT_DIR"
  [ -f "$TARGET_DTB" ] || die "Missing target DTB: $TARGET_DTB"

  setup_tmp
  setup_logging

  local status_dts="$TMP_DIR/audio-status.dts"
  dtc -I dtb -O dts -o "$status_dts" "$TARGET_DTB"

  local parsed gpio3_phandle
  parsed="$(inspect_dts "$status_dts")"
  eval "$parsed"

  if [ "${have_audio_codec:-0}" -ne 1 ] || [ "${have_audio_card_codec:-0}" -ne 1 ] || [ "${have_gpio3:-0}" -ne 1 ]; then
    die "Target DTS layout is missing required audio nodes."
  fi

  gpio3_phandle="${gpio3_phandle:-}"
  if [ -z "$gpio3_phandle" ]; then
    die "Could not resolve gpio3 phandle from DTS."
  fi

  if [ "${audio_spk_ctl:-0}" -eq 1 ] && [ "${audio_spk_mute:-0}" -eq 1 ] && [ "${audio_spk_con:-0}" -eq 1 ]; then
    printf 'Experimental speaker noise patch already applied. Nothing to do.\n'
    return 0
  fi

  make_backup "audio-noise"

  local input_dts="$TMP_DIR/audio-input.dts"
  local patched_dts="$TMP_DIR/audio-patched.dts"
  local rebuilt_dtb="$TMP_DIR/audio-rebuilt.dtb"
  local verify_dts="$TMP_DIR/audio-verify.dts"
  local original_size new_size
  local rebuilt_sha target_sha

  cp "$doctor_dts" "$input_dts"
  patch_audio_noise_dts \
    "$input_dts" \
    "$patched_dts" \
    "$gpio3_phandle" \
    "${audio_spk_ctl:-0}" \
    "${audio_spk_mute:-0}" \
    "${audio_spk_con:-0}"
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

  if [ "${audio_spk_ctl:-0}" -ne 1 ] || [ "${audio_spk_mute:-0}" -ne 1 ] || [ "${audio_spk_con:-0}" -ne 1 ]; then
    die "Verification failed after audio patch rebuild."
  fi

  write_temp_replacement "$rebuilt_dtb"
  sync
  target_sha="$(sha256sum "$TARGET_DTB" | awk '{print $1}')"
  [ "$target_sha" = "$rebuilt_sha" ] || die "Target DTB hash mismatch after replacement."

  copy_file "$LOG_FILE" "$BACKUP_DIR/patch.log"
  {
    printf 'patch_applied=audio-noise\n'
    printf 'patch_kind=audio-noise\n'
    printf 'gpio3_phandle=%s\n' "$gpio3_phandle"
    printf 'spk_ctl_gpio=gpio3 pin7 active-high\n'
    printf 'spk_con_gpio=gpio3 pin7 active-high\n'
  } >> "$BACKUP_DIR/manifest.txt"
  mirror_log_if_possible
  printf 'Experimental speaker noise patch applied. Please reboot.\n'
}

restore_audio_noise_mode() {
  need_cmd awk
  need_cmd sha256sum
  need_cmd cp
  need_cmd mv
  need_cmd sync

  if [ "${R36S_DTB_PATCHER_SKIP_ARCH:-0}" != "1" ]; then
    [ "$(uname -m)" = "aarch64" ] || die "This tool must run on aarch64."
  fi
  [ -d "$BOOT_DIR" ] || die "Missing /boot directory: $BOOT_DIR"
  [ -f "$TARGET_DTB" ] || die "Missing target DTB: $TARGET_DTB"

  setup_tmp

  local status_dts="$TMP_DIR/audio-status.dts"
  dtc -I dtb -O dts -o "$status_dts" "$TARGET_DTB"

  local parsed
  parsed="$(inspect_dts "$status_dts")"
  eval "$parsed"

  if [ "${audio_spk_ctl:-0}" -ne 1 ] && [ "${audio_spk_con:-0}" -ne 1 ] && [ "${audio_spk_mute:-0}" -ne 1 ]; then
    printf 'Experimental speaker noise patch already absent. Nothing to do.\n'
    return 0
  fi

  local backup_dir
  backup_dir="$(find_latest_backup_by_kind audio-noise)"

  if [ -n "$backup_dir" ] && [ -f "$backup_dir/$TARGET_BASENAME" ] && [ -f "$backup_dir/original.sha256" ]; then
    local backup_sha target_sha target_tmp
    backup_sha="$(awk '{print $1}' "$backup_dir/original.sha256" | head -n1)"
    target_tmp="$BOOT_DIR/.r36s-audio-restore.tmp"
    copy_file "$backup_dir/$TARGET_BASENAME" "$target_tmp"
    sync
    move_file "$target_tmp" "$TARGET_DTB"
    copy_file "$backup_dir/$TARGET_BASENAME" "$PC_RECOVERY_COPY"
    target_sha="$(sha256sum "$TARGET_DTB" | awk '{print $1}')"
    [ "$target_sha" = "$backup_sha" ] || die "Restored DTB hash mismatch."
    verify_checksum "$backup_dir"
    sync
    mirror_log_if_possible
    printf 'Experimental speaker noise patch restored. Please reboot.\n'
    return 0
  fi

  local input_dts="$TMP_DIR/audio-input.dts"
  local restored_dts="$TMP_DIR/audio-restored.dts"
  local rebuilt_dtb="$TMP_DIR/audio-restored.dtb"
  local verify_dts="$TMP_DIR/audio-verify.dts"
  local original_size new_size
  local rebuilt_sha target_sha
  local gpio3_phandle="${gpio3_phandle:-}"

  if [ -z "$gpio3_phandle" ]; then
    gpio3_phandle="$(printf '%s\n' "$parsed" | awk -F= '/^gpio3_phandle=/ {print $2; exit}')"
  fi
  [ -n "$gpio3_phandle" ] || die "Could not resolve gpio3 phandle from DTS."

  cp "$doctor_dts" "$input_dts"
  unpatch_audio_noise_dts "$input_dts" "$restored_dts"
  dtc -I dts -O dtb -o "$rebuilt_dtb" "$restored_dts"

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

  if [ "${audio_spk_ctl:-0}" -eq 1 ] || [ "${audio_spk_mute:-0}" -eq 1 ] || [ "${audio_spk_con:-0}" -eq 1 ]; then
    die "Verification failed after audio patch restore."
  fi

  write_temp_replacement "$rebuilt_dtb"
  sync
  target_sha="$(sha256sum "$TARGET_DTB" | awk '{print $1}')"
  [ "$target_sha" = "$rebuilt_sha" ] || die "Target DTB hash mismatch after replacement."
  mirror_log_if_possible
  printf 'Experimental speaker noise patch restored. Please reboot.\n'
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
  local patch_kind="${1:-full}"
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
    printf 'patch_kind=%s\n' "$patch_kind"
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

find_latest_backup_by_kind() {
  local kind="$1"
  local latest=""
  local dir manifest

  while IFS= read -r dir; do
    manifest="$dir/manifest.txt"
    if [ -f "$manifest" ] && grep -q "^patch_kind=$kind$" "$manifest" 2>/dev/null; then
      latest="$dir"
    fi
  done <<EOF
$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2-)
EOF

  printf '%s\n' "$latest"
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

experimental_noise_patch_warning() {
  cat <<'EOF'
This is an experimental R36S speaker noise reduction patch.
It adds RK817 speaker amplifier control from known R36S donor DTBs.
It reduced noise on one tested unit but may not improve all hardware revisions.
A backup will be created. Reboot is required.
EOF
}

experimental_noise_restore_warning() {
  cat <<'EOF'
This restores the previous DTB/audio state.
Use this if sound became worse or your device behaved better before the noise patch.
Reboot is required.
EOF
}

experimental_dummy_audio_patch_warning() {
  cat <<'EOF'
This experimental userspace patch makes EmulationStation use SDL dummy audio so it does not keep ALSA playback open while idle.
It fixed idle menu hiss on one tested R36S-V1.0 2024-09-27 unit.
Games were still able to use ALSA audio directly in testing.
Hardware and firmware revisions may vary.
EOF
}

experimental_dummy_audio_restore_warning() {
  cat <<'EOF'
This removes only the R36S managed EmulationStation dummy audio drop-in.
Use this if menus, game launching, or audio behavior became worse.
EOF
}

patch_es_dummy_audio_mode() {
  need_cmd grep
  need_cmd cmp
  need_cmd cp
  need_cmd sync
  need_cmd systemctl

  if [ "${R36S_DTB_PATCHER_SKIP_ARCH:-0}" != "1" ]; then
    [ "$(uname -m)" = "aarch64" ] || die "This tool must run on aarch64."
  fi

  setup_tmp

  local current_file="$ES_DUMMY_AUDIO_DROPIN"
  local new_file="$TMP_DIR/r36s-audio.conf"
  local hook_on_new="$TMP_DIR/r36s-audio-on.sh"
  local hook_off_new="$TMP_DIR/r36s-audio-off.sh"
  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"

  ensure_dir "$ES_DUMMY_AUDIO_DROPIN_DIR"
  ensure_dir "$ES_GAME_START_DIR"
  ensure_dir "$ES_GAME_END_DIR"

  managed_es_dummy_audio_dropin_content > "$new_file"
  managed_es_dummy_audio_start_hook_content > "$hook_on_new"
  managed_es_dummy_audio_end_hook_content > "$hook_off_new"

  if es_dummy_audio_patched; then
    printf 'EmulationStation dummy audio patch already applied. Nothing to do.\n'
    return 0
  fi

  if [ -f "$current_file" ] && ! grep -qxF 'Environment=SDL_AUDIODRIVER=dummy' "$current_file"; then
    copy_file "$current_file" "$ES_DUMMY_AUDIO_DROPIN.bak-$timestamp"
  fi
  if [ -f "$ES_AUDIO_ON_HOOK" ] && ! cmp -s "$ES_AUDIO_ON_HOOK" "$hook_on_new"; then
    copy_file "$ES_AUDIO_ON_HOOK" "$ES_AUDIO_ON_HOOK.bak-$timestamp"
  fi
  if [ -f "$ES_AUDIO_OFF_HOOK" ] && ! cmp -s "$ES_AUDIO_OFF_HOOK" "$hook_off_new"; then
    copy_file "$ES_AUDIO_OFF_HOOK" "$ES_AUDIO_OFF_HOOK.bak-$timestamp"
  fi

  copy_file "$new_file" "$current_file"
  maybe_sudo chmod 0644 "$current_file" >/dev/null 2>&1 || true
  copy_file "$hook_on_new" "$ES_AUDIO_ON_HOOK"
  copy_file "$hook_off_new" "$ES_AUDIO_OFF_HOOK"
  maybe_sudo chmod 0755 "$ES_AUDIO_ON_HOOK" "$ES_AUDIO_OFF_HOOK" >/dev/null 2>&1 || true
  maybe_sudo systemctl daemon-reload
  printf 'Patch applied.\n\nPlease reboot the device\nto complete this change.\n'
  return 0
}

restore_es_dummy_audio_mode() {
  need_cmd grep
  need_cmd sync
  need_cmd systemctl

  if [ "${R36S_DTB_PATCHER_SKIP_ARCH:-0}" != "1" ]; then
    [ "$(uname -m)" = "aarch64" ] || die "This tool must run on aarch64."
  fi

  setup_tmp

  local current_file="$ES_DUMMY_AUDIO_DROPIN"

  if [ ! -f "$current_file" ] && [ ! -e "$ES_AUDIO_ON_HOOK" ] && [ ! -e "$ES_AUDIO_OFF_HOOK" ]; then
    printf 'EmulationStation audio already restored. Nothing to do.\n'
    return 0
  fi

  maybe_sudo rm -f "$current_file"
  maybe_sudo rm -f "$ES_AUDIO_ON_HOOK"
  maybe_sudo rm -f "$ES_AUDIO_OFF_HOOK"
  maybe_sudo systemctl daemon-reload
  printf 'Audio restored.\n\nPlease reboot the device\nto complete this change.\n'
  return 0
}

speaker_noise_text_menu() {
  while true; do
    printf 'Reduce Speaker Noise (experimental)\n\n'
    printf '1) Patch DTB Speaker Control\n'
    printf '2) Restore DTB Speaker Control\n'
    printf '3) Patch EmulationStation Dummy Audio\n'
    printf '4) Restore EmulationStation Audio\n'
    printf '5) Back\n'
    printf '\nSelect an option: '

    local choice
    read -r choice || return 1

    case "$choice" in
      1)
        if confirm_dangerous_action "$(experimental_noise_patch_warning)"; then
          patch_audio_noise_mode
        fi
        pause_for_enter
        ;;
      2)
        if confirm_dangerous_action "$(experimental_noise_restore_warning)"; then
          restore_audio_noise_mode
        fi
        pause_for_enter
        ;;
      3)
        if confirm_dangerous_action "$(experimental_dummy_audio_patch_warning)"; then
          patch_es_dummy_audio_mode
        fi
        pause_for_enter
        ;;
      4)
        if confirm_dangerous_action "$(experimental_dummy_audio_restore_warning)"; then
          restore_es_dummy_audio_mode
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

reduce_speaker_noise_dialog_menu() {
  while true; do
    local choice_file choice rc
    choice_file="$(mktemp)"
    if dialog --cancel-label "Back" --backtitle "$MENU_TITLE" --title " Reduce Speaker Noise (experimental) " --menu "This patch is experimental." 16 78 5 \
      1 "Patch DTB Speaker Control" \
      2 "Restore DTB Speaker Control" \
      3 "Patch EmulationStation Dummy Audio" \
      4 "Restore EmulationStation Audio" \
      5 "Back" 2> "$choice_file"; then
      choice="$(<"$choice_file")"
      rm -f "$choice_file"
      case "$choice" in
        1)
          if dialog_confirm_experimental_action "$(experimental_noise_patch_warning)"; then
            show_action_dialog "$MENU_TITLE - Reduce Speaker Noise (experimental) - DTB Speaker Control" patch_audio_noise_mode
          fi
          ;;
        2)
          if dialog_confirm_experimental_action "$(experimental_noise_restore_warning)"; then
            show_action_dialog "$MENU_TITLE - Reduce Speaker Noise (experimental) - Restore DTB Speaker Control" restore_audio_noise_mode
          fi
          ;;
        3)
          if dialog_confirm_experimental_action "$(experimental_dummy_audio_patch_warning)"; then
            show_action_dialog "$MENU_TITLE - Reduce Speaker Noise (experimental) - EmulationStation Dummy Audio" patch_es_dummy_audio_mode
          fi
          ;;
        4)
          if dialog_confirm_experimental_action "$(experimental_dummy_audio_restore_warning)"; then
            show_action_dialog "$MENU_TITLE - Reduce Speaker Noise (experimental) - Restore EmulationStation Audio" restore_es_dummy_audio_mode
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

interactive_menu() {
  while true; do
    printf 'R36S DTB Patcher\n\n'
    printf '1) Check status\n'
    printf '2) Apply DTB patch\n'
    printf '3) Rollback DTB\n'
    printf '4) Remove USB gadget service\n'
    printf '5) Reduce Speaker Noise\n'
    printf '6) Exit\n'
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
        if dialog_available; then
          reduce_speaker_noise_dialog_menu
        else
          speaker_noise_text_menu
        fi
        ;;
      6)
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
