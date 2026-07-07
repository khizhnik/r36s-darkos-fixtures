# R36S DTB Patcher

Status:
Experimental

Validated:
✓ local DTB patch matrix
✓ partial patch states
✓ idempotent apply
✓ rollback integrity test
✓ live R36S dArkOSRE hardware test (already patched device)

Small CLI tool for dArkOS on R36S.

Targets only:
- `/boot/rk3326-r36s-linux.dtb`

Never touches:
- `/boot/rg351mp-uboot.dtb`

Requirements:
- dArkOSRE / R36S
- `dtc` must already exist on the device
- no internet required
- no `apt` used by this tool

Usage:
```bash
./r36s-dtb-patcher.sh --doctor
./r36s-dtb-patcher.sh --apply
reboot manually
./r36s-dtb-patcher.sh --rollback
./r36s-dtb-patcher.sh --remove-service
./r36s-dtb-patcher.sh
```

What it does:
- backs up the current DTB under `/boot/r36s-dtb-patcher-backups/<timestamp>/`
- creates `/boot/rk3326-r36s-linux.dtb.pre-r36s-devkit`
- decompiles the live DTB
- applies only the required SD2, OTG, and USB gadget changes
- rebuilds and verifies the DTB before replacement
- installs the USB gadget service from this repo after a successful DTB update

Tested:
- R36S
- dArkOSRE
- RK3326
- Linux 4.4.189

Adds:
- improved SD2 compatibility
- USB OTG ethernet gadget support
- SSH over USB cable

Notes:
- Different R36S board revisions and clones may need testing.
- Launching without arguments on the console opens a `dialog`-based button menu when `dialog` is available.
- If `dialog` is missing, the script falls back to the older text menu.
- If no interactive tty is available, the script writes a fallback note to `r36s-dtb-patcher.log` next to the script and prints usage.
- `--doctor` is read-only.
- `--apply` does not reboot automatically.
- `--rollback` restores the latest backup and does not reboot automatically.
- `--remove-service` only removes the USB gadget service layer.
- The tool is intentionally minimal and is not a general device manager.

If something goes wrong:
1. Power off R36S.
2. Remove the system SD card.
3. Open the `BOOT` partition on a PC.
4. Rename `rk3326-r36s-linux.dtb.pre-r36s-devkit` to `rk3326-r36s-linux.dtb`.
5. Boot again.

Warning:
- A wrong DTB may break boot, display, buttons, SD, or USB.
