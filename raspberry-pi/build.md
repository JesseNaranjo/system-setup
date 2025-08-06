# build raspberry pi (RPi) OS images

Packages needed:
- build-essentials
- dosfstools
- f2fs-tools (because the primary drive filesystem is set to f2fs)
- git (optional, if you want to manually download the source)
- time
- vmdb2

<sup>(all others should be automatically installed as dependencies)</sup>

## image naming convention

The naming convention is important because this is how `make` understands what needs to be built.

Naming convention:
```bash
raspi_<model>_<release>.<result-type>
```
where
- `raspi` - exact value required
- `<model>` - Raspberry Pi board version, e.g., `1`, `2`, `3`, `4`, `5`, etc.
- `<release>` - identifies the Debian release, e.g., `trixie`, `bookworm`, `bullseye`, etc.
- `<result-type>` - the build output, only `img` and `yaml` are available (as of this guide)
  - `img` will generate a standard image with no customizations
  - `yaml` will generate the specfile (i.e., image definition) which you can modify before building the image

For example,
```bash
make raspi_3_bookworm.img
```
will generate a disk image that can be flashed directly to an SD card or USB drive. This image will boot directly into Debian Bookworm.

## 1. build a custom image

The following call will result into a single `yaml` file,
```bash
make raspi_3_bookworm.yaml
```

Once the standard-named file (e.g., `raspi_3_bookworm`) has been created, it can be rename it to something more memorable, such as,
```bash
orange_rpi3_bookworm.yaml
```

Edit the `yaml` file as desired. Recommended sections to review:
- see file `orange_rpi3_bookworm.yaml` for reference
- apt: install - add packages that you need/want preinstalled
- debootstrap components - useful during install (`main`, `contrib`, `non-free`, `non-free-firmware`)
- /etc/apt/sources.list - set your sources here
- mkfs (file system format)
- review everything else in the file

Build the image,
```bash
vmdb2 -v --output orange_rpi3_bookworm.img --rootfs-tarball orange_rpi3_bookworm.tar.gz --log orange_rpi3_bookworm.log orange_rpi3_bookworm.yaml
```

## 2. build a standard image

Building standard images is a little easier. Simply structure the raspi file name correctly and,
```bash
make raspi_3_bookworm.img
```
this results in a ready-to-go `img` file that can be written directly to a dis.

## 3. copy image to drive

Make sure `of` targets the device and not a partition, such as `/dev/mmcblkX` or `/dev/sdX`.

```bash
#                                       v-- typically mmcblkX or sdX
dd if=orange_rpi3_bookworm.img of=/dev/<device> bs=64K oflag=dsync status=progressm
```

## 4. resize root partition

Use `parted`, `fdisk`, or your favorite partition manager. Below we use `parted`.

```bash
parted /dev/<device>        #  (typically mmcblkX or sdX)

print free                  #  note the amount of space left
## Sample Output:
#  Number  Start   End     Size    Type     File system  Flags
#          32.3kB  4194kB  4162kB           Free Space
#   1      4194kB  537MB   533MB   primary  fat16        lba
#   2      537MB   2621MB  2085MB  primary  f2fs
#          2621MB  7969MB  5348MB           Free Space

resizepart <Number> -1s     #  <Number> = Number from print free output
                            #  -1s represents the very last sector

quit
```

Then, use `resize.f2fs` to make the file system recognize the partition size.

```bash
resize.f2fs /dev/<device>   #  (typically mmcblkXp2 or sdX2)
```

<sup>Source (for steps 1-3): https://salsa.debian.org/raspi-team/image-specs/-/tree/master?ref_type=heads</sup>

## Post-boot

Things to keep in mind:
- This install uses `iwd` and `iwctl` - more info here: https://wiki.debian.org/WiFi/HowToUse#IWCtl
  - Edit `/etc/iwd/main.conf` and set (uncomment) `EnableNetworkConfiguration` (otherwise, the interface won't get an IP)
    ```bash
    [General]
    EnableNetworkConfiguration=true
    ```
  - Ensure `iwd` and `systemd-resolved` services are enabled and running (using `systemctl`)
  - Then:
    ```bash
    iwctl
    > station list
    > station <device> scan
    > station <device> get-networks
    > station <device> connect <ssid>
    ```
- Enable swap file: https://wiki.debian.org/Swap
  ```bash
  dd if=/dev/zero of=/var/swapfile bs=1024 count=SIZE    #   <2GB RAM: 2x RAM or equal to RAM for hibernation.
                                                         #  2-8GB RAM: Equal to RAM or 2x RAM for hibernation. 
                                                         # 8-64GB RAM: At least 4GB, or 1.5x RAM for hibernation. 
                                                         #  >64GB RAM: Minimum 4GB, hibernation not recommended.
  chmod 600 /var/swapfile
  mkswap /var/swapfile
  swapon /var/swapfile
  ```
  ```bash
  # /etc/fstab
  /var/swapfile       none    swap    sw      0       0
  ```
