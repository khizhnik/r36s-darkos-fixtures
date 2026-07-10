# R36S EmulationStation Dummy Audio Hooks
#
# Documentation-only artifact. This is not a git-apply patch because the
# targets are runtime files on the handheld, not repository-tracked sources.
#
# Managed files:
# - /etc/systemd/system/emulationstation.service.d/r36s-audio.conf
# - /home/ark/.emulationstation/scripts/game-start/r36s-audio-on.sh
# - /home/ark/.emulationstation/scripts/game-end/r36s-audio-off.sh
#
# Exact contents are shown below so advanced users can install or remove the
# change manually if needed.

--- /dev/null
+++ /etc/systemd/system/emulationstation.service.d/r36s-audio.conf
@@
+[Service]
+Environment=SDL_AUDIODRIVER=dummy

--- /dev/null
+++ /home/ark/.emulationstation/scripts/game-start/r36s-audio-on.sh
@@
+#!/bin/bash
+amixer set 'Playback Path' SPK_HP >/dev/null 2>&1 || true

--- /dev/null
+++ /home/ark/.emulationstation/scripts/game-end/r36s-audio-off.sh
@@
+#!/bin/bash
+amixer set 'Playback Path' OFF >/dev/null 2>&1 || true

## Manual install

1. Create the systemd drop-in directory if needed:
   ```bash
   sudo mkdir -p /etc/systemd/system/emulationstation.service.d
   ```
2. Write the three files exactly as shown above.
3. Make the hook scripts executable:
   ```bash
   sudo chmod 755 /home/ark/.emulationstation/scripts/game-start/r36s-audio-on.sh
   sudo chmod 755 /home/ark/.emulationstation/scripts/game-end/r36s-audio-off.sh
   ```
4. Reload systemd:
   ```bash
   sudo systemctl daemon-reload
   ```

## Manual remove

Remove only the three managed files:
```bash
sudo rm -f /etc/systemd/system/emulationstation.service.d/r36s-audio.conf
sudo rm -f /home/ark/.emulationstation/scripts/game-start/r36s-audio-on.sh
sudo rm -f /home/ark/.emulationstation/scripts/game-end/r36s-audio-off.sh
sudo systemctl daemon-reload
```

## Behavior

- Menu idle: EmulationStation uses SDL dummy audio and does not keep ALSA playback open.
- Game start: the start hook sets `Playback Path` to `SPK_HP`.
- Game exit: the end hook sets `Playback Path` to `OFF`.
- Reboot is required after apply or remove if you are changing the running desktop session.