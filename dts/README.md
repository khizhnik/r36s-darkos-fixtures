# DTS References

DTS files in this directory are generated decompiled references.
The source DTB files live under `dtb/`.

Key references:
- `dts/darkos-rk3326-r36s-linux-original.dts`
- `dts/darkos-devkit-rk3326-r36s-linux.dts`

The patch series in `patches/` documents the intended minimal changes.

To rebuild a DTB from the final patched DTS:
```bash
dtc -I dts -O dtb -o rebuilt.dtb dts/darkos-devkit-rk3326-r36s-linux.dts
```
