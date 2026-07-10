# DTS Patch Series

These are the board-level patches for the R36S/dArkOS image.

Apply in order:
1. `0001-r36s-darkos-fix-sd2-compatibility.patch`
2. `0002-r36s-darkos-enable-usb-otg-port.patch`
3. `0003-r36s-darkos-force-usb-gadget-mode.patch`
4. `0004-r36s-darkos-reduce-speaker-noise.patch`

Notes:
- Keep the filenames unchanged.
- These patches are intended for advanced users who build or edit the live DTB.
- Patches 0001-0003 are preserved as historical/reference DTS artifacts from the original SD2/OTG/USB gadget investigation.
- Patch 0004 is the current speaker amplifier control patch and applies cleanly to the current repo checkout.
