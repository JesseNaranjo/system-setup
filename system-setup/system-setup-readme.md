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

## Workflow

### 1. Self-Update Check
- Automatically fetches latest version from GitHub using curl or wget
- Displays full script content and diff before updating
- Prompts for confirmation before overwriting and restarting
- Continues with local version if update declined or unavailable
- Shows large warning box if neither curl nor wget is available

### 2. Container Detection & Static IP Configuration
- Detects LXC (via `/proc/1/environ`), Docker (via `/.dockerenv`), systemd containers (via `/run/systemd/container`), and cgroup-based detection
- **Container Static IP** (prompted at startup if container detected):
  - Adds secondary static IP while retaining DHCP for primary IP
  - Uses systemd-networkd configuration (`/etc/systemd/network/10-<interface>.network`)
  - CIDR notation input (defaults to /24 if not specified)
  - Validates IP octets (0-255) and prefix (1-32)
  - Automatically restarts systemd-networkd to apply changes
- Automatically skips swap configuration in containers (no prompt, silent)

### 3. APT Sources Modernization (Linux only)
- Runs `apt modernize-sources` to convert old sources.list to DEB822 format
- Removes `/etc/apt/sources.list.bak` if present
- Detects Debian release from `/etc/apt/sources.list.d/debian.sources`
- Updates main release stanza in `/etc/apt/sources.list.d/debian.sources`:
  - Adds `-updates` and `-backports` to Suites line
  - Adds `non-free` and `non-free-firmware` to Components line
  - Removes standalone `-updates` and `-backports` stanzas (merged into main)
- Ensures all stanzas (main, security) have `non-free` and `non-free-firmware` components
- Idempotent: only modifies if changes needed
- Offers optional manual editing with nano after automated changes

### 4. Package Management
Checks for and optionally installs packages individually with user confirmation:

**macOS (Homebrew):**
- 7-zip (sevenzip), ca-certificates, Git, htop, Nano Editor, Ollama, Screen (GNU)
- Shows dependencies before installation with formatted column output

**Linux (apt):**
- 7-zip (7zip), aptitude, ca-certificates, cURL, Git, htop, Nano Editor, OpenSSH Server, Screen (GNU)
- apt automatically displays packages and dependencies during installation

### 5. Configuration Scope Selection
**User-specific (Option 1):**
- Configures nano, screen, and shell for current user only

**System-wide (Option 2):**
- nano/screen: System-wide configuration (`/etc/nanorc`, `/etc/screenrc`)
- /etc/issue: Network interface display (Linux only)
- Shell: Configures root and all users in `/home/`
- Shell Prompt: Custom colored PS1 in system config with user config PS1 commenting
- Swap: Configures swap memory (Linux only, automatically skipped in containers)
- SSH: Optional socket-based activation (Linux only)

## Component Configuration

### nano Editor
- **Settings**: atblanks, autoindent, constantshow, indicator, linenumbers, minibar, mouse, multibuffer, nonewlines, smarthome, softwrap, tabsize 4
- **macOS**: Includes Homebrew syntax definitions path (`/opt/homebrew/share/nano/*.nanorc`)
- **Files**: `~/.nanorc` (user) or `/etc/nanorc` (system)

### GNU Screen
- **Settings**: startup_message off, defscrollback 9999, scrollback 9999, defmousetrack on, mousetrack on
- **Files**: `~/.screenrc` (user) or `/etc/screenrc` (system)

### /etc/issue Network Display (System scope, Linux only)
- Auto-detects network interfaces (excluding loopback, veth, docker)
- Interface types: wire (ethernet), wifi (wireless), bridge, vpn, docker
- Display format: `<type>: \4{<interface>} / \6{<interface>} (<interface>)` for dynamic IPv4/IPv6
- Idempotent: updates only if interface list changes
- Replaces existing box at same location or appends on initial setup
- Example output:
  ```
  ╔═══════════════════════════════════════════════════════════════════════════
  ║ Network Interfaces
  ╠═══════════════════════════════════════════════════════════════════════════
  ║ - wire: \4{eth0} / \6{eth0} (eth0)
  ║ - wifi: \4{wlan0} / \6{wlan0} (wlan0)
  ╚═══════════════════════════════════════════════════════════════════════════
  ```

### Shell Aliases
**Safety Aliases:**
- `cp='cp -aiv'` - copy with archive mode, interactive, verbose
- `mkdir='mkdir -v'` - verbose mkdir
- `mv='mv -iv'` - interactive move, verbose
- `rm='rm -Iv'` - interactive remove, verbose
- `chmod='chmod -vv'` - very verbose chmod
- `chown='chown -vv'` - very verbose chown

**Utility Aliases:**
- `ls='ls --color=auto --group-directories-first -AFHhl'` (Linux)
- `ls='ls -AFGHhl'` (macOS with `CLICOLOR=YES` export)
- `diff='diff --color'` - colored diff output
- `lsblk='lsblk -o "NAME,FSTYPE,FSVER,LABEL,FSAVAIL,SIZE,FSUSE%,MOUNTPOINTS,UUID"'` - enhanced lsblk
- `lxc-ls='lxc-ls -f'` - formatted lxc list
- `screen='screen -T $TERM'` - screen with proper terminal type (only if screen is installed)

**Compression Aliases:**
- `7z-ultra1` - LZMA2 256m dictionary
- `7z-ultra2` - LZMA2 512m dictionary
- `7z-ultra3` - LZMA2 1536m dictionary
- Linux uses `7z` command, macOS uses `7zz` command

**Files**: Current user's shell config (user) or root + all users in `/home/` (system)

### Shell Prompt Colors (System scope only)
**System-wide Configuration:**
- Linux (bash): Custom PS1 in `/etc/bash.bashrc`
  - Conditional: red username with `!!` for root, green for non-root
  - Format: `[gray-hostname:color-username] cyan-bold-path $ [!! if root]`
- macOS (zsh): Custom PS1 in `/etc/zshrc`
  - Format: `[gray-hostname:color-username] cyan-bold-path # [!! if root]`
- Handles existing PS1 definitions:
  - 0 definitions: Adds custom PS1 at end
  - 1 definition: Comments out existing, adds new immediately after
  - Multiple definitions: Comments out all, adds new at end, opens nano for manual review

**User Configuration Commenting:**
- Comments out PS1 definitions in root and all users in `/home/`
- Linux: Preserves terminal title escape sequences (`PS1="\[\e]0;`), comments out others
- macOS: Comments out all PS1 definitions
- Skips files/users with no uncommented PS1 definitions

### Swap Memory (System scope, Linux only)
- **Auto-sizing**: ≤2GB RAM = 2x RAM, >2GB RAM = 1.5x RAM
- **Location**: `/var/swapfile`
- **Persistent**: Adds entry to `/etc/fstab` for automatic activation on reboot
- **Container-aware**: Automatically skips in containers (no prompt, silent)

### OpenSSH Server (System scope, Linux only)
- **Socket-based activation**: Starts SSH daemon on-demand via systemd socket (saves resources)
- **Configuration**: Opens nano for `systemctl edit ssh.socket` customization
- **Conflict resolution**: Automatically disables ssh.service if both enabled (no prompt)
- **States handled**:
  - ssh.socket enabled + ssh.service enabled → Disables ssh.service automatically
  - ssh.socket enabled only → No action needed
  - ssh.socket disabled → Prompts to configure and enable

## Idempotent Behavior

The script intelligently detects existing configurations:
- ✅ **Correct settings**: Left unchanged
- ➕ **Missing settings**: Added
- ⚙️ **Incorrect settings**: Updated (old values commented with timestamp)
- 🔒 **No duplicates**: Safe to run repeatedly

Example output:
```
[SUCCESS] - softwrap setting already configured correctly
[   INFO] + Adding linenumbers setting to ~/.nanorc
[WARNING] ✖ tabsize setting has different value: 'set tabsize 8' in ~/.nanorc
[SUCCESS] ✓ tab size setting updated in ~/.nanorc
```

## Safety Features

- **Backups**: Timestamped backups created before any file modification (`file.backup.YYYYMMDD_HHMMSS`)
- **Change headers**: Managed sections marked with timestamps and script name
- **Permissions**: Preserves file ownership and permissions (uses `chown` to restore)
- **Smart detection**: Recognizes and preserves existing correct configurations
- **Session tracking**: Tracks backed up files and header additions per script run to avoid duplicates
- **Graceful skipping**: Skips configuration for packages not installed

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

## Platform Differences

### macOS
- Shell: zsh (`.zshrc`)
- Package manager: Homebrew
- Commands: BSD variants (`ls -AFGHhl`, `7zz`, `stat -f "%u:%g"`)
- System config: `/etc/zshrc`
- Export: `CLICOLOR=YES`

### Linux
- Shell: bash (`.bashrc`)
- Package manager: apt (Debian/Ubuntu)
- Commands: GNU coreutils (`ls --color`, `7z`, `stat -c "%u:%g"`)
- System config: `/etc/bash.bashrc`
- Features: systemd-networkd, SSH socket, swap, /etc/issue, container detection

## Output Colors

- **BLUE**: Informational messages
- **GREEN**: Success messages
- **YELLOW**: Warning messages
- **RED**: Error messages
- **GRAY**: Backup operation messages
- **MAGENTA**: Debug messages
- **CYAN**: Lines/borders
- **WHITE**: Code blocks

## Exit Codes

- `0`: Success
- `1`: Error (package manager missing, unknown OS, configuration failure)
