# System Setup Script

`system-setup.sh` - Comprehensive bash script for automated package management and system configuration across Linux and macOS platforms.

## Features

- **Self-updating**: Automatically checks for and applies updates from GitHub repository
- **Cross-platform**: Detects and configures Linux (apt-based) and macOS (Homebrew)
- **Idempotent**: Safe to run multiple times - only changes what needs updating
- **Interactive**: User prompts for package installation, configuration scope, and optional features
- **Safe**: Backs up files before modification, preserves correct settings
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

### 2. Package Management
Checks for and optionally installs packages:

**macOS (Homebrew):**
- 7-zip (p7zip), ca-certificates, Git, htop, nano, Ollama, screen

**Linux (apt):**
- 7-zip, aptitude, ca-certificates, curl, Git, htop, nano, openssh-server, screen

### 3. Configuration Scope Selection
**User-specific (Option 1):**
- Configures nano, screen, and shell for current user only

**System-wide (Option 2):**
- nano/screen: System-wide configuration (`/etc/`)
- Shell: Configures root and all users in `/home/`
- Swap: Configures swap memory (Linux only, LXC-aware)
- SSH: Optional socket-based activation (Linux only)

### 4. Component Configuration

#### nano Editor
- **Settings**: atblanks, autoindent, constantshow, indicator, linenumbers, minibar, mouse, multibuffer, nonewlines, smarthome, softwrap, tabsize 4
- **macOS**: Includes Homebrew syntax definitions path
- **Files**: `~/.nanorc` (user) or `/etc/nanorc` (system)

#### GNU Screen
- **Settings**: startup_message off, scrollback 9999, mouse tracking enabled
- **Files**: `~/.screenrc` (user) or `/etc/screenrc` (system)

#### Shell Aliases
- **Safety**: Interactive/verbose cp, mv, rm, chmod, chown
- **Utilities**: Enhanced ls (color, formatting), lsblk, lxc-ls
- **Compression**: 7z ultra compression aliases (3 levels)
- **Platform-specific**: 
  - Linux: GNU coreutils options, `.bashrc`
  - macOS: BSD options, CLICOLOR export, `.zshrc`, 7zz command
- **Files**: Current user's shell config (user) or all users in `/home/` (system)

#### Swap Memory (System scope, Linux only)
- **Auto-sizing**: ≤2GB RAM = 2x RAM, >2GB RAM = 1.5x RAM
- **Location**: `/var/swapfile`
- **Features**: Persistent across reboots via `/etc/fstab`, LXC-aware (skips in containers)

#### OpenSSH Server (System scope, Linux only)
- **Socket-based activation**: Starts SSH daemon on-demand (saves resources)
- **Configuration**: Opens systemd override editor for customization
- **Conflict resolution**: Automatically disables ssh.service if both enabled

## Idempotent Behavior

The script intelligently detects existing configurations:
- ✅ **Correct settings**: Left unchanged
- ➕ **Missing settings**: Added
- ⚙️ **Incorrect settings**: Updated (old values commented with timestamp)
- 🔒 **No duplicates**: Safe to run repeatedly

Example output:
```
[INFO] ✓ softwrap setting already configured correctly
[INFO] + Adding linenumbers setting to ~/.nanorc
[INFO] ✗ tabsize setting has different value: '8' (expected: '4')
```

## Safety Features

- **Backups**: Timestamped backups created before any file modification
- **Change headers**: Managed sections clearly marked with timestamps
- **Permissions**: Preserves file ownership and permissions
- **Smart detection**: Recognizes and preserves existing correct configurations
- **Graceful skipping**: Skips configuration for packages not installed

## Requirements

- **bash**: 4.0+
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
- Uses zsh as default shell
- Homebrew-based package management
- BSD command variants for ls and other tools
- 7-zip uses `7zz` command

### Linux
- Uses bash as default shell
- apt package manager (Debian/Ubuntu-based)
- GNU coreutils with extended options
- Systemd-based SSH socket configuration
- LXC container detection for swap configuration

## Exit Codes

- `0`: Success
- `1`: Error occurred (package manager missing, unknown OS, configuration failure)
