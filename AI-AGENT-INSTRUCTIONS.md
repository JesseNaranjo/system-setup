# AI Agent Instructions for Bash Scripts

## Document Purpose
This document provides comprehensive patterns, styles, and conventions used across all bash scripts in this repository. Optimized for LLM consumption to enable rapid, accurate code generation and modification without requiring full source file analysis.

**Last Updated:** December 21, 2025
**Primary Reference:** system-setup.sh + utils.sh
**Secondary Reference:** _download-*-scripts.sh (standalone script pattern)
**Scope:** All `.sh` scripts in repository (modular, standalone, and lightweight)

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
2. [Script Architecture](#script-architecture)
3. [Script Structure](#script-structure)
4. [Modular Script Patterns](#modular-script-patterns)
5. [Bash Standards](#bash-standards)
6. [Function Patterns](#function-patterns)
7. [User Interaction](#user-interaction)
8. [Configuration Management](#configuration-management)
9. [Output & Logging](#output--logging)
10. [Cross-Platform Support](#cross-platform-support)
11. [Error Handling](#error-handling)
12. [File Modification](#file-modification)
13. [Security & Safety](#security--safety)
14. [Download & Self-Update Patterns](#download--self-update-patterns)

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

## Script Architecture

This repository uses two distinct script architectures. Choose based on context:

### 1. Modular Scripts (system-setup/)

**When to use:** Complex, multi-component scripts that share utilities.

**Structure:**
- Main orchestrator: `system-setup.sh`
- Shared utilities: `utils.sh` (colors, prompts, config functions, file operations)
- Feature modules: `system-modules/*.sh` (each handles one concern)
- Modules are sourced at runtime, not executed directly

**Key characteristics:**
- Source `utils.sh` for all shared functions
- Use `main_*` naming for module entry points (e.g., `main_configure_system`, `main_manage_packages`)
- Modules can be run standalone for testing but are designed to be sourced
- Global state shared via variables in `utils.sh`

### 2. Standalone Scripts (github/, kubernetes/, lxc/, llm/)

**When to use:** Self-contained scripts that must work when downloaded individually.

**Structure:**
- Each script is fully self-contained
- Duplicate essential functions inline (colors, `print_*`, `prompt_yes_no`)
- Managed by `_download-*-scripts.sh` updaters in each directory

**Key characteristics:**
- No external dependencies (except system tools)
- Include full color definitions and output functions
- Include `prompt_yes_no` if user interaction needed
- Can be copied/downloaded and run immediately

### Decision Guide

| Scenario | Architecture | Reason |
|----------|-------------|--------|
| New feature for system-setup | Modular | Add to existing module or create new one |
| New utility script in lxc/, k8s/, etc. | Standalone | Must work when downloaded individually |
| Shared helper used by multiple modules | Add to utils.sh | Centralized maintenance |
| One-off automation script | Standalone | Simpler, no dependencies |
| Simple system task (start/stop services) | Lightweight | Minimal overhead, quick execution |

### 3. Lightweight Scripts (kubernetes/, utils/)

**When to use:** Simple automation tasks that don't need user interaction or complex output.

**Structure:**
- Minimal or no error handling (`set -euo pipefail` optional)
- Basic `echo` output or simple `echo_internal()` helper
- Commands grouped in subshells with `set -x` for visibility

**Key characteristics:**
- No color output or structured logging
- No user prompts - runs non-interactively
- Often uses subshells `( set -x; command )` to show what's executing
- Quick, single-purpose scripts

**Example:**
```bash
#!/usr/bin/env bash

echo_internal() {
    printf "\n$1\n"
}

echo_internal "Turning off swap..."
(
    set -x
    sudo swapoff -a
)

echo_internal "Starting services..."
(
    set -x
    sudo systemctl start myservice.service
)
```

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

## Modular Script Patterns

### Shared Utilities (utils.sh)

The `utils.sh` file provides all shared functionality for the system-setup suite.

**Multiple-source guard:**
```bash
#!/usr/bin/env bash

# Prevent multiple sourcing
if [[ -n "${UTILS_SH_LOADED:-}" ]]; then
    return 0
fi
readonly UTILS_SH_LOADED=true

set -euo pipefail

# All shared constants, variables, and functions follow...
```

**Global variables provided by utils.sh:**
```bash
# State tracking arrays
BACKED_UP_FILES=()
CREATED_BACKUP_FILES=()
HEADER_ADDED_FILES=()

# Detection results (set by detect_* functions)
DETECTED_OS=""
RUNNING_IN_CONTAINER=false

# Package tracking
CURL_INSTALLED=false
FASTFETCH_INSTALLED=false
NANO_INSTALLED=false
SCREEN_INSTALLED=false
OPENSSH_SERVER_INSTALLED=false

# Package cache for performance
declare -A PACKAGE_CACHE=()
PACKAGE_CACHE_POPULATED=false

# Debug mode
DEBUG_MODE=false
```

### Module Script Template

Modules in `system-modules/` follow this pattern:

```bash
#!/usr/bin/env bash

# module-name.sh - Brief description
# Part of the system-setup suite
#
# This script:
# - Feature 1
# - Feature 2

# Get the directory where this script is located
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Source utilities
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Module Functions
# ============================================================================

helper_function() {
    # Internal helper
}

# ============================================================================
# Main Entry Point
# ============================================================================

# Use main_<module_name> naming convention
main_configure_component() {
    local scope="${1:-user}"

    # Ensure environment is detected
    detect_environment

    print_info "Configuring component..."
    # Module logic here
    print_success "Component configured"
}

# Run main function if script is executed directly (for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_component "$@"
fi
```

### Orchestrator Pattern (system-setup.sh)

The main script sources and orchestrates modules:

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utilities first
source "${SCRIPT_DIR}/utils.sh"

# Remote repository for self-update
readonly REMOTE_BASE="https://raw.githubusercontent.com/USER/REPO/refs/heads/main/path"

# List of module scripts to download/update
get_script_list() {
    echo "system-modules/module-a.sh"
    echo "system-modules/module-b.sh"
}

main() {
    # Self-update check first
    if detect_download_cmd; then
        if [[ ${scriptUpdated:-0} -eq 0 ]]; then
            self_update "$@"
        fi
        update_modules
    fi

    # Detect environment
    detect_os
    detect_container

    # Source and run modules as needed
    source "${SCRIPT_DIR}/system-modules/module-a.sh"
    main_module_a "$scope"

    source "${SCRIPT_DIR}/system-modules/module-b.sh"
    main_module_b "$scope"

    print_success "Setup complete!"
    print_session_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

### Environment Detection (Combined)

```bash
# Detect both OS and container environment in one call
# Sets global variables DETECTED_OS and RUNNING_IN_CONTAINER
detect_environment() {
    # Detect OS if not already detected
    if [[ -z "$DETECTED_OS" ]]; then
        detect_os
    fi

    # Detect container environment on Linux
    if [[ "$DETECTED_OS" == "linux" ]]; then
        detect_container
    fi
}
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

### Environment Variable Configuration
```bash
# Document env vars in header comments
# Usage:
#   SRC_ORG="OldOrg" DST_ORG="NewOrg" ./script.sh

# Optional with default
readonly VAR="${VAR:-default_value}"

# Required - validate early
readonly REQUIRED_VAR="${REQUIRED_VAR:-}"
[[ -z "$REQUIRED_VAR" ]] && print_error "REQUIRED_VAR is required" && exit 1
```

### Exit Codes (sysexits.h)
```bash
# Standard exit codes for better error reporting
exit 0   # EX_OK - Success
exit 1   # General error
exit 64  # EX_USAGE - Command line usage error
exit 65  # EX_DATAERR - Data format error
exit 66  # EX_NOINPUT - Cannot open input
exit 69  # EX_UNAVAILABLE - Service unavailable
exit 70  # EX_SOFTWARE - Internal software error
exit 73  # EX_CANTCREAT - Can't create output file
exit 74  # EX_IOERR - Input/output error
exit 77  # EX_NOPERM - Permission denied
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

**escape_regex** - Escape special regex characters:
```bash
escape_regex() {
    printf '%s' "$1" | sed 's/[.[\(*^$+?{|\\]/\\&/g'
}
```

**grep_file** - Privilege-aware grep:
```bash
# Grep a file with proper elevation handling
# Usage: grep_file [grep_options] <pattern> <file>
# Returns: grep exit status (0 if match found, 1 if no match)
# Note: The file must be the LAST argument, pattern second to last
grep_file() {
    local args=()
    local file=""
    local pattern=""

    # Parse arguments - all but last two are options, second to last is pattern, last is file
    while [[ $# -gt 2 ]]; do
        args+=("$1")
        shift
    done
    pattern="$1"
    file="$2"

    if needs_elevation "$file"; then
        run_elevated grep "${args[@]+"${args[@]}"}" "$pattern" "$file"
    else
        grep "${args[@]+"${args[@]}"}" "$pattern" "$file"
    fi
}
```

**config_exists** - Check if setting exists:
```bash
config_exists() {
    local file="$1"
    local pattern="$2"
    [[ -f "$file" ]] && grep_file -qE "^[[:space:]]*${pattern}" "$file"
}
```

**get_config_value** - Extract current value:
```bash
get_config_value() {
    local file="$1"
    local setting="$2"
    if [[ -f "$file" ]]; then
        grep_file -E "^[[:space:]]*${setting}" "$file" | head -n 1 | \
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

### File Management Functions

**get_file_permissions** - Cross-platform permission check:
```bash
get_file_permissions() {
    local file="$1"

    if [[ "$DETECTED_OS" == "macos" ]]; then
        stat -f "%Lp" "$file"  # macOS syntax
    else
        stat -c "%a" "$file"   # Linux syntax
    fi
}
```

**create_config_file** - Create file with permissions:
```bash
# Usage: create_config_file <path> [perms] [content]
#   path: file path (required)
#   perms: octal permissions like 644, 600 (default: 644)
#   content: optional content to write (if omitted, creates empty file)
create_config_file() {
    local file="$1"
    local perms="${2:-644}"
    local content="${3:-}"

    if [[ -f "$file" ]]; then
        # File exists - check permissions and warn if different
        local actual_perms=$(get_file_permissions "$file")
        if [[ "$actual_perms" != "$perms" ]]; then
            print_warning "$file exists with permissions $actual_perms (expected $perms)"
        fi
        return 0
    fi

    # File doesn't exist - create it
    if needs_elevation "$file"; then
        if [[ -n "$content" ]]; then
            echo "$content" | run_elevated tee "$file" > /dev/null
        else
            run_elevated touch "$file"
        fi
        run_elevated chmod "$perms" "$file"
    else
        if [[ -n "$content" ]]; then
            echo "$content" > "$file"
        else
            touch "$file"
        fi
        chmod "$perms" "$file"
    fi
}
```

**normalize_trailing_newlines** - Fix file endings:
```bash
# Ensure a file ends with exactly N blank lines (default: 1)
# Usage: normalize_trailing_newlines <file> [num_lines]
normalize_trailing_newlines() {
    local file="$1"
    local num_lines="${2:-1}"
    local temp_file=$(mktemp)

    # Remove all trailing blank lines (last content line keeps its newline)
    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$file" > "$temp_file"

    # Add (N-1) more newlines since the last line already ends with one
    for ((i=1; i<num_lines; i++)); do
        printf '\n' >> "$temp_file"
    done

    run_elevated mv "$temp_file" "$file"
}
```

### Package Tracking

**track_special_packages** - Track installed packages for later configuration:
```bash
track_special_packages() {
    local package="$1"

    if [[ "$package" == "curl" ]]; then
        CURL_INSTALLED=true
    elif [[ "$package" == "fastfetch" ]]; then
        FASTFETCH_INSTALLED=true
    elif [[ "$package" == "nano" ]]; then
        NANO_INSTALLED=true
    elif [[ "$package" == "screen" ]]; then
        SCREEN_INSTALLED=true
    elif [[ "$package" == "openssh-server" ]]; then
        OPENSSH_SERVER_INSTALLED=true
    fi
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
print_summary() { echo -e "${BLUE}[ SUMMARY ]${NC} $1"; }
```

### Warning Box Function
```bash
# Print a warning box with multiple lines of content
# Usage: print_warning_box "line1" "line2" "line3" ...
print_warning_box() {
    local box_width=77
    local padding=8
    local content_width=$((box_width - padding - 1))

    echo ""
    echo -e "            ${YELLOW}╔$(printf '═%.0s' $(seq 1 $box_width))╗${NC}"
    echo -e "            ${YELLOW}║$(printf ' %.0s' $(seq 1 $box_width))║${NC}"

    for line in "$@"; do
        local line_len=${#line}
        local right_pad=$((content_width - line_len))
        if [[ $right_pad -lt 0 ]]; then
            right_pad=0
            line="${line:0:$content_width}"
        fi
        printf -v padded_line "%-${content_width}s" "$line"
        echo -e "            ${YELLOW}║        ${padded_line}║${NC}"
    done

    echo -e "            ${YELLOW}║$(printf ' %.0s' $(seq 1 $box_width))║${NC}"
    echo -e "            ${YELLOW}╚$(printf '═%.0s' $(seq 1 $box_width))╝${NC}"
    echo ""
}
```

### Diff Display Pattern
```bash
# Show changes with colored borders
echo -e "${CYAN}╭────────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────╮${NC}"
diff -u --color "${LOCAL_FILE}" "${TEMP_FILE}" || true
echo -e "${CYAN}╰─────────────────────────── ${SCRIPT_FILE} ───────────────────────────────╯${NC}"
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

### Optional Visual Elements

These functions provide enhanced formatting for specific use cases. Not part of core utils.sh but useful patterns:

**print_section** - Bordered section header (for standalone scripts):
```bash
print_section() {
    echo -e "${CYAN}╭────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${CYAN}│${NC} $1"
    echo -e "${CYAN}╰────────────────────────────────────────────────────────────────────────╯${NC}"
}
```

**print_header** - Timestamped header with borders (for long-running scripts):
```bash
print_header() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}[$(date +'%H:%M:%S')] $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}
```

**print_step** - Indented step indicator:
```bash
print_step() {
    echo -e "${BLUE}  →${NC} $1"
}
```

**print_timestamp** - Gray timestamped log line:
```bash
print_timestamp() {
    local section="$1"
    echo -e "${GRAY}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} ${section}"
}
```

### Log File Pattern

For scripts that need persistent logging:
```bash
readonly LOG_FILE="${HOME}/.script-name.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Usage
log "Starting synchronization"
log "Error: $error_message"
```

---

## Cross-Platform Support

### OS Detection (Sets Global)
```bash
# Sets DETECTED_OS global variable (preferred for modular scripts)
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        DETECTED_OS="macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        DETECTED_OS="linux"
    else
        DETECTED_OS="unknown"
    fi
}
```

### Container Detection (Sets Global)
```bash
# Sets RUNNING_IN_CONTAINER global variable
detect_container() {
    # Check for LXC container via environment variable
    if [[ -f /proc/1/environ ]] && grep -qa container=lxc /proc/1/environ; then
        RUNNING_IN_CONTAINER=true
        return
    fi

    # Check for Docker container
    if [[ -f /.dockerenv ]]; then
        RUNNING_IN_CONTAINER=true
        return
    fi

    # Check for systemd container
    if [[ -f /run/systemd/container ]]; then
        RUNNING_IN_CONTAINER=true
        return
    fi

    # Check for LXC in cgroup
    if grep -q lxc /proc/1/cgroup 2>/dev/null; then
        RUNNING_IN_CONTAINER=true
        return
    fi

    RUNNING_IN_CONTAINER=false
}
```

### Privilege Management
```bash
# Check if we have necessary privileges for the operation
# Returns: 0 if privileges are sufficient, 1 otherwise
check_privileges() {
    local operation="$1"  # "package_install", "system_config", or "apt_operations"

    if [[ "$operation" == "package_install" ]]; then
        if [[ "$DETECTED_OS" == "linux" ]]; then
            # Linux requires root for apt
            if [[ $EUID -ne 0 ]]; then
                return 1
            fi
        fi
        # macOS doesn't need root for brew
    elif [[ "$operation" == "system_config" ]] || [[ "$operation" == "apt_operations" ]]; then
        # System-wide config and apt operations need root on Linux
        if [[ "$DETECTED_OS" == "linux" ]] && [[ $EUID -ne 0 ]]; then
            return 1
        fi
    fi
    return 0
}

# Run command with appropriate privileges (macOS sudo, Linux expects root)
run_elevated() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        if [[ "$DETECTED_OS" == "macos" ]]; then
            sudo "$@"
        else
            print_error "Insufficient privileges to run: $*"
            return 1
        fi
    fi
}

# Check if a file operation needs elevation (macOS-specific)
needs_elevation() {
    local file="$1"

    # If already root or running Linux (should already be root), no elevation needed
    if [[ $EUID -eq 0 ]] || [[ "$OSTYPE" == "linux"* ]]; then
        return 1
    fi

    # Check if file is in a system directory
    if [[ "$file" == /etc/* ]] || [[ "$file" == /usr/* ]] || [[ "$file" == /var/* ]]; then
        return 0
    fi

    # Check if parent directory requires elevated permissions
    local dir=$(dirname "$file")
    if [[ ! -w "$dir" ]]; then
        return 0
    fi

    return 1
}
```

### Package Cache (Performance Optimization)
```bash
# Use associative array for O(1) package lookups
declare -A PACKAGE_CACHE=()
PACKAGE_CACHE_POPULATED=false

# Populate the package cache with installed packages
populate_package_cache() {
    local package_list=()
    while read -r line; do
        package_list+=("${line##*:}")
    done < <(get_package_list)

    local installed_packages
    if [[ "$DETECTED_OS" == "macos" ]]; then
        installed_packages=$(brew list --formula -1 2>/dev/null || true)
    else
        installed_packages=$(dpkg -l 2>/dev/null | awk '/^ii/ {print $2}' || true)
    fi

    PACKAGE_CACHE=()
    for package in "${package_list[@]}"; do
        if echo "$installed_packages" | grep -qx "$package"; then
            PACKAGE_CACHE["$package"]="installed"
        else
            PACKAGE_CACHE["$package"]="not_installed"
        fi
    done

    PACKAGE_CACHE_POPULATED=true
}

# Check if a package is installed (uses cache)
is_package_installed() {
    local package="$1"

    # Populate cache if not yet populated
    if [[ "$PACKAGE_CACHE_POPULATED" != "true" ]]; then
        populate_package_cache
    fi

    # Check cache first
    if [[ -n "${PACKAGE_CACHE[$package]:-}" ]]; then
        [[ "${PACKAGE_CACHE[$package]}" == "installed" ]]
        return $?
    fi

    # Fallback to direct check if not in cache
    if [[ "$DETECTED_OS" == "macos" ]]; then
        brew list "$package" &>/dev/null
    else
        dpkg -l "$package" 2>/dev/null | grep -q "^ii"
    fi
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
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S).bak"
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

## Download & Self-Update Patterns

These patterns are used in `_download-*-scripts.sh` files and the main `system-setup.sh` orchestrator.

### Download Command Detection
```bash
# Detect available download command (curl or wget)
# Sets global DOWNLOAD_CMD variable
detect_download_cmd() {
    if command -v curl &>/dev/null; then
        DOWNLOAD_CMD="curl"
        return 0
    elif command -v wget &>/dev/null; then
        DOWNLOAD_CMD="wget"
        return 0
    else
        DOWNLOAD_CMD=""
        # Display warning box if neither is available
        print_warning_box \
            "⚠️   UPDATES NOT AVAILABLE  ⚠️" \
            "" \
            "Neither 'curl' nor 'wget' is installed on this system." \
            "Self-updating functionality requires one of these tools." \
            "" \
            "To enable self-updating, please install one of the following:" \
            "  • curl  (recommended)" \
            "  • wget" \
            "" \
            "Installation commands:" \
            "  macOS:    brew install curl" \
            "  Debian:   apt install curl" \
            "  RHEL:     yum install curl" \
            "" \
            "Continuing with local version of the scripts..."
        return 1
    fi
}
```

### Download Script Function
```bash
# Download a script file from the remote repository
# Args: $1 = script filename (relative path), $2 = output file path
# Returns: 0 on success, 1 on failure
download_script() {
    local script_file="$1"
    local output_file="$2"
    local http_status=""

    print_info "Fetching ${script_file}..."
    echo "            ▶ ${REMOTE_BASE}/${script_file}..."

    if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
        http_status=$(curl -H 'Cache-Control: no-cache, no-store' -o "${output_file}" -w "%{http_code}" -fsSL "${REMOTE_BASE}/${script_file}" 2>/dev/null || echo "000")
        if [[ "$http_status" == "200" ]]; then
            # Validate that we got a script, not an error page
            # Check first 10 lines for shebang to handle files with leading comments
            if head -n 10 "${output_file}" | grep -q "^#!/"; then
                return 0
            else
                print_error "✖ Invalid content received (not a script)"
                return 1
            fi
        elif [[ "$http_status" == "429" ]]; then
            print_error "✖ Rate limited by GitHub (HTTP 429)"
            return 1
        elif [[ "$http_status" != "000" ]]; then
            print_error "✖ HTTP ${http_status} error"
            return 1
        else
            print_error "✖ Download failed"
            return 1
        fi
    elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
        if wget --no-cache --no-cookies -O "${output_file}" -q "${REMOTE_BASE}/${script_file}" 2>/dev/null; then
            # Validate that we got a script
            if head -n 10 "${output_file}" | grep -q "^#!/"; then
                return 0
            else
                print_error "✖ Invalid content received (not a script)"
                return 1
            fi
        else
            print_error "✖ Download failed"
            return 1
        fi
    fi

    return 1
}
```

### Self-Update Function
```bash
# Check for updates to the main script itself
# Will restart the script if updated
self_update() {
    local SCRIPT_FILE="$(basename "${BASH_SOURCE[0]}")"
    local LOCAL_SCRIPT="${BASH_SOURCE[0]}"
    local TEMP_SCRIPT="$(mktemp)"

    if ! download_script "${SCRIPT_FILE}" "${TEMP_SCRIPT}"; then
        rm -f "${TEMP_SCRIPT}"
        echo ""
        return 1
    fi

    # Compare and handle differences
    if diff -u "${LOCAL_SCRIPT}" "${TEMP_SCRIPT}" > /dev/null 2>&1; then
        print_success "- ${SCRIPT_FILE} is already up-to-date"
        rm -f "${TEMP_SCRIPT}"
        echo ""
        return 0
    fi

    # Show diff with colored borders
    echo ""
    echo -e "${CYAN}╭───────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────╮${NC}"
    diff -u --color "${LOCAL_SCRIPT}" "${TEMP_SCRIPT}" || true
    echo -e "${CYAN}╰───────────────────────── ${SCRIPT_FILE} ─────────────────────────────╯${NC}"
    echo ""

    if prompt_yes_no "→ Overwrite and restart with updated ${SCRIPT_FILE}?" "y"; then
        echo ""
        chmod +x "${TEMP_SCRIPT}"
        mv -f "${TEMP_SCRIPT}" "${LOCAL_SCRIPT}"
        print_success "✓ Updated ${SCRIPT_FILE} - restarting..."
        echo ""
        export scriptUpdated=1
        exec "${LOCAL_SCRIPT}" "$@"
        exit 0
    else
        print_warning "⚠ Skipped ${SCRIPT_FILE} update - continuing with local version"
        rm -f "${TEMP_SCRIPT}"
    fi
    echo ""
}
```

### Module Update Function
```bash
# Update all module scripts
# Downloads each module and prompts user to replace if different
update_modules() {
    local uptodate_count=0
    local updated_count=0
    local skipped_count=0
    local failed_count=0

    print_info "Checking for module updates..."
    echo ""

    while IFS= read -r script_path; do
        local SCRIPT_FILE="$script_path"
        local LOCAL_SCRIPT="${SCRIPT_DIR}/${SCRIPT_FILE}"
        local TEMP_SCRIPT="$(mktemp)"

        # Ensure the local directory exists
        local script_dir="$(dirname "$LOCAL_SCRIPT")"
        mkdir -p "$script_dir"

        if ! download_script "${SCRIPT_FILE}" "${TEMP_SCRIPT}"; then
            echo "            (skipping ${SCRIPT_FILE})"
            ((failed_count++)) || true
            rm -f "${TEMP_SCRIPT}"
            echo ""
            continue
        fi

        # Create file if it doesn't exist
        if [[ ! -f "${LOCAL_SCRIPT}" ]]; then
            touch "${LOCAL_SCRIPT}"
        fi

        # Compare and handle differences
        if diff -u "${LOCAL_SCRIPT}" "${TEMP_SCRIPT}" > /dev/null 2>&1; then
            print_success "- ${SCRIPT_FILE} is already up-to-date"
            ((uptodate_count++)) || true
            rm -f "${TEMP_SCRIPT}"
            echo ""
        else
            echo ""
            echo -e "${CYAN}╭────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────╮${NC}"
            diff -u --color "${LOCAL_SCRIPT}" "${TEMP_SCRIPT}" || true
            echo -e "${CYAN}╰────────────────────── ${SCRIPT_FILE} ───────────────────────╯${NC}"
            echo ""

            if prompt_yes_no "→ Overwrite local ${SCRIPT_FILE} with remote copy?" "y"; then
                echo ""
                chmod +x "${TEMP_SCRIPT}"
                mv -f "${TEMP_SCRIPT}" "${LOCAL_SCRIPT}"
                print_success "✓ Replaced ${SCRIPT_FILE}"
                ((updated_count++)) || true
            else
                print_warning "⚠ Skipped ${SCRIPT_FILE}"
                ((skipped_count++)) || true
                rm -f "${TEMP_SCRIPT}"
            fi
            echo ""
        fi
    done < <(get_script_list)

    # Display final statistics
    echo ""
    echo "============================================================================"
    print_info "Module Update Summary"
    echo "============================================================================"
    echo -e "${BLUE}Up-to-date:${NC}  ${uptodate_count} file(s)"
    echo -e "${GREEN}Updated:${NC}     ${updated_count} file(s)"
    echo -e "${YELLOW}Skipped:${NC}     ${skipped_count} file(s)"
    echo -e "${RED}Failed:${NC}      ${failed_count} file(s)"
    echo "============================================================================"
    echo ""

    if [[ $failed_count -gt 0 ]]; then
        return 1
    fi
}
```

### Script List and Obsolete Cleanup
```bash
# List of module scripts to download/update
get_script_list() {
    echo "script-a.sh"
    echo "script-b.sh"
    echo "subdir/script-c.sh"
}

# List of obsolete scripts to clean up (renamed or removed from repository)
OBSOLETE_SCRIPTS=(
    "old-script-name.sh"  # renamed to new-script-name.sh
)

# Clean up obsolete scripts
# Usage: cleanup_obsolete_scripts "${OBSOLETE_SCRIPTS[@]+"${OBSOLETE_SCRIPTS[@]}"}"
cleanup_obsolete_scripts() {
    # Safely handle empty argument list
    for obsolete_script in "${@+"$@"}"; do
        local script_path="${SCRIPT_DIR}/${obsolete_script}"
        if [[ -f "${script_path}" ]]; then
            echo -e "${RED}[ CLEANUP ]${NC} Found obsolete script: ${obsolete_script}"
            if prompt_yes_no "            → Delete ${obsolete_script}?" "n"; then
                rm -f "${script_path}"
                print_success "✓ Deleted ${obsolete_script}"
            else
                print_warning "⚠ Kept ${obsolete_script}"
            fi
        fi
    done
}
```

### Complete Download Script Template

Use this template for `_download-*-scripts.sh` files:

```bash
#!/usr/bin/env bash

# _download-DOMAIN-scripts.sh - DOMAIN Script Management and Auto-Updater
#
# Usage: ./_download-DOMAIN-scripts.sh
#
# This script:
# - Self-updates from the remote repository before running
# - Downloads the latest versions of all DOMAIN management scripts
# - Shows diffs for changed files before updating
# - Prompts for confirmation before overwriting local files

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly CYAN="\033[0;36m"
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Remote repository configuration
readonly REMOTE_BASE="https://raw.githubusercontent.com/USER/REPO/refs/heads/main/DOMAIN"

# List of script files to download/update
get_script_list() {
    echo "script-a.sh"
    echo "script-b.sh"
}

# List of obsolete scripts to clean up
OBSOLETE_SCRIPTS=()

# Include: print_info, print_success, print_warning, print_error
# Include: prompt_yes_no
# Include: detect_download_cmd (with print_warning_box inline or simplified)
# Include: download_script
# Include: cleanup_obsolete_scripts
# Include: self_update
# Include: update_modules

# Main execution
if detect_download_cmd; then
    if [[ ${scriptUpdated:-0} -eq 0 ]]; then
        self_update "$@"
    fi
    update_modules
    cleanup_obsolete_scripts "${OBSOLETE_SCRIPTS[@]+"${OBSOLETE_SCRIPTS[@]}"}"
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
system-setup/         - Main system configuration suite (modular)
    system-modules/   - Feature modules (sourced, not run directly)
    utils.sh          - Shared utilities for all modules
    system-setup.sh   - Main orchestrator script
github/               - GitHub CLI automation (org copying, issue management)
kubernetes/           - K8s cluster management (start, stop, update repos)
lxc/                  - LXC container operations (create, start, stop, config)
llm/                  - LLM tools (Ollama management)
utils/                - Cross-platform utility scripts (rsync, monitoring, macOS display reset)
configs/              - Documentation for tool configurations (markdown)
walkthroughs/         - Step-by-step guides (debian-f2fs, macOS external monitor fixes)
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

### Session Summary Function
```bash
# Print a summary of all changes made during the session
print_session_summary() {
    if [[ ${#BACKED_UP_FILES[@]} -eq 0 && ${#CREATED_BACKUP_FILES[@]} -eq 0 ]]; then
        echo -e "            ${GRAY}No files were modified during this session.${NC}"
        return
    fi

    print_summary "─── Session ─────────────────────────────────────────────────────────────"
    echo ""

    if [[ ${#BACKED_UP_FILES[@]} -gt 0 ]]; then
        print_success "${GREEN}Files Updated:${NC}"
        for file in "${BACKED_UP_FILES[@]+"${BACKED_UP_FILES[@]}"}" ; do
            echo "            - $file"
        done
        echo ""
    fi

    if [[ ${#CREATED_BACKUP_FILES[@]} -gt 0 ]]; then
        print_backup "Backup Files:"
        for file in "${CREATED_BACKUP_FILES[@]+"${CREATED_BACKUP_FILES[@]}"}" ; do
            echo "            - $file"
        done
        echo ""
    fi
    print_summary "─────────────────────────────────────────────────────────────────────"
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
                    sudo apt install "$pkg"
                fi
            fi
        fi
    done
}
```

---

**End of AI Agent Instructions**

*Optimized for LLM consumption. For human-readable documentation, see repository README and individual script comments.*
