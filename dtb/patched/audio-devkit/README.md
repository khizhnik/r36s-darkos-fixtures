# R36S Audio DTB Candidate Matrix

These folders contain experimental DTB/DTS candidates tested during the R36S speaker hiss investigation.

They are preserved for future board revisions and comparison.

## Tested candidates

| Candidate | Speaker GPIO | Extra changes | Result on tested R36S-V1.0 2024-09-27 |
|---|---:|---|---|
| darkos-devkit-audio-test | gpio3 pin7 / gpio103 | spk-ctl + spk-con + mute delay | Best result; became final DTB patch |
| darkos-devkit-audio-test-gpio103-spkvol01 | gpio103 | same as above + lower spk-volume | Similar to first, volume did not solve hiss |
| darkos-devkit-audio-test-soysauce-gpio320 | gpio3 pin20 / gpio116 | soysauce-style candidate | Better than baseline, worse than gpio103 |
| darkos-devkit-audio-test-spkctl-only | gpio103 | spk-ctl only, no spk-con | Useful isolation candidate |

## Final selected path

The final patch uses:

```dts
spk-ctl-gpios = <gpio3 0x07 0x00>;
spk-mute-delay-ms = <0x32>;
spk-con-gpio = <gpio3 0x07 0x00>;
```

## Notes
- These candidates may be useful for other R36S board revisions.
- Different clones may route speaker control differently.
- Do not assume gpio103 is universal.
- Prefer the integrated patcher unless you are manually testing DTBs.