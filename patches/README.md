# R36S patch artifacts

This directory is split by patch category:

- `patches/dts/` - DTS / DTB-level patches for advanced users
- `patches/tools/` - tooling patch artifacts for the repository scripts
- `patches/userspace/` - documentation artifacts for runtime userspace hooks
  - these are reference files for the generated EmulationStation dummy audio drop-in and hooks

Do not apply the DTS patches out of order.

Current DTS patch order:
1. SD2 compatibility fix
2. Enable OTG PHY
3. Force USB gadget / peripheral mode
4. Reduce speaker noise

Final result on the tested R36S:
- SD2 compatibility improved
- USB OTG enabled
- USB Ethernet gadget works
- SSH over USB:
  ark@192.168.7.2
