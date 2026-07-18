#!/usr/bin/env bash
set -euo pipefail
[[ "${TRACE-0}" == "1" ]] && set -o xtrace

# unlock-keychain.sh — unlock the login keychain in the CURRENT shell/session.
#
# macOS gates the login keychain per GUI-login session: `security find-generic-password` (how
# himalaya reads plain-IMAP passwords via backend.auth.command) fails from a raw SSH shell with
# errSecInteractionNotAllowed (exit 36). Run this in that SSH session to unlock the login keychain
# there (prompts once for your macOS login password); afterwards himalaya's `security` command works
# in the same shell.
#
# The scheduled launchd run does NOT need this — it already runs in the GUI login session.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=utils-misc.sh
source "${SCRIPT_DIR}/utils-misc.sh"

readonly LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

show_usage() { cat <<EOF
Usage: ${0##*/}

Unlocks the macOS login keychain in the current shell/session so that
'security find-generic-password' works from a raw SSH shell.

Options:
  -h, --help    Show this help and exit
EOF
}

main() {
    local a
    for a in "$@"; do
        [[ "$a" == "-h" || "$a" == "--help" ]] && { show_usage; exit 0; }
    done

    command -v security >/dev/null || { print_error "'security' not found (macOS only)"; exit 1; }
    [[ -f "$LOGIN_KEYCHAIN" ]] || { print_error "keychain not found: $LOGIN_KEYCHAIN"; exit 1; }

    sweep_stale_temps '~*.tmp.??????'
    check_for_updates "${BASH_SOURCE[0]}" "$@"

    print_info "Unlocking $LOGIN_KEYCHAIN (enter your macOS login password when prompted)…"
    security unlock-keychain "$LOGIN_KEYCHAIN"
    print_success "Login keychain unlocked for this session."
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
