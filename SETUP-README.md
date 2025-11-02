# System Setup Script

This is `system-setup.sh`, a comprehensive bash script that manages package installation and system configurations specified in:
- `configs/nano.md` - nano editor settings
- `configs/screen-gnu.md` - GNU screen configuration  
- `configs/shell.md` - shell aliases and enhancements

## Features

- **Package Management**: Checks for required packages and offers to install missing ones
  - macOS: htop, nano, screen, sevenzip (via Homebrew)
  - Linux: 7zip, htop, nano, screen, openssh-server (via apt)
- **Cross-platform**: Automatically detects Linux vs macOS and configures appropriately
- **Idempotent**: Only adds or updates configurations that are missing or different - safe to run multiple times
- **Safe**: Backs up existing configuration files before modification (only once per session)
- **Interactive**: Prompts user for confirmation and installation scope
- **Flexible**: Supports both user-specific (~/) and system-wide (/etc/) installation
- **Smart detection**: Recognizes existing configurations and preserves correct settings
- **Skip unavailable**: Skips nano/screen configuration if packages are not installed

## Usage

```bash
./system-setup.sh
```

The script will:
1. Detect your operating system
2. Check for required packages and prompt to install missing ones
3. Install all selected packages in a single operation
4. Prompt you to continue with configuration
5. Ask whether you want user-specific or system-wide installation
6. Analyze existing configurations and determine what needs to be updated
7. Back up configuration files only when changes are needed
8. Apply missing or updated configurations while preserving correct existing settings

## Package Management

### macOS (Homebrew)
The script checks for and optionally installs:
- **nano** - text editor
- **screen** - terminal multiplexer
- **htop** - interactive process viewer
- **p7zip** - 7-Zip compression utility

### Linux (apt)
The script checks for and optionally installs:
- **nano** - text editor
- **screen** - terminal multiplexer
- **htop** - interactive process viewer
- **7zip** - 7-Zip compression utility
- **openssh-server** - SSH server

## What Gets Configured

### nano Editor
- Sensible defaults (line numbers, mouse support, syntax highlighting, etc.)
- macOS: Includes homebrew syntax definitions path
- **User scope**: `~/.nanorc`
- **System scope**: `/etc/nanorc`
- **Skipped if**: nano is not installed

### GNU Screen
- Startup message disabled
- Scrollback buffer set to 9999 lines
- Mouse tracking enabled
- **User scope**: `~/.screenrc`
- **System scope**: `/etc/screenrc`
- **Skipped if**: screen is not installed

### Shell Aliases
- Safety aliases for `cp`, `mv`, `rm`, `chmod`, `chown`
- Enhanced `ls` with colors and formatting
- Utility aliases for `lsblk`, `lxc-ls`, and 7z compression
- Linux: Uses GNU coreutils options
- macOS: Uses BSD-compatible options and `zsh` configuration
- **User scope**: Current user's `~/.bashrc` (Linux) or `~/.zshrc` (macOS)
- **System scope**: All users in `/home/` - iterates over each user's `.bashrc` or `.zshrc`

## Requirements

- bash 4.0+
- Write permissions to target directories
- For system-wide installation: root privileges
- Package manager:
  - macOS: Homebrew (`brew`)
  - Linux: apt (Debian/Ubuntu-based systems)

## Safety Features

- **Idempotent operation**: Safe to run multiple times - only changes what needs to be changed
- Configuration files are backed up with timestamps (only when modifications are made)
- User confirmation required before proceeding
- Existing correct configurations are preserved and not duplicated
- Smart detection prevents duplicate entries and unnecessary modifications
- Proper error handling and exit codes
- All package installations confirmed interactively

## Idempotent Behavior

The script is designed to be idempotent, meaning:
- ✅ **Existing correct configurations are left unchanged**
- ✅ **Missing configurations are added**
- ✅ **Incorrect configurations are updated to correct values**
- ✅ **No duplicate entries are created when run multiple times**
- ✅ **Backup files are created only when changes are made**

Example output on subsequent runs:
```
[INFO] ✓ softwrap setting already configured correctly
[INFO] ✓ startup message setting already configured correctly
[INFO] ✓ Linux ls with colors and formatting alias already configured correctly
```