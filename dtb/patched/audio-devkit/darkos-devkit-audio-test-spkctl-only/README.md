# Experimental RK817 speaker control isolation test

Base:
- `dts/darkos-devkit-rk3326-r36s-linux.dts`

Purpose:
- test whether `spk-ctl-gpios` alone reduces R36S hiss better than the full `spk-ctl-gpios` + `spk-con-gpio` donor pattern

Donor pattern:
- `R36S-V12 Variant 1/2` family

Changes in this variant:
- `rk817-codec`
  - `spk-ctl-gpios = <0x97 0x07 0x00>;`
  - `spk-mute-delay-ms = <0x32>;`

Not included:
- `spk-con-gpio`
- any SD2, USB, OTG, display, buttons, regulator, or clock changes