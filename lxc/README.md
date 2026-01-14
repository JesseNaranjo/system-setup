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

```bash
./create-lxc.sh <container_name> [distribution] [release] [architecture]

# Examples:
./create-lxc.sh mycontainer                        # Auto-detect everything
./create-lxc.sh mycontainer debian bookworm arm64  # Explicit parameters
```

### start-lxc.sh

Starts containers using systemd user services:

- Uses `lxc-bg-start@.service` for proper lifecycle management
- Auto-attaches to the container when starting a single container
- Shows container status after starting multiple containers

```bash
./start-lxc.sh <container_name> [[container_name], ...]
```

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
