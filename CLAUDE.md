# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**For comprehensive bash coding standards, patterns, and conventions, see [.ai/AI-AGENT-INSTRUCTIONS.md](.ai/AI-AGENT-INSTRUCTIONS.md).**

## Repository Overview

This is a personal system configuration repository containing bash scripts and documentation for setting up Linux and macOS systems. The scripts handle package management, system configuration, LXC container management, Kubernetes setup, and various utilities.

## Key Directories

- `system-setup/` - Main modular system configuration suite (the core of the repository)
- `lxc/` - LXC container management scripts (standalone)
- `kubernetes/` - Kubernetes cluster management scripts (standalone)
- `github/` - GitHub CLI automation scripts (standalone)
- `llm/` - Ollama/LLM management scripts (standalone)
- `utils/` - Cross-platform utility scripts (standalone)
- `configs/` - Configuration documentation (markdown)
- `walkthroughs/` - Step-by-step guides (markdown)

## Running the Scripts

**Main system setup:**
```bash
cd system-setup
./system-setup.sh           # Interactive setup
./system-setup.sh --debug   # Debug mode
```

**Individual modules:**
```bash
./system-modules/package-management.sh
./system-modules/system-configuration.sh user    # User scope
./system-modules/system-configuration.sh system  # System scope (requires root)
```

**LXC scripts:**
```bash
cd lxc
./_download-lxc-scripts.sh  # Update all LXC scripts
./create-lxc.sh             # Create container
./start-lxc.sh              # Start container
```

**Kubernetes scripts:**
```bash
cd kubernetes
./_download-k8s-scripts.sh  # Update all k8s scripts
./start-k8s.sh              # Start k8s services
./stop-k8s.sh               # Stop k8s services
```

## Quick Reference

**Critical requirements for all scripts:**
- Always use `set -euo pipefail` at script start
- Always quote variables: `"$var"` and `"${array[@]}"`
- Use `[[ ]]` for conditionals, not `[ ]`
- Use arrays, not space-separated strings
- Use `$(cmd)` not backticks for command substitution

**Platform support:**
- **Linux (Debian/Ubuntu):** apt package management, systemd, bash
- **macOS:** Homebrew, launchd, zsh
- **Containers:** LXC, Docker detection via `/proc/1/environ`, `/proc/1/cgroup`, `/.dockerenv`

**Script architectures:**
1. **Modular** (`system-setup/`): Shared `utils.sh`, feature modules in `system-modules/`
2. **Standalone** (`lxc/`, `kubernetes/`, etc.): Self-contained, managed by `_download-*-scripts.sh` updaters
