## GRUB CLI entry

This readme will explain how to auto-generate an additional entry in GRUB which automatically points to the most recent kernel version installed.

1. Duplicate `/etc/grub.d/10_linux` as `11_linux_cli`
2. Add a section at the top with the following lines:
```
### CUSTOM OVERRIDES
GRUB_DISTRIBUTOR="${GRUB_DISTRIBUTOR} (CLI)"
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} systemd.unit=multi-user.target"
GRUB_DISABLE_RECOVERY=true
### END
```

- This will ensure that the distribution title includes the text "(CLI)"
- It will ensure the system boots into the CLI / terminal only, instead of the graphical interface (by using `systemd.unit=multi-user.target`)
- And it will not include the default recovery entries (because they will already be part of the default menus)
3. Run `update-grub`

Note: you can start the Graphical interface using the following command:
```
systemctl isolate graphical.target
```
