# R36S DTB Patcher

Status:
Experimental

Validated:
✓ local DTB patch matrix
✓ partial patch states
✓ idempotent apply
✓ rollback integrity test
✓ live R36S dArkOSRE hardware test (already patched device)
✓ EmulationStation dummy audio idle fix test
✓ game-start / game-end audio lifecycle hooks

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
- opens a `Reduce Speaker Noise` submenu for the DTB speaker-control patch and the EmulationStation dummy-audio userspace patch

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
- `--doctor` reports `Audio DTB patch` and `ES dummy audio` separately; the ES dummy audio status can be `yes`, `partial`, or `no`.
- Launching without arguments on the console opens a `dialog`-based button menu when `dialog` is available.
- If `dialog` is missing, the script falls back to the older text menu.
- If no interactive tty is available, the script writes a fallback note to `r36s-dtb-patcher.log` next to the script and prints usage.
- `--doctor` is read-only.
- `--apply` does not reboot automatically.
- `--rollback` restores the latest backup and does not reboot automatically.
- `--remove-service` only removes the USB gadget service layer.
- The tool is intentionally minimal and is not a general device manager.

## Reduce Speaker Noise

The submenu has two independent fixes:

### Patch DTB Speaker Control

- Adds RK817 speaker amplifier GPIO control to the live DTB.
- Tested on the R36S-V1.0 2024-09-27 unit with GPIO3 pin 7 / `gpio103`.
- Restore is separate and only removes the DTB-level speaker-control properties.

### Patch EmulationStation Dummy Audio

- Adds the systemd drop-in:
  - `/etc/systemd/system/emulationstation.service.d/r36s-audio.conf`
- Adds the managed lifecycle hooks:
  - `/home/ark/.emulationstation/scripts/game-start/r36s-audio-on.sh`
  - `/home/ark/.emulationstation/scripts/game-end/r36s-audio-off.sh`
- Requires a reboot after apply or restore.
- Restore is separate from DTB restore.

Final confirmed audio behavior on the tested device:

- Menu idle:
  - `SDL_AUDIODRIVER=dummy`
  - EmulationStation does not keep `/dev/snd/pcmC0D0p` open
  - `Playback Path = OFF`
  - `gpio103 = LOW`
  - no speaker hiss
- Game start:
  - `game-start` hook sets `Playback Path = SPK_HP`
  - RetroArch opens ALSA PCM
  - `gpio103 = HIGH`
  - game audio works
- Game exit:
  - `game-end` hook sets `Playback Path = OFF`
  - PCM closes
  - `gpio103 = LOW`
  - speaker hiss disappears

### Current investigation result

The original hiss problem was mixed:
- missing or mismatched DTB speaker control
- EmulationStation keeping ALSA playback open while idle
- RK817 `Playback Path` staying in a speaker-enabled state after games

The final working fix combines:
- DTB speaker control
- EmulationStation dummy audio
- game-start / game-end `Playback Path` hooks

If something goes wrong:
1. Power off R36S.
2. Remove the system SD card.
3. Open the `BOOT` partition on a PC.
4. Rename `rk3326-r36s-linux.dtb.pre-r36s-devkit` to `rk3326-r36s-linux.dtb`.
5. Boot again.

Warning:
- A wrong DTB may break boot, display, buttons, SD, or USB.

## Manual verification

Doctor:
```bash
sudo /opt/system/r36s-dtb-patcher.sh --doctor
```

Idle audio:
```bash
amixer | grep -A5 "Playback Path"
cat /proc/asound/card0/pcm0p/sub0/status
sudo cat /sys/kernel/debug/gpio | grep 103
```

Expected:
- Menu idle: `Playback Path OFF`, status closed, `gpio103 out lo`
- Game: `Playback Path SPK_HP`, RetroArch owns PCM, `gpio103 out hi`
- After exit: `Playback Path OFF`, status closed, `gpio103 out lo`

Safety notes:
- Experimental.
- Tested on R36S-V1.0 2024-09-27 with RK817 + JS2001/20N52 amplifier.
- Hardware revisions vary.
- Restore actions exist separately for DTB speaker control and EmulationStation dummy audio.
- Reboot is required after EmulationStation dummy audio apply or restore.
