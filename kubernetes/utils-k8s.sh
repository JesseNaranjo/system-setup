#!/usr/bin/env bash

# utils-k8s.sh - Common utilities and variables for kubernetes-setup scripts
# This script provides shared functionality used across all kubernetes-setup modules
# Forked from system-setup/utils-sys.sh and maintained independently

# Prevent multiple sourcing
if [[ -n "${K8S_UTILS_SH_LOADED:-}" ]]; then
    return 0
fi
readonly K8S_UTILS_SH_LOADED=true

set -euo pipefail

# ============================================================================
# Colors and Output Constants
# ============================================================================

readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m' # Cyan for lines/borders
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly MAGENTA='\033[0;35m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# ============================================================================
# Global Variables
# ============================================================================
#
# MODULE DEPENDENCY NOTES:
# These global variables create dependencies between modules. The orchestrator
# (kubernetes-setup.sh) must ensure proper initialization order:
#
# 1. detect_environment() must be called first - sets DETECTED_OS, RUNNING_IN_CONTAINER
# 2. install-k8s-packages.sh populates *_INSTALLED flags via track_special_packages()
# 3. Other modules read *_INSTALLED flags to decide what to configure
#
# When running modules standalone, call detect_environment() and verify that
# any required *_INSTALLED flags are set (they default to false).
# ============================================================================

DEBUG_MODE=false
DETECTED_OS=""
DETECTED_PKG_MANAGER=""
BACKED_UP_FILES=()
CREATED_BACKUP_FILES=()
HEADER_ADDED_FILES=()
CREATED_CONFIG_FILES=()
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

# Defense-in-depth: at startup, reap any same-FS temp files (e.g., from a
# prior SIGKILL / power-loss / interrupted self-update) older than a normal
# run window. The EXIT trap above handles in-flight cleanup; this function
# handles what the trap couldn't fire for. TTY-aware so cron/ssh -T runs
# don't block on the prompt.
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

# Render a unified diff between two files inside a labeled box. Pages through
# `less -RFX` when stdout is a TTY (-R passes ANSI through, -F exits if content
# fits one screen, -X skips alt-screen so output stays in scrollback); falls
# back to inline `diff` when piped or `less` is missing. `--color=always`
# forces ANSI even when piped.
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

# Package installation tracking flags
# Set by: track_special_packages() called from install-k8s-packages.sh
# Read by: other modules to determine what to configure
KUBECTL_INSTALLED=false
KUBEADM_INSTALLED=false
KUBELET_INSTALLED=false
CRIO_INSTALLED=false

declare -A SPECIAL_PACKAGE_FLAGS=(
    [kubectl]=KUBECTL_INSTALLED
    [kubeadm]=KUBEADM_INSTALLED
    [kubelet]=KUBELET_INSTALLED
    [cri-o]=CRIO_INSTALLED
)

# Environment detection flags
# Set by: detect_container() called from detect_environment()
RUNNING_IN_CONTAINER=false

# Package cache for performance optimization
# Populated by: ensure_package_cache_populated() or lazily by is_package_installed()
# Requires: DETECTED_OS must be set first
declare -A PACKAGE_CACHE=()
PACKAGE_CACHE_POPULATED=false

# ============================================================================
# Output Functions
# ============================================================================

# Print colored output
print_backup() {
    echo -e "${GRAY}[ BACKUP  ] $1${NC}"
}

print_debug() {
    echo -e "${MAGENTA}[ DEBUG   ] $1${NC}"
}

print_error() {
    echo -e "${RED}[ ERROR   ]${NC} $1" >&2
}

print_info() {
    echo -e "${BLUE}[ INFO    ]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[ SUCCESS ]${NC} $1"
}

print_summary() {
    echo -e "${BLUE}[ SUMMARY ]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[ WARNING ]${NC} $1"
}

# Print a warning box with multiple lines of content
# Usage: print_warning_box "line1" "line2" "line3" ...
# Each line will be padded to fit within the box
print_warning_box() {
    local box_width=77
    local padding=8
    local content_width=$((box_width - padding - 1))

    echo ""
    echo -e "            ${YELLOW}╔$(printf '═%.0s' $(seq 1 $box_width))╗${NC}"
    echo -e "            ${YELLOW}║$(printf ' %.0s' $(seq 1 $box_width))║${NC}"

    local line
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

# ============================================================================
# User Input Functions
# ============================================================================

# Prompt user for yes/no confirmation
# Usage: prompt_yes_no "message" [default]
#   default: "y" or "n" (optional, defaults to "n")
# Returns: 0 for yes, 1 for no
prompt_yes_no() {
    local prompt_message="$1"
    local default="${2:-n}"
    local prompt_suffix
    local user_reply

    # Non-TTY context (cron, systemd, ssh -T, CI): signal "no" rather than fall
    # through to the empty-reply branch and silently auto-accept the default.
    [[ -r /dev/tty ]] || return 1

    # Set the prompt suffix based on default
    if [[ "${default,,}" == "y" ]]; then
        prompt_suffix="(Y/n)"
    else
        prompt_suffix="(y/N)"
    fi

    # Read from /dev/tty to work correctly in while-read loops
    read -p "$prompt_message $prompt_suffix: " -r user_reply </dev/tty

    # If user just pressed Enter (empty reply), use default
    if [[ -z "$user_reply" ]]; then
        [[ "${default,,}" == "y" ]]
    else
        [[ $user_reply =~ ^[Yy]$ ]]
    fi
}

# ============================================================================
# Cleanup Functions
# ============================================================================

# Clean up obsolete scripts that have been renamed or removed from the repository
# Usage: cleanup_obsolete_scripts "script1.sh" "script2.sh" ...
# Args: List of obsolete script filenames to remove (relative to SCRIPT_DIR)
# Requires: SCRIPT_DIR variable to be set, prompt_yes_no function
cleanup_obsolete_scripts() {
    # Safely handle empty argument list
    local obsolete_script
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

# ============================================================================
# OS and Environment Detection
# ============================================================================

# Detect OS and populate DETECTED_OS global variable
detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        DETECTED_OS="macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        DETECTED_OS="linux"
    else
        DETECTED_OS="unknown"
    fi
}

# Detect if running inside a container (LXC, Docker, or other)
# Sets the global RUNNING_IN_CONTAINER variable
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

    # Not in a container
    RUNNING_IN_CONTAINER=false
}

# Detect both OS and container environment in one call
# This consolidates the common pattern used in all modules
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

# Detect the system's package manager
# Sets DETECTED_PKG_MANAGER to: "apt", "brew", "dnf", "zypper", or "unknown"
# Extensible: Add new package managers by adding to the array
detect_package_manager() {
    local -a pkg_managers=("apt" "brew" "dnf" "zypper")

    local mgr
    for mgr in "${pkg_managers[@]}"; do
        if command -v "$mgr" &>/dev/null; then
            DETECTED_PKG_MANAGER="$mgr"
            return 0
        fi
    done

    DETECTED_PKG_MANAGER="unknown"
}

# ============================================================================
# Kernel Module Utilities
# ============================================================================

# Check if a kernel module is currently loaded (dynamically)
# Args: module_name
# Returns: 0 if loaded, 1 otherwise
is_module_loaded() {
    local module="$1"
    if command -v lsmod &>/dev/null; then
        lsmod | grep -q "^${module}[[:space:]]"
    elif [[ -r /proc/modules ]]; then
        grep -q "^${module} " /proc/modules
    else
        return 1
    fi
}

# Check if a kernel module is available (loaded or built into kernel)
# Args: module_name
# Returns: 0 if available, 1 otherwise
is_module_available() {
    local module="$1"
    # Check if dynamically loaded
    is_module_loaded "$module" && return 0
    # /sys/module/ exists for both loaded and built-in modules;
    # since is_module_loaded already checked, presence here means built-in
    [[ -d "/sys/module/${module}" ]] && return 0
    return 1
}

# ============================================================================
# Container Swap Utilities
# ============================================================================

# Print informational message about swap behavior in containers
# Called by configure-swap.sh
print_container_swap_info() {
    print_info "/proc/swaps reflects the host's swap — it cannot be changed from inside the container"
    print_info "initialize-cluster.sh handles this automatically via failSwapOn: false in the kubeadm config"
    print_info "For cgroup-level swap restriction, use: start-lxc.sh --no-swap <container_name>"
}

# ============================================================================
# Privilege Management
# ============================================================================

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

# Run command with appropriate privileges (macOS only - uses sudo for system operations)
# On Linux, script should already be running as root for system operations
run_elevated() {
    if [[ $EUID -eq 0 ]]; then
        # Already running as root, just execute
        "$@"
    else
        if [[ "$DETECTED_OS" == "macos" ]]; then
            # On macOS, use sudo for system changes
            sudo "$@"
        else
            # On Linux, shouldn't get here (should already be root for system operations)
            print_error "✖ Insufficient privileges to run: $*"
            return 1
        fi
    fi
}

# Check if a file operation needs elevation (macOS-specific)
# Returns 0 if elevation needed, 1 if not
needs_elevation() {
    local file="$1"

    # If already root or running Linux (which should already be root), no elevation needed
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

# Append one or more lines to a file with proper elevation handling
# Usage: append_to_file <file> <line1> [line2] [line3] ...
# Each argument after the file path is written as a separate line
# Empty string arguments create blank lines
append_to_file() {
    local file="$1"
    shift

    if [[ "$DEBUG_MODE" == true ]]; then
        print_debug "append_to_file: appending $# line(s) to $file"
    fi

    if needs_elevation "$file"; then
        printf '%s\n' "$@" | run_elevated tee -a "$file" > /dev/null
    else
        printf '%s\n' "$@" >> "$file"
    fi
}

# Grep a file with proper elevation handling
# Usage: grep_file [grep_options] <pattern> <file>
# Returns: grep exit status (0 if match found, 1 if no match, 2 if error)
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

    if [[ "$DEBUG_MODE" == true ]]; then
        print_debug "grep_file: pattern='$pattern' file='$file' options='${args[*]:-}'"
    fi

    if needs_elevation "$file"; then
        run_elevated grep "${args[@]+"${args[@]}"}" "$pattern" "$file"
    else
        grep "${args[@]+"${args[@]}"}" "$pattern" "$file"
    fi
}

# ============================================================================
# Package Management Functions
# ============================================================================

# Get package definitions for Kubernetes
get_package_list() {
    echo "kubeadm:kubeadm"
    echo "kubectl:kubectl"
    echo "kubelet:kubelet"
    echo "CRI-O:cri-o"
}

# Get packages that should be removed if installed
# Returns: "Display Name:package-name" pairs for packages to remove
get_removable_package_list() {
    # No k8s packages to remove
    :
}

# Populate the package cache with installed packages from the package list
populate_package_cache() {
    if [[ "$DEBUG_MODE" == true ]]; then
        print_debug "Populating package cache..."
    fi

    # Get all package names from the package list
    local package_list=()
    local line
    while read -r line; do
        package_list+=("${line##*:}")
    done < <(get_package_list)

    local installed_packages
    # Get all installed packages from dpkg (Linux only for k8s)
    # Strip :arch suffix (e.g., curl:amd64 -> curl) for reliable matching on multiarch systems
    installed_packages=$(dpkg -l 2>/dev/null | awk '/^ii/ {sub(/:.*/, "", $2); print $2}' || true)

    PACKAGE_CACHE=()
    # Check each package from our list against installed packages
    local package
    for package in "${package_list[@]}"; do
        if echo "$installed_packages" | grep -qx "$package"; then
            PACKAGE_CACHE["$package"]="installed"
        else
            PACKAGE_CACHE["$package"]="not_installed"
        fi
    done

    PACKAGE_CACHE_POPULATED=true

    if [[ "$DEBUG_MODE" == true ]]; then
        print_debug "Package cache contents:"
        local pkg
        for pkg in "${!PACKAGE_CACHE[@]}"; do
            print_debug "  $pkg: ${PACKAGE_CACHE[$pkg]}"
        done
    fi
}

# Ensure the package cache is populated (explicit initialization)
# Call this early in orchestration to avoid hidden side effects in is_package_installed
# Requires: DETECTED_OS must be set (call detect_os first)
ensure_package_cache_populated() {
    if [[ "$PACKAGE_CACHE_POPULATED" != "true" ]]; then
        populate_package_cache
    fi
}

# Invalidate the package cache so next is_package_installed() call refreshes
# Call after installing or removing packages to prevent stale state
invalidate_package_cache() {
    PACKAGE_CACHE=()
    PACKAGE_CACHE_POPULATED=false
}

# Check if a package is installed (Linux/apt only for k8s)
# Uses cache for performance optimization
# Note: Will populate cache on first call if not already populated via ensure_package_cache_populated()
# Requires: DETECTED_OS must be set (call detect_os or detect_environment first)
is_package_installed() {
    local package="$1"

    # Populate cache if not yet populated (lazy initialization)
    ensure_package_cache_populated

    # Check cache first
    if [[ -n "${PACKAGE_CACHE[$package]:-}" ]]; then
        [[ "${PACKAGE_CACHE[$package]}" == "installed" ]]
        return $?
    fi

    # Fallback to direct check if not in cache (shouldn't happen normally)
    dpkg -l "$package" 2>/dev/null | grep -q "^ii"
}

# Verify package manager is available
verify_package_manager() {
    if ! command -v apt &>/dev/null; then
        print_error "✖ apt package manager not found. This script requires apt (Debian/Ubuntu-based systems)"
        return 1
    fi
    return 0
}

# Track if specific packages are installed for later configuration
track_special_packages() {
    local package="$1"
    local flag_name="${SPECIAL_PACKAGE_FLAGS[$package]:-}"
    if [[ -n "$flag_name" ]]; then
        printf -v "$flag_name" '%s' 'true'
    fi
}

# ============================================================================
# File Management Functions
# ============================================================================

# Get current file permissions in octal format (e.g., "644")
# Works on both macOS and Linux
get_file_permissions() {
    local file="$1"

    if [[ "$DETECTED_OS" == "macos" ]]; then
        # macOS stat syntax - returns last 3 digits of mode
        stat -f "%Lp" "$file"
    else
        # Linux stat syntax
        stat -c "%a" "$file"
    fi
}

# Check if a filesystem has enough free space
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

    if [[ -z "$available_mb" || ! "$available_mb" =~ ^[0-9]+$ || "$available_mb" -lt "$total_needed" ]]; then
        print_error "✖ Insufficient disk space on ${path} (${available_mb:-unknown} MB available, need ${required_mb} MB + ${buffer_mb} MB buffer)"
        return 1
    fi
    return 0
}

# Create a config file with specified permissions
# Usage: create_config_file <path> [perms] [content]
#   path: file path (required)
#   perms: octal permissions like 644, 600 (default: 644)
#   content: optional content to write (if omitted, creates empty file)
#
# Behavior:
#   - New file: create with content (or empty), chmod to perms
#   - Existing file: check permissions, warn if mismatch, do not modify
#   - System paths (/etc/*): use run_elevated on macOS
create_config_file() {
    local file="$1"
    local perms="${2:-644}"
    local content="${3:-}"

    if [[ -f "$file" ]]; then
        # File exists - check permissions and warn if different
        local actual_perms=$(get_file_permissions "$file")
        if [[ "$actual_perms" != "$perms" ]]; then
            print_warning "⚠ $file exists with permissions $actual_perms (expected $perms)"
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
    CREATED_CONFIG_FILES+=("$file")
}

# Backup file if it exists (only once per session)
backup_file() {
    local file="$1"
    local already_backed_up=false

    # Check if already backed up in this session
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

        # Copy file with preserved permissions (-p flag)
        if needs_elevation "$file"; then
            run_elevated cp -p "$file" "$backup"
        else
            cp -p "$file" "$backup"
        fi

        # Preserve ownership (requires appropriate permissions)
        # Get the owner and group of the original file
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

# Add change header to file (only once per session)
add_change_header() {
    local file="$1"
    local config_type="$2"  # "k8s", "sysctl", "modules", etc.
    local already_added=false

    # Check if header already added in this session
    for added_file in "${HEADER_ADDED_FILES[@]+"${HEADER_ADDED_FILES[@]}"}"; do
        if [[ "$added_file" == "$file" ]]; then
            already_added=true
            break
        fi
    done

    if [[ "$already_added" == true ]]; then
        return 0
    fi

    # Prepare header content based on config type
    local header_line=""
    case "$config_type" in
        k8s)
            header_line="# Kubernetes configuration - managed by kubernetes-setup.sh"
            ;;
        sysctl)
            header_line="# Sysctl configuration - managed by kubernetes-setup.sh"
            ;;
        modules)
            header_line="# Kernel modules - managed by kubernetes-setup.sh"
            ;;
        shell)
            header_line="# Shell configuration - managed by kubernetes-setup.sh"
            ;;
        *)
            header_line="# Configuration - managed by kubernetes-setup.sh"
            ;;
    esac

    # Add header before changes
    append_to_file "$file" "" "$header_line" "# Updated: $(date)"

    # Mark this file as having header added
    HEADER_ADDED_FILES+=("$file")
}

# ============================================================================
# Configuration Management Functions
# ============================================================================

# Escape special regex characters in a string for use in grep/sed/awk patterns
# Usage: escaped=$(escape_regex "string with $pecial (chars)")
# Note: In the character class, ] must come first and [ must come last for proper escaping
escape_regex() {
    printf '%s' "$1" | sed 's/[].[^$*+?{}|()\\[]/\\&/g'
}

# Check if a configuration line exists in a file
config_exists() {
    local file="$1"
    local pattern="$2"

    [[ -f "$file" ]] && grep_file -qE "^[[:space:]]*${pattern}" "$file"
}

# Get current value of a configuration setting
get_config_value() {
    local file="$1"
    local setting="$2"

    if [[ -f "$file" ]]; then
        grep_file -E "^[[:space:]]*${setting}" "$file" | head -n 1 | sed -E "s/^[[:space:]]*${setting}[[:space:]]*//" || true
    fi
}

# Add or update a configuration line in a file.
update_config_line() {
    local config_type="$1"
    local file="$2"
    local setting_pattern="$3" # Regex pattern to find the line
    local full_line="$4"       # The full line to be added/updated
    local description="$5"

    if [[ "$DEBUG_MODE" == true && $full_line =~ ls ]]; then
        print_debug "update_config_line called with:"
        print_debug "  config_type: $config_type"
        print_debug "  file: $file"
        print_debug "  setting_pattern: $setting_pattern"
        print_debug "  full_line: $full_line"
        print_debug "  description: $description"
    fi

    if config_exists "$file" "$setting_pattern"; then
        # Setting exists, check if it's already correct
        local escaped_full_line=$(escape_regex "$full_line")
        if grep_file -qE "^[[:space:]]*${escaped_full_line}[[:space:]]*$" "$file"; then
            print_success "- $description already configured correctly"
            return 0
        else
            local current_value=$(grep_file -E "^[[:space:]]*${setting_pattern}" "$file" | head -n 1)
            print_warning "⚠ $description has different value: '$current_value' in $file"
            backup_file "$file"
            add_change_header "$file" "$config_type"

            local temp_file
            temp_file=$(mktemp)
            TEMP_FILES+=("$temp_file")
            local original_perms=$(get_file_permissions "$file")

            # Use awk to find the line, comment it, and append the new line at the end of the file
            if ! awk -v pattern="^[[:space:]]*${setting_pattern}" -v new_line="${full_line}" '
            BEGIN { found=0 }
            $0 ~ pattern {
                "date +%Y-%m-%d" | getline datestr;
                print "# " $0 " # Replaced by kubernetes-setup.sh on " datestr;
                found=1;
                next;
            }
            { print }
            END {
                if (found) {
                    print new_line;
                }
            }
            ' "$file" > "$temp_file"; then
                rm -f "$temp_file"
                print_error "✖ Failed to process $file with awk"
                return 1
            fi

            # Replace the original file with the updated temporary file
            # and restore original permissions (mktemp creates files with 600)
            if needs_elevation "$file"; then
                if ! run_elevated mv "$temp_file" "$file"; then
                    rm -f "$temp_file"
                    print_error "✖ Failed to update $file"
                    return 1
                fi
                run_elevated chmod "$original_perms" "$file"
            else
                if ! mv "$temp_file" "$file"; then
                    rm -f "$temp_file"
                    print_error "✖ Failed to update $file"
                    return 1
                fi
                chmod "$original_perms" "$file"
            fi
            print_success "✓ $description updated in $file"
        fi
    else
        backup_file "$file"
        add_change_header "$file" "$config_type"
        if needs_elevation "$file"; then
            echo "$full_line" | run_elevated tee -a "$file" > /dev/null
        else
            echo "$full_line" >> "$file"
        fi
        print_success "✓ $description added to $file"
    fi
}

# Wrapper for simple key-value or key-only settings
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

    # The pattern is the setting key itself
    if [[ $setting =~ ^[[:space:]]*set[[:space:]]+ ]]; then
        local setting_key=${setting#set }
        local escaped_key=$(escape_regex "$setting_key")
        local setting_pattern="set[[:space:]]+${escaped_key}"
    else
        local setting_pattern="${escaped_setting}"
    fi

    update_config_line "$config_type" "$file" "$setting_pattern" "$full_setting" "$description"
}

# Wrapper for shell exports
add_export_if_needed() {
    local file="$1"
    local var_name="$2"
    local var_value="$3"
    local description="$4"

    local full_export="export ${var_name}=${var_value}"
    # The pattern finds 'export NAME='
    local setting_pattern="export[[:space:]]+${var_name}="

    update_config_line "shell" "$file" "$setting_pattern" "$full_export" "$description"
}

# Ensure a file ends with exactly N blank lines (default: 1)
# Usage: normalize_trailing_newlines <file> [num_lines]
normalize_trailing_newlines() {
    local file="$1"
    local num_lines="${2:-1}"
    local original_perms
    original_perms=$(get_file_permissions "$file")
    local temp_file
    temp_file=$(mktemp)
    TEMP_FILES+=("$temp_file")

    # Remove all trailing blank lines (last content line keeps its newline)
    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$file" > "$temp_file"

    # Add (N-1) more newlines since the last line already ends with one
    local i
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

# ============================================================================
# Summary Functions
# ============================================================================

# Print a summary of all changes made
print_session_summary() {
    if [[ ${#BACKED_UP_FILES[@]} -eq 0 && ${#CREATED_BACKUP_FILES[@]} -eq 0 && ${#CREATED_CONFIG_FILES[@]} -eq 0 ]]; then
        echo -e "            ${GRAY}No files were modified during this session.${NC}"
        return
    fi

    local file

    print_summary "─── Session ─────────────────────────────────────────────────────────"
    echo ""

    if [[ ${#CREATED_CONFIG_FILES[@]} -gt 0 ]]; then
        print_info "Files Created:"
        for file in "${CREATED_CONFIG_FILES[@]+"${CREATED_CONFIG_FILES[@]}"}"; do
            echo "            - $file"
        done
        echo ""
    fi

    if [[ ${#BACKED_UP_FILES[@]} -gt 0 ]]; then
        print_success "Files Updated:"
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

# ============================================================================
# Self-Update Functions
# ============================================================================
_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _UTILS_DIR
readonly REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/kubernetes"
DOWNLOAD_CMD=""

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
        print_warning_box \
            "UPDATES NOT AVAILABLE" \
            "" \
            "Neither 'curl' nor 'wget' is installed on this system." \
            "Self-updating functionality requires one of these tools." \
            "" \
            "To enable self-updating, please install one of the following:" \
            "  • curl  (recommended)" \
            "  • wget" \
            "" \
            "Installation commands:" \
            "  Debian:   apt install curl" \
            "  RHEL:     yum install curl" \
            "" \
            "Continuing with local version of the scripts..."
        return 1
    fi
}

# Download a script file from the remote repository
# Args: $1 = script filename (relative path from REMOTE_BASE), $2 = output file path
# Returns: 0 on success, 1 on failure
download_script() {
    local script_file="$1"
    local output_file="$2"
    local http_status=""

    print_info "Fetching ${script_file}..."
    echo "            ▶ ${REMOTE_BASE}/${script_file}..."

    if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
        # Drop -f so 4xx/5xx populate http_status cleanly; --max-time 15 prevents
        # multi-minute hangs against sinkholed networks. Empty status => transport
        # failure (DNS/timeout/connect) — set explicit "000" sentinel.
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
                    rm -f "${output_file}"
                    return 1
                fi
                ;;
            429) print_error "✖ Rate limited by GitHub (HTTP 429)"; rm -f "${output_file}"; return 1 ;;
            000) print_error "✖ Download failed (network/timeout)"; rm -f "${output_file}"; return 1 ;;
            *)   print_error "✖ HTTP ${http_status} error"; rm -f "${output_file}"; return 1 ;;
        esac
    elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
        local wget_exit=0
        wget --no-cache --no-cookies \
            --timeout=15 \
            -O "${output_file}" -q "${REMOTE_BASE}/${script_file}" 2>/dev/null \
            || wget_exit=$?
        if [[ "$wget_exit" -ne 0 ]]; then
            print_error "✖ Download failed (wget exit ${wget_exit})"
            rm -f "${output_file}"
            return 1
        fi
        if head -n 10 "${output_file}" | grep -q "^#!/"; then
            return 0
        else
            print_error "✖ Invalid content received (not a script)"
            rm -f "${output_file}"
            return 1
        fi
    fi

    return 1
}

# Check for updates to the utils file and the calling script
# Called at the start of main() or inside the source guard of each script
# Args: $1 = caller script path (${BASH_SOURCE[0]}), remaining args = original script args
check_for_updates() {
    local caller_script="$1"
    shift

    [[ -n "${K8S_SCRIPTS_UPDATED:-}" ]] && return 0

    detect_download_cmd || return 0

    local utils_basename
    utils_basename=$(basename "${BASH_SOURCE[0]}")
    local caller_abs
    caller_abs="$(cd "$(dirname "$caller_script")" && pwd)/$(basename "$caller_script")"
    local caller_relpath="${caller_abs#"${_UTILS_DIR}/"}"
    local any_updated=false
    local temp_file

    print_info "Checking for updates..."

    # Check utils file. Template adjacent to destination so `mv` is atomic
    # rename(2) (same FS), not copy+unlink. ~name.tmp.XXXXXX matches the sweep
    # glob and is unambiguous enough that no user spontaneously creates it.
    temp_file=$(mktemp "${_UTILS_DIR}/~${utils_basename}.tmp.XXXXXX")
    TEMP_FILES+=("$temp_file")
    if download_script "$utils_basename" "$temp_file"; then
        if ! diff -q "${_UTILS_DIR}/${utils_basename}" "$temp_file" > /dev/null 2>&1; then
            show_diff_box "${_UTILS_DIR}/${utils_basename}" "$temp_file" "$utils_basename"
            if prompt_yes_no "→ Update ${utils_basename}?" "y"; then
                chmod +x "$temp_file"
                if ! mv -f "$temp_file" "${_UTILS_DIR}/${utils_basename}"; then
                    rm -f "$temp_file"
                    print_error "✖ Failed to install update — keeping local version"
                    return 1
                fi
                print_success "✓ Updated ${utils_basename}"
                any_updated=true
            else
                print_info "Skipped ${utils_basename}"
                rm -f "$temp_file"
            fi
        else
            print_success "- ${utils_basename} is up-to-date"
            rm -f "$temp_file"
        fi
    else
        rm -f "$temp_file"
    fi

    # Check calling script. Use caller_abs (already resolved) for path-sensitive
    # operations — the raw ${BASH_SOURCE[0]} caller_script may be a bare basename
    # when invoked via PATH or bash <name>, breaking ${caller_script%/*} dirname
    # extraction and PATH-resolved exec.
    temp_file=$(mktemp "$(dirname "$caller_abs")/~$(basename "$caller_abs").tmp.XXXXXX")
    TEMP_FILES+=("$temp_file")
    if download_script "$caller_relpath" "$temp_file"; then
        if ! diff -q "$caller_abs" "$temp_file" > /dev/null 2>&1; then
            show_diff_box "$caller_abs" "$temp_file" "$caller_relpath"
            if prompt_yes_no "→ Update ${caller_relpath}?" "y"; then
                chmod +x "$temp_file"
                if ! mv -f "$temp_file" "$caller_abs"; then
                    rm -f "$temp_file"
                    print_error "✖ Failed to install update — keeping local version"
                    return 1
                fi
                print_success "✓ Updated ${caller_relpath}"
                any_updated=true
            else
                print_info "Skipped ${caller_relpath}"
                rm -f "$temp_file"
            fi
        else
            print_success "- ${caller_relpath} is up-to-date"
            rm -f "$temp_file"
        fi
    else
        rm -f "$temp_file"
    fi

    if [[ "$any_updated" == "true" ]]; then
        print_success "Restarting with updated scripts..."
        export K8S_SCRIPTS_UPDATED=1
        exec "$caller_abs" "$@"
    fi
}
