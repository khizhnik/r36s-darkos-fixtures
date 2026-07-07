## Quick Install (R36S users)

This is the recommended method if you just want to enable the fixes on your device.

### 1. Copy the patcher

Download:

```text
tools/r36s-dtb-patcher.sh
```

from this repository.

Power off your R36S and remove the **system SD card (SD Card 1)**.

Insert the SD card into your computer and copy:

```text
r36s-dtb-patcher.sh
```

to:

```text
/opt/system/
```

on the SD card.

Safely eject the SD card and put it back into your R36S.

---

### 2. Run the patcher

Boot your R36S.

Open:

```text
START
 → Settings
 → R36S DTB Patcher
```

You should see the patcher menu.

---

### 3. Check your device

First run:

```text
1. Check status
```

Check status only checks your current DTB status.  
It does not modify anything.

---

### 4. Apply the patch

Select:

```text
2. Apply DTB patch
```

The tool will:

- create a backup of your current DTB
- patch the device tree
- enable SD2 compatibility fixes
- enable USB OTG gadget support
- install the USB network service

When finished, reboot your R36S.

---

## Restore / Troubleshooting

If you want to undo the changes:

Run:

```text
3. Rollback DTB
```

This restores the original DTB from the automatic backup.

If you only want to disable the USB gadget service:

Run:

```text
4. Remove USB gadget service
```

This removes the userspace USB network service without changing your DTB.

> Note: Rollback is the safest option if you want to completely return to the previous state.