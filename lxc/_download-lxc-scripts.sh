#!/usr/bin/env bash

# _download-lxc-scripts.sh - LXC Script Management and Auto-Updater
#
# Usage: ./_download-lxc-scripts.sh
#
# This script:
# - Self-updates from the remote repository before running
# - Downloads the latest versions of all LXC management scripts
# - Shows diffs for changed files before updating
# - Prompts for confirmation before overwriting local files
# - Preserves executable permissions on downloaded scripts
# - Removes obsolete scripts on request, and exits 1 if any download failed
#
# The script checks for curl or wget and uses whichever is available.
# If neither is installed, it displays installation instructions and continues
# with the local version of the script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=utils-lxc.sh
source "${SCRIPT_DIR}/utils-lxc.sh"

# List of script files to download/update (excludes _download-lxc-scripts.sh and utils-lxc.sh)
get_script_list() {
    echo "backup-lxc.sh"
    echo "config-lxc-ssh.sh"
    echo "create-lxc.sh"
    echo "destroy-lxc.sh"
    echo "protect-lxc.sh"
    echo "restart-lxc.sh"
    echo "restore-lxc.sh"
    echo "setup-lxc.sh"
    echo "start-lxc.sh"
    echo "stop-lxc.sh"
    echo "unprotect-lxc.sh"
    echo "watch-lxc.sh"
}

# List of obsolete scripts to clean up (renamed or removed from repository)
# Add filenames here when scripts are renamed or deprecated
OBSOLETE_SCRIPTS=(
    "refresh-lxc.sh"      # renamed to restart-lxc.sh
    "create-priv-lxc.sh"  # absorbed into create-lxc.sh --privileged
)

# Update all script files (managed scripts)
# Downloads each script and prompts user to replace if different
# Continues processing all scripts even if some downloads fail
# Returns: 1 if any downloads failed, 0 otherwise
update_modules() {
    local uptodate_count=0
    local updated_count=0
    local skipped_count=0
    local failed_count=0

    print_info "Checking for LXC script updates..."
    echo ""

    # Check each script for updates
    while IFS= read -r script_path; do
        local SCRIPT_FILE="$script_path"
        local LOCAL_SCRIPT="${SCRIPT_DIR}/${SCRIPT_FILE}"
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
                # Both steps inside the chain: update_modules is invoked in a
                # `||` list, which suspends errexit for its whole body, so a bare
                # chmod that failed would install anyway. `chmod 755`, not `+x` —
                # `+x` on a 0600 mktemp file is umask-relative (0711 under umask
                # 022): runnable by its owner, unreadable by anyone else.
                if chmod 755 "${TEMP_SCRIPT_FILE}" && mv -f "${TEMP_SCRIPT_FILE}" "${LOCAL_SCRIPT}"; then
                    print_success "✓ Replaced ${SCRIPT_FILE}"
                    ((updated_count++)) || true
                else
                    rm -f "${TEMP_SCRIPT_FILE}"
                    print_error "✖ Failed to install update — keeping local version"
                    ((failed_count++)) || true
                    echo ""
                    continue
                fi
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
    print_info "LXC Script Update Summary"
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

main() {
    sweep_stale_temps '~*.tmp.??????'
    check_for_updates "${BASH_SOURCE[0]}" "$@"
    [[ -n "$DOWNLOAD_CMD" ]] || return 0

    # update_modules keeps going past individual download failures and RETURNS
    # 1 to report them. Run the obsolete-script cleanup regardless, then surface
    # the failure as this script's exit status — called bare under `set -e` it
    # aborted here and skipped the cleanup.
    local update_rc=0
    update_modules || update_rc=1
    cleanup_obsolete_scripts "${OBSOLETE_SCRIPTS[@]+"${OBSOLETE_SCRIPTS[@]}"}"
    return "$update_rc"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
