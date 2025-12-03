#!/usr/bin/env bash

# _download-ollama-scripts.sh - Ollama Script Management and Auto-Updater
#
# Usage: ./_download-ollama-scripts.sh
#
# This script:
# - Self-updates from the remote repository before running
# - Downloads the latest versions of all Ollama management scripts
# - Shows diffs for changed files before updating
# - Prompts for confirmation before overwriting local files
# - Preserves executable permissions on downloaded scripts
#
# The script checks for curl or wget and uses whichever is available.
# If neither is installed, it displays installation instructions and continues
# with the local version of the script.

set -euo pipefail

# Colors for output
readonly BLUE='\033[0;34m'
readonly CYAN="\033[0;36m"
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Remote repository configuration
readonly REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/llm"

# List of script files to download/update (excludes _download-ollama-scripts.sh)
get_script_list() {
    echo "ollama-remote.sh"
    echo "ollama-screen.sh"
}

# List of obsolete scripts to clean up (renamed or removed from repository)
# Add filenames here when scripts are renamed or deprecated
OBSOLETE_SCRIPTS=()

# Clean up obsolete scripts that have been renamed or removed from the repository
# Usage: cleanup_obsolete_scripts "script1.sh" "script2.sh" ...
# Args: List of obsolete script filenames to remove
cleanup_obsolete_scripts() {
    # Safely handle empty argument list
    for obsolete_script in "${@+"$@"}"; do
        if [[ -f "${obsolete_script}" ]]; then
            echo -e "${RED}[ CLEANUP ]${NC} Found obsolete script: ${obsolete_script}"
            if prompt_yes_no "            → Delete ${obsolete_script}?" "n"; then
                rm -f "${obsolete_script}"
                print_success "✓ Deleted ${obsolete_script}"
            else
                print_warning "⚠ Kept ${obsolete_script}"
            fi
        fi
    done
}

# Print colored output
print_info() {
    echo -e "${BLUE}[ INFO    ]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[ SUCCESS ]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[ WARNING ]${NC} $1"
}

print_error() {
    echo -e "${RED}[ ERROR   ]${NC} $1"
}

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
# Self-Update Functionality
# ============================================================================

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
        # Display large error message if neither curl nor wget is available
        echo ""
        echo -e "            ${YELLOW}╔═════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}║                        ⚠️   UPDATES NOT AVAILABLE  ⚠️                         ║${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}║        Neither 'curl' nor 'wget' is installed on this system.               ║${NC}"
        echo -e "            ${YELLOW}║        Self-updating functionality requires one of these tools.             ║${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}║        To enable self-updating, please install one of the following:        ║${NC}"
        echo -e "            ${YELLOW}║          • curl  (recommended)                                              ║${NC}"
        echo -e "            ${YELLOW}║          • wget                                                             ║${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}║        Installation commands:                                               ║${NC}"
        echo -e "            ${YELLOW}║          macOS:    brew install curl                                        ║${NC}"
        echo -e "            ${YELLOW}║          Debian:   apt install curl                                         ║${NC}"
        echo -e "            ${YELLOW}║          RHEL:     yum install curl                                         ║${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}║        Continuing with local version of the scripts...                      ║${NC}"
        echo -e "            ${YELLOW}║                                                                             ║${NC}"
        echo -e "            ${YELLOW}╚═════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        return 1
    fi
}

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
            # Check first 10 lines for shebang to handle files with leading comments/blank lines
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
            # Validate that we got a script, not an error page
            # Check first 10 lines for shebang to handle files with leading comments/blank lines
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

# Check for updates to _download-ollama-scripts.sh itself
# This function only updates the main script and will restart if updated
self_update() {
    local SCRIPT_FILE="_download-ollama-scripts.sh"
    local LOCAL_SCRIPT="${BASH_SOURCE[0]}"
    local TEMP_SCRIPT_FILE="$(mktemp)"

    if ! download_script "${SCRIPT_FILE}" "${TEMP_SCRIPT_FILE}"; then
        rm -f "${TEMP_SCRIPT_FILE}"
        echo ""
        return 1
    fi

    # Compare and handle differences
    if diff -u "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
        print_success "- ${SCRIPT_FILE} is already up-to-date"
        rm -f "${TEMP_SCRIPT_FILE}"
        echo ""
        return 0
    fi

    # Show diff
    echo ""
    echo -e "${CYAN}╭────────────────────────────────────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────────────────────────────────╮${NC}"
    diff -u --color "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" || true
    echo -e "${CYAN}╰───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╯${NC}"
    echo ""

    if prompt_yes_no "→ Overwrite and restart with updated ${SCRIPT_FILE}?" "y"; then
        echo ""
        chmod +x "${TEMP_SCRIPT_FILE}"
        mv -f "${TEMP_SCRIPT_FILE}" "${LOCAL_SCRIPT}"
        print_success "✓ Updated ${SCRIPT_FILE} - restarting..."
        echo ""
        export scriptUpdated=1
        exec "${LOCAL_SCRIPT}" "$@"
        exit 0
    else
        print_warning "⚠ Skipped ${SCRIPT_FILE} update - continuing with local version"
        rm -f "${TEMP_SCRIPT_FILE}"
    fi
    echo ""
}

# Update all script files (managed scripts)
# Downloads each script and prompts user to replace if different
# Continues processing all scripts even if some downloads fail
# Returns: 1 if any downloads failed, 0 otherwise
update_modules() {
    local uptodate_count=0
    local updated_count=0
    local skipped_count=0
    local failed_count=0

    print_info "Checking for Ollama script updates..."
    echo ""

    # Check each script for updates
    while IFS= read -r script_path; do
        local SCRIPT_FILE="$script_path"
        local LOCAL_SCRIPT="${SCRIPT_FILE}"
        local TEMP_SCRIPT_FILE="$(mktemp)"

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
            echo ""
            echo -e "${CYAN}╭────────────────────────────────────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────────────────────────────────╮${NC}"
            diff -u --color "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" || true
            echo -e "${CYAN}╰───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╯${NC}"
            echo ""

            if prompt_yes_no "→ Overwrite local ${SCRIPT_FILE} with remote copy?" "y"; then
                echo ""
                chmod +x "${TEMP_SCRIPT_FILE}"
                mv -f "${TEMP_SCRIPT_FILE}" "${LOCAL_SCRIPT}"
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
    print_info "Ollama Script Update Summary"
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

# ============================================================================
# Main Orchestration
# ============================================================================

# Detect download command (curl or wget) for update functionality
if detect_download_cmd; then
    # Only run self-update if not already updated in this session
    if [[ ${scriptUpdated:-0} -eq 0 ]]; then
        self_update "$@"
    fi

    # Always check for module updates (not skipped by scriptUpdated) if download cmd available
    update_modules

    # Clean up any obsolete scripts
    cleanup_obsolete_scripts "${OBSOLETE_SCRIPTS[@]+"${OBSOLETE_SCRIPTS[@]}"}"
fi
