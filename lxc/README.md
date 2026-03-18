# LXC Container Management Scripts

This directory contains scripts for managing unprivileged LXC containers on Linux systems. The scripts provide a complete workflow for setting up, creating, managing, backing up, and restoring containers.

## Script Overview

| Script | Description | Requires Root |
|--------|-------------|---------------|
| `setup-lxc.sh` | Configure unprivileged LXC for a user | Yes |
| `create-lxc.sh` | Create a new container (auto-detects distro) | No |
| `start-lxc.sh` | Start container(s) via systemd user service | No |
| `stop-lxc.sh` | Stop container(s) gracefully | No |
| `restart-lxc.sh` | Restart container(s) | No |
| `backup-lxc.sh` | Backup container to compressed archive | Yes (sudo) |
| `restore-lxc.sh` | Restore container from backup | Yes (sudo) |
| `config-lxc-ssh.sh` | Configure SSH keys for container access | Yes |
| `_download-lxc-scripts.sh` | Self-updating script manager | No |
| `create-priv-lxc.sh` | Create privileged container (legacy/unsafe) | Yes |

## Quick Start

### Initial Setup

```bash
# 1. Configure LXC for your user (run as root)
sudo ./setup-lxc.sh myuser

# 2. Switch to the configured user
su - myuser

# 3. Create your first container
./create-lxc.sh mycontainer
```

### Daily Operations

```bash
# Start a container (auto-attaches if single container)
./start-lxc.sh mycontainer

# Start multiple containers
./start-lxc.sh web db cache

# Stop containers
./stop-lxc.sh mycontainer
./stop-lxc.sh              # Stop all running containers

# Restart containers
./restart-lxc.sh mycontainer
```

### Backup and Restore

```bash
# Backup a container (creates .tar.7z archive)
./backup-lxc.sh mycontainer /backups

# Backup with compression options
./backup-lxc.sh mycontainer --compression=fast      # Quick, larger files
./backup-lxc.sh mycontainer --compression=balanced  # Moderate
./backup-lxc.sh mycontainer --compression=small     # Maximum compression (default)

# Restore from backup
./restore-lxc.sh mycontainer_20241222_120000.tar.7z

# Restore with new name
./restore-lxc.sh mycontainer_20241222_120000.tar.7z newname
```

## Script Details

### setup-lxc.sh

Configures the host system for unprivileged LXC containers:

- Installs and configures bridge-utils for br0 networking (optional)
- Configures veth interface permissions (`/etc/lxc/lxc-usernet`)
- Sets up subuid/subgid mappings (`/etc/subuid`, `/etc/subgid`)
- Enables kernel user namespace support
- Creates user's default LXC configuration (`~/.config/lxc/default.conf`)
- Sets up systemd user service for container auto-start
- Enables systemd lingering for the user

```bash
sudo ./setup-lxc.sh <username> [subuid_start]
```

### create-lxc.sh

Creates an LXC container with auto-detection of distribution, release, and architecture:

- Auto-detects host OS parameters if not specified
- Prompts before destroying existing containers
- Uses the sibling `start-lxc.sh` script to start the container
- When the container name contains `k8s`, prompts to apply Kubernetes settings (`--delegate --no-swap`)

```bash
./create-lxc.sh <container_name> [distribution] [release] [architecture]

# Examples:
./create-lxc.sh mycontainer                        # Auto-detect everything
./create-lxc.sh mycontainer debian bookworm arm64  # Explicit parameters
./create-lxc.sh tst-k8s1                           # Prompts for k8s settings
```

### start-lxc.sh

Starts containers using systemd user services:

- Uses `lxc-bg-start@.service` for proper lifecycle management
- Auto-attaches to the container when starting a single container
- Shows container status after starting multiple containers
- Supports cgroup delegation and swap restriction flags for Kubernetes containers
- Persistent settings are applied even if the container is already running (take effect on next restart)

```bash
./start-lxc.sh [options] <container_name> [...]
```

**Options:**

| Flag | Persists | Effect |
|------|----------|--------|
| `--delegate` | Yes | Creates systemd drop-in with `Delegate=cpuset cpu io memory pids` |
| `--delegate-once` | No | One-time cgroup delegation via `systemd-run` |
| `--no-swap` | Yes | Creates `MemorySwapMax=0` drop-in AND masks `/proc/swaps` in container config |
| `--no-swap-once` | No | One-time `MemorySwapMax=0` via `systemd-run` (does not mask `/proc/swaps`) |

Flags are combinable. For full Kubernetes support, use `--delegate --no-swap`:

```bash
# Full k8s setup (persist delegation + swap restriction + mask /proc/swaps)
./start-lxc.sh --delegate --no-swap tst-k8s1

# One-time swap restriction only (cgroup limit, no /proc/swaps mask)
./start-lxc.sh --no-swap-once tst-k8s1

# Apply settings to an already-running container (takes effect on next restart)
./start-lxc.sh --delegate --no-swap tst-k8s1
```

**What `--no-swap` does:**

1. **Cgroup enforcement**: Creates a systemd drop-in (`MemorySwapMax=0`) so the container cannot use swap (cgroup v2)
2. **Visibility masking**: Adds `lxc.mount.entry = /dev/null proc/swaps none bind,optional 0 0` to the container's LXC config (best-effort — LXCFS may override this mount)

**Note:** On systems with LXCFS, the `/proc/swaps` bind mount is overridden by the LXCFS FUSE filesystem. The Kubernetes setup script (`initialize-cluster.sh`) handles this automatically by setting `failSwapOn: false` in the kubeadm config for container environments. The `--no-swap` flag remains valuable for cgroup-level swap restriction.

Containers with `k8s` in their name receive a warning if delegation or swap restriction is missing.

### stop-lxc.sh

Stops containers gracefully:

- Uses `lxc-stop` for graceful shutdown
- Stops associated systemd user service
- Stops all running containers if no arguments provided

```bash
./stop-lxc.sh [container_name] [[container_name], ...]
```

### backup-lxc.sh

Creates compressed backups of containers:

- Preserves all permissions and ownership with `tar --numeric-owner`
- Uses 7z LZMA2 compression with three presets
- Stops running containers before backup (with confirmation)
- Supports both unprivileged and privileged containers

```bash
./backup-lxc.sh <container_name> [backup_dir] [--privileged] [--compression=level]
```

**Compression Presets:**
| Preset | Speed | Size | Options |
|--------|-------|------|---------|
| `fast` | Quick | Larger | `-mx=3 -md=128m` |
| `balanced` | Moderate | Medium | `-mx=5 -md=512m` |
| `small` | Slow | Smallest | `-mx=9 -md=1536m` |

### restore-lxc.sh

Restores containers from backup archives:

- Detects original container name from archive
- Supports renaming during restore
- Updates config file paths when renaming
- Offers to edit config before starting

```bash
./restore-lxc.sh <backup_file> [container_name] [--privileged]
```

### config-lxc-ssh.sh

Configures SSH key-based authentication for containers:

- Generates a shared SSH key pair for LXC access
- Deploys public key to all containers
- Configures `~/.ssh/config` for easy access
- Works with stopped containers (direct rootfs access)

```bash
sudo ./config-lxc-ssh.sh <username>
```

After configuration, connect to containers with:
```bash
ssh <container-hostname>
# or
ssh -i ~/.ssh/id_local-lxc-access.key user@<container-ip>
```

### _download-lxc-scripts.sh

Self-updating script manager:

- Downloads latest versions from the repository
- Shows diffs before updating
- Cleans up obsolete/renamed scripts
- Requires curl or wget

```bash
./_download-lxc-scripts.sh
```

## Architecture

### Container Paths

| Container Type | Path |
|---------------|------|
| Unprivileged | `~/.local/share/lxc/<container>/` |
| Privileged | `/var/lib/lxc/<container>/` |

### Systemd Integration

Containers are managed via systemd user services:

```bash
# Service template location
~/.config/systemd/user/lxc-bg-start@.service

# Enable auto-start for a container
systemctl --user enable lxc-bg-start@mycontainer.service

# Manual service control
systemctl --user start lxc-bg-start@mycontainer.service
systemctl --user stop lxc-bg-start@mycontainer.service
systemctl --user status lxc-bg-start@mycontainer.service
```

### Network Modes

| Bridge | Mode | Description |
|--------|------|-------------|
| `br0` | Direct | Containers on same network as host |
| `lxcbr0` | NAT | Isolated network, NAT'd to host |

## Additional Documentation

The `README/` subdirectory contains additional guides:

- **bridge-net.md** - Setting up host bridge networking
- **gpu-passthru.md** - NVIDIA GPU passthrough configuration

## Dependencies

- **LXC** - Container runtime
- **systemd** - Service management
- **7zip** - Backup compression (backup/restore scripts)
- **bridge-utils** - Network bridging (optional, for br0)
- **curl** or **wget** - Script updates

## Exit Codes

Scripts use standard sysexits.h codes:

| Code | Name | Description |
|------|------|-------------|
| 0 | EX_OK | Success |
| 64 | EX_USAGE | Command line usage error |
| 65 | EX_DATAERR | Data format error |
| 66 | EX_NOINPUT | Input file not found |
| 67 | EX_NOUSER | User does not exist |
| 69 | EX_UNAVAILABLE | Required tool not available |
| 74 | EX_IOERR | I/O error |
| 75 | EX_TEMPFAIL | Temporary failure (user cancelled) |
