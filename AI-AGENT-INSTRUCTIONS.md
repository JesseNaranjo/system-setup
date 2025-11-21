# AI Agent Instructions for Bash Scripts

## Document Purpose
This document provides comprehensive patterns, styles, and conventions used across all bash scripts in this repository. Optimized for LLM consumption to enable rapid, accurate code generation and modification without requiring full source file analysis.

**Last Updated:** November 15, 2025
**Primary Reference:** system-setup.sh (1982 lines)
**Scope:** All `.sh` scripts in repository

---

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

---

## Table of Contents
1. [Core Principles](#core-principles)
2. [Script Structure](#script-structure)
3. [Bash Standards](#bash-standards)
4. [Function Patterns](#function-patterns)
5. [User Interaction](#user-interaction)
6. [Configuration Management](#configuration-management)
7. [Output & Logging](#output--logging)
8. [Cross-Platform Support](#cross-platform-support)
9. [Error Handling](#error-handling)
10. [File Modification](#file-modification)
11. [Security & Safety](#security--safety)

---

## Core Principles

### Critical Rules (Always Apply)
1. **Idempotency**: Check state before changes, skip if already correct
2. **Safety**: Backup files before modification, comment (never delete) old configs
3. **Quote Everything**: All variable expansions must be quoted: `"$var"`
4. **set -euo pipefail**: Always at script top
5. **Return Codes**: 0 = success, 1 = error

### User Experience
- Default to "n" for destructive ops, "y" for safe ops
- Provide clear feedback before and after actions
- Continue script if non-critical components fail
- Use color-coded output functions

### Platform Independence
- Detect OS (macOS/Linux) and adapt
- Handle both brew and apt package managers
- Support user and system-wide configurations
- Detect container environments (Docker, LXC)

---

## Script Structure

### Header Template
```bash
#!/usr/bin/env bash

# script-name.sh - Brief one-line description
# Extended description (optional)
#
# Usage: ./script-name.sh [options]
#
# This script:
# - Feature list (optional)

set -euo pipefail
```

### Global Constants (Define Early)
```bash
# Colors - define before any other code that might use them
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'
```

### Global Variables (Use Arrays for Collections)
```bash
# State tracking - prefer arrays over space-separated strings
BACKED_UP_FILES=()
CREATED_BACKUP_FILES=()
HEADER_ADDED_FILES=()
NANO_INSTALLED=false
SCREEN_INSTALLED=false
RUNNING_IN_CONTAINER=false
DEBUG_MODE=false
```

### Function Organization Order
1. **Utility functions** (prompts, colors, detection)
2. **Helper functions** (backup, config checking)
3. **Configuration functions** (component-specific)
4. **Main function** (orchestration)
5. **Execution guard** (if run directly)

```bash
# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

---

## Bash Standards

### Critical Syntax Rules
```bash
# Quote ALL variables (security + correctness)
"$var" "${array[@]}"  # ✓ Correct
$var ${array[@]}      # ✖ Wrong

# Arrays (not space-separated strings)
arr=() arr+=("item")  # ✓ Correct
str="" str="$str item" # ✖ Avoid

# Conditionals - use [[ ]] not [ ]
[[ -f "$file" ]]      # ✓ Correct
[ -f "$file" ]        # ✖ Avoid

# Command substitution
result=$(cmd)         # ✓ Correct
result=`cmd`          # ✖ Avoid
```

### Common Conditionals
```bash
# Files
[[ -f "$file" ]]      # exists
[[ -d "$dir" ]]       # directory
[[ -w "$file" ]]      # writable
[[ ! -f "$file" ]]    # doesn't exist

# Strings
[[ -z "$var" ]]       # empty
[[ -n "$var" ]]       # non-empty
[[ "$a" == "$b" ]]    # equals
[[ "$var" =~ ^regex$ ]] # regex
[[ "$var" == glob* ]] # glob

# Numbers
[[ $n -eq 5 ]]        # equal
[[ $n -gt 5 ]]        # greater
[[ $n -lt 5 ]]        # less
```

### Variable Naming
```bash
readonly CONSTANT="value"  # Global constant
GLOBAL_VAR="value"         # Global variable
local local_var="value"    # Function local
local param1="$1"          # Function parameter
```

### Array Iteration
```bash
for item in "${array[@]}"; do
    echo "$item"
done

# Check if already in array
local found=false
for item in "${array[@]}"; do
    if [[ "$item" == "$target" ]]; then
        found=true
        break
    fi
done
```

---

## Function Patterns

### Function Template
```bash
# Brief description
# Usage: function_name "param1" ["param2"]
# Returns: 0 on success, 1 on error
function_name() {
    local param1="$1"
    local param2="${2:-default}"

    if [[ -z "$param1" ]]; then
        print_error "param1 required"
        return 1
    fi

    # Logic here
    return 0
}
```

### Function Call Patterns
```bash
# Capture return value
if function_name "arg"; then
    # Success
else
    # Error
fi

# Capture output
local result=$(function_name "arg")

# Both
if result=$(function_name "arg"); then
    echo "Got: $result"
fi
```

---

## User Interaction

### prompt_yes_no Implementation
```bash
# Standard prompt - use /dev/tty for pipe compatibility
prompt_yes_no() {
    local prompt_message="$1"
    local default="${2:-n}"
    local user_reply

    if [[ "${default,,}" == "y" ]]; then
        local prompt_suffix="(Y/n)"
    else
        local prompt_suffix="(y/N)"
    fi

    read -p "$prompt_message $prompt_suffix: " -r user_reply </dev/tty

    if [[ -z "$user_reply" ]]; then
        [[ "${default,,}" == "y" ]]
    else
        [[ $user_reply =~ ^[Yy]$ ]]
    fi
}
```

### Prompt Usage
```bash
# Destructive - default NO
if prompt_yes_no "Delete file?" "n"; then
    rm "$file"
fi

# Safe - default YES
if prompt_yes_no "Configure?" "y"; then
    configure
fi

# Context-aware defaults
local default="y"
[[ "$RUNNING_IN_CONTAINER" == true ]] && default="n"
if prompt_yes_no "Install package?" "$default"; then
    install_package
fi
```

### Input Validation
```bash
while true; do
    read -p "Enter value: " -r input </dev/tty
    [[ "$input" =~ ^valid$ ]] && break
    print_error "Invalid input"
done
```

---

## Configuration Management

### Configuration File Patterns

#### User vs System Scope
```bash
# Determine config file based on scope
configure_component() {
    local os="$1"
    local scope="$2"  # "user" or "system"

    local config_file
    if [[ "$scope" == "system" ]]; then
        config_file="/etc/component.conf"
        # Check write permissions
        if [[ ! -w "/etc" ]]; then
            print_error "No write permission to /etc. Run as root or choose user scope."
            return 1
        fi
    else
        config_file="$HOME/.componentrc"
    fi

    # Create if doesn't exist
    if [[ ! -f "$config_file" ]]; then
        print_info "Creating new configuration file: $config_file"
        touch "$config_file"
    fi

    # Configuration logic here
}
```

### Core Configuration Functions

**config_exists** - Check if setting exists:
```bash
config_exists() {
    local file="$1"
    local pattern="$2"
    [[ -f "$file" ]] && grep -qE "^[[:space:]]*${pattern}" "$file"
}
```

**get_config_value** - Extract current value:
```bash
get_config_value() {
    local file="$1"
    local setting="$2"
    if [[ -f "$file" ]]; then
        grep -E "^[[:space:]]*${setting}" "$file" | head -n 1 | \
            sed -E "s/^[[:space:]]*${setting}[[:space:]]*//" || true
    fi
}
```

**update_config_line** - Idempotent update (internal):
```bash
update_config_line() {
    local config_type="$1"  # "nano", "screen", "shell"
    local file="$2"
    local setting_pattern="$3"  # Regex to match
    local full_line="$4"        # Complete line to add
    local description="$5"

    if config_exists "$file" "$setting_pattern"; then
        if grep -qE "^[[:space:]]*${full_line}[[:space:]]*$" "$file"; then
            print_success "- $description already configured"
            return 0
        fi
        backup_file "$file"
        add_change_header "$file" "$config_type"
        # Comment old, append new
        awk -v pat="$setting_pattern" -v new="$full_line" '
            $0 ~ pat { print "# " $0 " # Replaced " strftime("%Y-%m-%d"); next }
            { print }
            END { print new }
        ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    else
        backup_file "$file"
        add_change_header "$file" "$config_type"
        echo "$full_line" >> "$file"
    fi
}
```

### Wrapper Functions

**add_config_if_needed** - Simple key-value settings:
```bash
add_config_if_needed() {
    local config_type="$1"
    local file="$2"
    local setting="$3"
    local value="$4"
    local description="$5"

    local full_setting="${setting}${value:+ $value}"
    local pattern="^[[:space:]]*${setting}"
    update_config_line "$config_type" "$file" "$pattern" "$full_setting" "$description"
}
```

**add_alias_if_needed** - Shell aliases:
```bash
add_alias_if_needed() {
    local file="$1"
    local alias_name="$2"
    local alias_value="$3"
    local description="$4"

    local full_alias="alias ${alias_name}='${alias_value}'"
    local pattern="alias[[:space:]]+${alias_name}="
    update_config_line "shell" "$file" "$pattern" "$full_alias" "$description"
}
```

**add_export_if_needed** - Environment variables:
```bash
add_export_if_needed() {
    local file="$1"
    local var_name="$2"
    local var_value="$3"
    local description="$4"

    local full_export="export ${var_name}=${var_value}"
    local pattern="export[[:space:]]+${var_name}="
    update_config_line "shell" "$file" "$pattern" "$full_export" "$description"
}
```

---

## Output & Logging

### Standard Output Functions
```bash
print_info()    { echo -e "${BLUE}[ INFO    ]${NC} $1"; }
print_success() { echo -e "${GREEN}[ SUCCESS ]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[ WARNING ]${NC} $1"; }
print_error()   { echo -e "${RED}[ ERROR   ]${NC} $1"; }
print_backup()  { echo -e "${GRAY}[ BACKUP  ] $1${NC}"; }
print_debug()   { echo -e "${MAGENTA}[ DEBUG   ] $1${NC}"; }
```

### Usage Conventions
```bash
print_info "Checking configuration..."      # Process updates
print_success "✓ Configuration applied"     # Completed actions
print_warning "Feature unavailable"         # Non-fatal issues
print_error "Permission denied"             # Fatal errors
print_backup "- Created: file.backup"       # Backup operations
```

### Visual Elements
```bash
# Box borders for critical messages
echo -e "${YELLOW}╔════════════════╗${NC}"
echo -e "${YELLOW}║  Message       ║${NC}"
echo -e "${YELLOW}╚════════════════╝${NC}"

# Indented output
echo "            - Detail item"
echo "            • Bullet point"
```

---

## Cross-Platform Support

### OS Detection
```bash
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    else
        echo "unknown"
    fi
}
```

### Container Detection (Sets Global)
```bash
detect_container() {
    [[ -f /proc/1/environ ]] && grep -qa container=lxc /proc/1/environ && RUNNING_IN_CONTAINER=true && return
    [[ -f /.dockerenv ]] && RUNNING_IN_CONTAINER=true && return
    [[ -f /run/systemd/container ]] && RUNNING_IN_CONTAINER=true && return
    grep -q lxc /proc/1/cgroup 2>/dev/null && RUNNING_IN_CONTAINER=true && return
    RUNNING_IN_CONTAINER=false
}
```

### Platform-Specific Patterns
```bash
# Package manager
if [[ "$os" == "macos" ]]; then
    command -v brew &>/dev/null || { print_error "Homebrew required"; return 1; }
else
    command -v apt &>/dev/null || { print_error "apt required"; return 1; }
fi

# stat command
if [[ "$OSTYPE" == "darwin"* ]]; then
    owner=$(stat -f "%u:%g" "$file")  # macOS
else
    owner=$(stat -c "%u:%g" "$file")   # Linux
fi

# Package names
get_package_list() {
    local os="$1"
    if [[ "$os" == "macos" ]]; then
        echo "Nano:nano" "Screen:screen"
    else
        echo "Nano:nano" "Screen:screen" "OpenSSH:openssh-server"
    fi
}
```

### Package Installation Check
```bash
is_package_installed() {
    local os="$1"
    local package="$2"
    if [[ "$os" == "macos" ]]; then
        brew list "$package" &>/dev/null
    else
        dpkg -l "$package" 2>/dev/null | grep -q "^ii"
    fi
}
```

---

## Error Handling

### Always Use set -euo pipefail
```bash
#!/usr/bin/env bash
set -euo pipefail  # Exit on error, undefined var, pipe failure
```

### Return Code Patterns
```bash
function_name() {
    [[ -z "$required" ]] && print_error "Missing param" && return 1
    [[ ! -f "$file" ]] && print_warning "File not found, skipping" && return 0
    risky_operation || { print_error "Failed"; return 1; }
    return 0
}
```

### Graceful Degradation
```bash
# Continue on non-critical failures
configure_component_a "$os" || print_warning "Component A failed, continuing"
configure_component_b "$os" || print_warning "Component B failed, continuing"
```

### Tool Detection
```bash
# Fallback to alternatives
if command -v curl &>/dev/null; then
    DOWNLOAD_CMD="curl"
elif command -v wget &>/dev/null; then
    DOWNLOAD_CMD="wget"
else
    print_warning "No download tool available"
    DOWNLOAD_CMD=""
fi

# Later usage
[[ -n "$DOWNLOAD_CMD" ]] && download_file
```

### Permission Checks
```bash
[[ ! -w "/etc/config" ]] && print_error "No write permission" && return 1
[[ $EUID -ne 0 ]] && [[ "$scope" == "system" ]] && print_error "Requires root" && return 1
```

---

## File Modification

### backup_file - Once Per Session
```bash
backup_file() {
    local file="$1"
    local already_backed_up=false

    for backed_up_file in "${BACKED_UP_FILES[@]}"; do
        [[ "$backed_up_file" == "$file" ]] && already_backed_up=true && break
    done
    [[ "$already_backed_up" == true ]] && return 0

    if [[ -f "$file" ]]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp -p "$file" "$backup"

        # Preserve ownership (platform-specific)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            local owner=$(stat -f "%u:%g" "$file")
        else
            local owner=$(stat -c "%u:%g" "$file")
        fi
        chown "$owner" "$backup" 2>/dev/null || true

        print_backup "- Created backup: $backup"
        BACKED_UP_FILES+=("$file")
        CREATED_BACKUP_FILES+=("$backup")
    fi
}
```

### add_change_header - Once Per Session
```bash
add_change_header() {
    local file="$1"
    local config_type="$2"  # "nano", "screen", "shell"
    local already_added=false

    for added_file in "${HEADER_ADDED_FILES[@]}"; do
        [[ "$added_file" == "$file" ]] && already_added=true && break
    done
    [[ "$already_added" == true ]] && return 0

    echo "" >> "$file"
    case "$config_type" in
        nano)   echo "# nano configuration - managed by script" >> "$file" ;;
        screen) echo "# GNU screen configuration - managed by script" >> "$file" ;;
        shell)  echo "# Shell configuration - managed by script" >> "$file" ;;
    esac
    echo "# Updated: $(date)" >> "$file"
    echo "" >> "$file"

    HEADER_ADDED_FILES+=("$file")
}
```

### Safe Edit Patterns
```bash
# Comment old, don't delete (macOS/Linux compatible)
sed -i.bak "s/^\([[:space:]]*\)\(${pattern}\)/\1# \2  # Replaced $(date +%Y-%m-%d)/" "$file" && rm -f "${file}.bak"

# Prefer awk for complex replacements
awk -v pattern="$pat" -v new="$newline" '
    $0 ~ pattern { print "# " $0 " # Replaced"; next }
    { print }
    END { print new }
' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

# Preserve ownership
[[ $EUID -eq 0 ]] && [[ "$user" != "root" ]] && chown "$user:$user" "$file" 2>/dev/null || true
```

---

## Security & Safety

### Privilege Checks
```bash
[[ $EUID -eq 0 ]] && print_warning "Running as root"
[[ "$scope" == "system" ]] && [[ $EUID -ne 0 ]] && print_error "Requires root" && exit 1
```

### Safe Defaults in Prompts
```bash
prompt_yes_no "Delete data?" "n"        # Destructive - default NO
prompt_yes_no "Apply config?" "y"       # Safe - default YES
```

### Input Validation Example
```bash
while true; do
    read -p "Enter IP: " -r input </dev/tty
    if [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -ra octets <<< "$input"
        valid=true
        for oct in "${octets[@]}"; do
            [[ $oct -gt 255 ]] && valid=false && break
        done
        [[ "$valid" == true ]] && break
    fi
    print_error "Invalid IP"
done
```

### Temp File Cleanup
```bash
temp_file=$(mktemp)
trap 'rm -f "${temp_file}"' EXIT  # Auto-cleanup
echo "content" > "$temp_file"
# Use temp_file...
```

---



---

## Self-Update Pattern

### GitHub Auto-Update (Before Main Logic)
```bash
if [[ ${scriptUpdated:-0} -eq 0 ]]; then
    REMOTE_BASE="https://raw.githubusercontent.com/USER/REPO/refs/heads/main"
    SCRIPT_FILE="$(basename "${BASH_SOURCE[0]}")"
    TEMP_SCRIPT_FILE="$(mktemp)"
    trap 'rm -f "${TEMP_SCRIPT_FILE}"' EXIT

    # Detect download tool
    DOWNLOAD_CMD=""
    command -v curl &>/dev/null && DOWNLOAD_CMD="curl"
    command -v wget &>/dev/null && [[ -z "$DOWNLOAD_CMD" ]] && DOWNLOAD_CMD="wget"

    if [[ -n "$DOWNLOAD_CMD" ]]; then
        DOWNLOAD_SUCCESS=false
        if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
            curl -H 'Cache-Control: no-cache' -o "${TEMP_SCRIPT_FILE}" \
                 -fsSL "${REMOTE_BASE}/${SCRIPT_FILE}" && DOWNLOAD_SUCCESS=true
        elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
            wget --no-cache -O "${TEMP_SCRIPT_FILE}" \
                 -q "${REMOTE_BASE}/${SCRIPT_FILE}" && DOWNLOAD_SUCCESS=true
        fi

        if [[ "$DOWNLOAD_SUCCESS" == true ]]; then
            if ! diff -u "${BASH_SOURCE[0]}" "${TEMP_SCRIPT_FILE}" >/dev/null 2>&1; then
                # Show diff
                echo -e "${CYAN}╭── Changes ──╮${NC}"
                diff -u --color "${BASH_SOURCE[0]}" "${TEMP_SCRIPT_FILE}" || true
                echo -e "${CYAN}╰─────────────╯${NC}"

                if prompt_yes_no "Update and restart?" "y"; then
                    chmod +x "$TEMP_SCRIPT_FILE"
                    mv -f "$TEMP_SCRIPT_FILE" "${BASH_SOURCE[0]}"
                    export scriptUpdated=1
                    exec "${BASH_SOURCE[0]}" "$@"
                    exit 0
                fi
            else
                echo "✓ Script up-to-date"
            fi
        fi
    else
        print_warning "No download tool (curl/wget) available for auto-update"
    fi
fi
```

---

## Common Patterns

### Idempotent Configuration Flow
```
1. Detect current state
2. Compare with desired state
3. Skip if matches (print success)
4. Backup if updating
5. Add header if first change
6. Comment old + add new
7. Report result
```

### User Interaction Flow
```
1. Check current state
2. Explain action
3. Prompt (contextual default)
4. Execute
5. Confirm result
```

### Scope-Based Configuration
```
1. Determine scope (user/system)
2. Set config file path
3. Check write permissions
4. Create file if missing
5. Apply settings
6. Preserve ownership
```

---

## Anti-Patterns - Never Do This

| ❌ Wrong | ✓ Correct |
|---------|----------|
| `sed -i "/old/d" "$file"` | `sed -i "s/^old/# old  # Replaced/" "$file"` |
| `cp $file $backup` | `cp "$file" "$backup"` |
| `curl -O "$url"` | `command -v curl &>/dev/null && curl -O "$url"` |
| `config="/home/user/.rc"` | `config="$HOME/.rc"` |
| `echo "x=y" >> "$file"` | `config_exists "$file" "x" \|\| echo "x=y" >> "$file"` |
| `[ -f "$file" ]` | `[[ -f "$file" ]]` |
| `result=\`cmd\`` | `result=$(cmd)` |
| `str="$str item"` | `arr+=("item")` |



---

## LLM Optimization Guidelines

### When Generating New Code
1. **Start with structure**: Headers, globals, utility functions first
2. **Use templates**: Adapt from Quick Reference section
3. **Batch similar operations**: Group config additions, use loops
4. **Minimize redundancy**: Extract repeated logic to functions
5. **Test assumptions**: Check file existence, tool availability, permissions

### When Modifying Existing Code
1. **Read minimal context**: Use grep_search for function locations
2. **Preserve patterns**: Match existing style exactly
3. **Update in batches**: Use multi_replace when possible
4. **Verify idempotency**: Ensure changes don't break re-runs
5. **Test return codes**: Ensure success/failure paths work

### Code Review Checklist
- [ ] Variables quoted: `"$var"`
- [ ] Arrays used (not strings): `arr+=()`
- [ ] Idempotency: Check before modify
- [ ] Backups: Before file changes
- [ ] Error handling: Return codes set
- [ ] Cross-platform: OS detection used
- [ ] Prompts: Contextual defaults
- [ ] Comments: Updated with code

---

## Repository-Specific Patterns

### Script Naming Conventions
- **Main scripts**: `action-noun.sh` (e.g., `system-setup.sh`, `ollama-screen.sh`)
- **Download helpers**: `_download-*-scripts.sh` (underscore prefix for utilities)
- **Action scripts**: `verb-noun.sh` (e.g., `start-k8s.sh`, `stop-lxc.sh`, `config-lxc-ssh.sh`)

### Script Organization by Directory
```
github/     - GitHub CLI automation (org copying, issue management)
kubernetes/ - K8s cluster management (start, stop, update repos)
lxc/        - LXC container operations (create, start, stop, config)
llm/        - LLM tools (Ollama management)
misc/       - Utility scripts (rsync, monitoring)
configs/    - Documentation for tool configurations
```

### Simple Scripts Pattern (No Color Output)
```bash
#!/bin/bash  # Note: Some use #!/bin/bash, not #!/usr/bin/env bash

# Simple echo for status
echo "Status message"

# Group commands in subshells for atomic execution
(
    set -x  # Show commands
    sudo command1
    sudo command2
)

# Use echo_internal for complex scripts
echo_internal() {
    printf "\n$1\n"
}
```

### Complex Scripts Pattern (Full Color Support)
```bash
#!/usr/bin/env bash
set -euo pipefail

# Full color constants
readonly BLUE='\033[0;34m'
readonly GREEN='\033[0;32m'
# ... (all colors)

# Structured output functions
print_info() { ... }
print_success() { ... }

# Global counters for reporting
TOTAL_REPOS_PROCESSED=0
TOTAL_WIKIS_COPIED=0
# ...

# Timing
START_TIME=$(date +%s)
END_TIME=$(date +%s)
```

### Environment Variable Configuration
```bash
# Document env vars in header comments
# Usage:
#   SRC_ORG="OldOrg" DST_ORG="NewOrg" ./script.sh
#   THROTTLE=2 ./script.sh

readonly VAR="${VAR:-default_value}"
readonly REQUIRED_VAR="${REQUIRED_VAR:-}"
[[ -z "$REQUIRED_VAR" ]] && print_error "VAR required" && exit 1
```

---

## Complete Function Templates

### Configuration Function
```bash
configure_component() {
    local os="$1"
    local scope="$2"  # "user" or "system"

    print_info "Configuring component..."

    local config_file
    if [[ "$scope" == "system" ]]; then
        config_file="/etc/component.conf"
        [[ ! -w "/etc" ]] && print_error "Requires root" && return 1
    else
        config_file="$HOME/.componentrc"
    fi

    [[ ! -f "$config_file" ]] && touch "$config_file"

    add_config_if_needed "component" "$config_file" "setting1" "value1" "Setting 1"
    add_config_if_needed "component" "$config_file" "setting2" "value2" "Setting 2"

    print_success "Component configured"
}
```

### Detection Function
```bash
detect_feature() {
    [[ -f /path/to/indicator ]] && return 0
    command -v feature_cmd &>/dev/null && return 0
    return 1
}
```

### Package Management
```bash
install_packages() {
    local os=$(detect_os)
    verify_package_manager "$os" || return 1

    local packages=("nano" "screen" "htop")
    for pkg in "${packages[@]}"; do
        if is_package_installed "$os" "$pkg"; then
            print_success "✓ $pkg already installed"
        else
            if prompt_yes_no "Install $pkg?" "y"; then
                if [[ "$os" == "macos" ]]; then
                    brew install "$pkg"
                else
                    sudo apt install -y "$pkg"
                fi
            fi
        fi
    done
}
```

---

**End of AI Agent Instructions**

*Optimized for LLM consumption. For human-readable documentation, see repository README and individual script comments.*
