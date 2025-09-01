# System Configuration Script

This directory contains `setup-configs.sh`, a bash script that implements the configurations specified in:
- `nano.md` - nano editor settings
- `screen-gnu.md` - GNU screen configuration  
- `shell.md` - shell aliases and enhancements

## Features

- **Cross-platform**: Automatically detects Linux vs macOS and configures appropriately
- **Safe**: Backs up existing configuration files before modification
- **Interactive**: Prompts user for confirmation and installation scope
- **Flexible**: Supports both user-specific (~/) and system-wide (/etc/) installation

## Usage

```bash
cd configs
./setup-configs.sh
```

The script will:
1. Detect your operating system
2. Prompt you to continue with the configuration
3. Ask whether you want user-specific or system-wide installation
4. Configure each component (nano, screen, shell) with appropriate prompts
5. Back up any existing configuration files
6. Apply the new configurations

## What Gets Configured

### nano Editor
- Sensible defaults (line numbers, mouse support, syntax highlighting, etc.)
- macOS: Includes homebrew syntax definitions path
- Files: `~/.nanorc` or `/etc/nanorc`

### GNU Screen
- Startup message disabled
- Scrollback buffer set to 9999 lines
- Mouse tracking enabled
- Files: `~/.screenrc` or `/etc/screenrc`

### Shell Aliases
- Safety aliases for `cp`, `mv`, `rm`, `chmod`, `chown`
- Enhanced `ls` with colors and formatting
- Utility aliases for `lsblk`, `lxc-ls`, and 7z compression
- Linux: Uses GNU coreutils options
- macOS: Uses BSD-compatible options and `zsh` configuration
- Files: `~/.bashrc` (Linux) or `~/.zshrc` (macOS)

## Requirements

- bash 4.0+
- Write permissions to target directories
- For system-wide installation: root privileges

## Safety Features

- All existing configuration files are backed up with timestamps
- User confirmation required before overwriting
- Non-destructive installation (appends to existing files)
- Proper error handling and exit codes