#!/usr/bin/env bash

# reset-macOS-display-settings.sh — reset macOS WindowServer display preferences.
#
# Removes the system-wide and per-user (ByHost) WindowServer display-preference
# plists that macOS uses to remember monitor resolution, arrangement, and mirroring.
# Useful when displays are misdetected, stuck at the wrong resolution, or the
# arrangement is corrupted after a monitor/dock change. macOS regenerates these
# plists automatically on next login/restart.
#
# Every plist is backed up (<file>.backup.<timestamp>.bak) before removal, and the
# whole operation requires an explicit confirmation (default: no) since it is
# destructive. The script runs as the invoking user; only the system-plist
# cp/rm are elevated via sudo, so check_for_updates still writes user-owned files.

set -euo pipefail
[[ "${TRACE-0}" == "1" ]] && set -o xtrace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=utils-misc.sh
source "${SCRIPT_DIR}/utils-misc.sh"

readonly SYSTEM_DISPLAYS_PLIST="/Library/Preferences/com.apple.windowserver.displays.plist"

show_usage() { cat <<EOF
Usage: ${0##*/}

Resets macOS display configuration by removing the WindowServer display
preference plists (system-wide and per-user ByHost). Useful when displays
are misdetected, resolutions are stuck, or window arrangement is corrupted.

Every plist is backed up before removal (<file>.backup.<timestamp>.bak).
You will be prompted to confirm before anything is changed or removed.

Options:
  -h, --help    Show this help and exit

Note: macOS only. Log out or restart afterward for changes to take effect.
EOF
}

main() {
    local a
    for a in "$@"; do
        [[ "$a" == "-h" || "$a" == "--help" ]] && { show_usage; exit 0; }
    done

    [[ "$OSTYPE" == darwin* ]] || { print_error "macOS only"; exit 1; }

    sweep_stale_temps '~*.tmp.??????'
    check_for_updates "${BASH_SOURCE[0]}" "$@"

    prompt_yes_no "Reset macOS display settings now?" "n" || { print_info "Skipped"; return 0; }

    local stamp
    stamp="$(date +%Y%m%d_%H%M%S)"

    if [[ -f "$SYSTEM_DISPLAYS_PLIST" ]]; then
        local system_backup="${SYSTEM_DISPLAYS_PLIST}.backup.${stamp}.bak"
        sudo cp -p "$SYSTEM_DISPLAYS_PLIST" "$system_backup"
        print_backup "- Created backup: $system_backup"
        sudo rm -f "$SYSTEM_DISPLAYS_PLIST"
        print_success "✓ Removed $SYSTEM_DISPLAYS_PLIST"
    else
        print_info "Not present: $SYSTEM_DISPLAYS_PLIST"
    fi

    shopt -s nullglob
    local f found=0
    for f in "$HOME"/Library/Preferences/ByHost/com.apple.windowserver.displays.*.plist; do
        found=1
        cp -p "$f" "${f}.backup.${stamp}.bak"
        print_backup "- Created backup: ${f}.backup.${stamp}.bak"
        rm -f "$f"
        print_success "✓ Removed $f"
    done
    shopt -u nullglob
    [[ "$found" -eq 0 ]] && print_info "No ByHost display plists present"

    print_warning "⚠ Log out or restart for changes to take effect."
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
