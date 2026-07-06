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
