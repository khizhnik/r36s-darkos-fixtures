# Experimental soysauce-style RK817 speaker GPIO test

Base:
- `dts/darkos-devkit-rk3326-r36s-linux.dts`

Purpose:
- test `gpio3_20` speaker control and lower speaker analog volume using the soysauce donor pattern

Source donor family:
- `soysauce Y3506`

Changes in this variant:
- `rk817-codec`
  - `spk-ctl-gpios = <0x97 0x14 0x00>;`
  - `spk-volume = <0x01>;`

Not included:
- `spk-con-gpio`
- any SD2, USB, OTG, display, buttons, regulator, or clock changes