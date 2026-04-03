# System Setup

Automated system configuration and package management for Linux and macOS. This modular script suite provides idempotent, platform-aware setup of development environments with self-updating capabilities.

## Quick Start

```bash
cd system-setup
./system-setup.sh
```

The script will:
1. Auto-update all scripts from GitHub (if curl/wget available)
2. Detect your OS (Linux/macOS) and environment (container/host)
3. Offer to install required packages
4. Configure git, nano, tmux, and shell settings
5. Apply system-level configurations (swap, SSH, /etc/issue) if running with appropriate privileges

## Directory Structure

```
system-setup/
├── install-desktop.sh                         # TigerVNC + XRDP desktop setup
├── system-setup.sh                            # Main orchestrator
├── utils-sys.sh                               # Shared utilities and functions
└── system-modules/
    ├── configure-container-static-ip.sh       # Static IP for containers
    ├── migrate-to-systemd-networkd.sh         # ifupdown to systemd-networkd migration
    ├── modernize-apt-sources.sh               # APT DEB822 migration
    ├── package-management.sh                  # Package installation
    ├── system-configuration-git.sh            # Git configuration
    ├── system-configuration.sh                # Nano/tmux/shell setup
    ├── system-configuration-issue.sh          # /etc/issue network display
    ├── system-configuration-openssh-server.sh # SSH socket activation
    ├── system-configuration-swap.sh           # Swap memory setup
    └── system-configuration-timezone.sh       # Timezone configuration
```

---

## Core Scripts

### system-setup.sh

Main orchestrator that coordinates all configuration modules.

**Key Features:**
- **Self-Update**: Downloads and updates all scripts from GitHub repository
- **Auto-Detection**: Identifies OS (Linux/macOS) and container environments (LXC, Docker)
- **Interactive Prompts**: Asks for user vs system-wide configuration scope
- **Module Orchestration**: Runs configuration modules in dependency order
- **Session Tracking**: Records all file modifications and backups

**Execution Flow:**
1. Detect download tool (curl/wget) and check for script updates
2. Update `system-setup.sh` itself and restart if changed
3. Update all module scripts
4. Detect OS and container environment
5. Migrate network to systemd-networkd (if ifupdown present, Linux only)
6. Offer container static IP configuration (if in container)
7. Modernize APT sources (Linux only)
8. Check and install packages
9. Prompt for configuration scope (user vs system)
10. Configure git (if installed)
11. Run configuration modules (nano, tmux, shell)
12. Configure timezone (system scope only)
13. Configure swap (system scope, Linux only)
14. Configure OpenSSH socket (system scope, if installed)
15. Update /etc/issue (system scope, Linux only)
16. Display summary of changes

**Self-Update Process:**
- Fetches scripts from: `https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/system-setup`
- Shows unified diff for each changed file
- Prompts to accept or skip each update
- Validates downloaded files are valid bash scripts
- Restarts with updated version if main script changed

### utils-sys.sh

Shared utility library providing common functionality across all modules.

**Global Variables:**
- `DETECTED_OS`: "linux", "macos", or "unknown"
- `RUNNING_IN_CONTAINER`: Boolean for container detection
- `CURL_INSTALLED`, `FASTFETCH_INSTALLED`, `GIT_INSTALLED`, `NANO_INSTALLED`, `TMUX_INSTALLED`, `OPENSSH_SERVER_INSTALLED`: Package tracking
- `BACKED_UP_FILES[]`: List of files backed up in current session
- `CREATED_BACKUP_FILES[]`: List of backup files created
- `HEADER_ADDED_FILES[]`: Files that have received change headers
- `CREATED_CONFIG_FILES[]`: Config files created in current session
- `TEMP_FILES[]`: Tracked temp files for cleanup on exit

**Output Functions:**
- `print_info()`, `print_success()`, `print_warning()`, `print_error()`
- `print_backup()`, `print_debug()`
- Color-coded with consistent formatting

**OS & Environment Detection:**
- `detect_os()`: Identifies Linux vs macOS via `$OSTYPE`
- `detect_container()`: Checks for LXC, Docker, systemd containers
  - Inspects `/proc/1/environ`, `/.dockerenv`, `/run/systemd/container`, `/proc/1/cgroup`

**Privilege Management:**
- `check_privileges()`: Validates sufficient permissions for operations
- `run_elevated()`: Executes commands with sudo when needed (macOS)
- `needs_elevation()`: Determines if file operation requires elevated privileges

**Package Management:**
- `get_package_list()`: Returns OS-specific package definitions
- `is_package_installed()`: Checks if package exists (works with apt/Homebrew)
- `verify_package_manager()`: Ensures apt or Homebrew is available
- `get_removable_package_list()`: Returns OS-specific packages to remove
- `track_special_packages()`: Sets flags for curl, fastfetch, git, nano, tmux, openssh-server

**File Management:**
- `backup_file()`: Creates timestamped backups (once per session per file)
- `add_change_header()`: Adds managed-by comment block to config files
- `check_disk_space()`: Pre-flight validation of available disk space
- `make_temp_file()`: Creates tracked temp files cleaned up on exit
- Both backup/header functions track modifications to avoid duplicate operations

**Configuration Management:**
- `config_exists()`: Checks if config line exists in file
- `get_config_value()`: Extracts current value of setting
- `update_config_line()`: Adds or updates config with diff detection
- `add_config_if_needed()`: Wrapper for key-value settings
- `add_alias_if_needed()`: Wrapper for shell aliases
- `add_export_if_needed()`: Wrapper for environment variables
- `add_git_config_if_needed()`: Wrapper for git config settings (user/system scope)

**User Interaction:**
- `prompt_yes_no()`: Interactive confirmation with default values
  - Reads from `/dev/tty` to work in piped contexts

**Summary:**
- `print_session_summary()`: Displays all file modifications and backups at end of session

### install-desktop.sh

Installs and configures TigerVNC and XRDP for remote desktop access (Linux only).

**Not part of system-setup.sh orchestration** — this is a standalone script downloaded by system-setup.sh but run independently.

**Must be run as the target user** (not root). Uses sudo for operations requiring root privileges.

**Components:**
- **TigerVNC**: VNC server with XFCE4 desktop, clipboard support via vncconfig, proper session management via dbus-launch
- **XRDP**: RDP server with TLS encryption, XFCE4 desktop session

**Features:**
- Idempotent — safe to run multiple times
- Prompts before installing each component (skips prompt if already installed)
- Checks configuration files and updates only if needed
- TLS certificate management with 30-day expiry check and renewal prompt
- Optional cleanup of unnecessary packages (default: yes)

**Usage:**
```bash
./install-desktop.sh
```

**Packages Installed:**
- TigerVNC: `tigervnc-standalone-server`, `xfce4`, `xfce4-terminal`, `dbus-x11`
- XRDP: `xrdp`, `xorgxrdp`, `xfce4`, `xfce4-terminal`, `dbus-x11`

**Packages Optionally Removed:**
- `dosfstools`, `eject`, `exfatprogs`, `gnome-accessibility-themes`, `gnome-themes-extra`, `gnome-themes-extra-data`, `gnupg-utils`, `ipp-usb`, `libgpg-error-l10n`, `libgphoto2-l10n`, `sane-airscan`, `sane-utils`, `usbmuxd`, `xserver-xorg-legacy`

**Configuration Files Managed:**
- `~/.config/tigervnc/config` — VNC server settings (session, geometry via resolution prompt, security)
- `~/.vnc/xstartup` — VNC session startup script (XFCE with clipboard support)
- `~/.vnc/passwd` — VNC password (set interactively on first run)
- `~/.xsession` — XRDP per-user session preference
- `/etc/tigervnc/vncserver.users` — VNC user-to-display mapping
- `/etc/xrdp/startwm.sh` — XRDP window manager startup (modified for XFCE)
- `/etc/xrdp/xrdp.ini` — XRDP TLS configuration
- `/etc/xrdp/certs/` — TLS certificate and private key

**Services Managed:**
- `tigervncserver@:1.service`
- `xrdp`

---

## Module Scripts

### system-modules/migrate-to-systemd-networkd.sh

Migrates Linux systems from ifupdown to systemd-networkd (Linux only).

**Functionality:**
- Parses `/etc/network/interfaces` using `ifquery` for reliable extraction
- Generates systemd-networkd `.network` files for each interface
- Creates `.netdev` files for bridge configurations
- Handles DHCP, static IPs, and bridges with best-effort migration
- Appends original interface stanza as comments for reference
- Manages service transitions (networking → systemd-networkd)
- Configures systemd-resolved for DNS management
- Provides detailed rollback instructions

**Supported Configurations:**
- DHCP interfaces
- Static IP addresses with gateway and DNS
- Bridge interfaces with member ports
- Loopback interfaces (preserved)

**Unsupported Configurations (warnings displayed):**
- VLANs (`vlan-raw-device`)
- Bonding (`bond-master`, `bond-slaves`, `bond-mode`)
- Pre/post hooks (`pre-up`, `post-up`, `pre-down`, `post-down`)
- Wireless (`wpa-ssid`, `wpa-psk`, `wpa-conf`)
- PPP connections
- MTU and hardware address overrides

**Generated Files:**
```
/etc/systemd/network/
├── 10-eth0.network     # Standard interfaces
├── 20-br0.netdev       # Bridge device definition
└── 20-br0.network      # Bridge network config
```

**Process:**
1. Checks for ifupdown presence and non-loopback interfaces
2. Validates systemd-networkd availability
3. Detects unsupported configurations and warns
4. Parses each interface stanza with `ifquery`
5. Generates systemd-networkd configuration files
6. Optionally symlinks `/etc/resolv.conf` to systemd-resolved
7. Disables networking.service, enables systemd-networkd
8. Displays rollback instructions

**Requirements:**
- Linux with ifupdown currently in use
- systemd-networkd available
- Root privileges
- `ifquery` command (from ifupdown package)

### system-modules/modernize-apt-sources.sh

Modernizes APT package sources to DEB822 format (Debian/Ubuntu).

**Functionality:**
- Runs `apt modernize-sources` to convert old `sources.list` to DEB822
- Removes backup file `/etc/apt/sources.list.bak`
- Detects Debian release from `/etc/apt/sources.list.d/debian.sources`
- Consolidates `-updates` and `-backports` into main release stanza
- Ensures `non-free` and `non-free-firmware` components are enabled
- Preserves security sources separately

**AWK Processing:**
- Parses DEB822 stanzas (blank-line separated records)
- Modifies `Suites:` line to include `bookworm bookworm-updates bookworm-backports`
- Adds or updates `Components:` to include `main contrib non-free non-free-firmware`
- Removes standalone `-updates` and `-backports` stanzas

**Requirements:**
- Linux with APT package manager
- Root privileges
- Debian/Ubuntu with APT 2.x+ (DEB822 support)

**Example Output:**
```
[INFO] Modernizing APT sources configuration...
[SUCCESS] ✓ Removed /etc/apt/sources.list.bak
[INFO] Detected Debian release: bookworm
[SUCCESS] ✓ APT sources file modernized successfully.
```

### system-modules/package-management.sh

Checks for and installs required packages.

**Package Definitions:**

> **Source of truth:** These lists mirror `get_package_list()` in `utils-sys.sh`. Update both when adding or removing packages.

**Linux (apt):**
- 7-zip → `7zip`
- aptitude → `aptitude`
- ca-certificates → `ca-certificates`
- cURL → `curl`
- Fastfetch → `fastfetch`
- Git → `git`
- Git LFS → `git-lfs`
- gpm → `gpm`
- htop → `htop`
- jq (JSON data processor) → `jq`
- Nano Editor → `nano`
- OpenSSH Server → `openssh-server`
- ShellCheck → `shellcheck`
- sudo → `sudo`
- tmux (terminal multiplexer) → `tmux`
- UDisks → `udisks2`

**macOS (Homebrew):**
- 7-zip → `sevenzip`
- AWK → `awk`
- Apple Containers → `container`
- Bash → `bash`
- CA Certificates → `ca-certificates`
- cURL → `curl`
- Fastfetch → `fastfetch`
- Git → `git`
- Git LFS → `git-lfs`
- htop → `htop`
- Monocle → `monocle-app`
- Nano Editor → `nano`
- Ollama → `ollama`
- OrbStack → `orbstack`
- ShellCheck → `shellcheck`
- tmux (terminal multiplexer) → `tmux`
- UTM → `utm`

**Functionality:**
- Checks each package individually with interactive prompts
- On Linux: Uses `dpkg -l` to check installation
- On macOS: Uses `brew list` to check installation
- Displays dependency tree before installation (macOS only)
- Prompts for confirmation before installing
- Tracks special packages (nano, tmux, openssh-server) for later configuration
- Continues with partial success (doesn't abort on installation failure)

**Installation Process:**
```bash
# Linux
apt update && apt install <packages>

# macOS
brew install <packages>
```

### system-modules/system-configuration-git.sh

Configures git with sensible defaults using `git config` commands.

**Parameters:**
- `user`: Configure current user only (`~/.gitconfig`)
- `system`: Configure system-wide (`/etc/gitconfig` or `/opt/homebrew/etc/gitconfig`)

**Settings Applied:**
```bash
init.defaultBranch = development
fetch.prune = true
branch.sort = -committerdate
push.autoSetupRemote = true
column.ui = auto
tag.sort = -version:refname
diff.colorMoved = zebra
diff.algorithm = histogram
merge.conflictstyle = diff3
help.autocorrect = prompt
```

**Conditional Settings:**
- `core.editor = nano` (only if nano is installed)
- Git LFS initialization (only if git-lfs is installed)

**Architecture:**
- Uses `git config` commands directly (not file editing) for correct INI format handling
- Data-driven settings array for DRY iteration
- Backs up gitconfig file before modifications
- Idempotent: skips settings already at desired value

### system-modules/system-configuration.sh

Configures nano editor, tmux, and shell settings.

**Parameters:**
- `user`: Configure current user only (`~/.nanorc`, `~/.tmux.conf`, `~/.bashrc` or `~/.zshrc`)
- `system`: Configure system-wide (all users in `/home/` plus root)

#### Nano Configuration

**Settings Applied:**
```bash
set atblanks
set autoindent
set constantshow
set indicator
set linenumbers
set minibar
set mouse
set multibuffer
set nonewlines
set smarthome
set softwrap
set tabsize 4
```

**macOS-Specific:**
- Adds syntax highlighting include: `include "/opt/homebrew/share/nano/*.nanorc"`
- Creates config at `/opt/homebrew/etc/nanorc` (system) or `~/.nanorc` (user)

**Linux:**
- Creates config at `/etc/nanorc` (system) or `~/.nanorc` (user)

#### tmux Configuration

**Settings Applied:**
```bash
set -g base-index 1
set -g pane-base-index 1
set -g default-terminal "tmux-256color"

set -g history-limit 50000
set -g mouse on

set -g window-style 'bg=color235'
set -g window-active-style 'bg=color233'

set -g pane-border-lines double

set -g prefix C-a
unbind C-b

bind | split-window -hc "#{pane_current_path}"
bind \\ split-window -hc "#{pane_current_path}"
unbind %
bind - split-window -vc "#{pane_current_path}"
bind _ split-window -vc "#{pane_current_path}"
unbind \"
```

**Config Locations:**
- System (Linux): `/etc/tmux.conf`
- System (macOS): `/opt/homebrew/etc/tmux.conf`
- User: `~/.tmux.conf`

#### Shell Configuration

**Safety Aliases:**
```bash
alias cp='cp -aiv'
alias mkdir='mkdir -v'
alias mv='mv -iv'
alias rm='rm -Iv'
alias chmod='chmod -vv'
alias chown='chown -vv'
```

**Platform-Specific ls:**

**macOS (zsh):**
```bash
export CLICOLOR=YES
alias ls='ls -AFGHhl'
```

**Linux (bash):**
```bash
alias ls='ls --color=auto --group-directories-first -AFHhl'
```

**Utility Aliases:**
```bash
alias diff='diff --color'
alias lsblk='lsblk -o "NAME,FSTYPE,FSVER,LABEL,FSAVAIL,SIZE,FSUSE%,MOUNTPOINTS,UUID"'
alias lxc-ls='lxc-ls -f'
```

**7-Zip Compression Helpers:**
```bash
# macOS uses 7zz, Linux uses 7z
alias 7z-ultra1='7z(z) a -t7z -m0=lzma2 -mx=9 -md=256m -mfb=273 -mmf=bt4 -ms=on -mmt'
alias 7z-ultra2='7z(z) a -t7z -m0=lzma2 -mx=9 -md=512m -mfb=273 -mmf=bt4 -ms=on -mmt'
alias 7z-ultra3='7z(z) a -t7z -m0=lzma2 -mx=9 -md=1536m -mfb=273 -mmf=bt4 -ms=on -mmt'
```

**Editor Environment Variables** (only if nano is installed):
- `EDITOR=nano` — default editor
- `KUBE_EDITOR=nano` — kubernetes editor (only if `kubectl` is available)
- `SUDO_EDITOR=nano` — sudo editor
- `SYSTEMD_EDITOR=nano` — systemd editor (only if `systemctl` is available)
- `VISUAL=nano` — visual editor

#### Prompt Configuration (System Scope)

**macOS (zsh):**
```zsh
PS1="[%F{247}%m%f:%F{%(!.red.green)}%n%f] %B%F{cyan}%~%f%b %#%(!.%F{red}%B!!%b%f.) "
```
- Gray hostname, red/green username (root/non-root), cyan directory, `!!` for root

**Linux (bash):**
```bash
# Root user - red username with !! warning
PS1="${debian_chroot:+($debian_chroot)}[\[\e[90m\]\h\[\e[0m\]:\[\e[91m\]\u\[\e[0m\]] \[\e[96;1m\]\w\[\e[0m\] \$\[\e[91;1m\]!!\[\e[0m\] "

# Non-root user - green username
PS1="${debian_chroot:+($debian_chroot)}[\[\e[90m\]\h\[\e[0m\]:\[\e[92m\]\u\[\e[0m\]] \[\e[96;1m\]\w\[\e[0m\] \$ "
```

**System Scope Behavior:**
- Comments out existing PS1 definitions in user dotfiles (except terminal title sequences on Linux)
- Adds conditional PS1 to system-wide config (`/etc/bash.bashrc` or `/etc/zshrc`)
- If multiple PS1 definitions found in system config, opens nano for manual review

**User Scope Behavior:**
- Only configures current user's dotfile
- Does not modify system-wide configs
- Does not alter PS1 (preserves user's prompt)

### system-modules/system-configuration-swap.sh

Creates and enables swap memory (Linux only, system scope).

**Functionality:**
- Checks if swap already enabled with `swapon --show`
- Skips if running in container environment
- Calculates swap size based on RAM:
  - ≤2 GB RAM: 2x RAM
  - \>2 GB RAM: 1.5x RAM
- Creates swap file at `/var/swapfile`
- Sets permissions to `600`
- Formats with `mkswap`
- Enables with `swapon`
- Adds entry to `/etc/fstab` for persistence

**Process:**
```bash
dd if=/dev/zero of=/var/swapfile bs=1M count=<size_mb>
chmod 600 /var/swapfile
mkswap /var/swapfile
swapon /var/swapfile
echo "/var/swapfile none swap sw 0 0" >> /etc/fstab
```

**Requirements:**
- Linux with systemd
- Not in container
- Root privileges

### system-modules/system-configuration-timezone.sh

Configures system timezone interactively.

**Functionality:**
- Detects current system timezone
- Only prompts if timezone is set to UTC (common default for fresh installs)
- Offers common US timezone presets for quick selection
- Supports custom timezone input via "Other" option
- Works on both Linux (timedatectl) and macOS (systemsetup)

**Timezone Options:**
1. Eastern (America/New_York)
2. Central (America/Chicago)
3. Mountain (America/Denver)
4. Pacific (America/Los_Angeles)
5. Other (displays all available timezones)

**Platform Support:**

**Linux:**
- Uses `timedatectl` to get/set timezone
- Lists timezones via `timedatectl list-timezones`

**macOS:**
- Reads timezone from `/etc/localtime` symlink
- Uses `systemsetup` for setting timezone (requires admin)
- Lists timezones via `systemsetup -listtimezones`

**Example Output:**
```
[ INFO    ] Checking timezone configuration...
[ WARNING ] System timezone is set to UTC: Etc/UTC

Would you like to update the timezone? (y/N):
[ INFO    ] Select a timezone:
            1) Eastern  (America/New_York)
            2) Central  (America/Chicago)
            3) Mountain (America/Denver)
            4) Pacific  (America/Los_Angeles)
            5) Other    (show all timezones)

            Enter choice (1-5): 1

[ INFO    ] Setting timezone to: America/New_York
[ SUCCESS ] ✓ Timezone updated to: America/New_York
```

**Requirements:**
- Linux with timedatectl or macOS with systemsetup
- Root/admin privileges for setting timezone

### system-modules/configure-container-static-ip.sh

Configures static IP addresses for containers using systemd-networkd.

**Functionality:**
- Detects primary network interface (excludes lo, docker, veth, br-)
- Shows current IP addresses on interface
- Checks for existing static IP configuration in `/etc/systemd/network/`
- Prompts for static IP in CIDR notation (defaults to /24)
- Validates IP address format and CIDR prefix
- Creates systemd-networkd configuration with DHCP + static IP
- Restarts systemd-networkd to apply changes

**Configuration File Format:**
```ini
# /etc/systemd/network/10-eth0.network
[Match]
Name=eth0

[Network]
DHCP=yes

[Address]
Address=192.168.1.100/24
```

**Features:**
- Maintains DHCP for primary IP (adds static as secondary)
- Works with LXC, Docker, and other containerized environments
- Validates IP octets (0-255) and CIDR prefix (1-32)

**Requirements:**
- Linux container environment
- systemd-networkd available
- Root privileges

### system-modules/system-configuration-openssh-server.sh

Configures OpenSSH to use socket-based activation (Linux only, system scope).

**Functionality:**
- Detects current state of `ssh.service` and `ssh.socket`
- Three configuration scenarios:

**Scenario 1: Both enabled (conflict)**
- Automatically disables `ssh.service`
- Keeps `ssh.socket` enabled

**Scenario 2: Socket already enabled**
- No action needed

**Scenario 3: Socket not enabled**
- Prompts user to configure socket-based activation
- Disables `ssh.service` if currently enabled
- Opens `systemctl edit ssh.socket` for customization
- Enables and starts `ssh.socket`

**Benefits of Socket Activation:**
- Saves system resources (SSH daemon starts on-demand)
- Daemon only runs when connections arrive
- Faster boot times

**Editor Prompt:**
- Opens nano via `systemctl edit ssh.socket`
- Allows customization (e.g., changing port, adding ListenStream)
- Creates override file in `/etc/systemd/system/ssh.socket.d/`

**Requirements:**
- Linux with systemd
- openssh-server installed
- Root privileges

### system-modules/system-configuration-issue.sh

Updates `/etc/issue` with network interface information (Linux only, system scope).

**Functionality:**
- Detects all network interfaces and categorizes by type
- Skips loopback, veth, docker, and bridge interfaces
- Generates formatted box with interface listings
- Updates `/etc/issue` with current interfaces
- Only updates if interface list changes

**Interface Detection:**
- **Wire**: Physical ethernet (default for unknown types)
- **WiFi**: Detected via `/sys/class/net/*/wireless` or `/sys/class/net/*/phy80211`
- **Bridge**: Detected via `/sys/class/net/*/bridge`
- **VPN**: Detected via `/sys/class/net/*/tun_flags`
- **Docker**: Interfaces matching `docker*` or `br-*`
- **Veth**: Virtual ethernet pairs (skipped)

**Output Format:**
```
╔═══════════════════════════════════════════════════════════════════════════
║ Network Interfaces
╠═══════════════════════════════════════════════════════════════════════════
║ - wire: \4{eth0} / \6{eth0} (eth0)
║ - wifi: \4{wlan0} / \6{wlan0} (wlan0)
╚═══════════════════════════════════════════════════════════════════════════
```

**Escape Sequences:**
- `\4{iface}`: IPv4 address of interface
- `\6{iface}`: IPv6 address of interface

**Features:**
- Compares current interfaces with previously configured ones
- Only updates if changes detected
- Preserves existing `/etc/issue` content
- Uses AWK to replace existing network interface block

**Requirements:**
- Linux (non-container)
- Root privileges

---

## Configuration Scopes

### User Scope

**Target:** Current user only

**Modifications:**
- `~/.gitconfig`
- `~/.nanorc`
- `~/.tmux.conf`
- `~/.bashrc` (Linux) or `~/.zshrc` (macOS)

**Behavior:**
- No root privileges required
- Does not modify system files
- Does not alter prompt colors
- Preserves user's PS1 configuration

### System Scope

**Target:** All users + system-wide configs

**Modifications:**
- Root user: `/root/.nanorc`, `/root/.tmux.conf`, `/root/.bashrc` or `/root/.zshrc`
- All users: `/home/*/.nanorc`, `/home/*/.tmux.conf`, `/home/*/.bashrc` or `/home/*/.zshrc`
- System-wide: `/etc/gitconfig`, `/etc/nanorc`, `/etc/tmux.conf`, `/etc/bash.bashrc` or `/etc/zshrc`
- System configs: `/etc/fstab`, `/etc/issue`, `/etc/systemd/system/ssh.socket.d/`

**Additional Features:**
- Swap configuration
- OpenSSH socket activation
- /etc/issue network display
- Custom PS1 prompts for all users

**Requirements:**
- Root privileges (Linux)
- On macOS, uses `sudo` for system file modifications

---

## Platform Support

### Linux (Debian/Ubuntu)

**Supported:**
- APT package management
- DEB822 sources modernization
- systemd services and sockets
- Container detection (LXC, Docker)
- Swap configuration
- /etc/issue customization
- bash shell configuration

**Detection Methods:**
- Container: `/proc/1/environ`, `/proc/1/cgroup`, `/.dockerenv`, `/run/systemd/container`
- OS: `$OSTYPE` matching `linux-gnu*`

### macOS

**Supported:**
- Homebrew package management
- Nano syntax highlighting via Homebrew
- zsh shell configuration
- User and system configurations (with sudo)

**Adaptations:**
- Uses `brew` instead of `apt`
- Config paths: `/opt/homebrew/etc/nanorc`
- Shell: zsh instead of bash
- Uses BSD `stat` syntax instead of GNU
- ls uses `-G` for color instead of `--color=auto`
- 7z binary is `7zz` instead of `7z`

**Not Supported:**
- APT sources modernization
- Swap configuration
- /etc/issue customization
- OpenSSH socket configuration (uses launchd instead of systemd)

---

## Key Features

### Idempotency

All operations are safe to run multiple times:
- Existing correct configurations are detected and skipped
- Only missing or different settings trigger changes
- Backup files created only once per session per file
- Change headers added only once per session per file

### Backup System

**Timestamped Backups:**
- Format: `<filename>.backup.YYYYMMDD_HHMMSS.bak`
- Preserves permissions and ownership
- Created before first modification in session
- Tracked in `BACKED_UP_FILES[]` array

**Session Tracking:**
- Lists all modified files at end
- Shows all backup files created
- Prevents duplicate backups in same run

### Change Headers

**Format:**
```bash
# <component> configuration - managed by system-setup.sh
# Updated: Thu Nov 19 2025
```

**Behavior:**
- Added before first modification to a file in session
- Tracks via `HEADER_ADDED_FILES[]` array
- Clearly marks automated changes

### Error Handling

- Uses `set -euo pipefail` for strict error detection
- Continues on package installation failures
- Validates downloads are actual scripts (checks for shebang)
- Handles missing tools gracefully (curl/wget)
- Checks privileges before system modifications

### Self-Update System

**Mechanism:**
1. Detects curl or wget availability
2. Downloads each script from GitHub
3. Compares with local version using `diff`
4. Shows colored unified diff of changes
5. Prompts user to accept or skip each update
6. Validates downloaded content is a valid bash script
7. Restarts if `system-setup.sh` itself is updated

**Validation:**
- Checks for shebang (`#!/`) in first 10 lines
- Verifies HTTP 200 response
- Detects GitHub rate limiting (HTTP 429)

**Large Warning Display:**
If neither curl nor wget is installed, displays prominent warning box explaining updates are unavailable and continues with local scripts.

---

## Advanced Usage

### Running Individual Modules

```bash
# APT modernization
sudo ./system-modules/modernize-apt-sources.sh

# Package check only
./system-modules/package-management.sh

# Git configuration
./system-modules/system-configuration-git.sh user    # User scope
sudo ./system-modules/system-configuration-git.sh system  # System scope

# User-level config
./system-modules/system-configuration.sh user

# System-wide config
sudo ./system-modules/system-configuration.sh system

# Swap setup
sudo ./system-modules/system-configuration-swap.sh

# Timezone configuration
sudo ./system-modules/system-configuration-timezone.sh

# Container static IP
sudo ./system-modules/configure-container-static-ip.sh

# SSH socket
sudo ./system-modules/system-configuration-openssh-server.sh

# /etc/issue
sudo ./system-modules/system-configuration-issue.sh

# Migrate ifupdown to systemd-networkd
sudo ./system-modules/migrate-to-systemd-networkd.sh
```

### Debug Mode

```bash
./system-setup.sh --debug
```

Enables verbose output for troubleshooting.

### Skipping Self-Update

Run without curl/wget installed, or modify script to comment out update functions.

### Custom Package List

Edit `get_package_list()` function in `utils-sys.sh` to add or remove packages.

---

## Dependencies

### Required (Runtime)

**Linux:**
- bash 4.0+
- apt (Debian/Ubuntu)
- systemd (for service/socket management)

**macOS:**
- bash 4.0+ (install via Homebrew: `brew install bash`)
- Homebrew (for package management)

### Optional (Enhanced Features)

- **curl** or **wget**: Self-update functionality
- **nano**: Text editor for manual configuration reviews
- **diff**: Change visualization (usually pre-installed)
- **column**: Formatted output for brew dependencies (macOS)

---

## Troubleshooting

### Permission Denied

**Problem:** Script fails with permission errors

**Solution:**
- For system scope: Run with `sudo ./system-setup.sh`
- For user scope: Run without sudo as regular user

### Package Installation Fails

**Problem:** apt/brew errors during package installation

**Solution:**
- Script continues with configuration of already-installed packages
- Manually install failed packages and re-run script

### Self-Update Fails

**Problem:** Cannot download updates from GitHub

**Solution:**
- Check internet connectivity
- Verify curl or wget is installed
- Check for GitHub rate limiting
- Script will continue with local versions

### Prompt Not Updating

**Problem:** PS1 changes don't take effect

**Solution:**
```bash
# Reload shell configuration
source ~/.bashrc  # Linux
source ~/.zshrc   # macOS

# Or restart terminal
```

### Container Detection Fails

**Problem:** Script doesn't detect running in container

**Solution:**
- Manually check `/proc/1/environ` and `/proc/1/cgroup`
- Run container-specific modules manually

---

## Architecture Notes

### No Circular Dependencies

- `system-setup.sh` → sources `utils-sys.sh`
- All modules → source `utils-sys.sh`
- Modules never source each other
- Clear dependency hierarchy

### Global State Management

All global variables managed in `utils-sys.sh`:
- Detection flags: `DETECTED_OS`, `RUNNING_IN_CONTAINER`
- Package flags: `GIT_INSTALLED`, `NANO_INSTALLED`, `TMUX_INSTALLED`, `OPENSSH_SERVER_INSTALLED`
- Tracking arrays: `BACKED_UP_FILES[]`, `CREATED_BACKUP_FILES[]`, `HEADER_ADDED_FILES[]`, `CREATED_CONFIG_FILES[]`, `TEMP_FILES[]`

### Module Independence

Each module can run standalone:
- Sources `utils-sys.sh` independently
- Detects OS if not already done
- Has own `main_*()` function
- Checks `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` for direct execution

---

## License

This project is part of a personal system-setup repository. Use and modify freely.

## Usage

### Running the Main Script

```bash
cd system-setup
./system-setup.sh
```

The main script will:
1. Check for updates to all scripts (self-update)
2. Detect your OS (Linux/macOS) and environment (container/host)
3. Orchestrate all configuration modules in the proper order
4. Prompt for user vs system-wide configuration scope

### Running Individual Modules

Each module can be run independently for focused configuration:

```bash
# Modernize APT sources only (Linux)
./system-modules/modernize-apt-sources.sh

# Install/check packages only
./system-modules/package-management.sh

# Configure git only
./system-modules/system-configuration-git.sh user    # User scope
./system-modules/system-configuration-git.sh system  # System scope

# Configure nano, tmux, and shell only
./system-modules/system-configuration.sh user    # User scope
./system-modules/system-configuration.sh system  # System scope

# Configure swap only (Linux, requires root)
./system-modules/system-configuration-swap.sh

# Configure container static IP (containers only)
./system-modules/configure-container-static-ip.sh

# Configure OpenSSH socket (Linux, requires root)
./system-modules/system-configuration-openssh-server.sh

# Configure /etc/issue (Linux, requires root)
./system-modules/system-configuration-issue.sh
```

## Execution Order

When running the main script, modules are executed in this order:

1. **Environment Detection** - OS and container detection
2. **Network Migration** - Offered if system uses ifupdown (Linux only)
3. **Container Static IP** - Offered if running in a container
4. **Modernize APT Sources** - Updates APT sources (Linux only)
5. **Package Management** - Checks and installs packages
6. **Configuration Scope** - Prompts for user vs system-wide
7. **Git Configuration** - Configures git defaults (if installed)
8. **System Configuration** - Configures nano, tmux, and shell
9. **Timezone Configuration** - Prompts if system is set to UTC (system scope only)
10. **Swap Configuration** - Sets up swap memory (system scope only)
11. **OpenSSH Server** - Configures SSH socket activation (system scope only)
12. **Issue Configuration** - Updates /etc/issue (system scope only)

## Key Features

### Self-Update Mechanism

The main script automatically checks for updates to all scripts in the system-setup directory:

- Downloads each script from GitHub
- Shows diffs for changed files
- Prompts to apply updates selectively
- Restarts with updated version if changes are applied

### Shared Utilities

The `utils-sys.sh` file provides common functionality used by all modules:

- **Output Functions**: Colored print functions for consistent messaging
- **OS Detection**: Automatic Linux/macOS detection
- **Container Detection**: Identifies LXC, Docker, and other containers
- **Privilege Management**: Checks and handles sudo requirements
- **Package Management**: Unified package checking for apt and Homebrew
- **File Management**: Backup and header management with tracking
- **Configuration Management**: Update config files with idempotency

### DRY Principles

- Common functionality extracted to `utils-sys.sh`
- No circular dependencies between modules
- Each module is self-contained and independently executable
- Shared global variables managed centrally

### Maintainability

- Each module focuses on a single functional area
- Clear separation of concerns
- Consistent naming conventions
- Comprehensive inline documentation
- Proper error handling throughout

## Configuration Scopes

### User Scope
- Configures settings for the current user only
- Modifies `~/.nanorc`, `~/.tmux.conf`, `~/.bashrc` (or `~/.zshrc`)
- Does not require root privileges

### System Scope
- Configures settings system-wide
- Modifies `/etc/nanorc`, `/etc/tmux.conf`, `/etc/bash.bashrc` (or `/etc/zshrc`)
- Configures all users in `/home/` and root
- Includes system-level tasks: swap, SSH, /etc/issue
- Requires root privileges on Linux

## Platform Support

- **Linux**: Full support (Debian/Ubuntu-based systems)
  - APT package management
  - systemd-based services
  - Container detection (LXC, Docker)
  - All configuration modules

- **macOS**: Full support
  - Homebrew package management
  - User and system configurations
  - Automatic adaptation of commands and paths

## Notes

- All configuration changes are idempotent (safe to run multiple times)
- Original files are backed up before modification with timestamps
- Changes are tracked and summarized at the end
- Scripts follow bash best practices (`set -euo pipefail`)
- Shell alias and function updates preserve existing customizations
