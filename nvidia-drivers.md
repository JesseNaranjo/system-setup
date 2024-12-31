## nvidia driver install steps

- Ensure DKMS is configured (see dkms.md) and signing certificate is enrolled in mokutil
- Add "contrib non-free non-free-firmware" to all deb src lines in `/etc/apt/sources.list`
- Install `nvidia-driver` and `firmware-misc-nonfree` packages

Steps borrowed from https://wiki.debian.org/NvidiaGraphicsDrivers.

## additional driver configuration

- https://download.nvidia.com/XFree86/Linux-x86_64/460.32.03/README/powermanagement.html#PreserveAllVide719f0
