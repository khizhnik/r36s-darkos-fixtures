# RK3326 R36S Audio Test DTB

Experimental DTB artifact for investigating the R36S audio hiss issue.

## Source

- Base DTS: `dts/darkos-devkit-rk3326-r36s-linux.dts`
- Donor inspiration: `clone/R36S-V12 2023-08-18 Variant 3 Panel A`

## Added speaker control

This test artifact adds the donor speaker control hook using the live/current
`gpio3` phandle:

- `spk-ctl-gpios = <0x97 0x07 0x00>;`
- `spk-mute-delay-ms = <0x32>;`
- `spk-con-gpio = <0x97 0x07 0x00>;`

## Purpose

Investigate whether adding RK817 speaker amplifier control reduces or removes
the hiss that appears when the RK817 speaker playback path is active.