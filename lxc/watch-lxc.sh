#!/usr/bin/env bash

# watch-lxc.sh - Live status display for LXC containers and host disk usage
#
# Usage: ./watch-lxc.sh
#
# Refreshes the screen every 5 seconds with:
#   1. lxc-ls --fancy   (container list)
#   2. df -h /          (host root filesystem usage)
#
# Press Ctrl+C to stop.
#
# When run as root (e.g., via sudo), lxc-ls reports privileged
# (system-scope) containers. Otherwise it reports unprivileged
# (user-scope) containers.

set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck source=utils-lxc.sh
source "${SCRIPT_DIR}/utils-lxc.sh"

readonly WATCH_INTERVAL=5

declare -g _WATCH_RESIZE=0

cleanup_watch() {
    # Drop below the rendered frame so the next shell prompt lands on a fresh line
    echo ""
}

watch_loop() {
    trap cleanup_watch EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap '_WATCH_RESIZE=1' WINCH

    clear
    while true; do
        if (( _WATCH_RESIZE )); then
            clear
            _WATCH_RESIZE=0
        else
            tput cup 0 0
            tput ed
        fi

        echo -e "LXC ($(date '+%Y-%m-%d %H:%M:%S'))  ${GRAY}[Watching every ${WATCH_INTERVAL}s - Ctrl+C to stop]${NC}"
        echo ""
        /usr/bin/lxc-ls --fancy || print_warning "⚠ lxc-ls failed (continuing)"
        echo ""
        df -h /
        sleep "$WATCH_INTERVAL"
    done
}

main() {
    check_for_updates "${BASH_SOURCE[0]}" "$@"

    if (( $# > 0 )); then
        print_error "✖ Unexpected argument(s): $*"
        print_info "Usage: ./watch-lxc.sh"
        exit 64  # EX_USAGE
    fi

    if [[ ! -x /usr/bin/lxc-ls ]]; then
        print_error "✖ /usr/bin/lxc-ls not found — is LXC installed?"
        exit 69  # EX_UNAVAILABLE
    fi

    watch_loop
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
