# steam (on bazzite)

I had the uncommon situation where Steam downloading large games (1GB+) would cause the machine to freeze or crash.

## possible solution (1 of 2)

Create (or edit) `steam_dev.cfg`. This file is normally located in `~/.steam/steam/steam_dev.cfg`.

Add the following lines:
```
@nClientDownloadEnableHTTP2PlatformLinux 1
@fDownloadRateImprovementToAddAnotherConnection 1.0
```

<sub>Note, this worked until I restarted the machine. Then it started freezing and crashing.</sub>

## possible solution (2 of 2)

Update the Bee GTi14 firmware:
- https://dr.bee-link.cn/?dir=uploads%2FGTI%2FGTi14%2FBIOS-EC%2FGTi14-BIOS-Version2-T204-Note-Solve-Linux-issue-only-T201-can-update-this-BIOS
- uploads / GTI / GTi14 / BIOS-EC / GTi14-BIOS-Version2-T204-Note-Solve-Linux-issue-only-T201-can-update-this-BIOS

<sub>Note, this permanently fixed the issue for me.</sub>

## extra info

This occurred on a Bee GTi14
- Intel Core Ultra 9 185H (22) @ 5.20 GHz
- NVIDIA GeForce RTX 3080 Lite Hash Rate [Discrete]
- Intel Arc Graphics @ 2.35 GHz [Integrated]
- RAM 31.01 GiB
- SSD 929.91 GiB [btrfs]

Running Bazzite 42
- KDE Plasma 6.4.3
- KWin (Wayland)
- bash 5.2.37
- Ptyxis 48.4

Linux 6.15.6-105.bazzite.fc42.x86_64
- `journalctl` had no entries related to the freeze or crash and `dmesg` didn't seem to have anything relevant.
