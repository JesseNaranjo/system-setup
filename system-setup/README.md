# System Setup - Refactored Structure

This directory contains the refactored system-setup scripts, organized into focused, maintainable modules.

## Directory Structure

```
system-setup/
├── system-setup.sh                           # Main orchestrator script
├── utils.sh                                  # Common utilities and functions
└── modules/                                  # Focused configuration modules
    ├── configure-container-static-ip.sh      # Container static IP configuration
    ├── modernize-apt-sources.sh              # APT sources modernization
    ├── package-management.sh                 # Package installation (apt/Homebrew)
    ├── system-configuration.sh               # Nano, screen, and shell configuration
    ├── system-configuration-issue.sh         # /etc/issue network interface display
    ├── system-configuration-openssh-server.sh # OpenSSH socket configuration
    └── system-configuration-swap.sh          # Swap memory configuration
```

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
./modules/modernize-apt-sources.sh

# Install/check packages only
./modules/package-management.sh

# Configure nano, screen, and shell only
./modules/system-configuration.sh user    # User scope
./modules/system-configuration.sh system  # System scope

# Configure swap only (Linux, requires root)
./modules/system-configuration-swap.sh

# Configure container static IP (containers only)
./modules/configure-container-static-ip.sh

# Configure OpenSSH socket (Linux, requires root)
./modules/system-configuration-openssh-server.sh

# Configure /etc/issue (Linux, requires root)
./modules/system-configuration-issue.sh
```

## Execution Order

When running the main script, modules are executed in this order:

1. **Environment Detection** - OS and container detection
2. **Container Static IP** - Offered if running in a container
3. **Modernize APT Sources** - Updates APT sources (Linux only)
4. **Package Management** - Checks and installs packages
5. **System Configuration** - Configures nano, screen, and shell
6. **Swap Configuration** - Sets up swap memory (system scope only)
7. **OpenSSH Server** - Configures SSH socket activation (system scope only)
8. **Issue Configuration** - Updates /etc/issue (system scope only)

## Key Features

### Self-Update Mechanism

The main script automatically checks for updates to all scripts in the system-setup directory:

- Downloads each script from GitHub
- Shows diffs for changed files
- Prompts to apply updates selectively
- Restarts with updated version if changes are applied

### Shared Utilities

The `utils.sh` file provides common functionality used by all modules:

- **Output Functions**: Colored print functions for consistent messaging
- **OS Detection**: Automatic Linux/macOS detection
- **Container Detection**: Identifies LXC, Docker, and other containers
- **Privilege Management**: Checks and handles sudo requirements
- **Package Management**: Unified package checking for apt and Homebrew
- **File Management**: Backup and header management with tracking
- **Configuration Management**: Update config files with idempotency

### DRY Principles

- Common functionality extracted to `utils.sh`
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
- Modifies `~/.nanorc`, `~/.screenrc`, `~/.bashrc` (or `~/.zshrc`)
- Does not require root privileges

### System Scope
- Configures settings system-wide
- Modifies `/etc/nanorc`, `/etc/screenrc`, `/etc/bash.bashrc` (or `/etc/zshrc`)
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
