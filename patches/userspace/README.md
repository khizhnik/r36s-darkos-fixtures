# EmulationStation Dummy Audio Userspace Artifact

This directory documents the runtime files created by the `Reduce Speaker Noise -> Patch EmulationStation Dummy Audio` action.

It is a documentation-first artifact so advanced users can see the exact files without reading the full patcher.

The companion file `0001-r36s-emulationstation-dummy-audio-hooks.md` is documentation-only and describes the runtime files plus install/remove commands.

Managed files:
- `/etc/systemd/system/emulationstation.service.d/r36s-audio.conf`
- `/home/ark/.emulationstation/scripts/game-start/r36s-audio-on.sh`
- `/home/ark/.emulationstation/scripts/game-end/r36s-audio-off.sh`

The patcher manages these files and their restore path separately from the DTB speaker-control patch.

Use this artifact when you want to inspect the exact runtime change set before applying it on a device.
