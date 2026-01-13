# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**For comprehensive coding standards, patterns, and conventions, see [.ai/AI-AGENT-INSTRUCTIONS.md](.ai/AI-AGENT-INSTRUCTIONS.md).**

> **Note:** Keep this file in sync with [.github/copilot-instructions.md](.github/copilot-instructions.md).

## Folder Documentation

Each folder contains a README.md documenting its contents. **Read the README before modifying any folder.** Update READMEs when adding, removing, or changing files.

## Quick Reference for LLMs

### Minimal Script Template
```bash
#!/usr/bin/env bash
set -euo pipefail

readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

print_info() { echo -e "${BLUE}[ INFO    ]${NC} $1"; }
print_success() { echo -e "${GREEN}[ SUCCESS ]${NC} $1"; }
print_error() { echo -e "${RED}[ ERROR   ]${NC} $1"; }

main() {
    print_info "Starting..."
    # Logic here
    print_success "Complete"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
```

### Most Common Operations

**Idempotent Config:**
```bash
config_exists "$file" "$setting" && [[ "$(get_config_value "$file" "$setting")" == "$val" ]] && return 0
backup_file "$file"
add_change_header "$file" "type"
echo "$setting $val" >> "$file"
```

**User Prompt:**
```bash
prompt_yes_no "Action?" "n" && execute || { print_info "Skipped"; return 0; }
```

**Platform Branch:**
```bash
[[ "$os" == "macos" ]] && macos_cmd || linux_cmd
```

**Loop with Check:**
```bash
for item in "${array[@]}"; do
    [[ condition ]] && continue
    process "$item"
done
```
