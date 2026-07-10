# Experimental R36S audio test: candidate A topology + lower speaker volume

Base:
- `dts/darkos-devkit-rk3326-r36s-linux.dts`

Purpose:
- keep the best current speaker-control topology and lower the speaker analog volume

Source patterns:
- `R36S-V12 Variant 3 Panel A` for `spk-ctl-gpios` + `spk-con-gpio`
- `soysauce Y3506` for `spk-volume = <0x01>`

Changes in this variant:
- `rk817-codec`
  - `spk-ctl-gpios = <0x97 0x07 0x00>;`
  - `spk-mute-delay-ms = <0x32>;`
  - `spk-volume = <0x01>;`
- `rk817-sound/simple-audio-card,codec`
  - `spk-con-gpio = <0x97 0x07 0x00>;`

Not included:
- any SD2, USB, OTG, display, buttons, regulator, or clock changes
