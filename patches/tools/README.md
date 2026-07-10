# Tooling Patch Artifact

This directory contains the patch artifact for `tools/r36s-dtb-patcher.sh` and its companion `tools/README.md`.

The patch captures the current tooling state:
- DTB doctor / apply / rollback / remove-service
- `Reduce Speaker Noise` submenu
- RK817 speaker control DTB handling
- EmulationStation dummy audio userspace handling
- managed game-start / game-end hooks

This is a normal `git apply` style patch and should be checked against a clean checkout.
