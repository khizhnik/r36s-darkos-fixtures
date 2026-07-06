# R36S USB Gadget

Requirements:
- patched DTB installed first

Install on R36S:
```bash
./install-r36s-usb-gadget.sh
```

Notes:
- The installer uses sudo internally when system files need to be updated.
- It can be run as ark from a console/PortMaster shell.
- It enables and starts the gadget immediately.
- It does not reboot automatically.
- After reboot, the service starts automatically.

After reboot:
- connect USB cable

Uninstall:
```bash
./uninstall-r36s-usb-gadget.sh
```

Host side:
```bash
./connect-r36s.sh
```

Expected:
```text
ssh ark@192.168.7.2
```
