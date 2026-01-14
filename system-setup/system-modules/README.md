# System Modules

This directory contains modular configuration scripts for the system-setup suite. Each module handles a specific configuration concern and can be run standalone or orchestrated by the main `system-setup.sh` script.

## Module Overview

| Script | Description | Platform | Scope |
|--------|-------------|----------|-------|
| `configure-container-static-ip.sh` | Configure static IP for containers | Linux | Container |
| `migrate-to-systemd-networkd.sh` | Migrate from ifupdown to systemd-networkd | Linux | System |
| `modernize-apt-sources.sh` | Convert APT sources to DEB822 format | Linux | System |
| `package-management.sh` | Install and verify required packages | Linux/macOS | System |
| `system-configuration.sh` | Configure nano, screen, and shell | Linux/macOS | User/System |
| `system-configuration-issue.sh` | Update /etc/issue with network info | Linux | System |
| `system-configuration-openssh-server.sh` | Configure SSH socket activation | Linux | System |
| `system-configuration-swap.sh` | Create and enable swap memory | Linux | System |
| `system-configuration-timezone.sh` | Configure system timezone | Linux/macOS | System |

## Usage

### Running via Main Script

The recommended way to run these modules is through the main orchestrator:

```bash
cd system-setup
./system-setup.sh
```

### Running Individually

Each module can be executed directly for targeted configuration:

```bash
# Source utils.sh is handled automatically
./system-modules/package-management.sh

# Some modules require root privileges
sudo ./system-modules/system-configuration-swap.sh

# Some modules accept scope parameter
./system-modules/system-configuration.sh user    # Current user only
./system-modules/system-configuration.sh system  # All users + system
```

## Architecture

All modules follow the same structure:

1. **Header**: Script description and purpose
2. **SCRIPT_DIR detection**: Locate parent directory for utils.sh
3. **Source utils.sh**: Import shared functions and variables
4. **Module functions**: Implementation specific to the module
5. **Main entry point**: `main_<module_name>()` function
6. **Execution guard**: Run main only if executed directly

### Example Module Structure

```bash
#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

source "${SCRIPT_DIR}/utils.sh"

# Module-specific functions here...

main_module_name() {
    detect_environment
    # Module logic
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_module_name "$@"
fi
```

## Dependencies

All modules depend on `../utils.sh` for:
- Color output functions (`print_info`, `print_success`, `print_error`, etc.)
- OS detection (`detect_os`, `detect_container`)
- Configuration management (`backup_file`, `add_config_if_needed`, etc.)
- User interaction (`prompt_yes_no`)
- Privilege management (`run_elevated`, `needs_elevation`)

## Adding New Modules

1. Create script in this directory following the structure above
2. Use `main_<descriptive_name>()` for the entry point
3. Source `utils.sh` for shared functionality
4. Add documentation to `../README.md`
5. Update this README's module table
