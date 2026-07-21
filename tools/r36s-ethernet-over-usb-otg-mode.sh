#!/bin/bash
set -u
set -o pipefail

USB0_ADDR="192.168.7.2/24"
USB0_HOST_MSG="ssh ark@192.168.7.2"
DWC2_DEV="/sys/bus/platform/devices/ff300000.usb"
DWC2_BIND_PATH="/sys/bus/platform/drivers/dwc2/bind"
DWC2_UNBIND_PATH="/sys/bus/platform/drivers/dwc2/unbind"
UDC_PATH="/sys/class/udc/ff300000.usb"
LOG_FILE=""
OTG_PATH=""
SSH_UNIT=""
POST_DESTRUCTIVE=0
DIAG_DIR=""
RUN_LOG_FILE=""
FAST_STATE_FILE=""
KERNEL_LOG_FILE=""
PROCESS_EVENTS_FILE=""
BEFORE_CABLE_FILE=""
FIRST_CONFIGURED_FILE=""
FIRST_DISCONNECT_FILE=""
POST_DISCONNECT_FILE=""
FINAL_STATE_FILE=""
FAST_STATE_BYTES=0
KERNEL_LOG_BYTES=0
PROCESS_EVENTS_BYTES=0
FAST_STATE_PID=""
KERNEL_LOG_PID=""
PROCESS_EVENTS_PID=""
POST_DISCONNECT_PID=""
DISCONNECT_CAPTURE_ACTIVE=0
DISCONNECT_CAPTURE_CLEANED=0
DIAG_CONFIGURED_SEEN=0
DIAG_DISCONNECT_SEEN=0
DIAG_RECONNECTED_SEEN=0
DIAG_POST_100_DONE=0
DIAG_POST_500_DONE=0
DIAG_POST_1000_DONE=0
DIAG_POST_2000_DONE=0
DIAG_POST_5000_DONE=0
DIAG_CONFIGURED_MONO_MS=""
DIAG_DISCONNECT_MONO_MS=""
DIAG_CONFIGURED_SAMPLE=""
DIAG_LAST_SAMPLE=""
DIAG_LAST_REG_SAMPLE_MS=0
DIAG_REG_GOTGCTL="unknown"
DIAG_REG_GUSBCFG="unknown"
DIAG_REG_GINTSTS="unknown"
DIAG_REG_DCTL="unknown"
DIAG_REG_DSTS="unknown"
DIAG_REG_HCFG="unknown"
DIAG_REG_HPRT0="unknown"
DIAG_DWC2_MODE="unknown"

script_path() {
  local dir
  dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s/%s\n' "$dir" "$(basename -- "${BASH_SOURCE[0]}")"
}

timestamp_now() {
  date '+%Y-%m-%d %H:%M:%S.%N %Z' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'
}

monotonic_now() {
  awk '{print $1}' /proc/uptime 2>/dev/null || printf 'unknown'
}

tty1_line() {
  stdout_is_tty1 && return 0
  [ -w /dev/tty1 ] || return 0
  printf '%s\n' "$*" >/dev/tty1 2>/dev/null || true
}

stdout_is_tty1() {
  [ -t 1 ] || return 1
  [ "$(readlink /proc/$$/fd/1 2>/dev/null)" = "/dev/tty1" ]
}

log_line() {
  [ -n "$LOG_FILE" ] || return 0
  local line
  line="$(timestamp_now) $*"
  printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
  [ -n "$RUN_LOG_FILE" ] && printf '%s\n' "$line" >>"$RUN_LOG_FILE" 2>/dev/null || true
}

say() {
  printf '%s\n' "$*"
  log_line "$*"
  tty1_line "$*"
}

say_step() {
  say "[STEP] $1"
}

die() {
  say "ERROR: $*"
  sleep 5
  exit 1
}

fatal_after_destructive() {
  say "ERROR: $*"
  compact_status "failure"
  sleep 15
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is missing"
}

choose_ssh_unit(){ systemctl cat ssh.service >/dev/null 2>&1 && { printf 'ssh.service'; return 0; }; systemctl cat sshd.service >/dev/null 2>&1 && { printf 'sshd.service'; return 0; }; return 1; }
ssh_state(){ systemctl is-active "$1" 2>/dev/null || printf 'unknown'; }
ssh_listener(){ ss -lnt 2>/dev/null | awk '$4 ~ /:22($|[[:space:]])/ {found=1} END{exit(found?0:1)}' && printf 'yes' || printf 'no'; }
discover_otg_path(){ local candidate; candidate="/sys/devices/platform/ff2c0000.syscon/ff2c0000.syscon:usb2-phy@100/otg_mode"; [ -e "$candidate" ] && { OTG_PATH="$candidate"; return 0; }; candidate="$(find /sys/devices/platform -path '*/otg_mode' 2>/dev/null | head -n 1)"; [ -n "$candidate" ] || return 1; OTG_PATH="$candidate"; }
init_log(){ local dir; for dir in /roms2 /tmp; do mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ] && { LOG_FILE="$dir/runtime-otg-gadget.log"; : >"$LOG_FILE" 2>/dev/null || return 1; return 0; }; done; return 1; }
current_driver_path(){ readlink -f "$DWC2_DEV/driver" 2>/dev/null || printf 'absent'; }
current_dwc2_bound(){ local path base; path="$(current_driver_path)"; [ "$path" != "absent" ] || { printf 'no'; return 0; }; base="$(basename "$path" 2>/dev/null || printf unknown)"; [ "$base" = "dwc2" ] && printf 'yes' || printf 'no'; }
current_g_ether(){ awk '$1=="g_ether"{found=1} END{exit(found?0:1)}' /proc/modules 2>/dev/null && printf 'loaded' || printf 'absent'; }
current_usb0_present(){ ip link show usb0 >/dev/null 2>&1 && printf 'yes' || printf 'no'; }
current_usb0_operstate(){ [ "$(current_usb0_present)" = "yes" ] && cat /sys/class/net/usb0/operstate 2>/dev/null || printf 'absent'; }
current_usb0_carrier(){ [ "$(current_usb0_present)" = "yes" ] && cat /sys/class/net/usb0/carrier 2>/dev/null || printf 'absent'; }
current_usb0_ipv4(){ [ "$(current_usb0_present)" = "yes" ] && ip -o -4 addr show dev usb0 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="inet") {print $(i+1); exit}}' || printf 'absent'; }
current_usb0_rx(){ [ "$(current_usb0_present)" = "yes" ] && cat /sys/class/net/usb0/statistics/rx_bytes 2>/dev/null || printf 'absent'; }
current_usb0_tx(){ [ "$(current_usb0_present)" = "yes" ] && cat /sys/class/net/usb0/statistics/tx_bytes 2>/dev/null || printf 'absent'; }
current_udc_state(){ cat "$UDC_PATH/state" 2>/dev/null || printf 'UNAVAILABLE'; }
current_udc_speed(){ cat "$UDC_PATH/current_speed" 2>/dev/null || printf 'UNAVAILABLE'; }
compact_status(){ local label="$1"; say "[STEP] $label"; say "otg_mode=$(cat "$OTG_PATH" 2>/dev/null || printf UNAVAILABLE)"; say "driver=$(current_driver_path)"; say "dwc2_bound=$(current_dwc2_bound)"; say "udc_state=$(current_udc_state)"; say "udc_speed=$(current_udc_speed)"; say "g_ether=$(current_g_ether)"; say "usb0=$(current_usb0_present) operstate=$(current_usb0_operstate) carrier=$(current_usb0_carrier) ipv4=$(current_usb0_ipv4)"; say "ssh_unit=${SSH_UNIT:-unselected} ssh_state=$(ssh_state "${SSH_UNIT:-ssh.service}") ssh_listener=$(ssh_listener)"; }
wait_for_path(){ local path="$1" expect="$2" timeout="${3:-5}" i=0; while [ "$i" -lt "$timeout" ]; do case "$expect" in present) [ -e "$path" ] && return 0 ;; absent) [ ! -e "$path" ] && return 0 ;; esac; sleep 1; i=$((i + 1)); done; return 1; }
cleanup_existing_gadget_state(){ local rc=0; [ "$(current_usb0_present)" = "yes" ] && { ip link set usb0 down >/dev/null 2>&1 || rc=1; ip addr flush dev usb0 >/dev/null 2>&1 || rc=1; }; if [ "$(current_g_ether)" = "loaded" ]; then modprobe -r g_ether >/dev/null 2>&1 || rc=1; fi; return "$rc"; }
start_ssh_unit(){ systemctl start "$SSH_UNIT" >/dev/null 2>&1 || return 1; local i=0; while [ "$i" -lt 10 ]; do [ "$(ssh_state "$SSH_UNIT")" = "active" ] && [ "$(ssh_listener)" = "yes" ] && return 0; sleep 1; i=$((i + 1)); done; return 1; }
monotonic_ms_now(){ awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime 2>/dev/null || printf '0'; }
is_headers_sent(){ headers_sent; }
append_limited_line() {
  local file="$1" limit="$2" counter_var="$3" line="$4" current len
  eval "current=\${$counter_var:-0}"
  [ "$current" -ge "$limit" ] && return 1
  printf '%s\n' "$line" >>"$file" 2>/dev/null || return 1
  len=$(( ${#line} + 1 ))
  current=$((current + len))
  if [ "$current" -ge "$limit" ]; then
    printf '%s\n' "# truncated at $(timestamp_now)" >>"$file" 2>/dev/null || true
    current="$limit"
  fi
  eval "$counter_var=\$current"
  [ "$current" -lt "$limit" ]
}
dump_command_to_limited_file() {
  local file="$1" limit="$2" counter_var="$3" title="$4"
  shift 4
  local line
  append_limited_line "$file" "$limit" "$counter_var" "### $title" || return 1
  while IFS= read -r line; do
    append_limited_line "$file" "$limit" "$counter_var" "$line" || return 1
  done < <("$@" 2>/dev/null)
}
capture_reg_cache() {
  local regfile="/sys/kernel/debug/ff300000.usb/regdump" line key value
  DIAG_REG_GOTGCTL="unknown"
  DIAG_REG_GUSBCFG="unknown"
  DIAG_REG_GINTSTS="unknown"
  DIAG_REG_DCTL="unknown"
  DIAG_REG_DSTS="unknown"
  DIAG_REG_HCFG="unknown"
  DIAG_REG_HPRT0="unknown"
  DIAG_DWC2_MODE="unknown"
  [ -r "$regfile" ] || return 0
  while IFS='=' read -r key value; do
    key="${key%%[[:space:]]*}"
    value="${value# }"
    value="${value% }"
    case "$key" in
      GOTGCTL) DIAG_REG_GOTGCTL="$value" ;;
      GUSBCFG) DIAG_REG_GUSBCFG="$value" ;;
      GINTSTS)
        DIAG_REG_GINTSTS="$value"
        case "$value" in
          *CURMODE_HOST*) DIAG_DWC2_MODE="host" ;;
          *CURMODE_DEV*|*CURMODE_DEVICE*) DIAG_DWC2_MODE="device" ;;
        esac
        ;;
      DCTL) DIAG_REG_DCTL="$value" ;;
      DSTS) DIAG_REG_DSTS="$value" ;;
      HCFG) DIAG_REG_HCFG="$value" ;;
      HPRT0) DIAG_REG_HPRT0="$value" ;;
    esac
  done < <(awk '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    /^GOTGCTL[[:space:]]*=/ || /^GUSBCFG[[:space:]]*=/ || /^GINTSTS[[:space:]]*=/ || /^DCTL[[:space:]]*=/ || /^DSTS[[:space:]]*=/ || /^HCFG[[:space:]]*=/ || /^HPRT0[[:space:]]*=/ {
      split($0, parts, "=")
      key = trim(parts[1])
      value = trim(substr($0, index($0, "=") + 1))
      print key "=" value
    }
  ' "$regfile")
}
maybe_refresh_reg_cache() {
  local now_ms
  now_ms="$(monotonic_ms_now)"
  if [ $((now_ms - DIAG_LAST_REG_SAMPLE_MS)) -ge 100 ]; then
    capture_reg_cache
    DIAG_LAST_REG_SAMPLE_MS="$now_ms"
  fi
}
phase_for_sample() {
  local udc_state="$1" driver_path="$2" usb0_present="$3" usb0_carrier="$4"
  if [ "$DIAG_CONFIGURED_SEEN" -eq 0 ]; then
    if [ "$driver_path" != "absent" ] || [ "$usb0_present" = "yes" ] || [ "$udc_state" = "configured" ]; then
      printf 'attached'
    else
      printf 'waiting'
    fi
    return 0
  fi
  if [ "$DIAG_DISCONNECT_SEEN" -eq 0 ]; then
    if [ "$udc_state" = "configured" ]; then
      printf 'configured'
    else
      printf 'disconnecting'
    fi
    return 0
  fi
  if [ "$DIAG_RECONNECTED_SEEN" -eq 1 ]; then
    printf 'reconnected'
    return 0
  fi
  if [ "$udc_state" = "configured" ] && [ "$usb0_carrier" = "1" ]; then
    printf 'reconnected'
  else
    printf 'disconnected'
  fi
}
current_sample_line() {
  local wall_time mono_time phase otg_mode driver_path dwc2_bound dwc2_mode udc_state udc_speed g_ether_loaded usb0_present usb0_operstate usb0_carrier usb0_rx usb0_tx ssh_state_now ssh_listener_now
  wall_time="$(timestamp_now)"
  mono_time="$(monotonic_ms_now)"
  maybe_refresh_reg_cache
  phase="$(phase_for_sample "$(current_udc_state)" "$(current_driver_path)" "$(current_usb0_present)" "$(current_usb0_carrier)")"
  otg_mode="$(cat "$OTG_PATH" 2>/dev/null || printf UNAVAILABLE)"
  driver_path="$(current_driver_path)"
  dwc2_bound="$(current_dwc2_bound)"
  dwc2_mode="$DIAG_DWC2_MODE"
  udc_state="$(current_udc_state)"
  udc_speed="$(current_udc_speed)"
  g_ether_loaded="$(current_g_ether)"
  usb0_present="$(current_usb0_present)"
  usb0_operstate="$(current_usb0_operstate)"
  usb0_carrier="$(current_usb0_carrier)"
  usb0_rx="$(current_usb0_rx)"
  usb0_tx="$(current_usb0_tx)"
  ssh_state_now="$(ssh_state "$SSH_UNIT")"
  ssh_listener_now="$(ssh_listener)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$wall_time" "$mono_time" "$phase" "$otg_mode" "$dwc2_bound" "$driver_path" "$dwc2_mode" \
    "$udc_state" "$udc_speed" "$g_ether_loaded" "$usb0_present" "$usb0_operstate" "$usb0_carrier" \
    "$usb0_rx" "$usb0_tx" "$ssh_state_now" "$ssh_listener_now" \
    "$DIAG_REG_GOTGCTL" "$DIAG_REG_GUSBCFG" "$DIAG_REG_GINTSTS" "$DIAG_REG_DCTL" "$DIAG_REG_DSTS" "$DIAG_REG_HCFG" "$DIAG_REG_HPRT0"
}
snapshot_state_file() {
  local file="$1" title="$2"
  {
    printf '%s\n' "title=$title"
    printf '%s\n' "wall_time=$(timestamp_now)"
    printf '%s\n' "monotonic_time=$(monotonic_ms_now)"
    printf '%s\n' "otg_mode=$(cat "$OTG_PATH" 2>/dev/null || printf UNAVAILABLE)"
    printf '%s\n' "driver_path=$(current_driver_path)"
    printf '%s\n' "dwc2_bound=$(current_dwc2_bound)"
    printf '%s\n' "dwc2_mode=$DIAG_DWC2_MODE"
    printf '%s\n' "udc_state=$(current_udc_state)"
    printf '%s\n' "udc_speed=$(current_udc_speed)"
    printf '%s\n' "g_ether_loaded=$(current_g_ether)"
    printf '%s\n' "usb0_present=$(current_usb0_present)"
    printf '%s\n' "usb0_operstate=$(current_usb0_operstate)"
    printf '%s\n' "usb0_carrier=$(current_usb0_carrier)"
    printf '%s\n' "usb0_rx=$(current_usb0_rx)"
    printf '%s\n' "usb0_tx=$(current_usb0_tx)"
    printf '%s\n' "ssh_state=$(ssh_state "$SSH_UNIT")"
    printf '%s\n' "ssh_listener=$(ssh_listener)"
    printf '%s\n' "GOTGCTL=$DIAG_REG_GOTGCTL"
    printf '%s\n' "GUSBCFG=$DIAG_REG_GUSBCFG"
    printf '%s\n' "GINTSTS=$DIAG_REG_GINTSTS"
    printf '%s\n' "DCTL=$DIAG_REG_DCTL"
    printf '%s\n' "DSTS=$DIAG_REG_DSTS"
    printf '%s\n' "HCFG=$DIAG_REG_HCFG"
    printf '%s\n' "HPRT0=$DIAG_REG_HPRT0"
    printf '\n[regdump]\n'
    cat /sys/kernel/debug/ff300000.usb/regdump 2>/dev/null || printf 'regdump unavailable\n'
    printf '\n[kernel tail]\n'
    tail -n 100 "$KERNEL_LOG_FILE" 2>/dev/null || true
    printf '\n[loaded modules]\n'
    cat /proc/modules 2>/dev/null || true
    printf '\n[network state]\n'
    ip -br link 2>/dev/null || true
    ip -br addr 2>/dev/null || true
    ip -s link show usb0 2>/dev/null || true
    printf '\n[relevant processes]\n'
    pgrep -af 'otg|usb|gadget|remote|emulationstation|portmaster' 2>/dev/null || true
  } >"$file" 2>/dev/null || true
}
append_process_inventory() {
  local line
  append_limited_line "$PROCESS_EVENTS_FILE" $((2 * 1024 * 1024)) PROCESS_EVENTS_BYTES "### systemctl list-units --type=service --state=running" || return 1
  while IFS= read -r line; do
    append_limited_line "$PROCESS_EVENTS_FILE" $((2 * 1024 * 1024)) PROCESS_EVENTS_BYTES "$line" || return 1
  done < <(systemctl list-units --type=service --state=running 2>/dev/null)
  append_limited_line "$PROCESS_EVENTS_FILE" $((2 * 1024 * 1024)) PROCESS_EVENTS_BYTES "### systemctl list-timers --all" || return 1
  while IFS= read -r line; do
    append_limited_line "$PROCESS_EVENTS_FILE" $((2 * 1024 * 1024)) PROCESS_EVENTS_BYTES "$line" || return 1
  done < <(systemctl list-timers --all 2>/dev/null)
  append_limited_line "$PROCESS_EVENTS_FILE" $((2 * 1024 * 1024)) PROCESS_EVENTS_BYTES "### systemctl list-sockets --all" || return 1
  while IFS= read -r line; do
    append_limited_line "$PROCESS_EVENTS_FILE" $((2 * 1024 * 1024)) PROCESS_EVENTS_BYTES "$line" || return 1
  done < <(systemctl list-sockets --all 2>/dev/null)
}
kernel_follow_source() {
  if dmesg --help 2>&1 | grep -q -- '--time-format'; then
    dmesg --follow --time-format=iso 2>/dev/null
  else
    dmesg -w 2>/dev/null
  fi
}
kernel_follow_recorder() {
  local line
  kernel_follow_source | while IFS= read -r line; do
    append_limited_line "$KERNEL_LOG_FILE" $((5 * 1024 * 1024)) KERNEL_LOG_BYTES "$line" || break
  done
}
process_events_recorder() {
  local last_fingerprint="" line wall mono otg_mode driver_path mods sshs pgrep_hits fingerprint
  while :; do
    wall="$(timestamp_now)"
    mono="$(monotonic_ms_now)"
    otg_mode="$(cat "$OTG_PATH" 2>/dev/null || printf UNAVAILABLE)"
    driver_path="$(current_driver_path)"
    mods="$(awk '$1 ~ /^(g_ether|dwc2|u_ether|rndis_host|usb_f_.*|libcomposite)$/ {printf "%s:%s ", $1, $3} END {if (NR == 0) printf "none"}' /proc/modules 2>/dev/null)"
    sshs="$(ssh_state "$SSH_UNIT")"
    pgrep_hits="$(pgrep -af 'otg|usb|gadget|remote|emulationstation|portmaster' 2>/dev/null | awk '{pid=$1; $1=""; sub(/^ /,""); printf "%s[%s] ", pid, $0}')"
    fingerprint="${otg_mode}|${driver_path}|${mods}|${sshs}|${pgrep_hits}"
    if [ "$fingerprint" != "$last_fingerprint" ]; then
      line="wall=$wall mono=$mono otg_mode=$otg_mode driver_path=$driver_path ssh_state=$sshs mods=${mods:-none} pgrep=${pgrep_hits:-none}"
      append_limited_line "$PROCESS_EVENTS_FILE" $((2 * 1024 * 1024)) PROCESS_EVENTS_BYTES "$line" || break
      if [ -n "$last_fingerprint" ]; then
        snapshot_process_snapshot "$wall" "$mono" "$line"
      fi
      last_fingerprint="$fingerprint"
    fi
    sleep 0.1
  done
}
snapshot_process_snapshot() {
  local wall="$1" mono="$2" headline="$3" line
  append_limited_line "$PROCESS_EVENTS_FILE" $((2 * 1024 * 1024)) PROCESS_EVENTS_BYTES "wall_time=$wall" || return 1
  append_limited_line "$PROCESS_EVENTS_FILE" $((2 * 1024 * 1024)) PROCESS_EVENTS_BYTES "monotonic_time=$mono" || return 1
  append_limited_line "$PROCESS_EVENTS_FILE" $((2 * 1024 * 1024)) PROCESS_EVENTS_BYTES "$headline" || return 1
  append_limited_line "$PROCESS_EVENTS_FILE" $((2 * 1024 * 1024)) PROCESS_EVENTS_BYTES "[ps -eo pid,ppid,user,lstart,args]" || return 1
  while IFS= read -r line; do
    append_limited_line "$PROCESS_EVENTS_FILE" $((2 * 1024 * 1024)) PROCESS_EVENTS_BYTES "$line" || return 1
  done < <(ps -eo pid,ppid,user,lstart,args 2>/dev/null)
}
detect_first_changed_field() {
  local prev="$1" curr="$2" prev_value curr_value
  local fields="udc_state usb0_carrier usb0_present driver_path dwc2_bound dwc2_mode otg_mode g_ether_loaded usb0_operstate usb0_rx usb0_tx ssh_state ssh_listener GOTGCTL GUSBCFG GINTSTS DCTL DSTS HCFG HPRT0"
  local field
  for field in $fields; do
    prev_value="$(printf '%s\n' "$prev" | awk -v key="$field" -F '\t' '{
      split($0, a, "\t");
      if (key == "udc_state") print a[8];
      else if (key == "usb0_carrier") print a[13];
      else if (key == "usb0_present") print a[11];
      else if (key == "driver_path") print a[6];
      else if (key == "dwc2_bound") print a[5];
      else if (key == "dwc2_mode") print a[7];
      else if (key == "otg_mode") print a[4];
      else if (key == "g_ether_loaded") print a[10];
      else if (key == "usb0_operstate") print a[12];
      else if (key == "usb0_rx") print a[14];
      else if (key == "usb0_tx") print a[15];
      else if (key == "ssh_state") print a[16];
      else if (key == "ssh_listener") print a[17];
      else if (key == "GOTGCTL") print a[18];
      else if (key == "GUSBCFG") print a[19];
      else if (key == "GINTSTS") print a[20];
      else if (key == "DCTL") print a[21];
      else if (key == "DSTS") print a[22];
      else if (key == "HCFG") print a[23];
      else if (key == "HPRT0") print a[24];
    }')"
    curr_value="$(printf '%s\n' "$curr" | awk -v key="$field" -F '\t' '{
      split($0, a, "\t");
      if (key == "udc_state") print a[8];
      else if (key == "usb0_carrier") print a[13];
      else if (key == "usb0_present") print a[11];
      else if (key == "driver_path") print a[6];
      else if (key == "dwc2_bound") print a[5];
      else if (key == "dwc2_mode") print a[7];
      else if (key == "otg_mode") print a[4];
      else if (key == "g_ether_loaded") print a[10];
      else if (key == "usb0_operstate") print a[12];
      else if (key == "usb0_rx") print a[14];
      else if (key == "usb0_tx") print a[15];
      else if (key == "ssh_state") print a[16];
      else if (key == "ssh_listener") print a[17];
      else if (key == "GOTGCTL") print a[18];
      else if (key == "GUSBCFG") print a[19];
      else if (key == "GINTSTS") print a[20];
      else if (key == "DCTL") print a[21];
      else if (key == "DSTS") print a[22];
      else if (key == "HCFG") print a[23];
      else if (key == "HPRT0") print a[24];
    }')"
    if [ "$prev_value" != "$curr_value" ]; then
      printf '%s\n' "$field"
      return 0
    fi
  done
  printf '%s\n' "unknown"
}
write_first_configured_snapshot() {
  local current_sample="$1"
  local wall mono
  wall="$(printf '%s' "$current_sample" | awk -F '\t' '{print $1}')"
  mono="$(printf '%s' "$current_sample" | awk -F '\t' '{print $2}')"
  {
    printf '%s\n' "configured_timestamp=$wall"
    printf '%s\n' "configured_monotonic_ms=$mono"
    printf '%s\n' "current_sample=$current_sample"
    printf '\n[compact state]\n'
    printf '%s\n' "$current_sample"
    printf '\n[regdump]\n'
    cat /sys/kernel/debug/ff300000.usb/regdump 2>/dev/null || printf 'regdump unavailable\n'
    printf '\n[kernel tail]\n'
    tail -n 100 "$KERNEL_LOG_FILE" 2>/dev/null || true
    printf '\n[loaded modules]\n'
    cat /proc/modules 2>/dev/null || true
    printf '\n[network state]\n'
    ip -br link 2>/dev/null || true
    ip -br addr 2>/dev/null || true
    ip -s link show usb0 2>/dev/null || true
    printf '\n[relevant processes]\n'
    pgrep -af 'otg|usb|gadget|remote|emulationstation|portmaster' 2>/dev/null || true
  } >"$FIRST_CONFIGURED_FILE" 2>/dev/null || true
}
write_first_disconnect_snapshot() {
  local prev_sample="$1" current_sample="$2"
  local first_changed_field wall mono configured_wall configured_mono elapsed_ms
  configured_wall="$(printf '%s' "$DIAG_CONFIGURED_SAMPLE" | awk -F '\t' '{print $1}')"
  configured_mono="$(printf '%s' "$DIAG_CONFIGURED_SAMPLE" | awk -F '\t' '{print $2}')"
  wall="$(printf '%s' "$current_sample" | awk -F '\t' '{print $1}')"
  mono="$(printf '%s' "$current_sample" | awk -F '\t' '{print $2}')"
  elapsed_ms=$((mono - configured_mono))
  first_changed_field="$(detect_first_changed_field "$prev_sample" "$current_sample")"
  {
    printf '%s\n' "configured_timestamp=$configured_wall"
    printf '%s\n' "configured_monotonic_ms=$configured_mono"
    printf '%s\n' "disconnect_indicator_timestamp=$wall"
    printf '%s\n' "disconnect_indicator_monotonic_ms=$mono"
    printf '%s\n' "elapsed_since_configured_ms=$elapsed_ms"
    printf '%s\n' "first_changed_field=$first_changed_field"
    printf '%s\n' "previous_sample=$prev_sample"
    printf '%s\n' "current_sample=$current_sample"
    printf '\n[role registers]\n'
    printf 'GOTGCTL=%s\n' "$DIAG_REG_GOTGCTL"
    printf 'GUSBCFG=%s\n' "$DIAG_REG_GUSBCFG"
    printf 'GINTSTS=%s\n' "$DIAG_REG_GINTSTS"
    printf 'DCTL=%s\n' "$DIAG_REG_DCTL"
    printf 'DSTS=%s\n' "$DIAG_REG_DSTS"
    printf 'HCFG=%s\n' "$DIAG_REG_HCFG"
    printf 'HPRT0=%s\n' "$DIAG_REG_HPRT0"
    printf '\n[regdump]\n'
    cat /sys/kernel/debug/ff300000.usb/regdump 2>/dev/null || printf 'regdump unavailable\n'
    printf '\n[kernel tail]\n'
    tail -n 100 "$KERNEL_LOG_FILE" 2>/dev/null || true
    printf '\n[loaded modules]\n'
    cat /proc/modules 2>/dev/null || true
    printf '\n[network state]\n'
    ip -br link 2>/dev/null || true
    ip -br addr 2>/dev/null || true
    ip -s link show usb0 2>/dev/null || true
    printf '\n[relevant processes]\n'
    pgrep -af 'otg|usb|gadget|remote|emulationstation|portmaster' 2>/dev/null || true
  } >"$FIRST_DISCONNECT_FILE" 2>/dev/null || true
}
write_post_disconnect_snapshots() {
  local current_sample="$1" base_mono elapsed marker
  base_mono="$(printf '%s' "$current_sample" | awk -F '\t' '{print $2}')"
  if [ "$DIAG_POST_100_DONE" -eq 0 ]; then
    marker=$((base_mono + 100))
    DIAG_POST_100_DONE=1
  fi
  {
    printf '%s\n' "disconnect_indicator_sample=$current_sample"
    printf '\n[+100ms]\n'
    sleep 0.100
    current_sample="$(current_sample_line)"
    printf '%s\n' "$current_sample"
    printf '\n[+500ms]\n'
    sleep 0.400
    current_sample="$(current_sample_line)"
    printf '%s\n' "$current_sample"
    printf '\n[+1s]\n'
    sleep 0.500
    current_sample="$(current_sample_line)"
    printf '%s\n' "$current_sample"
    printf '\n[+2s]\n'
    sleep 1.000
    current_sample="$(current_sample_line)"
    printf '%s\n' "$current_sample"
    printf '\n[+5s]\n'
    sleep 3.000
    current_sample="$(current_sample_line)"
    printf '%s\n' "$current_sample"
  } >"$POST_DISCONNECT_FILE" 2>/dev/null || true
}
start_disconnect_capture() {
  local stamp base
  stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || date '+%Y%m%d-%H%M%S')"
  for base in /roms2 /tmp; do
    DIAG_DIR="$base/runtime-otg-disconnect-$stamp"
    if mkdir -p "$DIAG_DIR" 2>/dev/null && [ -w "$DIAG_DIR" ]; then
      RUN_LOG_FILE="$DIAG_DIR/run.log"
      FAST_STATE_FILE="$DIAG_DIR/fast-state.tsv"
      KERNEL_LOG_FILE="$DIAG_DIR/kernel-follow.log"
      PROCESS_EVENTS_FILE="$DIAG_DIR/process-events.log"
      BEFORE_CABLE_FILE="$DIAG_DIR/before-cable.txt"
      FIRST_CONFIGURED_FILE="$DIAG_DIR/first-configured.txt"
      FIRST_DISCONNECT_FILE="$DIAG_DIR/first-disconnect.txt"
      POST_DISCONNECT_FILE="$DIAG_DIR/post-disconnect.txt"
      FINAL_STATE_FILE="$DIAG_DIR/final-state.txt"
      : >"$RUN_LOG_FILE" 2>/dev/null || return 1
      : >"$FAST_STATE_FILE" 2>/dev/null || return 1
      : >"$KERNEL_LOG_FILE" 2>/dev/null || return 1
      : >"$PROCESS_EVENTS_FILE" 2>/dev/null || return 1
      printf 'wall_time\tmonotonic_time\tphase\totg_mode\tdwc2_bound\tdriver_path\tdwc2_mode\tudc_state\tudc_speed\tg_ether_loaded\tusb0_present\tusb0_operstate\tusb0_carrier\tusb0_rx\tusb0_tx\tssh_state\tssh_listener\tGOTGCTL\tGUSBCFG\tGINTSTS\tDCTL\tDSTS\tHCFG\tHPRT0\n' >"$FAST_STATE_FILE" 2>/dev/null || return 1
      append_process_inventory || true
      return 0
    fi
  done
  return 1
}
stop_disconnect_capture() {
  local pid
  [ "$DISCONNECT_CAPTURE_CLEANED" -eq 1 ] && return 0
  for pid in "$FAST_STATE_PID" "$KERNEL_LOG_PID" "$PROCESS_EVENTS_PID"; do
    [ -n "$pid" ] || continue
    kill "$pid" >/dev/null 2>&1 || true
  done
  [ -n "$POST_DISCONNECT_PID" ] && kill "$POST_DISCONNECT_PID" >/dev/null 2>&1 || true
  for pid in "$FAST_STATE_PID" "$KERNEL_LOG_PID" "$PROCESS_EVENTS_PID"; do
    [ -n "$pid" ] || continue
    wait "$pid" >/dev/null 2>&1 || true
  done
  [ -n "$POST_DISCONNECT_PID" ] && wait "$POST_DISCONNECT_PID" >/dev/null 2>&1 || true
  DISCONNECT_CAPTURE_ACTIVE=0
  DISCONNECT_CAPTURE_CLEANED=1
}
final_state_snapshot() {
  [ -n "$FINAL_STATE_FILE" ] || return 0
  snapshot_state_file "$FINAL_STATE_FILE" "final state"
}
start_disconnect_recorders() {
  [ "$DISCONNECT_CAPTURE_ACTIVE" -eq 0 ] || return 0
  start_disconnect_capture || return 1
  DISCONNECT_CAPTURE_ACTIVE=1
  kernel_follow_recorder &
  KERNEL_LOG_PID=$!
  process_events_recorder &
  PROCESS_EVENTS_PID=$!
  fast_state_recorder &
  FAST_STATE_PID=$!
  printf '%s\n' "Diagnostics: $DIAG_DIR"
  log_line "Diagnostics: $DIAG_DIR"
  snapshot_state_file "$BEFORE_CABLE_FILE" "before cable instruction"
}
fast_state_recorder() {
  local sample prev_sample changed_field current_field current_phase configured_marker disconnect_marker last_line line current_mono previous_value current_value
  local fast_limit=$((10 * 1024 * 1024))
  local reg_sample_counter=0
  prev_sample="$DIAG_LAST_SAMPLE"
  if [ -z "$prev_sample" ]; then
    prev_sample="$(current_sample_line)"
  fi
  DIAG_LAST_SAMPLE="$prev_sample"
  while :; do
    sample="$(current_sample_line)"
    DIAG_LAST_SAMPLE="$sample"
    printf '%s\n' "$sample" >>"$FAST_STATE_FILE" 2>/dev/null || break
    FAST_STATE_BYTES=$((FAST_STATE_BYTES + ${#sample} + 1))
    if [ "$FAST_STATE_BYTES" -ge "$fast_limit" ]; then
      printf '%s\n' "# truncated at $(timestamp_now)" >>"$FAST_STATE_FILE" 2>/dev/null || true
      break
    fi
    current_phase="$(printf '%s' "$sample" | awk -F '\t' '{print $3}')"
    if [ "$DIAG_CONFIGURED_SEEN" -eq 0 ] && [ "$(printf '%s' "$sample" | awk -F '\t' '{print $8}')" = "configured" ]; then
      DIAG_CONFIGURED_SEEN=1
      DIAG_CONFIGURED_MONO_MS="$(printf '%s' "$sample" | awk -F '\t' '{print $2}')"
      DIAG_CONFIGURED_SAMPLE="$sample"
      write_first_configured_snapshot "$sample"
      log_line "first configured captured at $(printf '%s' "$sample" | awk -F '\t' '{print $1}')"
    fi
    if [ "$DIAG_CONFIGURED_SEEN" -eq 1 ] && [ "$DIAG_DISCONNECT_SEEN" -eq 0 ]; then
      if [ "$(printf '%s' "$sample" | awk -F '\t' '{print $8}')" != "configured" ] || [ "$(printf '%s' "$sample" | awk -F '\t' '{print $13}')" = "0" ] || [ "$(printf '%s' "$sample" | awk -F '\t' '{print $11}')" = "no" ] || [ "$(printf '%s' "$sample" | awk -F '\t' '{print $5}')" = "no" ] || [ "$(printf '%s' "$sample" | awk -F '\t' '{print $10}')" = "absent" ]; then
        DIAG_DISCONNECT_SEEN=1
        DIAG_DISCONNECT_MONO_MS="$(printf '%s' "$sample" | awk -F '\t' '{print $2}')"
        write_first_disconnect_snapshot "$prev_sample" "$sample"
        log_line "first disconnect captured: $(detect_first_changed_field "$prev_sample" "$sample")"
        capture_post_disconnect_sequence "$sample" &
        POST_DISCONNECT_PID=$!
      fi
    fi
    if [ "$DIAG_DISCONNECT_SEEN" -eq 1 ] && [ "$DIAG_RECONNECTED_SEEN" -eq 0 ]; then
      if [ "$(printf '%s' "$sample" | awk -F '\t' '{print $8}')" = "configured" ] && [ "$(printf '%s' "$sample" | awk -F '\t' '{print $13}')" = "1" ]; then
        DIAG_RECONNECTED_SEEN=1
        log_line "reconnected captured at $(printf '%s' "$sample" | awk -F '\t' '{print $1}')"
      fi
    fi
    prev_sample="$sample"
    sleep 0.025
  done
}
save_before_cable_snapshot() {
  snapshot_state_file "$BEFORE_CABLE_FILE" "before cable instruction"
}
capture_post_disconnect_sequence() {
  local base_sample="$1"
  : >"$POST_DISCONNECT_FILE" 2>/dev/null || true
  {
    printf '%s\n' "disconnect_indicator_sample=$base_sample"
    printf '\n[+100ms]\n'
    sleep 0.100
    printf '%s\n' "$(current_sample_line)"
    printf '\n[+500ms]\n'
    sleep 0.400
    printf '%s\n' "$(current_sample_line)"
    printf '\n[+1s]\n'
    sleep 0.500
    printf '%s\n' "$(current_sample_line)"
    printf '\n[+2s]\n'
    sleep 1.000
    printf '%s\n' "$(current_sample_line)"
    printf '\n[+5s]\n'
    sleep 3.000
    printf '%s\n' "$(current_sample_line)"
  } >>"$POST_DISCONNECT_FILE" 2>/dev/null || true
}
show_launch_probe(){ local script; script="$(script_path)"; printf 'current_uid=%s\n' "$(id -u)"; printf 'would_elevate=%s\n' "$( [ "$(id -u)" -ne 0 ] && printf yes || printf no )"; printf 'resolved_script_path=%s\n' "$script"; printf 'sudo_noninteractive_available=%s\n' "$(sudo -n true >/dev/null 2>&1 && printf yes || printf no)"; }
self_elevate(){ local script; [ "$(id -u)" -eq 0 ] && return 0; script="$(script_path)"; if sudo -n true >/dev/null 2>&1; then exec sudo -n -- bash "$script" "$@"; fi; if printf '%s\n' 'ark' | sudo -S -p '' true >/dev/null 2>&1; then exec bash -c 'printf "%s\n" ark | sudo -S -p "" -- bash "$1" "${@:2}"' bash "$script" "$@"; fi; say "ERROR: sudo elevation failed"; tty1_line "ERROR: sudo elevation failed"; sleep 5; exit 1; }
signal_exit(){ local sig="$1" code="$2"; stop_disconnect_capture; final_state_snapshot; [ "$POST_DESTRUCTIVE" -eq 1 ] && { say "Interrupted: $sig"; compact_status "interrupted"; sleep 15; }; exit "$code"; }

cleanup_on_exit(){ stop_disconnect_capture; final_state_snapshot; }

main() {
  local bind_start target actual lateness sleep_for burst_label sec state speed carrier oper listener sshs
  local burst_labels=(post-bind-100ms post-bind-250ms post-bind-500ms post-bind-1s post-bind-2s post-bind-5s)
  local burst_targets=(0.100 0.250 0.500 1.000 2.000 5.000)
  local connected_sec=0 ssh_ready_announced=0 usb_connected_announced=0

  if [ "${1:-}" = "--test-launch" ]; then
    show_launch_probe
    exit 0
  fi

  self_elevate "$@"

  for cmd in ip modprobe systemctl ss awk basename cat tr find sleep date wc sed readlink grep pgrep ps; do
    require_cmd "$cmd"
  done
  discover_otg_path || die "otg_mode path not found"
  [ -w "$OTG_PATH" ] || die "otg_mode not writable"
  [ -e "$DWC2_BIND_PATH" ] || die "dwc2 bind path missing"
  [ -e "$DWC2_UNBIND_PATH" ] || die "dwc2 unbind path missing"
  [ -e "$DWC2_DEV" ] || die "dwc2 device missing"
  SSH_UNIT="$(choose_ssh_unit)" || die "no ssh service unit found"
  init_log || die "cannot initialize log"
  trap 'cleanup_on_exit' EXIT
  trap 'signal_exit INT 130' INT
  trap 'signal_exit TERM 143' TERM

  say "RUNNING AS ROOT"
  say "RUNTIME OTG PROVEN SEQUENCE"
  say "============================"
  compact_status baseline

  say "WARNING: USB WI-FI WILL DISCONNECT"
  say "STARTING IN 5 SECONDS"
  sleep 5

  POST_DESTRUCTIVE=1
  cleanup_existing_gadget_state || fatal_after_destructive "cleanup of existing usb0/g_ether failed"
  compact_status "cleanup existing usb0/g_ether"

  say_step "peripheral write"
  sh -c "echo peripheral > '$OTG_PATH'" || fatal_after_destructive "write to otg_mode failed"
  compact_status "after peripheral write"

  say_step "before unbind"
  compact_status "before unbind"

  say_step "DWC2 unbind"
  sh -c "echo ff300000.usb > '$DWC2_UNBIND_PATH'" || fatal_after_destructive "unbind failed"
  wait_for_path "$DWC2_DEV/driver" absent 5 || fatal_after_destructive "driver path still present after unbind"
  compact_status "after unbind"

  say_step "DWC2 bind"
  bind_start="$(monotonic_now)"
  sh -c "echo ff300000.usb > '$DWC2_BIND_PATH'" || fatal_after_destructive "bind failed"
  wait_for_path "$DWC2_DEV/driver" present 5 || fatal_after_destructive "driver path missing after bind"
  compact_status "immediately after bind"

  for i in 0 1 2 3 4 5; do
    target="${burst_targets[$i]}"
    burst_label="${burst_labels[$i]}"
    actual="$(awk -v n="$(monotonic_now)" -v s="$bind_start" 'BEGIN{printf "%.3f", n-s}')"
    sleep_for="$(awk -v t="$target" -v a="$actual" 'BEGIN{r=t-a; if (r>0) printf "%.3f", r; else printf "0"}')"
    awk -v r="$sleep_for" 'BEGIN{exit(r>0?0:1)}' && sleep "$sleep_for"
    actual="$(awk -v n="$(monotonic_now)" -v s="$bind_start" 'BEGIN{printf "%.3f", n-s}')"
    lateness="$(awk -v a="$actual" -v t="$target" 'BEGIN{printf "%.3f", a-t}')"
    compact_status "$burst_label"
    say "burst target=${target}s actual=${actual}s lateness=${lateness}s"
  done
  compact_status "after 5s"

  say_step "g_ether load"
  modprobe g_ether dev_addr=02:36:36:00:00:02 host_addr=02:36:36:00:00:01 || fatal_after_destructive "modprobe g_ether failed"
  wait_for_path /sys/class/net/usb0 present 5 || fatal_after_destructive "usb0 did not appear"

  say_step "usb0 configuration"
  ip addr flush dev usb0 >/dev/null 2>&1 || fatal_after_destructive "usb0 flush failed"
  ip addr add "$USB0_ADDR" dev usb0 >/dev/null 2>&1 || fatal_after_destructive "usb0 address add failed"
  ip link set usb0 up >/dev/null 2>&1 || fatal_after_destructive "usb0 link up failed"

  say_step "SSH start"
  start_ssh_unit || fatal_after_destructive "SSH unit did not become active/listening"
  compact_status "after g_ether/usb0/SSH"

  start_disconnect_recorders || fatal_after_destructive "disconnect recorder initialization failed"
  say "========================================"
  say "USB GADGET READY"
  say "DISCONNECT THE USB WI-FI DONGLE"
  say "CONNECT THE USB CABLE TO THE PC"
  say "WAITING UP TO 120 SECONDS"
  say "========================================"
  sleep 1

  sec=0
  while [ "$sec" -lt 120 ]; do
    state="$(current_udc_state)"
    speed="$(current_udc_speed)"
    carrier="$(current_usb0_carrier)"
    oper="$(current_usb0_operstate)"
    listener="$(ssh_listener)"
    sshs="$(ssh_state "$SSH_UNIT")"
    if [ $((sec % 5)) -eq 0 ]; then
      say "waiting: state=$state speed=$speed carrier=$carrier operstate=$oper"
    fi
    if [ "$state" = "configured" ] && { [ "$speed" = "high-speed" ] || [ "$speed" = "full-speed" ]; } && [ "$carrier" = "1" ] && [ "$(current_usb0_ipv4)" = "$USB0_ADDR" ]; then
      say "========================================"
      say "USB GADGET CONNECTED"
      say "RNDIS CONFIGURED"
      say "UDC: $state"
      say "SPEED: $speed"
      say "USB0 CARRIER: $carrier"
      say "USB0: $USB0_ADDR"
      say "SSH SERVICE: $sshs"
      say "SSH LISTENER: $listener"
      say "========================================"
      say "Linux host:"
      say "1. Find the new RNDIS/USB network interface:"
      say "   ip -br link"
      say "   ip -br addr"
      say "2. Configure it:"
      say "   sudo ip link set <interface> up"
      say "   sudo ip addr flush dev <interface>"
      say "   sudo ip addr add 192.168.7.1/24 dev <interface>"
      say "3. Test:"
      say "   ping -c 3 192.168.7.2"
      say "   ssh ark@192.168.7.2"
      say "========================================"
      usb_connected_announced=1
      break
    fi
    sleep 1
    sec=$((sec + 1))
  done

  if [ "$sec" -ge 120 ]; then
    say "========================================"
    say "USB ENUMERATION TIMEOUT"
    say "GADGET STATE LEFT ACTIVE"
    say "state=$(current_udc_state)"
    say "speed=$(current_udc_speed)"
    say "carrier=$(current_usb0_carrier)"
    say "operstate=$(current_usb0_operstate)"
    say "========================================"
    sleep 15
    exit 1
  fi

  say "USB LINK IS READY"
  say "WAITING FOR SSH SERVICE"
  ssh_ready_announced=0
  connected_sec=1
  while :; do
    state="$(current_udc_state)"
    speed="$(current_udc_speed)"
    carrier="$(current_usb0_carrier)"
    oper="$(current_usb0_operstate)"
    listener="$(ssh_listener)"
    sshs="$(ssh_state "$SSH_UNIT")"
    if [ "$state" = "configured" ] && { [ "$speed" = "high-speed" ] || [ "$speed" = "full-speed" ]; } && [ "$carrier" = "1" ] && [ "$(current_usb0_ipv4)" = "$USB0_ADDR" ]; then
      if [ "$usb_connected_announced" -eq 0 ]; then
        say "========================================"
        say "USB GADGET CONNECTED"
        say "RNDIS CONFIGURED"
        say "UDC: $state"
        say "SPEED: $speed"
        say "USB0 CARRIER: $carrier"
        say "USB0: $USB0_ADDR"
        say "SSH SERVICE: $sshs"
        say "SSH LISTENER: $listener"
        say "========================================"
        say "Linux host:"
        say "1. Find the new RNDIS/USB network interface:"
        say "   ip -br link"
        say "   ip -br addr"
        say "2. Configure it:"
        say "   sudo ip link set <interface> up"
        say "   sudo ip addr flush dev <interface>"
        say "   sudo ip addr add 192.168.7.1/24 dev <interface>"
        say "3. Test:"
        say "   ping -c 3 192.168.7.2"
        say "   ssh ark@192.168.7.2"
        say "========================================"
        usb_connected_announced=1
      fi
      if [ "$sshs" = "active" ] && [ "$listener" = "yes" ]; then
        if [ "$ssh_ready_announced" -eq 0 ]; then
          say "SSH READY"
          say "ssh ark@192.168.7.2"
          ssh_ready_announced=1
        fi
      else
        if [ "$ssh_ready_announced" -eq 1 ]; then
          say "SSH LISTENER LOST"
          ssh_ready_announced=0
        fi
      fi
    else
      if [ "$usb_connected_announced" -eq 1 ]; then
        say "USB CABLE DISCONNECTED"
        say "GADGET MODE REMAINS ACTIVE"
        say "RECONNECT THE USB CABLE"
        usb_connected_announced=0
        ssh_ready_announced=0
      fi
    fi
    sleep 1
    connected_sec=$((connected_sec + 1))
    if [ $((connected_sec % 30)) -eq 0 ]; then
      if [ "$usb_connected_announced" -eq 1 ]; then
        say "CONNECTED: state=$state speed=$speed carrier=$carrier operstate=$oper ssh=$([ "$ssh_ready_announced" -eq 1 ] && printf ready || printf not-ready)"
      else
        say "DISCONNECTED: state=$state speed=$speed carrier=$carrier operstate=$oper"
      fi
    fi
  done
}

main "$@"