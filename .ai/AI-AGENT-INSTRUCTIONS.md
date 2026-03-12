# AI Agent Instructions

<!-- DRIFT GUARD — Do not remove the audience line below. -->
> **Audience: AI coding agents only.** This file is written for LLM-based coding assistants (Claude Code, GitHub Copilot, etc.), not human developers. You MUST follow these guidelines. It assumes you already know general programming principles (SOLID, DRY, YAGNI, etc.) and focuses on project-specific conventions.

> **Sync note:** [CLAUDE.md](../CLAUDE.md) and [.github/copilot-instructions.md](../.github/copilot-instructions.md) are minimal pointer files that reference this document. They must stay in sync with each other.

Personal system configuration repository with bash scripts for setting up Linux and macOS systems. Modular architecture with package management, system configuration, LXC containers, Kubernetes setup, and utilities.

## Table of Contents

**Understanding the system**
- [Design Principles](#design-principles)
- [Key Patterns & Conventions](#key-patterns--conventions)
- [Script Architecture](#script-architecture)
- [Important Implementation Notes](#important-implementation-notes)

**Development lifecycle**
- [Script Structure](#script-structure)
- [Modular Script Patterns](#modular-script-patterns)
- [Adding a New Module Script](#adding-a-new-module-script)
- [Quick Reference for LLMs](#quick-reference-for-llms)
- [Complete Function Templates](#complete-function-templates)

**Subsystem references**
- [Configuration Management](#configuration-management)
- [User Interaction](#user-interaction)
- [Output & Logging](#output--logging)
- [Cross-Platform Support](#cross-platform-support)
- [Error Handling](#error-handling)
- [File Modification](#file-modification)
- [Security & Safety](#security--safety)
- [Download & Self-Update Patterns](#download--self-update-patterns)

**Documentation**
- [Folder Documentation](#folder-documentation)
- [README Content Standards](#readme-content-standards)

**Operational**
- [Git Worktrees](#git-worktrees)
- [Running the Scripts](#running-the-scripts)
- [LLM Optimization Guidelines](#llm-optimization-guidelines)

---

## Design Principles

These principles guide all code changes. You know the general definitions — below are the project-specific applications only.

- **Idempotency**: Check state before changes, skip if already correct. Project pattern: `config_exists` + `get_config_value` before any modification.
- **Safety**: Backup files before modification, comment old configs (NEVER delete). `set -euo pipefail` at every script top.
- **Clarity**: Prefer explicit, well-named functions over aliases or abbreviations. Function names MUST describe what they do. Variable names MUST be descriptive.
- **Consistency**: Match existing patterns exactly. Same output functions, same guard patterns, same naming conventions. Avoid maintaining multiple ways to accomplish the same task.
- **KISS**: No one-time abstractions. Three similar lines beats a premature abstraction. Minimum complexity for the current task.
- **DRY**: Single source of truth over duplicated expressions — even for small things like threshold values or format strings.
- **Platform Independence**: Detect OS (macOS/Linux) and adapt. Handle both brew and apt. Detect container environments (Docker, LXC).
- **YAGNI**: Do NOT add speculative features or defensive code for impossible scenarios. Placeholder features are removed rather than maintained.

### DRY: When to Extract

Apply the DRY principle when code duplication creates maintenance risk. Extract shared code when:

#### When to Extract

1. **Sensitive Logic** - Code that is delicate, complex, or where bugs would have serious consequences
   ```bash
   # Backup with ownership preservation - used by multiple modules
   backup_file() {
       local file="$1"
       [[ ! -f "$file" ]] && return 0

       local backup="${file}.backup.$(date +%Y%m%d_%H%M%S).bak"
       cp -p "$file" "$backup"

       # Preserve ownership (platform-specific)
       if [[ "$OSTYPE" == "darwin"* ]]; then
           local owner=$(stat -f "%u:%g" "$file")
       else
           local owner=$(stat -c "%u:%g" "$file")
       fi
       chown "$owner" "$backup" 2>/dev/null || true
   }
   ```

2. **Multi-Step Operations** - Sequences of 3+ statements that perform a cohesive action
   ```bash
   # Idempotent config update - 3+ steps that belong together
   add_config_if_needed() {
       local file="$1" setting="$2" value="$3"

       # Step 1: Check if already correct
       config_exists "$file" "$setting" && \
           [[ "$(get_config_value "$file" "$setting")" == "$value" ]] && return 0

       # Step 2: Backup before modifying
       backup_file "$file"

       # Step 3: Add change header
       add_change_header "$file" "config"

       # Step 4: Apply change
       echo "${setting} ${value}" >> "$file"
   }
   ```

3. **Business Rules** - Logic encoding domain rules that may change
   ```bash
   # Container detection - rules may change as new container types emerge
   detect_container() {
       [[ -f /proc/1/environ ]] && grep -qa container=lxc /proc/1/environ && return 0
       [[ -f /.dockerenv ]] && return 0
       [[ -f /run/systemd/container ]] && return 0
       grep -q lxc /proc/1/cgroup 2>/dev/null && return 0
       return 1
   }
   ```

4. **Configuration Patterns** - Repeated setup/configuration code
   ```bash
   # Color constants - extracted because used everywhere
   readonly BLUE='\033[0;34m'
   readonly GREEN='\033[0;32m'
   readonly RED='\033[0;31m'
   readonly NC='\033[0m'

   # Output functions - extracted because pattern repeats
   print_info()    { echo -e "${BLUE}[ INFO    ]${NC} $1"; }
   print_success() { echo -e "${GREEN}[ SUCCESS ]${NC} $1"; }
   print_error()   { echo -e "${RED}[ ERROR   ]${NC} $1"; }
   ```

#### When NOT to Extract

- **Coincidentally Similar Code** - Code that looks the same but serves different purposes and may evolve independently
- **Simple One-Liners** - Trivial operations where extraction adds indirection without value
- **Single Use** - Code used in only one place (wait for the second use case)

#### Extraction Strategies

| Scenario | Strategy |
|----------|----------|
| Same script | Private function (defined before use) |
| Same directory/suite | Source shared `utils-sys.sh` |
| Cross-repository | Standalone script with inline functions |
| Configuration | Constants at script top with `readonly` |

### No Dead Code or Backwards-Compatibility Shims

- **Remove, don't comment out.** Dead code, unused functions, and unreferenced variables MUST be deleted. Git history preserves anything that needs to be recovered.
- **Breaking changes over compatibility layers.** NEVER add backwards-compatibility code or legacy fallbacks unless the user explicitly requests it.
- **Exception: Config file modifications.** The comment-then-add pattern (commenting out old values with `# Replaced` annotation) is the intended convention for system config files, not dead code. This preserves a rollback path for system configuration changes that could break the user's environment.

### No Simple Wrapper Functions

A "simple wrapper" is a function whose only job is to call one other function/command — it renames, re-exports, or forwards arguments without adding logic.

- **Do NOT create them.** Call the underlying command directly at each call site.
- **Inline existing ones when found.**

**Not simple wrappers** (justified):
- Functions that add error handling, guards, or availability checks (e.g., `command -v` before use)
- Functions that add cross-platform branching (macOS vs Linux)
- Functions that enforce idempotency (check-before-modify pattern)
- Functions that add user interaction (prompts, confirmations)

### Architecture Decisions

Intentional patterns that may appear redundant but serve specific purposes:

1. **Per-Session Tracking Arrays** (`BACKED_UP_FILES`, `CREATED_BACKUP_FILES`): Track which files have been backed up/modified during the current session to prevent duplicate backups and headers. Do NOT simplify to boolean flags — the arrays are used for the session summary report.
2. **Comment-Then-Add Pattern**: Old config values are commented out rather than overwritten. This is deliberate safety — users can see what changed and manually revert if a configuration breaks their system.
3. **utils-sys.sh Multiple-Source Guard**: The `UTILS_SYS_SH_LOADED` readonly flag prevents double-sourcing when multiple modules source utils-sys.sh. This is NOT redundant — without it, readonly variable re-declarations would cause fatal errors.

---

## Key Patterns & Conventions

Ordered from most universally applicable to most specialized.

### Critical Syntax Rules

```bash
# MUST quote ALL variables (security + correctness)
"$var" "${array[@]}"  # ✓ Correct
$var ${array[@]}      # ✖ NEVER

# MUST use arrays (not space-separated strings)
arr=() arr+=("item")  # ✓ Correct
str="" str="$str item" # ✖ NEVER

# MUST use [[ ]] not [ ]
[[ -f "$file" ]]      # ✓ Correct
[ -f "$file" ]        # ✖ NEVER

# MUST use $() not backticks
result=$(cmd)         # ✓ Correct
result=`cmd`          # ✖ NEVER

# MUST use set -euo pipefail
#!/usr/bin/env bash
set -euo pipefail     # ALWAYS at script top
```

#### Common Conditionals

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

#### Anti-Patterns

| ❌ NEVER | ✓ ALWAYS |
|---------|----------|
| `sed -i "/old/d" "$file"` | `sed -i "s/^old/# old  # Replaced/" "$file"` |
| `cp $file $backup` | `cp "$file" "$backup"` |
| `curl -O "$url"` | `command -v curl &>/dev/null && curl -O "$url"` |
| `config="/home/user/.rc"` | `config="$HOME/.rc"` |
| `echo "x=y" >> "$file"` | `config_exists "$file" "x" \|\| echo "x=y" >> "$file"` |
| `[ -f "$file" ]` | `[[ -f "$file" ]]` |
| `` result=`cmd` `` | `result=$(cmd)` |
| `str="$str item"` | `arr+=("item")` |

### Naming Conventions

#### Variables

```bash
readonly CONSTANT="value"  # Global constant
GLOBAL_VAR="value"         # Global variable
local local_var="value"    # Function local
local param1="$1"          # Function parameter
```

#### Variable Declaration with Assignment

```bash
# ALWAYS combine local declaration with initial assignment
local variable="initial_value"    # ✓ Correct
local config_file="/etc/myapp.conf"
local count=0

# Do NOT split declaration and assignment
local variable                    # ✖ NEVER
variable="initial_value"
```

#### Environment Variable Configuration

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

#### Script Naming

- **Main scripts**: `action-noun.sh` (e.g., `system-setup.sh`, `ollama-screen.sh`)
- **Download helpers**: `_download-*-scripts.sh` (underscore prefix for utilities)
- **Action scripts**: `verb-noun.sh` (e.g., `start-k8s.sh`, `stop-lxc.sh`, `config-lxc-ssh.sh`)

#### Exit Codes

```bash
# Functions: return 0 (success) or 1 (error)
# Standalone scripts: use sysexits.h for better error reporting
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

### Function Conventions

#### Standard Function Template

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

#### Function Call Patterns

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

#### Array Iteration

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

### Common Workflows

#### Idempotent Configuration Flow

1. Detect current state
2. Compare with desired state
3. Skip if matches (print success)
4. Backup if updating
5. Add header if first change
6. Comment old + add new
7. Report result

#### User Interaction Flow

1. Check current state
2. Explain action
3. Prompt (contextual default)
4. Execute
5. Confirm result

#### Scope-Based Configuration

1. Determine scope (user/system)
2. Set config file path
3. Check write permissions
4. Create file if missing
5. Apply settings
6. Preserve ownership

---

## Script Architecture

### Repository Overview

Personal system configuration repository containing bash scripts and documentation for setting up Linux and macOS systems. The scripts handle package management, system configuration, LXC container management, Kubernetes setup, and various utilities.

### Key Directories

| Directory | Type | Description |
|-----------|------|-------------|
| `system-setup/` | Modular | Main system configuration suite (the core of the repository) |
| `lxc/` | Standalone | LXC container management scripts |
| `kubernetes/` | Modular | Kubernetes cluster setup and configuration suite |
| `github/` | Standalone | GitHub CLI automation scripts |
| `llm/` | Standalone | Ollama/LLM management scripts |
| `utils/` | Standalone | Cross-platform utility scripts |
| `configs/` | Documentation | Configuration documentation (markdown) |
| `walkthroughs/` | Documentation | Step-by-step guides (markdown) |

This repository uses two distinct script architectures. Choose based on context:

### 1. Modular Scripts (system-setup/)

**When to use:** Complex, multi-component scripts that share utilities.

**Structure:**
- Main orchestrator: `system-setup.sh`
- Shared utilities: `utils-sys.sh` (colors, prompts, config functions, file operations)
- Feature modules: `system-modules/*.sh` (each handles one concern)
- Modules are sourced at runtime, not executed directly

**Key characteristics:**
- Source `utils-sys.sh` for all shared functions
- Use `main_*` naming for module entry points (e.g., `main_configure_system`, `main_manage_packages`)
- Modules can be run standalone for testing but are designed to be sourced
- Global state shared via variables in `utils-sys.sh`

### 2. Standalone Scripts (github/, lxc/, llm/)

**When to use:** Self-contained scripts that MUST work when downloaded individually.

**Structure:**
- Each script is fully self-contained
- Duplicate essential functions inline (colors, `print_*`, `prompt_yes_no`)
- Managed by `_download-*-scripts.sh` updaters in each directory

**Key characteristics:**
- No external dependencies (except system tools)
- Include full color definitions and output functions
- Include `prompt_yes_no` if user interaction needed
- Can be copied/downloaded and run immediately

### 3. Lightweight Scripts (utils/)

**When to use:** Simple automation tasks that don't need user interaction, complex output, or shared utilities.

**Structure:**
- Minimal or no error handling (`set -euo pipefail` optional)
- Basic `echo` output only
- No external dependencies (no sourcing of utils-*.sh)

**Key characteristics:**
- No color output or structured logging
- No user prompts - runs non-interactively
- Quick, single-purpose scripts

**Example:**
```bash
#!/usr/bin/env bash

while (true); do
    date +' %k:%M'
    upower -i /org/freedesktop/UPower/devices/battery_BAT1 | grep 'percentage'
    sleep 60s
done
```

### Decision Guide

| Scenario | Architecture | Reason |
|----------|-------------|--------|
| New feature for system-setup | Modular | Add to existing module or create new one |
| New utility script in lxc/, llm/, etc. | Standalone | Must work when downloaded individually |
| Shared helper used by multiple modules | Add to utils-sys.sh | Centralized maintenance |
| One-off automation script | Standalone | Simpler, no dependencies |
| Simple system task (start/stop services) | Standalone | Source utils for shared functions, run independently |

---

## Important Implementation Notes

1. **Source Guard Required**: All scripts MUST use the `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"` execution guard.
2. **utils-sys.sh Multiple-Source Guard**: Library uses `UTILS_SYS_SH_LOADED` to prevent double-sourcing. Do NOT remove this pattern.
3. **SCRIPT_DIR Pattern**: Module scripts MUST use the `SCRIPT_DIR` / `source` pattern to locate and load utils-sys.sh.
4. **Quote Everything**: All variable expansions MUST be quoted: `"$var"`, `"${array[@]}"`.
5. **Return Codes Only**: Functions return 0 (success) or 1 (error). No complex exit codes except sysexits.h for standalone scripts.
6. **Backup Before Modify**: The `backup_file` function tracks per-session to avoid duplicates. ALWAYS call before modifying a file.
7. **Comment, Don't Delete**: Old config values are commented out with `# Replaced` annotation, NEVER removed from config files.
8. **Platform Detection**: ALWAYS use `detect_os` / `detect_container` — NEVER hardcode paths or package managers.
9. **User Experience Defaults**: Default to "n" for destructive operations, "y" for safe operations. Continue script if non-critical components fail.

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
TMUX_INSTALLED=false
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

### Shared Utilities (utils-sys.sh)

The `utils-sys.sh` file provides all shared functionality for the system-setup suite.

**Multiple-source guard:**
```bash
#!/usr/bin/env bash

# Prevent multiple sourcing
if [[ -n "${UTILS_SYS_SH_LOADED:-}" ]]; then
    return 0
fi
readonly UTILS_SYS_SH_LOADED=true

set -euo pipefail

# All shared constants, variables, and functions follow...
```

**Global variables provided by utils-sys.sh:**
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
TMUX_INSTALLED=false
OPENSSH_SERVER_INSTALLED=false

# Package cache for performance
declare -A PACKAGE_CACHE=()
PACKAGE_CACHE_POPULATED=false

# Debug mode
DEBUG_MODE=false
```

### Module Script Template

Modules in `system-modules/` MUST follow this pattern:

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
# shellcheck source=utils-sys.sh
source "${SCRIPT_DIR}/utils-sys.sh"

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
source "${SCRIPT_DIR}/utils-sys.sh"

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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
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

    local packages=("nano" "tmux" "htop")
    for pkg in "${packages[@]}"; do
        if is_package_installed "$os" "$pkg"; then
            print_success "- $pkg already installed"
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
# Note: The file MUST be the LAST argument, pattern second to last
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
    local config_type="$1"  # "nano", "tmux", "shell"
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
    elif [[ "$package" == "tmux" ]]; then
        TMUX_INSTALLED=true
    elif [[ "$package" == "openssh-server" ]]; then
        OPENSSH_SERVER_INSTALLED=true
    fi
}
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

These functions provide enhanced formatting for specific use cases. Not part of core utils-sys.sh but useful patterns:

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
        echo "Nano:nano" "tmux:tmux"
    else
        echo "Nano:nano" "tmux:tmux" "OpenSSH:openssh-server"
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
    local config_type="$2"  # "nano", "tmux", "shell"
    local already_added=false

    for added_file in "${HEADER_ADDED_FILES[@]}"; do
        [[ "$added_file" == "$file" ]] && already_added=true && break
    done
    [[ "$already_added" == true ]] && return 0

    echo "" >> "$file"
    case "$config_type" in
        nano)   echo "# nano configuration - managed by script" >> "$file" ;;
        tmux)   echo "# tmux configuration - managed by system-setup.sh" >> "$file" ;;
        shell)  echo "# Shell configuration - managed by script" >> "$file" ;;
    esac
    echo "# Updated: $(date)" >> "$file"
    echo "" >> "$file"

    HEADER_ADDED_FILES+=("$file")
}
```

### Safe Edit Patterns
```bash
# Comment old, NEVER delete (macOS/Linux compatible)
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

## Folder Documentation

Each significant folder contains a `README.md` that documents its contents, patterns, and usage. **These READMEs are the source of truth for understanding each component.**

### Required Workflow

1. **Read Before Modifying** - Before making changes to any folder, read its README.md first
2. **Update After Changes** - When adding, removing, or significantly modifying files in a folder, update its README.md
3. **Current State Only** - READMEs document the current codebase, not historical or removed code. Remove documentation for deleted features.

### README Locations

✅ = exists, ❌ = needs creation

#### Script Directories

| Path | Documents | Status |
|------|-----------|--------|
| `README.md` | Repository overview | ✅ |
| `github/README.md` | GitHub CLI automation scripts | ✅ |
| `kubernetes/README.md` | Kubernetes cluster scripts | ✅ |
| `llm/README.md` | Ollama/LLM management scripts | ✅ |
| `lxc/README.md` | LXC container management scripts | ✅ |
| `system-setup/README.md` | Main system setup suite | ✅ |
| `system-setup/system-modules/README.md` | Module scripts documentation | ✅ |
| `git/README.md` | Git-related scripts | ❌ |
| `raspberry-pi/README.md` | Raspberry Pi setup scripts | ❌ |
| `utils/README.md` | Cross-platform utilities | ❌ |

#### Documentation Folders

| Path | Documents | Status |
|------|-----------|--------|
| `.ai/AI-AGENT-INSTRUCTIONS.md` | LLM coding standards (this document) | ✅ |
| `configs/README.md` | Configuration documentation files | ❌ |
| `walkthroughs/README.md` | Step-by-step guides | ❌ |

### README Maintenance Rules

When modifying code:

- **Adding a file**: Add an entry describing the file's purpose to the folder's README
- **Removing a file**: Remove the file's documentation from the README
- **Renaming a file**: Update the README to reflect the new name
- **Changing behavior**: Update the README to describe current behavior
- **Adding a folder**: Create a README.md in the new folder documenting its purpose

**NEVER document:**
- Removed or deprecated code
- Planned but unimplemented features
- Historical context (use git history for that)

### Code Comments

- Explain "why" not "what" in inline comments
- Keep comments up-to-date with code changes

---

## README Content Standards

Each folder type requires different documentation. Use these templates when creating or updating READMEs.

### Standard Section Order

All READMEs MUST follow this section order (omit sections that don't apply):

1. Title (H1)
2. Purpose/Overview (paragraph under title)
3. Features (if service root)
4. Structure (table of sub-folders/files)
5. Files (detailed file descriptions)
6. Key Concepts (if complex patterns)
7. Configuration (if applicable)
8. Usage (code examples)
9. Adding New [Items] (extension guide)

### Template: Script Directory

Use for: `lxc/`, `github/`, `llm/`, `utils/` - directories containing standalone scripts.

```markdown
# Directory Name

Brief description of what these scripts do.

## Scripts

| Script | Purpose |
|--------|---------|
| `script-a.sh` | What script-a does |
| `script-b.sh` | What script-b does |
| `_download-*.sh` | Auto-updater for this directory |

## Usage

\`\`\`bash
./script-a.sh [options]
\`\`\`

## Adding New Scripts

1. Create script following repository conventions (see AI-AGENT-INSTRUCTIONS.md)
2. Add to `get_script_list()` in the download script
3. Update this README
```

### Template: Module Suite

Use for: `system-setup/` - directories containing a main script with sourced modules.

```markdown
# Suite Name

Brief description of the suite and its purpose.

## Structure

| Component | Purpose |
|-----------|---------|
| `main.sh` | Orchestrator script |
| `utils-sys.sh` | Shared utilities |
| `modules/` | Feature modules |

## Running

\`\`\`bash
./main.sh           # Interactive mode
./main.sh --debug   # Debug mode
\`\`\`

## Modules

### module-a.sh
Description of what this module configures.

### module-b.sh
Description of what this module configures.

## Adding New Modules

1. Create module in `modules/` following existing patterns
2. Source `utils-sys.sh` for shared functions
3. Add `main_<module_name>()` entry point
4. Source and call from main script
5. Update this README
```

### Template: Documentation Folder

Use for: `configs/`, `walkthroughs/` - directories containing markdown documentation.

```markdown
# Folder Name

Brief description of what documentation this folder contains.

## Contents

| File | Topic |
|------|-------|
| `topic-a.md` | What topic-a covers |
| `topic-b.md` | What topic-b covers |

## Adding Documentation

1. Create markdown file with descriptive name
2. Follow existing format conventions
3. Update this README
```

---

## Git Worktrees

### Worktree Directory

Create worktrees in `.worktrees/<branch-name>/` relative to the repository root. This directory is gitignored.

### Required Files to Copy

| File/Folder | Purpose |
|-------------|---------|
| `.claude/` | Claude Code settings and session data |

### Quick Setup

```bash
cp -r .claude <worktree-path>/
```

### Files NOT to Copy

No generated/cached directories need copying — this project has no build step or dependency installation. If any temporary directories exist (`logs/`, `.cache/`, `tmp/`), they are created automatically when needed.

### Worktree Cleanup

ALWAYS delete the worktree **before** the branch:
```bash
git worktree remove --force .worktrees/<branch-name>
git branch -d <branch-name>
```

### Verification

Scripts are standalone bash — no install step needed. Verify with: `ls .worktrees/<branch-name>/system-setup/system-setup.sh`

---

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
sudo ./kubernetes-setup.sh  # Full orchestrated setup
./start-k8s.sh              # Start k8s services
./stop-k8s.sh               # Stop k8s services
```

### Script Naming Conventions
- **Main scripts**: `action-noun.sh` (e.g., `system-setup.sh`, `ollama-screen.sh`)
- **Download helpers**: `_download-*-scripts.sh` (underscore prefix for utilities)
- **Action scripts**: `verb-noun.sh` (e.g., `start-k8s.sh`, `stop-lxc.sh`, `config-lxc-ssh.sh`)

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

<!-- DRIFT GUARD — Do not remove this closing reminder. It reinforces the audience declaration at the top of this file. -->
> **Reminder:** This entire document is for AI coding agents, not human developers. If you are an AI agent editing this file, preserve the audience declaration and drift guard comments.
