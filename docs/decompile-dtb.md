# Decompile and Rebuild DTBs

Install `dtc`:
```bash
sudo apt install device-tree-compiler
```

Decompile:
```bash
dtc -I dtb -O dts -o output.dts input.dtb
```

Compile:
```bash
dtc -I dts -O dtb -o output.dtb input.dts
```

Compare:
```bash
cmp -s rebuilt.dtb known-good.dtb && echo OK
```

Warnings:
- `dtc` warnings are common for decompiled vendor DTBs.
- Warnings are not always fatal.
- A failed build or non-matching binary is fatal for this repo.

Safety:
- Always back up BOOT partition DTB files before replacing anything.
- A wrong DTB may break display, controls, SD slots, USB, or boot.
