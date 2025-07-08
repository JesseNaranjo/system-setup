# gpu passthru

## update container config

After creating the container, edit the container file config located at `/var/lib/lxc/<container-name>/config`.

Add these lines (assuming NVIDIA GPU):
```shell
# GPU passthrough

# Allow cgroup access
lxc.cgroup2.devices.allow = c 195:* rwm
lxc.cgroup2.devices.allow = c 234:* rwm

# Pass through device files
lxc.mount.entry = /dev/nvidia0           dev/nvidia0           none  bind,optional,create=file
lxc.mount.entry = /dev/nvidiactl         dev/nvidiactl         none  bind,optional,create=file
lxc.mount.entry = /dev/nvidia-modeset    dev/nvidia-modeset    none  bind,optional,create=file
lxc.mount.entry = /dev/nvidia-uvm        dev/nvidia-uvm        none  bind,optional,create=file
lxc.mount.entry = /dev/nvidia-uvm-tools  dev/nvidia-uvm-tools  none  bind,optional,create=file
```

You can find the numbers to use for `lxc.cgroup2.devices.allow` using `ls -l /dev/nvidia*`. Sample output:
```
$ ls -l /dev/nvidia*
crw-rw-rw- 1 root root  195,   0 Feb  2 07:45 /dev/nvidia0
crw-rw-rw- 1 root root  195, 255 Feb  2 07:45 /dev/nvidiactl
crw-rw-rw- 1 root root  195, 254 Feb  2 07:45 /dev/nvidia-modeset
crw-rw-rw- 1 root root  234,   0 Feb  2 08:16 /dev/nvidia-uvm
crw-rw-rw- 1 root root  234,   1 Feb  2 08:16 /dev/nvidia-uvm-tools
```

YMMV, but I had to comment out the inclusion of `userns.conf` near the top when running an unpriviledge container:
```shell
#lxc.include = /usr/share/lxc/config/userns.conf
```
(leaving this line in caused the container's `systemd-networkd` to fail and not get a network connection, and stopping the container took a long time)

## install drivers in container

Packages needed for NVIDIA:
- `nvidia-driver`
- `nvidia-smi`
- `libcuda1`
- (no need to install all recommended packages, just dependencies)
