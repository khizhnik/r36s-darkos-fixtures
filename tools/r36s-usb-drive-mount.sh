#!/bin/bash
set -u

prompt_exit() {
  printf 'Press Enter to return...\n'
  read -r
}
print_context() {
  printf '[System]\n'
  uname -a
  printf '[USB]\n'
  if command -v lsusb >/dev/null 2>&1; then
    lsusb
  else
    printf 'lsusb is not available\n'
  fi
  printf '[Block devices]\n'
  lsblk -o NAME,PATH,TYPE,TRAN,RM,SIZE,FSTYPE,LABEL,MOUNTPOINTS
}

fail() {
  local stage="$1" reason="$2" rc="${3:-1}"
  printf 'MOUNT FAILED\n'
  printf 'Stage: %s\n' "$stage"
  printf 'Reason: %s\n' "$reason"
  printf 'Return code: %s\n' "$rc"
  prompt_exit
  exit "$rc"
}
[ -t 1 ] && printf '\033c'
printf 'R36S USB Drive Mount Test\n'
printf '=========================\n'
printf '\n'

command -v lsblk >/dev/null 2>&1 || fail startup "lsblk is missing" 8
command -v mount >/dev/null 2>&1 || fail startup "mount is missing" 8
command -v findmnt >/dev/null 2>&1 || fail startup "findmnt is missing" 8
command -v mkdir >/dev/null 2>&1 || fail startup "mkdir is missing" 8
command -v id >/dev/null 2>&1 || fail startup "id is missing" 8
if [ "$(id -u)" -eq 0 ]; then
  RUN_AS_ROOT=()
else
  command -v sudo >/dev/null 2>&1 || fail startup "sudo is missing" 8
  RUN_AS_ROOT=(sudo)
fi
print_context
printf '\n'

dev="/dev/sda1"
found=0
for i in $(seq 1 15); do
  if [ -b "$dev" ]; then
    found=1
    break
  fi
  printf 'Waiting for /dev/sda1... %s/15\n' "$i"
  sleep 1
done
[ "$found" -eq 1 ] || fail discovery "/dev/sda1 was not created" 2

fs="$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -n1 | tr -d '\r\n')"
printf 'Device: %s\n' "$dev"
printf 'Filesystem: %s\n' "${fs:-}"
[ -n "${fs:-}" ] || fail filesystem "filesystem type is empty" 3
uid="$(id -u ark 2>/dev/null || id -u)"
gid="$(id -g ark 2>/dev/null || id -g)"
mnt="/mnt/usbdrive"
if [ "${#RUN_AS_ROOT[@]}" -eq 0 ]; then
  printf '[1] Creating mountpoint: mkdir -p %s\n' "$mnt"
else
  printf '[1] Creating mountpoint: sudo mkdir -p %s\n' "$mnt"
fi
"${RUN_AS_ROOT[@]}" mkdir -p "$mnt"
rc=$?
printf 'Return code: %s\n' "$rc"
[ "$rc" -eq 0 ] || fail mountpoint "could not create mountpoint" "$rc"
case "$fs" in
  fat) mntfs="vfat" ;;
  vfat|exfat|ext2|ext3|ext4|ntfs3) mntfs="$fs" ;;
  ntfs)
    if command -v ntfs-3g >/dev/null 2>&1; then
      mntfs="ntfs-3g"
    else
      fail filesystem "ntfs-3g is not installed" 4
    fi
    ;;
  *) fail filesystem "unsupported filesystem: $fs" 4 ;;
esac
opts=""
case "$fs" in
  vfat|fat|exfat|ntfs|ntfs3) opts="uid=$uid,gid=$gid,umask=022" ;;
esac

cmd=("${RUN_AS_ROOT[@]}" mount -t "$mntfs" "$dev" "$mnt")
[ -n "$opts" ] && cmd+=(-o "$opts")
printf '[2] Mount command: %s\n' "${cmd[*]}"
err="/tmp/new-r36s-usb-drive-mount.$$.$RANDOM.err"
rm -f "$err"
"${cmd[@]}" 2>"$err"
rc=$?
printf 'Mount return code: %s\n' "$rc"
if [ "$rc" -ne 0 ]; then
  if [ -s "$err" ]; then
    tail -n 10 "$err"
  else
    printf 'mount returned no error text\n'
  fi
  printf '[Kernel tail]\n'
  if command -v dmesg >/dev/null 2>&1; then
    dmesg | tail -n 30
  else
    printf 'dmesg is not available\n'
  fi
  rm -f "$err"
  fail mount "mount command failed" "$rc"
fi
rm -f "$err"
printf '[3] Verifying result...\n'
if ! findmnt "$mnt" >/dev/null 2>&1; then
  fail verification "findmnt did not confirm the mount" 7
fi
findmnt "$mnt"
printf 'ls -la %s | head -n 20\n' "$mnt"
ls -la "$mnt" | head -n 20
printf '\nUSB DRIVE MOUNTED\n'
printf 'Device: %s\n' "$dev"
printf 'Filesystem: %s\n' "$fs"
printf 'Mountpoint: %s\n' "$mnt"
prompt_exit
exit 0
