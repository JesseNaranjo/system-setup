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
       [[ -f /proc/1/environ ]] && grep -qa container=lxc /proc/1/environ 2>/dev/null && return 0
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
   print_error()   { echo -e "${RED}[ ERROR   ]${NC} $1" >&2; if [[ -t 2 ]]; then printf '\a' >&2; sleep 2; fi; }
   print_info()    { echo -e "${BLUE}[ INFO    ]${NC} $1"; }
   print_success() { echo -e "${GREEN}[ SUCCESS ]${NC} $1"; }
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

**Bash subshell-capture gotcha.** A wrapper that mutates parent state (e.g., appending to a global array) and is also captured via `$()` runs in a subshell — the mutation never reaches the parent. Real example: `tmp=$(make_temp_file "$tpl")` where `make_temp_file` does both `mktemp` and `TEMP_FILES+=("$tmp")`. The `+=` lands in the subshell's array, so the EXIT-trap cleanup later iterates an empty parent array and the temp file leaks. Inline `mktemp` + `TEMP_FILES+=()` at the call site instead. See [Inline mktemp + TEMP_FILES](#inline-mktemp--temp_files) for the canonical replacement and [Defense-in-depth Cleanup](#defense-in-depth-cleanup) for the broader cleanup architecture.

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

#### Loop Variable Scoping

Declare loop variables with `local` before the loop — bash dynamic scoping will otherwise leak the variable into callers:

```bash
local item
for item in "${array[@]}"; do
    # ...
done

local line
while read -r line; do
    # ...
done < <(some_command)
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
local item
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
| `lxc/` | Modular Standalone | LXC container management scripts |
| `kubernetes/` | Modular | Kubernetes cluster setup and configuration suite |
| `github/` | Standalone | GitHub CLI automation scripts |
| `llm/` | Modular Standalone | Ollama/LLM management scripts |
| `utils/` | Standalone | Cross-platform utility scripts |
| `configs/` | Documentation | Configuration documentation (markdown) |
| `walkthroughs/` | Documentation | Step-by-step guides (markdown) |

This repository uses several script architectures. Choose based on context:

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

### 2. Standalone Scripts (github/)

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

### 3. Modular Standalone Scripts (lxc/, llm/)

**When to use:** Scripts managed by a `_download-*-scripts.sh` updater that share utilities within their directory.

**Structure:**
- Shared utilities: `utils-lxc.sh` / `utils-llm.sh` (colors, prompts, self-update functions)
- Each script sources its directory's utils file
- Managed by `_download-*-scripts.sh` updaters
- Self-update when run directly via `check_for_updates()`

**Key characteristics:**
- Require `utils-*.sh` in the same directory (downloaded by `_download-*-scripts.sh`)
- Source guard pattern: only self-update when executed directly, not when sourced
- Share output functions, prompts, and download infrastructure via utils

### 4. Lightweight Scripts (utils/)

**When to use:** Simple automation tasks that don't need user interaction, complex output, or shared utilities.

**Structure:**
- Minimal or no error handling (`set -euo pipefail` optional)
- Basic `echo` output only
- No external dependencies (no sourcing of utils-*.sh)

**Key characteristics:**
- No color output or structured logging
- No user prompts - runs non-interactively
- Quick, single-purpose scripts

**Exception:** `tools-update.sh` uses Standalone Script patterns (colors, `print_*` functions,
user prompts, self-update mechanism) because it needs interactive self-update and structured output.
New complex scripts in `utils/` should follow Standalone conventions if they need these capabilities.

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
| New utility script in lxc/, llm/ | Modular Standalone | Source utils-*.sh, self-update via check_for_updates |
| Shared helper used by multiple modules | Add to utils-sys.sh | Centralized maintenance |
| One-off automation script | Standalone | Simpler, no dependencies |
| Simple system task (start/stop services) | Standalone | Source utils for shared functions, run independently |

### Helper Library Duplication (Intentional)

The canonical helper functions — `download_script`, `prompt_yes_no`, `print_error`, `print_success`, `print_warning`, `cleanup`, `sweep_stale_temps`, `show_diff_box` — are **deliberately duplicated** across:

- `system-setup/utils-sys.sh`
- `kubernetes/utils-k8s.sh`
- `lxc/utils-lxc.sh`
- `llm/utils-llm.sh`
- `utils/services-check.sh` (defined inline; standalone)
- `github/gh_org_copy.sh`, `github/gh_org_delete_repos.sh`, `github/gh_org_delete_issues.sh` (defined inline; standalones)

**This is INTENTIONAL.** The suite-isolation architecture requires every directory to be independently downloadable: a user pulling `lxc/script.sh` must get a working script without also fetching `system-setup/utils-sys.sh`. The `github/gh_org_*.sh` standalones go further — they MUST work as a single-file copy/paste with zero external dependencies.

**Rules:**

- **Do NOT extract these helpers to a single shared library.** That would break the standalone invariant the `github/` scripts depend on and the suite-isolation invariant the per-directory `_download-*-scripts.sh` flows depend on.
- When fixing a bug or adjusting behavior in one of these helpers, **update every copy in the same change**. The pattern letters (A–J) used in the self-update backport plans exist precisely so cross-copy parity can be audited mechanically.
- Drift between copies is managed by **careful code review**, not tooling. Every PR that touches one helper must justify why the others were or were not also touched.

When adding a NEW helper that is genuinely shared logic (not an existing canonical helper), prefer adding it to the per-suite utils file rather than promoting to a new shared library.

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
# Detection results (set by detect_* functions)
DETECTED_OS=""
DETECTED_PKG_MANAGER=""
RUNNING_IN_CONTAINER=false

# State tracking arrays
BACKED_UP_FILES=()
CREATED_BACKUP_FILES=()
CREATED_CONFIG_FILES=()
HEADER_ADDED_FILES=()
TEMP_FILES=()

# Package tracking via associative array
declare -A SPECIAL_PACKAGE_FLAGS=(
    [curl]=CURL_INSTALLED
    [fastfetch]=FASTFETCH_INSTALLED
    [git]=GIT_INSTALLED
    [nano]=NANO_INSTALLED
    [tmux]=TMUX_INSTALLED
    [openssh-server]=OPENSSH_SERVER_INSTALLED
)
# Individual flags (set dynamically by track_special_packages)
CURL_INSTALLED=false
FASTFETCH_INSTALLED=false
GIT_INSTALLED=false
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

## Adding a New Module Script

Step-by-step recipe for adding a new module to the system-setup suite.

### 1. Create the Module File

Create `system-setup/system-modules/<module-name>.sh` using the [Module Script Template](#modular-script-patterns):

- Follow naming convention: `<verb-noun>.sh` or `<noun>.sh`
- Include SCRIPT_DIR pattern and `source utils-sys.sh`
- Name main function `main_<module_name>` (underscores, not hyphens)
- Add execution guard for standalone testing

### 2. Add Module Functions

```bash
main_configure_example() {
    local scope="${1:-user}"

    detect_environment

    local os="$DETECTED_OS"
    local config_file
    if [[ "$scope" == "system" ]]; then
        config_file="/etc/example.conf"
    else
        config_file="$HOME/.examplerc"
    fi

    # Check if already configured (idempotent)
    if config_exists "$config_file" "setting_name"; then
        local current_value
        current_value=$(get_config_value "$config_file" "setting_name")
        if [[ "$current_value" == "desired_value" ]]; then
            print_success "- Example already configured correctly"
            return 0
        fi
    fi

    # Prompt user
    if ! prompt_yes_no "Configure example?" "y"; then
        print_info "Skipped example configuration"
        return 0
    fi

    # Install package if needed
    if ! is_package_installed "example-pkg"; then
        print_info "+ Installing example-pkg..."
        if [[ "$os" == "macos" ]]; then
            brew install example-pkg
        else
            sudo apt install -y example-pkg
        fi
        invalidate_package_cache
    fi

    # Apply configuration
    backup_file "$config_file"
    add_change_header "$config_file" "example"
    add_config_if_needed "example" "$config_file" "setting_name" "desired_value" "Example setting"

    print_success "Example configured"
}
```

Key patterns used:
- `detect_environment` at the top
- `config_exists` + `get_config_value` for idempotency
- `prompt_yes_no` before changes
- `is_package_installed` (single argument) before installing
- `invalidate_package_cache` after installing
- `backup_file` + `add_change_header` before file modifications

### 3. Register in Orchestrator

In `system-setup/system-setup.sh`:

```bash
# Source the module (with conditional modules, add an if block)
source "${SCRIPT_DIR}/system-modules/configure-example.sh"

# Call the module's main function
main_configure_example "$scope"
```

Add the script path to `get_script_list()` for auto-update:

```bash
get_script_list() {
    # ... existing entries ...
    echo "system-modules/configure-example.sh"
}
```

### 4. Update Folder README

Add an entry to `system-setup/system-modules/README.md` with a description of what the module does.

### 5. Test Standalone

```bash
# Run the module directly
./system-setup/system-modules/configure-example.sh

# Verify idempotency: run twice, second run MUST skip all changes
./system-setup/system-modules/configure-example.sh
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

print_error()   { echo -e "${RED}[ ERROR   ]${NC} $1" >&2; if [[ -t 2 ]]; then printf '\a' >&2; sleep 2; fi; }
print_info()    { echo -e "${BLUE}[ INFO    ]${NC} $1"; }
print_success() { echo -e "${GREEN}[ SUCCESS ]${NC} $1"; }

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
    if [[ ${#BACKED_UP_FILES[@]} -eq 0 && ${#CREATED_BACKUP_FILES[@]} -eq 0 && ${#CREATED_CONFIG_FILES[@]} -eq 0 ]]; then
        echo -e "            ${GRAY}No files were modified during this session.${NC}"
        return
    fi

    print_summary "─── Session ─────────────────────────────────────────────────────────────"
    echo ""

    if [[ ${#CREATED_CONFIG_FILES[@]} -gt 0 ]]; then
        print_info "Files Created:"
        for file in "${CREATED_CONFIG_FILES[@]+"${CREATED_CONFIG_FILES[@]}"}"; do
            echo "            - $file"
        done
        echo ""
    fi

    if [[ ${#BACKED_UP_FILES[@]} -gt 0 ]]; then
        print_success "${GREEN}Files Updated:${NC}"
        for file in "${BACKED_UP_FILES[@]+"${BACKED_UP_FILES[@]}"}"; do
            echo "            - $file"
        done
        echo ""
    fi

    if [[ ${#CREATED_BACKUP_FILES[@]} -gt 0 ]]; then
        print_backup "Backup Files:"
        for file in "${CREATED_BACKUP_FILES[@]+"${CREATED_BACKUP_FILES[@]}"}"; do
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
        if is_package_installed "$pkg"; then
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
    printf '%s' "$1" | sed 's/[].[^$*+?{}|()\\[]/\\&/g'
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
        # Check if already set to desired value (escape for literal matching)
        local escaped_full_line=$(escape_regex "$full_line")
        if grep_file -qE "^[[:space:]]*${escaped_full_line}[[:space:]]*$" "$file"; then
            print_success "- $description already configured correctly"
            return 0
        fi
        backup_file "$file"
        add_change_header "$file" "$config_type"

        local temp_file=$(mktemp)
        local original_perms=$(get_file_permissions "$file")

        # Comment old line, append new at end of file
        awk -v pattern="^[[:space:]]*${setting_pattern}" -v new_line="${full_line}" '
            $0 ~ pattern {
                "date +%Y-%m-%d" | getline datestr;
                print "# " $0 " # Replaced by system-setup.sh on " datestr;
                next;
            }
            { print }
            END { print new_line }
        ' "$file" > "$temp_file" && mv "$temp_file" "$file"
        chmod "$original_perms" "$file"
    else
        backup_file "$file"
        add_change_header "$file" "$config_type"
        append_to_file "$file" "$full_line"
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

    local full_setting
    if [[ -n "$value" ]]; then
        full_setting="${setting} ${value}"
    else
        full_setting="${setting}"
    fi

    # Escape regex special characters in the setting for pattern matching
    local escaped_setting=$(escape_regex "$setting")

    # Handle shell "set" prefix separately for proper matching
    local setting_pattern
    if [[ $setting =~ ^[[:space:]]*set[[:space:]]+ ]]; then
        local setting_key=${setting#set }
        local escaped_key=$(escape_regex "$setting_key")
        setting_pattern="set[[:space:]]+${escaped_key}"
    else
        setting_pattern="${escaped_setting}"
    fi

    update_config_line "$config_type" "$file" "$setting_pattern" "$full_setting" "$description"
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

**add_git_config_if_needed** - Git config settings (uses `git config` directly, not file editing):
```bash
# Uses git config commands directly (handles INI format correctly)
# Usage: add_git_config_if_needed "scope" "key" "value" "description"
#   scope: "user" (--global) or "system" (--system)
add_git_config_if_needed() {
    local scope="$1"
    local key="$2"
    local value="$3"
    local description="$4"

    local git_scope_flag
    if [[ "$scope" == "system" ]]; then
        git_scope_flag="--system"
    else
        git_scope_flag="--global"
    fi

    local current_value
    current_value=$(git config "$git_scope_flag" --get "$key" 2>/dev/null || echo "")

    if [[ "$current_value" == "$value" ]]; then
        print_success "- $description already configured correctly"
        return 0
    fi

    if [[ -n "$current_value" ]]; then
        print_info "+ Updating $description ($current_value → $value)"
    else
        print_info "+ Setting $description"
    fi

    if [[ "$scope" == "system" ]]; then
        run_elevated git config --system "$key" "$value"
    else
        git config --global "$key" "$value"
    fi
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
    local original_perms
    original_perms=$(get_file_permissions "$file")
    # Pattern E3 (bookkeeping-only inline): the destination is a user-provided
    # config path (often /etc/...) reached via run_elevated, so atomic same-FS
    # rename is not the goal here — just cleanup-trap bookkeeping.
    local temp_file
    temp_file=$(mktemp)
    TEMP_FILES+=("$temp_file")

    # Remove all trailing blank lines (last content line keeps its newline)
    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$file" > "$temp_file"

    # Add (N-1) more newlines since the last line already ends with one
    for ((i=1; i<num_lines; i++)); do
        printf '\n' >> "$temp_file"
    done

    # Restore original permissions (mktemp creates files with 0600)
    if needs_elevation "$file"; then
        run_elevated mv "$temp_file" "$file"
        run_elevated chmod "$original_perms" "$file"
    else
        mv "$temp_file" "$file"
        chmod "$original_perms" "$file"
    fi
}
```

### Package Tracking

**track_special_packages** - Track installed packages for later configuration:
```bash
# Associative array mapping package names to their tracking flag variables
declare -A SPECIAL_PACKAGE_FLAGS=(
    [curl]=CURL_INSTALLED
    [fastfetch]=FASTFETCH_INSTALLED
    [git]=GIT_INSTALLED
    [nano]=NANO_INSTALLED
    [openssh-server]=OPENSSH_SERVER_INSTALLED
    [tmux]=TMUX_INSTALLED
)

track_special_packages() {
    local package="$1"
    local flag_name="${SPECIAL_PACKAGE_FLAGS[$package]:-}"
    if [[ -n "$flag_name" ]]; then
        printf -v "$flag_name" '%s' 'true'
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
    local prompt_suffix
    local user_reply

    # Non-TTY context (cron, systemd, ssh -T, CI): signal "no" rather than fall
    # through to the empty-reply branch and silently auto-accept the default.
    [[ -r /dev/tty ]] || return 1

    if [[ "${default,,}" == "y" ]]; then
        prompt_suffix="(Y/n)"
    else
        prompt_suffix="(y/N)"
    fi

    read -p "$prompt_message $prompt_suffix: " -r user_reply </dev/tty

    if [[ -z "$user_reply" ]]; then
        [[ "${default,,}" == "y" ]]
    else
        [[ $user_reply =~ ^[Yy]$ ]]
    fi
}
```

**`/dev/tty` guard requirement.** The `[[ -r /dev/tty ]] || return 1` line MUST appear after the `local` declarations and BEFORE any `read`. Without it, `read </dev/tty` fails under `set -e` in non-TTY contexts (cron, `systemd`, `ssh -T`, CI). When that failure happens inside an `if`-context, `set -e` is suppressed and `user_reply` stays empty — the script then falls through to the default branch and silently auto-accepts. For self-update prompts that means a cron job ships an unreviewed script change.

**Pattern B' — bare-`read` self-update prompts (github scripts).** The 3 `github/gh_org_*.sh` standalones use a bare `read -p ... </dev/tty` instead of `prompt_yes_no` for their self-update prompt because they want a single-keystroke `-n 1` UX. The same silent-auto-accept bug applies. Add the same guard immediately before the `read`, but `return 0` (not 1) because the github scripts can continue running with the unchanged local version after a skipped update:

```bash
# Non-TTY context (cron, systemd, ssh -T, CI): skip self-update rather than
# silently auto-accept via the empty-reply branch. Continue with the local
# version since the github scripts can run unchanged.
[[ -r /dev/tty ]] || { print_info "Non-interactive — skipping self-update"; rm -f "${TEMP_SCRIPT_FILE}"; return 0; }

read -p "→ Overwrite and restart with updated ${SCRIPT_FILE}? [Y/n] " -n 1 -r </dev/tty
if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
    # ... apply update ...
fi
```

Note the inline `rm -f "${TEMP_SCRIPT_FILE}"` on the non-TTY branch — the EXIT trap reaps on script exit, but a long-running standalone (e.g., iterating across many repos) keeps the temp visible in `$SCRIPT_DIR` until exit. See [Defense-in-depth Cleanup](#defense-in-depth-cleanup).

**Why `[[ -r /dev/tty ]]` for prompts but `{ : </dev/tty; } 2>/dev/null` for `sweep_stale_temps`?** `prompt_yes_no` is always called in `if` context, where `set -e` is suspended for the test command. Under cron / `ssh -T` / CI (the common non-TTY contexts), `/dev/tty` has no read permission for the calling user, so the guard fires and returns 1. Under `setsid` (rare — detaches the controlling TTY but leaves the device world-readable), the permissions check passes incorrectly; the subsequent `read </dev/tty` then fails with `set -e` suspended, the function falls through to the default branch, and the caller's `else` branch runs — same net behavior as the cron case **when the default is "n"**. Edge case: `setsid` + default "y" can still produce silent acceptance — see `docs/future-todos.md`. For `sweep_stale_temps`, the function is called as a statement (not in `if` context), so a failed `read </dev/tty` aborts the script under `set -e` — hence the open-probe gate.

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
print_backup()  { echo -e "${GRAY}[ BACKUP  ] $1${NC}"; }
print_debug()   { echo -e "${MAGENTA}[ DEBUG   ] $1${NC}"; }
print_error()   { echo -e "${RED}[ ERROR   ]${NC} $1" >&2; if [[ -t 2 ]]; then printf '\a' >&2; sleep 2; fi; }
print_info()    { echo -e "${BLUE}[ INFO    ]${NC} $1"; }
print_success() { echo -e "${GREEN}[ SUCCESS ]${NC} $1"; }
print_summary() { echo -e "${BLUE}[ SUMMARY ]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[ WARNING ]${NC} $1"; }
```

**Stream rules:**

- **`print_error` MUST write to stderr (`>&2`).** Errors must be separable from normal output so callers can pipe stdout to consumers (e.g., a watch loop or a logging sink) without mixing in error noise. Without `>&2`, callers that redirect `2>err.log >out.log` see errors swallowed into stdout and lose the distinction.
- **`print_warning` stays on stdout.** Warnings are informational — they describe degraded but non-fatal states (a missing optional tool, a config that defaulted to a fallback). They belong with the rest of the run narrative.
- **All other `print_*` helpers stay on stdout.** Only `print_error` is fd-2.
- **`print_error` MUST emit a terminal bell (`printf '\a' >&2`) and then `sleep 2`, both gated on `[[ -t 2 ]]`.** Errors are easily lost when subsequent output scrolls them off-screen; the bell pulls attention to the terminal and the pause keeps the message visible long enough to be read. Both effects are interactive-only — gating on `[[ -t 2 ]]` keeps CI / cron / `ssh -T` runs fast and prevents BEL bytes from polluting redirected logs. Use `if/fi` (not `&& { …; }`) so a non-TTY run still returns exit 0 and doesn't trip `set -euo pipefail` in the caller. Use `sleep 2` (not `sleep 2s`) — the unit suffix is a GNU coreutils extension and breaks on older BSD `sleep`.

**Caller-side glyph convention.** The function bodies above don't include glyphs — the `[ ERROR   ]`, `[ WARNING ]`, etc. tags identify the channel. The MEANING glyph is the caller's responsibility:

| Function | Glyph | When |
|----------|-------|------|
| `print_success` | `✓ ` | Action completed / state changed |
| `print_success` | `- ` | Already correct / no-op (idempotent skip) |
| `print_warning` | `⚠ ` | Non-fatal warning |
| `print_error` | `✖ ` | Fatal error |

Example:

```bash
print_success "✓ Configuration applied"
print_success "- Configuration already correct"
print_warning "⚠ Optional tool not found — falling back"
print_error   "✖ Permission denied"
```

Exceptions to the glyph requirement: decorative banners (`print_warning "═══..."`), multi-line continuations (`print_warning "  1. First..."`, `print_warning "  2. Second..."`), and completion summaries (`print_success "Setup complete!"`). See [Unicode Prefix Convention](#unicode-prefix-convention) below for the full rules.

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

Use the `show_diff_box` helper. It is defined once in every helper library (`utils-sys.sh`, `utils-k8s.sh`, `utils-lxc.sh`, `utils-llm.sh`) and inlined in every standalone (`services-check.sh`, `gh_org_*.sh`):

```bash
# Pretty-print a unified diff between two files inside a labeled box. Use
# `less` when stdout is a TTY (so multi-page diffs don't flood scrollback);
# fall back to inline output otherwise. `--color=always` forces ANSI even
# when piped to `less`; `-RFX` keeps less from clearing the screen.
show_diff_box() {
    local local_file="$1"
    local temp_file="$2"
    local label="$3"
    echo ""
    echo -e "${CYAN}╭────────────────────── Δ detected in ${label} ──────────────────────╮${NC}"
    if [[ -t 1 ]] && command -v less &>/dev/null; then
        diff -u --color=always "${local_file}" "${temp_file}" | less -RFX || true
    else
        diff -u --color=always "${local_file}" "${temp_file}" || true
    fi
    echo -e "${CYAN}╰─────────────────────────── ${label} ──────────────────────────────╯${NC}"
    echo ""
}
```

**Callsite:**

```bash
show_diff_box "${LOCAL_FILE}" "${TEMP_FILE}" "${SCRIPT_FILE}"
```

**Flag rationale:**

- **`--color=always` (NOT `--color` alone).** `diff --color` defaults to `--color=auto`, which suppresses ANSI when stdout is not a TTY. Pipes to `less`, redirects to a file, and CI capture all strip color in `auto` mode. `always` forces ANSI; `less -R` (below) interprets it correctly.
- **`less -RFX`:**
  - **`-R`** passes raw ANSI control sequences through (so the colors from `--color=always` reach the terminal).
  - **`-F`** quits automatically if the entire content fits on one screen — short diffs print inline with no pager interaction.
  - **`-X`** disables the alternate-screen switch on entry/exit, so the diff stays in scrollback after `less` exits instead of vanishing.
- **`[[ -t 1 ]] && command -v less &>/dev/null`** gates the pager. When stdout is not a TTY (CI, pipe, redirect) or `less` is missing, fall through to inline output. The same `--color=always` flag works in both branches.

Replace any inline 5-line diff block (`echo border; diff -u --color file_a file_b; echo border`) with a single `show_diff_box` call.

### Usage Conventions
```bash
print_info "Checking configuration..."      # Process updates
print_success "✓ Configuration applied"     # Completed actions
print_warning "⚠ Feature unavailable"      # Non-fatal issues
print_error "✖ Permission denied"          # Fatal errors
print_backup "- Created: file.backup"       # Backup operations
```

### Unicode Prefix Convention

All `print_success`, `print_warning`, and `print_error` messages MUST use Unicode symbol prefixes:

| Function | Prefix | Meaning | Example |
|----------|--------|---------|---------|
| `print_success` | `✓ ` | Action taken / something changed | `print_success "✓ Configuration applied"` |
| `print_success` | `- ` | Already set / no-op | `print_success "- Configuration already correct"` |
| `print_warning` | `⚠ ` | Warning | `print_warning "⚠ Feature unavailable"` |
| `print_error` | `✖ ` | Error | `print_error "✖ Permission denied"` |

**Exceptions — do NOT add a prefix:**
- Decorative/structural lines: `print_success "═══..."`, `print_warning "═══..."`
- Multi-line continuations: `print_warning "  1. First step..."`, `print_warning "  2. Second step..."`
- Completion summaries: `print_success "Setup complete!"`

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
    if [[ -f /proc/1/environ ]] && grep -qa container=lxc /proc/1/environ 2>/dev/null; then
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

### Package Manager Detection (Sets Global)
```bash
# Sets DETECTED_PKG_MANAGER to: "apt", "brew", "dnf", "zypper", or "unknown"
detect_package_manager() {
    local -a pkg_managers=("apt" "brew" "dnf" "zypper")
    for mgr in "${pkg_managers[@]}"; do
        if command -v "$mgr" &>/dev/null; then
            DETECTED_PKG_MANAGER="$mgr"
            return 0
        fi
    done
    DETECTED_PKG_MANAGER="unknown"
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
    local line
    while read -r line; do
        package_list+=("${line##*:}")
    done < <(get_package_list)

    # Also include removable packages in cache
    while read -r line; do
        package_list+=("${line##*:}")
    done < <(get_removable_package_list)

    local installed_packages
    if [[ "$DETECTED_OS" == "macos" ]]; then
        # Check both formulae and casks on macOS
        local installed_formulae=$(brew list --formula -1 2>/dev/null || true)
        local installed_casks=$(brew list --cask -1 2>/dev/null || true)
        installed_packages=$(printf "%s\n%s" "$installed_formulae" "$installed_casks")
    else
        # Strip :arch suffix (e.g., curl:amd64 → curl) for reliable matching
        installed_packages=$(dpkg -l 2>/dev/null | awk '/^ii/ {sub(/:.*/, "", $2); print $2}' || true)
    fi

    PACKAGE_CACHE=()
    local package
    for package in "${package_list[@]}"; do
        if echo "$installed_packages" | grep -qx "$package"; then
            PACKAGE_CACHE["$package"]="installed"
        else
            PACKAGE_CACHE["$package"]="not_installed"
        fi
    done

    PACKAGE_CACHE_POPULATED=true
}

# Ensure the package cache is populated (explicit initialization)
# Call early in orchestration to avoid hidden side effects in is_package_installed
ensure_package_cache_populated() {
    if [[ "$PACKAGE_CACHE_POPULATED" != "true" ]]; then
        populate_package_cache
    fi
}

# Invalidate the package cache so next check refreshes
# Call after installing or removing packages to prevent stale state
invalidate_package_cache() {
    PACKAGE_CACHE=()
    PACKAGE_CACHE_POPULATED=false
}

# Check if a package is installed (uses cache, single argument)
# Requires: DETECTED_OS MUST be set (call detect_os or detect_environment first)
is_package_installed() {
    local package="$1"

    # Lazy cache initialization
    ensure_package_cache_populated

    # Check cache first
    if [[ -n "${PACKAGE_CACHE[$package]:-}" ]]; then
        [[ "${PACKAGE_CACHE[$package]}" == "installed" ]]
        return $?
    fi

    # Fallback to direct check if not in cache
    if [[ "$DETECTED_OS" == "macos" ]]; then
        brew list --formula "$package" &>/dev/null || brew list --cask "$package" &>/dev/null
    else
        dpkg -l "$package" 2>/dev/null | grep -q "^ii"
    fi
}
```

### verify_package_manager - Prerequisite Check
```bash
# Verify package manager is available before attempting installs
# Call at the top of any function that installs packages
verify_package_manager() {
    if [[ "$DETECTED_OS" == "macos" ]]; then
        if ! command -v brew &>/dev/null; then
            print_error "Homebrew is not installed. Please install it from https://brew.sh"
            return 1
        fi
    else
        if ! command -v apt &>/dev/null; then
            print_error "apt package manager not found. This script requires apt (Debian/Ubuntu-based systems)"
            return 1
        fi
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

    # Safe expansion handles empty array
    for backed_up_file in "${BACKED_UP_FILES[@]+"${BACKED_UP_FILES[@]}"}"; do
        if [[ "$backed_up_file" == "$file" ]]; then
            already_backed_up=true
            break
        fi
    done

    if [[ "$already_backed_up" == true ]]; then
        return 0
    fi

    if [[ -f "$file" ]]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S).bak"

        # Copy with preserved permissions, using elevation if needed
        if needs_elevation "$file"; then
            run_elevated cp -p "$file" "$backup"
        else
            cp -p "$file" "$backup"
        fi

        # Preserve ownership (platform-specific)
        local owner
        if [[ "$DETECTED_OS" == "macos" ]]; then
            owner=$(stat -f "%u:%g" "$file")
        else
            owner=$(stat -c "%u:%g" "$file")
        fi
        if needs_elevation "$file"; then
            run_elevated chown "$owner" "$backup" 2>/dev/null || true
        else
            chown "$owner" "$backup" 2>/dev/null || true
        fi

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

    # Safe expansion handles empty array
    for added_file in "${HEADER_ADDED_FILES[@]+"${HEADER_ADDED_FILES[@]}"}"; do
        if [[ "$added_file" == "$file" ]]; then
            already_added=true
            break
        fi
    done

    if [[ "$already_added" == true ]]; then
        return 0
    fi

    local header_line=""
    case "$config_type" in
        nano)   header_line="# nano configuration - managed by system-setup.sh" ;;
        tmux)   header_line="# tmux configuration - managed by system-setup.sh" ;;
        shell)  header_line="# Shell configuration - managed by system-setup.sh" ;;
    esac

    # Uses append_to_file for proper elevation handling
    append_to_file "$file" "" "$header_line" "# Updated: $(date)"

    HEADER_ADDED_FILES+=("$file")
}
```

### append_to_file - Elevation-Aware File Appending
```bash
# Append lines to a file, using elevation (sudo) when needed
# Each argument after the file path is written as a separate line
# Empty string arguments create blank lines
append_to_file() {
    local file="$1"
    shift
    if needs_elevation "$file"; then
        printf '%s\n' "$@" | run_elevated tee -a "$file" > /dev/null
    else
        printf '%s\n' "$@" >> "$file"
    fi
}
```

### Inline mktemp + TEMP_FILES

Create temp files inline at the call site with `mktemp` followed by an immediate `TEMP_FILES+=()`. Do NOT wrap this in a helper that returns the temp path via `$()`. See [No Simple Wrapper Functions](#no-simple-wrapper-functions) for the Bash subshell-capture gotcha that makes the wrapped form leak — the short version: `tmp=$(make_temp_file)` runs the helper in a subshell, so the helper's `TEMP_FILES+=("$tmp")` lands in the subshell's array. The parent's `TEMP_FILES` stays empty, the EXIT trap iterates an empty array, and the temp file is never reaped.

There are three concrete variants. Pick by call site.

#### Pattern E — atomic-rename adjacent template (self-update flows)

For self-update flows where the temp file will be `mv`'d atomically over a known destination on the same filesystem. The template MUST be in the destination's directory so `mv` is `rename(2)`, not `copy + unlink`. The naming convention `~filename.tmp.XXXXXX` is required so the [startup sweep](#defense-in-depth-cleanup) glob is unambiguous:

```bash
# Utils file self-update (utils file path always known via _UTILS_DIR):
local temp_file
temp_file=$(mktemp "${_UTILS_DIR}/~${utils_basename}.tmp.XXXXXX")
TEMP_FILES+=("$temp_file")

# Caller script self-update (caller_script is an absolute path):
local temp_file
temp_file=$(mktemp "${caller_script%/*}/~${caller_script##*/}.tmp.XXXXXX")
TEMP_FILES+=("$temp_file")

# Standalone self-update (gh_org_*, services-check) where SCRIPT_FILE is a
# hardcoded basename and SCRIPT_DIR is set at file scope:
local TEMP_SCRIPT_FILE
TEMP_SCRIPT_FILE=$(mktemp "${SCRIPT_DIR}/~${SCRIPT_FILE}.tmp.XXXXXX")
TEMP_FILES+=("$TEMP_SCRIPT_FILE")
```

#### Pattern E2 — path-aware variant for `_download-*-scripts.sh` and orchestrators

For `_download-lxc-scripts.sh`, `_download-ollama-scripts.sh`, `system-setup/system-setup.sh:update_modules`, and `kubernetes/kubernetes-setup.sh:update_modules`, the iterated `LOCAL_SCRIPT` may include path components (e.g., `system-modules/configure-system.sh`, `kubernetes-modules/install-update-helm.sh`). Pattern E's `${SCRIPT_DIR}/~${SCRIPT_FILE}.tmp.XXXXXX` would collapse the path and miss the destination's actual directory. Use `dirname` / `basename` of the resolved local path instead:

```bash
local TEMP_SCRIPT_FILE
TEMP_SCRIPT_FILE=$(mktemp "$(dirname "${LOCAL_SCRIPT}")/~$(basename "${LOCAL_SCRIPT}").tmp.XXXXXX")
TEMP_FILES+=("$TEMP_SCRIPT_FILE")
```

This keeps the temp adjacent to `${LOCAL_SCRIPT}` regardless of whether `LOCAL_SCRIPT` is a basename, a `subdir/file`, or an absolute path.

#### Pattern E3 — bookkeeping-only inline (NOT atomic-rename)

For non-self-update sites that just need a temp scratch file with cleanup-trap bookkeeping. Examples: `utils-sys.sh:normalize_trailing_newlines()`, `utils-k8s.sh:update_config_line()`, `utils-k8s.sh:normalize_trailing_newlines()`. Their `mv` targets are arbitrary user-provided file paths (config files like `/etc/...`), often reached via `run_elevated mv` which crosses filesystems anyway. Atomic same-FS rename is irrelevant here; the goal is just cleanup-trap bookkeeping:

```bash
local temp_file
temp_file=$(mktemp)
TEMP_FILES+=("$temp_file")
```

Atomic-rename for these config-rewrite sites is a known-deferred gap. See `docs/future-todos.md` ("Atomic-rename for config-rewrite sites under elevation").

### check_disk_space - Pre-Operation Space Verification
```bash
# Verify sufficient disk space before large operations
# Usage: check_disk_space "/var" 4096  (checks /var has 4096 MB free)
# Returns: 0 if enough space, 1 if not (prints error)
check_disk_space() {
    local path="$1"
    local required_mb="$2"
    local buffer_mb="${3:-512}"
    local total_needed=$((required_mb + buffer_mb))

    local available_mb
    available_mb=$(df -BM "$path" --output=avail 2>/dev/null | tail -1 | tr -d ' M')

    # Fallback for macOS (no --output flag)
    if [[ -z "$available_mb" ]]; then
        available_mb=$(df -m "$path" | tail -1 | awk '{print $4}')
    fi

    if [[ "$available_mb" -lt "$total_needed" ]]; then
        print_error "Insufficient disk space at $path: ${available_mb}MB available, ${total_needed}MB needed"
        return 1
    fi
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

### Defense-in-depth Cleanup

Long-running scripts and live-replace self-updaters MUST defend temp-file leaks at every transition. Apply all three layers — they cover different failure modes and any one alone leaks.

#### Layer 1 — Inline `rm -f` per non-success branch

In every function that creates a temp via `mktemp` then takes a non-success path (download fail, user decline, no-op, mv-failure), `rm -f` the temp BEFORE the `return`. The EXIT trap below only reaps at script exit; without inline cleanup, a temp leaks visibly in `$SCRIPT_DIR` for the rest of the run — minutes for one-shot updaters, effectively-infinite for ping loops or `--watch` modes.

Example (every non-success branch carries its own `rm -f`):

```bash
if ! download_script "${SCRIPT_FILE}" "${TEMP_SCRIPT_FILE}"; then
    rm -f "${TEMP_SCRIPT_FILE}"
    return 1
fi

if diff -q "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
    print_success "- Script is already up-to-date"
    rm -f "${TEMP_SCRIPT_FILE}"
    return 0
fi

if prompt_yes_no "→ Update?" "y"; then
    if ! mv -f "${TEMP_SCRIPT_FILE}" "${LOCAL_SCRIPT}"; then
        rm -f "${TEMP_SCRIPT_FILE}"
        print_error "✖ Failed to install update — keeping local version"
        return 1
    fi
    # success: mv consumed the temp, no rm needed
else
    rm -f "${TEMP_SCRIPT_FILE}"
    print_warning "⚠ Skipped update"
fi
```

#### Layer 2 — File-scope EXIT trap

Reaps tracked temps on normal exit, SIGINT, SIGTERM. Insufficient alone (does not cover SIGKILL, OOM, power-loss, exec'd-away processes, bugs in the trap wiring). The `cleanup` function and `trap cleanup EXIT` MUST be at file scope, NOT inside `main()` — file scope means the trap is wired the moment the script is loaded, so a top-level guard that exits before `main()` still reaps tracked temps:

```bash
TEMP_FILES=()

# cleanup runs on normal exit, SIGINT, SIGTERM. Hoisted to file scope so the
# trap is wired the moment the script is loaded — a top-level guard that exits
# before main still reaps tracked temps.
cleanup() {
    local f
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        rm -f "$f" 2>/dev/null
    done
}
trap cleanup EXIT
```

The `"${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"` form expands to nothing when the array is unset/empty, so the loop is safe under `set -u`.

#### Layer 3 — Startup sweep

Reaps anything Layer 2 couldn't fire for. Runs at the top of `main()`. TTY-aware so cron / `ssh -T` / CI runs don't block on the prompt:

```bash
sweep_stale_temps() {
    local pattern="$1"
    local stale_files=()
    while IFS= read -r -d '' f; do
        stale_files+=("$f")
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -name "$pattern" -type f -mmin +10 -print0 2>/dev/null)

    [[ ${#stale_files[@]} -eq 0 ]] && return 0

    print_warning "⚠ Found ${#stale_files[@]} stale temp file(s) from a prior interrupted run:"
    for f in "${stale_files[@]}"; do
        print_warning "  - $f"
    done

    # `[[ -r /dev/tty ]]` only checks file permissions; under setsid the device
    # is world-readable but `open(2)` fails with ENXIO, so a subsequent
    # `read </dev/tty` aborts under set -e. Probe with a no-op stdin redirect
    # to detect actual openability.
    if { : </dev/tty; } 2>/dev/null; then
        # `|| true` swallows EOF (Ctrl+D) so set -e doesn't abort mid-cleanup.
        read -p "Press any key to delete and continue, Ctrl+C to abort: " -n 1 -r </dev/tty || true
        echo ""
    else
        print_warning "⚠ Non-interactive context — deleting and continuing without prompt."
    fi

    for f in "${stale_files[@]}"; do
        rm -f "$f"
    done
    print_success "✓ Cleaned up ${#stale_files[@]} stale temp file(s)"
}
```

Call from the top of `main()`:

```bash
main() {
    sweep_stale_temps '~*.tmp.??????'
    # ... rest of main
}
```

**Sweep requirements:**

- **TTY-aware** so cron / `ssh -T` / CI runs don't block on the prompt.
- **Mtime threshold** (`find -mmin +10`) so a concurrent run's in-flight temp is not removed.
- **Same directory** as the live target (`-maxdepth 1` rooted at `$SCRIPT_DIR`) so atomic-rename templates are covered.

#### Open-probe vs permissions check (`{ : </dev/tty; }` vs `[[ -r /dev/tty ]]`)

`sweep_stale_temps` MUST gate the prompt with `if { : </dev/tty; } 2>/dev/null; then`, NOT `if [[ -r /dev/tty ]]; then`. The two checks differ:

- **`[[ -r /dev/tty ]]`** is a **permissions** check. It reports whether the calling process's UID/GID has read permission on the device file. `/dev/tty` is world-readable (mode 0666) on every Linux system, so this check returns true even under `setsid`.
- **`{ : </dev/tty; } 2>/dev/null`** is an **openability** check. It actually attempts `open(2)`. Under `setsid` (no controlling terminal), `open("/dev/tty", ...)` fails with `ENXIO` — even though the permissions check passes. A subsequent `read </dev/tty` hits the same `ENXIO`, returns failure, and `set -e` aborts the script mid-cleanup.

The no-op stdin redirect (`:` is a builtin that does nothing; the redirect is what we want) drives the actual `open(2)` syscall and lets us branch on the real openability rather than the misleading permissions-only check.

For `prompt_yes_no` the simpler `[[ -r /dev/tty ]]` is acceptable because the failure mode is different — a `read </dev/tty` failure inside an `if`-context returns false from the function, which the caller handles. The `setsid` + default "y" combination is a known edge case where the misleading permissions check + `read` failure + default "y" produces silent acceptance — see `docs/future-todos.md`. For `sweep_stale_temps` the failure mode is `set -e` aborting the whole script before any branch fires, which is unrecoverable. Use the open-probe whenever the failure consequence is `set -e` abort.

#### Naming convention: `~filename.tmp.XXXXXX`

Atomic-rename temps MUST use the `~filename.tmp.XXXXXX` shape — leading `~`, `.tmp.` infix, mktemp's 6-character random suffix. The convention exists so:

- The sweep glob `~*.tmp.??????` is unambiguous — no user spontaneously creates files matching this exact shape, so the sweep can safely delete any matches.
- Leftovers sort to the bottom of `ls` output and read as obviously transient.
- A single sweep call with `~*.tmp.??????` covers BOTH a caller-script's temp (`~system-setup.sh.tmp.aBcDeF`) AND a sourced utils-file's temp (`~utils-sys.sh.tmp.gHiJkL`) when both end up in the same `$SCRIPT_DIR`. No "must call sweep twice" trap.

Bare-`mktemp` temps in `$TMPDIR` (Pattern E3 sites — reaped at boot anyway) don't need the convention.

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
        # Drop -f from curl so 4xx/5xx responses still populate http_status (otherwise
        # curl exits non-zero before %{http_code} is captured). --max-time 15 prevents
        # a sinkholed network from hanging for 5+ minutes. Set "000" only when
        # http_status is empty (transport failure), not unconditionally.
        http_status=$(curl -H 'Cache-Control: no-cache, no-store' \
            --max-time 15 \
            -o "${output_file}" -w "%{http_code}" -sSL \
            "${REMOTE_BASE}/${script_file}" 2>/dev/null || true)
        [[ -z "$http_status" ]] && http_status="000"
        case "$http_status" in
            200)
                if head -n 10 "${output_file}" | grep -q "^#!/"; then
                    return 0
                else
                    print_error "✖ Invalid content received (not a script)"
                    return 1
                fi
                ;;
            429) print_error "✖ Rate limited by GitHub (HTTP 429)"; return 1 ;;
            000) print_error "✖ Download failed (network/timeout)"; return 1 ;;
            *)   print_error "✖ HTTP ${http_status} error"; return 1 ;;
        esac
    elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
        local wget_exit=0
        wget --no-cache --no-cookies \
            --timeout=15 \
            -O "${output_file}" -q "${REMOTE_BASE}/${script_file}" 2>/dev/null \
            || wget_exit=$?
        if [[ "$wget_exit" -ne 0 ]]; then
            print_error "✖ Download failed (wget exit ${wget_exit})"
            return 1
        fi
        if head -n 10 "${output_file}" | grep -q "^#!/"; then
            return 0
        else
            print_error "✖ Invalid content received (not a script)"
            return 1
        fi
    fi

    return 1
}
```

**Critical changes from the older template:**

- **`-fsSL` → `-sSL`** (drop the `-f`). With `-f`, curl exits non-zero on 4xx/5xx BEFORE `%{http_code}` is written to the output, so the captured `http_status` is empty and the old `|| echo "000"` fallback turns every HTTP error into `"000"` (and on some platforms, the concatenation `404` + `000` produced visible `"404000"` strings in error messages). Without `-f`, curl writes the body (the GitHub error page) to `output_file`, exits 0, and `%{http_code}` is captured cleanly. The shebang validation downstream rejects the error-page body. The sister-repo audit traced an "HTTP 404000 error" message to this exact bug.
- **`--max-time 15`** caps total transfer time. Without it, a sinkholed/black-hole network can hang for 5+ minutes (curl's default connect/read timeouts are very generous). 15 seconds is enough for a slow GitHub raw fetch and short enough that an interactive user notices and Ctrl+C's. Verified via [everything.curl.dev/usingcurl/timeouts.html](https://everything.curl.dev/usingcurl/timeouts.html).
- **`[[ -z "$http_status" ]] && http_status="000"`** runs only when curl produced no status — true network failure, NOT HTTP error. The old `|| echo "000"` ran on any non-zero curl exit including HTTP-4xx-with-`-f`, conflating two different failures.
- **`case` statement** replaces the if/elif chain so each branch is one line and the failure-message wording is uniform.
- **wget `--timeout=15`** mirrors the curl change. The old wget branch had no timeout at all.
- **`local wget_exit=0; wget … || wget_exit=$?`** captures wget's exit code without aborting the function under `set -e`. The old form (`if wget …; then`) hid the exit code in the conditional and lost the error specificity.

### Self-Update Function

```bash
# Check for updates to the main script itself
# Will restart the script if updated
self_update() {
    local SCRIPT_FILE="services-check.sh"
    local LOCAL_SCRIPT="${SCRIPT_DIR}/${SCRIPT_FILE}"
    local TEMP_SCRIPT_FILE
    # Pattern E: mktemp adjacent to destination (same FS) so `mv` is atomic
    # rename(2). The `~filename.tmp.XXXXXX` shape is the sweep glob's anchor.
    TEMP_SCRIPT_FILE=$(mktemp "${SCRIPT_DIR}/~${SCRIPT_FILE}.tmp.XXXXXX")
    TEMP_FILES+=("$TEMP_SCRIPT_FILE")

    if ! download_script "${SCRIPT_FILE}" "${TEMP_SCRIPT_FILE}"; then
        rm -f "$TEMP_SCRIPT_FILE"
        return 1
    fi

    # Compare and handle differences
    if diff -q "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
        print_success "- Script is already up-to-date"
        rm -f "$TEMP_SCRIPT_FILE"
        return 0
    fi

    show_diff_box "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" "${SCRIPT_FILE}"

    if prompt_yes_no "→ Overwrite and restart with updated ${SCRIPT_FILE}?" "y"; then
        chmod +x "${TEMP_SCRIPT_FILE}"
        # Pattern D: explicit failure handler so a read-only $SCRIPT_DIR or
        # cross-FS attempt doesn't leave the local script half-overwritten.
        if ! mv -f "${TEMP_SCRIPT_FILE}" "${LOCAL_SCRIPT}"; then
            rm -f "$TEMP_SCRIPT_FILE"
            print_error "✖ Failed to install update — keeping local version"
            return 1
        fi
        print_success "✓ Updated ${SCRIPT_FILE} - restarting..."
        echo ""
        export scriptUpdated=1
        exec "${LOCAL_SCRIPT}" "$@"
        exit 0
    else
        rm -f "$TEMP_SCRIPT_FILE"
        print_warning "⚠ Skipped update - continuing with local version"
    fi
    echo ""
}
```

**Pattern callouts** (cross-references — see [Inline mktemp + TEMP_FILES](#inline-mktemp--temp_files), [Defense-in-depth Cleanup](#defense-in-depth-cleanup), and [Diff Display Pattern](#diff-display-pattern)):

- **Pattern E** (adjacent `mktemp` + `TEMP_FILES+=()`) replaces the older `local TEMP_SCRIPT="$(mktemp)"` form, which landed in `$TMPDIR` (tmpfs) and made `mv -f` a cross-FS `copy + unlink` rather than an atomic `rename(2)`. SIGKILL or power-loss mid-copy could leave a truncated script.
- **Pattern D** (`if ! mv -f`) replaces the bare `mv -f` so a read-only or cross-FS destination produces a typed error and the local file is preserved.
- **Pattern H** (`show_diff_box`) replaces the inline diff border + `diff -u --color` block. Color is now `--color=always` and multi-page diffs page through `less -RFX`.
- The function is called by every `_download-*-scripts.sh` updater and the standalones (`utils/services-check.sh`, `github/gh_org_*.sh`).

### check_for_updates Pattern (per-directory utils)

Used by individual scripts and modules in lxc/, llm/, kubernetes/, and system-setup/. Checks for updates to both the utils file and the calling script, then exec-restarts if updated.

```bash
# Called at the start of main() or inside source guard
check_for_updates "${BASH_SOURCE[0]}" "$@"
```

Flow: detect download cmd → adjacent-`mktemp` utils temp → download utils → diff/prompt → adjacent-`mktemp` caller temp → download caller → diff/prompt → exec restart if updated. Uses per-directory env var guards (`LXC_SCRIPTS_UPDATED`, `LLM_SCRIPTS_UPDATED`, `K8S_SCRIPTS_UPDATED`, `SYS_SCRIPTS_UPDATED`) to prevent infinite restart loops.

The two `mktemp` sites use the two Pattern E variants:

```bash
# Utils file temp (utils path always known via _UTILS_DIR):
temp_file=$(mktemp "${_UTILS_DIR}/~${utils_basename}.tmp.XXXXXX")
TEMP_FILES+=("$temp_file")
# ... download_script + show_diff_box + prompt_yes_no + Pattern D mv ...

# Caller script temp (caller_script is an absolute path):
temp_file=$(mktemp "${caller_script%/*}/~${caller_script##*/}.tmp.XXXXXX")
TEMP_FILES+=("$temp_file")
# ... download_script + show_diff_box + prompt_yes_no + Pattern D mv ...
```

Each non-success branch (download fail, no-diff, user decline, mv fail) carries its own `rm -f "$temp_file"` per [Layer 1 of the cleanup architecture](#defense-in-depth-cleanup). When the success branch runs, `mv` consumes the temp and no `rm` is needed.

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

        # Ensure the local directory exists (so the adjacent mktemp template below resolves)
        local script_dir="$(dirname "$LOCAL_SCRIPT")"
        mkdir -p "$script_dir"

        # Pattern E2 (path-aware): mktemp adjacent to LOCAL_SCRIPT (which may
        # contain a subdir like system-modules/...). Inline TEMP_FILES+=() so the
        # cleanup trap reaches the parent's array.
        local TEMP_SCRIPT_FILE
        TEMP_SCRIPT_FILE=$(mktemp "$(dirname "${LOCAL_SCRIPT}")/~$(basename "${LOCAL_SCRIPT}").tmp.XXXXXX")
        TEMP_FILES+=("$TEMP_SCRIPT_FILE")

        if ! download_script "${SCRIPT_FILE}" "${TEMP_SCRIPT_FILE}"; then
            echo "            (skipping ${SCRIPT_FILE})"
            ((failed_count++)) || true
            rm -f "${TEMP_SCRIPT_FILE}"
            echo ""
            continue
        fi

        # Create file if it doesn't exist
        if [[ ! -f "${LOCAL_SCRIPT}" ]]; then
            touch "${LOCAL_SCRIPT}"
        fi

        # Compare and handle differences
        if diff -u "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
            print_success "- ${SCRIPT_FILE} is already up-to-date"
            ((uptodate_count++)) || true
            rm -f "${TEMP_SCRIPT_FILE}"
            echo ""
        else
            show_diff_box "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" "${SCRIPT_FILE}"

            if prompt_yes_no "→ Overwrite local ${SCRIPT_FILE} with remote copy?" "y"; then
                echo ""
                chmod +x "${TEMP_SCRIPT_FILE}"
                # Pattern D: mv -f failure handler.
                if ! mv -f "${TEMP_SCRIPT_FILE}" "${LOCAL_SCRIPT}"; then
                    rm -f "${TEMP_SCRIPT_FILE}"
                    print_error "✖ Failed to install update for ${SCRIPT_FILE} — keeping local version"
                    ((failed_count++)) || true
                    echo ""
                    continue
                fi
                print_success "✓ Replaced ${SCRIPT_FILE}"
                ((updated_count++)) || true
            else
                print_warning "⚠ Skipped ${SCRIPT_FILE}"
                ((skipped_count++)) || true
                rm -f "${TEMP_SCRIPT_FILE}"
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

**Why Pattern E2 (not E)?** `LOCAL_SCRIPT` here is `${SCRIPT_DIR}/${SCRIPT_FILE}` where `SCRIPT_FILE` may contain a subdirectory (e.g., `system-modules/configure-system.sh` or `kubernetes-modules/install-update-helm.sh`). Pattern E's `${SCRIPT_DIR}/~${SCRIPT_FILE}.tmp.XXXXXX` would produce a literal `~system-modules/configure-system.sh.tmp.XXX` path that `mktemp` cannot create (the slash is interpreted as a directory separator). Pattern E2 wraps `dirname`/`basename` around `LOCAL_SCRIPT` so the temp lands in the right subdirectory regardless of path shape.

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

# Resolve script directory for adjacent-mktemp templates and the sweep root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Tracked temp files for the EXIT-trap cleanup. MUST be at file scope.
TEMP_FILES=()

# List of script files to download/update
get_script_list() {
    echo "script-a.sh"
    echo "script-b.sh"
}

# List of obsolete scripts to clean up
OBSOLETE_SCRIPTS=()

# Include: print_info, print_success, print_warning, print_error (>&2)
# Include: prompt_yes_no (with [[ -r /dev/tty ]] guard)
# Include: cleanup + trap cleanup EXIT (file-scope, NOT inside main)
# Include: sweep_stale_temps (with { : </dev/tty; } open-probe)
# Include: show_diff_box (with --color=always + less -RFX)
# Include: detect_download_cmd (with print_warning_box inline or simplified)
# Include: download_script (with --max-time 15, -sSL not -fsSL, case statement)
# Include: cleanup_obsolete_scripts
# Include: self_update (Pattern E adjacent mktemp + Pattern D mv handler)
# Include: update_modules (Pattern E2 path-aware mktemp + Pattern D mv handler)

# Main execution
main() {
    sweep_stale_temps '~*.tmp.??????'

    if detect_download_cmd; then
        if [[ ${scriptUpdated:-0} -eq 0 ]]; then
            self_update "$@"
        fi
        update_modules
        cleanup_obsolete_scripts "${OBSOLETE_SCRIPTS[@]+"${OBSOLETE_SCRIPTS[@]}"}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
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
| `utils/README.md` | Cross-platform utilities | ✅ |

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
