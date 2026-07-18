# utils/

Cross-platform utility scripts for system maintenance, file synchronization, and developer tool management. Most scripts are Modular Standalone: they source the shared `utils-misc.sh` library and self-update via `check_for_updates`, managed by `_download-utils-scripts.sh`. `monitor-battery.sh` and `disable-kvm-module.sh` are trivial one-offs kept as Lightweight scripts (no shared utilities, no self-update). The 2 `.ps1` scripts are Windows PowerShell and remain standalone.

## Scripts

| Script | Platform | Purpose |
|--------|----------|---------|
| `utils-misc.sh` | Linux/macOS | Shared utilities library (colors, prompts, self-update) required by the scripts below |
| `_download-utils-scripts.sh` | Linux/macOS | Self-updating script manager for this directory |
| `rsync-two-way.sh` | Linux/macOS | Two-way file synchronization using rsync |
| `monitor-battery.sh` | Linux | Monitors battery percentage at regular intervals |
| `dig-all.sh` | Linux/macOS | Queries all common DNS record types for one or more domains, with optional resolver override |
| `services-check.sh` | Linux/macOS | Checks local service availability (installation + port health) |
| `push-ghostty-terminfo.sh` | Linux/macOS | Installs the local xterm-ghostty terminfo on a remote SSH host (system-wide by default; `--user` for per-user) |
| `unlock-keychain.sh` | macOS | Unlocks the macOS login keychain in the current shell/session, so `security find-generic-password` works from a raw SSH shell |
| `disable-kvm-module.sh` | Linux | Disables the KVM kernel module |
| `reset-macOS-display-settings.sh` | macOS | Resets macOS display configuration |
| `compare-directories.ps1` | Windows | Compares two directory trees using PowerShell |
| `robocopy-two-way.ps1` | Windows | Two-way file synchronization using Robocopy |
| `troubleshooting.md` | — | Common troubleshooting notes and solutions |

## Usage

```bash
# Query all DNS record types for a domain
./dig-all.sh example.com

# Use a specific resolver
./dig-all.sh --resolver 1.1.1.1 example.com

# Query multiple domains (adds summary table)
./dig-all.sh example.com google.com anthropic.com

# Check all installed services
./services-check.sh

# Check specific services
./services-check.sh redis postgresql grafana

# Watch mode (refreshes every 10 seconds by default)
./services-check.sh --watch

# Watch specific services every 5 seconds
./services-check.sh --watch 5 redis postgresql

# Install xterm-ghostty system-wide on a remote (all users incl. root)
./push-ghostty-terminfo.sh user@host

# Per-user only (no remote sudo)
./push-ghostty-terminfo.sh --user user@host

# Reinstall / update an existing entry
./push-ghostty-terminfo.sh --force user@host

# Unlock the macOS login keychain in the current SSH session
./unlock-keychain.sh
```

## Self-Update

`dig-all.sh`, `push-ghostty-terminfo.sh`, `reset-macOS-display-settings.sh`, `rsync-two-way.sh`, `services-check.sh`, and `unlock-keychain.sh` self-update when run directly via `check_for_updates()`. This checks for updates to both `utils-misc.sh` and the calling script, showing diffs and prompting before overwriting. Scripts that are sourced (not executed directly) skip the update check.

`utils-misc.sh` must be present in the same directory as the scripts; it is kept current via `check_for_updates()` (above), not by the `_download-utils-scripts.sh` download manifest.

`monitor-battery.sh`, `disable-kvm-module.sh`, and the 2 `.ps1` scripts do NOT self-update (Lightweight/standalone, no shared utilities).

## Adding New Scripts

1. Create script following repository conventions (see AI-AGENT-INSTRUCTIONS.md)
2. Add the script's path to `get_script_list()` in `_download-utils-scripts.sh`
3. Update this README
