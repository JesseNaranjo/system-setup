# utils/

Cross-platform utility scripts for system maintenance, file synchronization, and developer tool management. These are standalone scripts — each can be copied and run independently.

## Scripts

| Script | Platform | Purpose |
|--------|----------|---------|
| `tools-update.sh` | Linux | Updates developer tools (nvm/Node.js, .NET, Claude CLI/plugins) and fixes container MTU |
| `rsync-two-way.sh` | Linux/macOS | Two-way file synchronization using rsync |
| `monitor-battery.sh` | Linux | Monitors battery percentage at regular intervals |
| `disable-kvm-module.sh` | Linux | Disables the KVM kernel module |
| `reset-macOS-display-settings.sh` | macOS | Resets macOS display configuration |
| `compare-directories.ps1` | Windows | Compares two directory trees using PowerShell |
| `robocopy-two-way.ps1` | Windows | Two-way file synchronization using Robocopy |
| `troubleshooting.md` | — | Common troubleshooting notes and solutions |

## Usage

```bash
# Update developer tools (run from any directory)
./tools-update.sh
```

## Adding New Scripts

1. Create script following repository conventions (see AI-AGENT-INSTRUCTIONS.md)
2. Update this README
