# utils/

Cross-platform utility scripts for system maintenance, file synchronization, and developer tool management. These are standalone scripts — each can be copied and run independently.

## Scripts

| Script | Platform | Purpose |
|--------|----------|---------|
| `rsync-two-way.sh` | Linux/macOS | Two-way file synchronization using rsync |
| `monitor-battery.sh` | Linux | Monitors battery percentage at regular intervals |
| `dig-all.sh` | Linux/macOS | Queries all common DNS record types for one or more domains, with optional resolver override |
| `services-check.sh` | Linux/macOS | Checks local service availability (installation + port health) |
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
```

## Adding New Scripts

1. Create script following repository conventions (see AI-AGENT-INSTRUCTIONS.md)
2. Update this README
