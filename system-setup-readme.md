# System Setup Script

`system-setup.sh` - Comprehensive bash script for automated package management and system configuration across Linux and macOS platforms.

## Features

- **Self-updating**: Automatically checks for and applies updates from GitHub repository
- **Cross-platform**: Detects and configures Linux (apt-based) and macOS (Homebrew)
- **Idempotent**: Safe to run multiple times - only changes what needs updating
- **Interactive**: User prompts for package installation, configuration scope, and optional features
- **Safe**: Backs up files before modification, preserves correct settings
- **Container-aware**: Detects LXC, Docker, and other containers; offers static IP configuration
- **Flexible**: User-specific or system-wide installation options

## Usage

```bash
./system-setup.sh
```

## What It Does

### 1. Self-Update Check
- Automatically fetches latest version from GitHub
- Shows diff and prompts before updating
- Continues with local version if update declined or unavailable
- Requires curl or wget

### 2. Container Detection
- Detects LXC, Docker, and systemd containers
- Offers static IP configuration for containers (secondary IP with DHCP retained)
- Uses systemd-networkd for persistent configuration
- Skips swap configuration in containers

### 3. Package Management
Checks for and optionally installs packages:

**macOS (Homebrew):**
- 7-zip, ca-certificates, Git, htop, Nano Editor, Ollama, Screen (GNU)

**Linux (apt):**
- 7-zip, aptitude, ca-certificates, cURL, Git, htop, Nano Editor, OpenSSH Server, Screen (GNU)

### 4. Configuration Scope Selection
**User-specific (Option 1):**
- Configures nano, screen, and shell for current user only

**System-wide (Option 2):**
- nano/screen: System-wide configuration (`/etc/`)
- /etc/issue: Network interface display (Linux only)
- Shell: Configures root and all users in `/home/`
- Swap: Configures swap memory (Linux only, skips in containers)
- SSH: Optional socket-based activation (Linux only)

### 5. Component Configuration

#### nano Editor
- **Settings**: atblanks, autoindent, constantshow, indicator, linenumbers, minibar, mouse, multibuffer, nonewlines, smarthome, softwrap, tabsize 4
- **macOS**: Includes Homebrew syntax definitions path (`/opt/homebrew/share/nano/*.nanorc`)
- **Files**: `~/.nanorc` (user) or `/etc/nanorc` (system)

#### GNU Screen
- **Settings**: startup_message off, defscrollback 9999, scrollback 9999, defmousetrack on, mousetrack on
- **Files**: `~/.screenrc` (user) or `/etc/screenrc` (system)

#### /etc/issue Network Display (System scope, Linux only)
- **Auto-detection**: Identifies all network interfaces (excluding loopback)
- **Interface types**: wire (ethernet), wifi (wireless), bridge, vpn, veth, docker
- **Display format**: `<type>: \4{<interface>} / \6{<interface>} (<interface>)` for dynamic IPv4/IPv6
- **Idempotent**: Updates interface list if devices are added, removed, or changed
- **Container awareness**: Warns but still allows configuration in containers
- **Example output**:
  ```
  ╔═══════════════════════════════════════════════════════════════════════════
  ║ Network Interfaces
  ╠═══════════════════════════════════════════════════════════════════════════
  ║ - wire: \4{eth0} / \6{eth0} (eth0)
  ║ - wifi: \4{wlan0} / \6{wlan0} (wlan0)
  ╚═══════════════════════════════════════════════════════════════════════════
  ```

#### Shell Aliases
- **Safety**: Interactive/verbose cp, mv, rm, chmod, chown, mkdir
- **Utilities**: Enhanced ls (color, formatting), lsblk, lxc-ls
- **Compression**: 7z ultra compression aliases (3 levels: 256m, 512m, 1536m dictionary)
- **Platform-specific**:
  - Linux: GNU coreutils options, `.bashrc`, `7z` command
  - macOS: BSD options, CLICOLOR export, `.zshrc`, `7zz` command
- **Files**: Current user's shell config (user) or root + all users in `/home/` (system)

**Alias Details:**
- `cp='cp -aiv'` - copy with archive mode, interactive, verbose
- `mkdir='mkdir -v'` - verbose mkdir
- `mv='mv -iv'` - interactive move, verbose
- `rm='rm -Iv'` - interactive remove (threshold before prompt), verbose
- `chmod='chmod -vv'` - very verbose chmod
- `chown='chown -vv'` - very verbose chown
- `ls='ls --color=auto --group-directories-first -AFHhl'` (Linux) or `ls='ls -AFGHhl'` (macOS)
- `lsblk='lsblk -o "NAME,FSTYPE,FSVER,LABEL,FSAVAIL,SIZE,FSUSE%,MOUNTPOINTS,UUID"'`
- `lxc-ls='lxc-ls -f'`
- `7z-ultra1`, `7z-ultra2`, `7z-ultra3` - LZMA2 compression with increasing dictionary sizes

#### Swap Memory (System scope, Linux only)
- **Auto-sizing**: ≤2GB RAM = 2x RAM, >2GB RAM = 1.5x RAM
- **Location**: `/var/swapfile`
- **Features**: Persistent across reboots via `/etc/fstab`
- **Container-aware**: Automatically skips in containers (no prompt)

#### OpenSSH Server (System scope, Linux only)
- **Socket-based activation**: Starts SSH daemon on-demand via systemd socket (saves resources)
- **Configuration**: Opens systemd override editor (`systemctl edit ssh.socket`) for customization
- **Conflict resolution**: Automatically disables ssh.service if both ssh.socket and ssh.service are enabled
- **States handled**:
  - ssh.socket enabled + ssh.service enabled → Disables ssh.service automatically
  - ssh.socket enabled only → No action needed
  - ssh.socket disabled → Prompts to configure and enable

#### Container Static IP (Containers only, prompted at startup)
- **Offered**: Only when running inside a container
- **Method**: systemd-networkd configuration with secondary static IP
- **DHCP**: Primary IP remains DHCP-based
- **CIDR notation**: User provides IP/prefix (defaults to /24)
- **File**: `/etc/systemd/network/10-<interface>.network`
- **Auto-restart**: Restarts systemd-networkd to apply changes

## Idempotent Behavior

The script intelligently detects existing configurations:
- ✅ **Correct settings**: Left unchanged
- ➕ **Missing settings**: Added
- ⚙️ **Incorrect settings**: Updated (old values commented with timestamp)
- 🔒 **No duplicates**: Safe to run repeatedly

Example output:
```
[SUCCESS] ✓ softwrap setting already configured correctly
[   INFO] + Adding linenumbers setting to ~/.nanorc
[   INFO] ✗ tabsize setting has different value: '8' (expected: '4')
[WARNING] Updating tab size setting in ~/.nanorc
```

## Safety Features

- **Backups**: Timestamped backups created before any file modification (format: `file.backup.YYYYMMDD_HHMMSS`)
- **Change headers**: Managed sections clearly marked with timestamps and script name
- **Permissions**: Preserves file ownership and permissions (uses `chown` to restore)
- **Smart detection**: Recognizes and preserves existing correct configurations
- **Graceful skipping**: Skips configuration for packages not installed
- **Session tracking**: Tracks backed up files and header additions per script run to avoid duplicates

## Requirements

- **bash**: 4.0+ (uses `set -euo pipefail`)
- **Package manager**: Homebrew (macOS) or apt (Linux)
- **Permissions**: Write access to target directories (root for system-wide)
- **Optional**: curl or wget (for self-update feature)

## Configuration Sources

The script implements configurations specified in:
- `configs/nano.md` - nano editor settings
- `configs/screen-gnu.md` - GNU screen configuration
- `configs/shell.md` - shell aliases and enhancements

## Platform Notes

### macOS
- Uses zsh as default shell (`.zshrc`)
- Homebrew-based package management
- BSD command variants for ls and other tools
- 7-zip uses `7zz` command
- macOS stat syntax for file ownership

### Linux
- Uses bash as default shell (`.bashrc`)
- apt package manager (Debian/Ubuntu-based systems)
- GNU coreutils with extended options
- Systemd-based SSH socket configuration
- Container detection via `/proc/1/environ`, `/.dockerenv`, `/run/systemd/container`, `/proc/1/cgroup`
- Linux stat syntax for file ownership

## Output Colors

- **BLUE**: Informational messages
- **GREEN**: Success messages
- **YELLOW**: Warning messages
- **RED**: Error messages
- **GRAY**: Backup operation messages
- **CYAN**: Lines/borders
- **WHITE**: Code blocks

## Exit Codes

- `0`: Success
- `1`: Error occurred (package manager missing, unknown OS, configuration failure)
