# R36S Hardware Profile

Verified device information collected during dArkOSRE development and testing.

## Device

- Model: R36S
- PCB revision: R36S-V1.0
- PCB date marking: 2024-09-27
- OS tested:
    - dArkOSRE
- Kernel:
    - Linux 4.4.189

Related board photos:

docs/photos/

## SoC

Rockchip RK3326

## RAM

Confirmed 1GB RAM variant.

Physical inspection:

Two DDR chips installed near RK3326.

Chip markings:

```
5DE77
D9QWN
```

Additional markings:

```
ZQ44
NCG5
```

Identification:

- Manufacturer: Micron
- Type: DDR3 / DDR3L SDRAM
- FBGA marking: D9QWN
- Estimated density:
    - 4Gbit per chip
    - 512MB per chip

Configuration:

```
2 × 512MB = 1024MB RAM
```

Kernel confirmation:

```
Memory: 901860K/1015808K available
```

Runtime confirmation:

```
MemTotal: 916856 kB
```

## Audio hardware

Codec / PMIC:

- Rockchip RK817

External speaker amplifier:

- Chip marking observed: 20N52
- Possible identification: JS2001 family (unconfirmed)

Speaker control:

Verified on this unit:

gpio3 pin 7
Linux GPIO: gpio103

Kernel debug:

```text
gpio-103 (                    |spk-ctl             ) out hi/lo
```

## Audio investigation summary

Original symptoms:
- speaker hiss in EmulationStation menu
- hiss after returning from games
- volume level did not affect hiss

Findings:
- RK817 codec exposes Playback Path control
- DTB lacked speaker-control GPIO definitions
- EmulationStation kept ALSA PCM active while idle

Final verified state on this board:
- idle:
  Playback Path OFF
  gpio103 LOW

- game:
  Playback Path SPK_HP
  gpio103 HIGH

- after game exit:
  Playback Path OFF
  gpio103 LOW
  speaker hiss removed

## Notes

Some R36S PCB V1.0 boards are reported with smaller RAM configurations.

This confirms that PCB revision alone does not identify RAM size.
The same PCB revision may exist with different RAM chip configurations.

Always verify:
- RAM chip markings
- kernel memory detection
- boot logs

## Tested fixes on this device

Working:

- SD2 compatibility DTB patch
- USB OTG gadget mode
- USB Ethernet SSH access
- dArkOSRE DTB live patcher
- RK817 speaker control DTB patch
- EmulationStation dummy audio lifecycle fix