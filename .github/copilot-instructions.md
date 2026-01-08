# GitHub Copilot Instructions

This file provides guidance to GitHub Copilot when working with code in this repository.

**For comprehensive bash coding standards, patterns, and conventions, see [.ai/AI-AGENT-INSTRUCTIONS.md](../.ai/AI-AGENT-INSTRUCTIONS.md).**

**For repository overview and running instructions, see [CLAUDE.md](../CLAUDE.md).**

> **Note:** Keep Quick Reference in sync with [CLAUDE.md](../CLAUDE.md).

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
