# r36s-darkos-fixtures

This is not a new firmware image.
It is a set of local fixtures and patch references for dArkOSRE on R36S.

What it is for:
- SD2 compatibility fixes
- USB OTG gadget enablement
- PortMaster /roms2 access
- SSH over USB without WiFi
- development and reproducible recovery of the working setup

Layout:
- `dtb/originals/` - preserved reference DTBs
- `dtb/patched/` - patched DTBs for the working setup
- `patches/` - DTB patch series
- `usb-gadget/` - userspace systemd gadget install workflow
- `logs/` - reference snapshots from the working device

Quick start:
1. Install the patched DTB for dArkOSRE.
2. Apply the USB gadget userspace setup from `usb-gadget/`.
3. Reboot the R36S.
4. Connect the USB cable.
5. From the host, run `usb-gadget/connect-r36s.sh`.

Expected result:
- R36S USB gadget IP: `192.168.7.2`
- Host IP: `192.168.7.1`
- SSH target: `ark@192.168.7.2`

Original firmware files are included only for reproducibility/reference.
Use at your own risk. Wrong DTB may break display, controls, SD slots or USB. Keep backups.
