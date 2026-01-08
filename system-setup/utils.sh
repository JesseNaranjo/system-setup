#!/usr/bin/env bash

# utils.sh - Common utilities and variables for system-setup scripts
# This script provides shared functionality used across all system-setup modules

# Prevent multiple sourcing
if [[ -n "${UTILS_SH_LOADED:-}" ]]; then
    return 0
fi
readonly UTILS_SH_LOADED=true

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

DEBUG_MODE=false
DETECTED_OS=""
DETECTED_PKG_MANAGER=""
BACKED_UP_FILES=()
CREATED_BACKUP_FILES=()
HEADER_ADDED_FILES=()
CURL_INSTALLED=false
FASTFETCH_INSTALLED=false
NANO_INSTALLED=false
SCREEN_INSTALLED=false
OPENSSH_SERVER_INSTALLED=false
RUNNING_IN_CONTAINER=false

# Package cache for performance optimization
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
    echo -e "${RED}[ ERROR   ]${NC} $1"
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
# Extensible: Add new package managers by adding elif blocks
detect_package_manager() {
    if command -v apt &>/dev/null; then
        DETECTED_PKG_MANAGER="apt"
    elif command -v brew &>/dev/null; then
        DETECTED_PKG_MANAGER="brew"
    elif command -v dnf &>/dev/null; then
        DETECTED_PKG_MANAGER="dnf"
    elif command -v zypper &>/dev/null; then
        DETECTED_PKG_MANAGER="zypper"
    # Future: Add more package managers here
    # elif command -v pacman &>/dev/null; then
    #     DETECTED_PKG_MANAGER="pacman"
    else
        DETECTED_PKG_MANAGER="unknown"
    fi
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
            print_error "Insufficient privileges to run: $*"
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

# Get package definitions for the given OS
get_package_list() {
    if [[ "$DETECTED_OS" == "macos" ]]; then
        # macOS packages (brew)
        echo "7-zip:sevenzip"
        echo "Apple Containers:container"
        echo "AWK:awk"
        echo "Bash:bash"
        echo "CA Certificates:ca-certificates"
        echo "cURL:curl"
        echo "Fastfetch:fastfetch"
        echo "Git:git"
        echo "htop:htop"
        echo "Monocle:monocle-app"
        echo "Nano Editor:nano"
        echo "Ollama:ollama"
        echo "OrbStack:orbstack"
        echo "Screen (GNU):screen"
        echo "UTM:utm"
    else
        # Linux packages (apt)
        echo "7-zip:7zip"
        echo "aptitude:aptitude"
        echo "ca-certificates:ca-certificates"
        echo "cURL:curl"
        echo "Fastfetch:fastfetch"
        echo "Git:git"
        echo "gpm:gpm"
        echo "htop:htop"
        echo "jq (JSON data processor):jq"
        echo "Nano Editor:nano"
        echo "OpenSSH Server:openssh-server"
        echo "Screen (GNU):screen"
        echo "sudo:sudo"
    fi
}

# Get packages that should be removed if installed
# Returns: "Display Name:package-name" pairs for packages to remove
get_removable_package_list() {
    if [[ "$DETECTED_OS" == "macos" ]]; then
        # macOS packages to remove (brew)
        # Empty for now - add packages here as needed
        :
    else
        # Linux packages to remove (apt)
        # These are typically unnecessary locale/i18n packages
        echo "Debconf i18n:debconf-i18n"
        echo "GnuPG Utils:gnupg-utils"
        echo "GPG WKS Client:gpg-wks-client"
        echo "GPG Error l10n:libgpg-error-l10n"
        echo "Util-Linux Locales:util-linux-locales"
        echo "Kerberos Locales:krb5-locales"
    fi
}

# Populate the package cache with installed packages from the package list
populate_package_cache() {
    if [[ "$DEBUG_MODE" == true ]]; then
        print_debug "Populating package cache..."
    fi

    # Get all package names from the package list
    local package_list=()
    while read -r line; do
        package_list+=("${line##*:}")
    done < <(get_package_list)

    local installed_packages
    if [[ "$DETECTED_OS" == "macos" ]]; then
        # Get all installed packages from brew (both formulae and casks)
        local installed_formulae=$(brew list --formula -1 2>/dev/null || true)
        local installed_casks=$(brew list --cask -1 2>/dev/null || true)
        installed_packages=$(printf "%s\n%s" "$installed_formulae" "$installed_casks")
    else
        # Get all installed packages from dpkg
        installed_packages=$(dpkg -l 2>/dev/null | awk '/^ii/ {print $2}' || true)
    fi

    PACKAGE_CACHE=()
    # Check each package from our list against installed packages
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
        for pkg in "${!PACKAGE_CACHE[@]}"; do
            print_debug "  $pkg: ${PACKAGE_CACHE[$pkg]}"
        done
    fi
}

# Check if a package is installed (unified for both macOS and Linux)
# Uses cache for performance optimization
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

    # Fallback to direct check if not in cache (shouldn't happen normally)
    if [[ "$DETECTED_OS" == "macos" ]]; then
        brew list --formula "$package" &>/dev/null || brew list --cask "$package" &>/dev/null
    else
        dpkg -l "$package" 2>/dev/null | grep -q "^ii"
    fi
}

# Verify package manager is available
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
    return 0
}

# Track if specific packages are installed for later configuration
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
        if [[ "$DETECTED_OS" == "macos" ]]; then
            # macOS stat syntax
            local owner=$(stat -f "%u:%g" "$file")
            if needs_elevation "$file"; then
                run_elevated chown "$owner" "$backup" 2>/dev/null
            else
                chown "$owner" "$backup" 2>/dev/null || true
            fi
        else
            # Linux stat syntax
            local owner=$(stat -c "%u:%g" "$file")
            if needs_elevation "$file"; then
                run_elevated chown "$owner" "$backup" 2>/dev/null
            else
                chown "$owner" "$backup" 2>/dev/null || true
            fi
        fi

        print_backup "- Created backup: $backup"
        BACKED_UP_FILES+=("$file")
        CREATED_BACKUP_FILES+=("$backup")
    fi
}

# Add change header to file (only once per session)
add_change_header() {
    local file="$1"
    local config_type="$2"  # "nano", "screen", or "shell"
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
        nano)
            header_line="# nano configuration - managed by system-setup.sh"
            ;;
        screen)
            header_line="# GNU screen configuration - managed by system-setup.sh"
            ;;
        shell)
            header_line="# Shell configuration - managed by system-setup.sh"
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

# Escape special regex characters in a string for use in grep/sed patterns
# Usage: escaped=$(escape_regex "string with $pecial (chars)")
escape_regex() {
    printf '%s' "$1" | sed 's/[.[\(*^$+?{|\\]/\\&/g'
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
            print_warning "✖ $description has different value: '$current_value' in $file"
            backup_file "$file"
            add_change_header "$file" "$config_type"

            local temp_file=$(mktemp)

            # Use awk to find the line, comment it, and append the new line at the end of the file
            awk -v pattern="^[[:space:]]*${setting_pattern}" -v new_line="${full_line}" '
            BEGIN { found=0 }
            $0 ~ pattern {
                "date +%Y-%m-%d" | getline datestr;
                print "# " $0 " # Replaced by system-setup.sh on " datestr;
                found=1;
                next;
            }
            { print }
            END {
                if (found) {
                    print new_line;
                }
            }
            ' "$file" > "$temp_file"

            # Replace the original file with the updated temporary file
            if needs_elevation "$file"; then
                run_elevated mv "$temp_file" "$file"
            else
                mv "$temp_file" "$file"
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

# Wrapper for simple key-value or key-only settings (e.g., nano, screen)
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

# Wrapper for shell aliases
add_alias_if_needed() {
    local file="$1"
    local alias_name="$2"
    local alias_value="$3"
    local description="$4"

    local full_alias="alias ${alias_name}='${alias_value}'"
    # The pattern finds 'alias name='
    local setting_pattern="alias[[:space:]]+${alias_name}="

    update_config_line "shell" "$file" "$setting_pattern" "$full_alias" "$description"
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
    local temp_file=$(mktemp)

    # Remove all trailing blank lines (last content line keeps its newline)
    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$file" > "$temp_file"

    # Add (N-1) more newlines since the last line already ends with one
    for ((i=1; i<num_lines; i++)); do
        printf '\n' >> "$temp_file"
    done

    run_elevated mv "$temp_file" "$file"
}

# ============================================================================
# Summary Functions
# ============================================================================

# Print a summary of all changes made
print_session_summary() {
    if [[ ${#BACKED_UP_FILES[@]} -eq 0 && ${#CREATED_BACKUP_FILES[@]} -eq 0 ]]; then
        echo -e "            ${GRAY}No files were modified during this session.${NC}"
        return
    fi

    print_summary "─── Session ─────────────────────────────────────────────────────────"
    echo ""

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
