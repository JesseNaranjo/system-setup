#!/usr/bin/env bash

# watch-lxc.sh - Live status display for LXC containers and host disk usage
#
# Usage: ./watch-lxc.sh
#
# Refreshes the screen every 5 seconds with:
#   1. NAME STATE IPV4 IPV6 UNPRIVILEGED PROTECTED   (container list; PROTECTED
#      is read from each container's own config, not reported by lxc-ls)
#   2. df -h /                                       (host root filesystem usage)
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

# Render lxc-ls's fancy table without AUTOSTART/GROUPS and with a PROTECTED
# column appended. lxc-ls pads every column, the last one included, to a width
# initialised from the header and follows each with one space, so header and
# data rows are the same width and already end in the separator the new
# column needs.
# Usage: render_container_table "/var/lib/lxc"
render_container_table() {
    local lxc_path="$1"
    local output

    # stdout only: a liblxc diagnostic on stderr would land on the terminal
    # mid-repaint (the watch loop redraws with tput) and corrupt the frame.
    # A failure is still surfaced via the warning below.
    if ! output=$(/usr/bin/lxc-ls --fancy --fancy-format NAME,STATE,IPV4,IPV6,UNPRIVILEGED 2>/dev/null); then
        print_warning "⚠ lxc-ls failed (continuing)"
        return 0
    fi

    # lxc-ls prints nothing at all — not even a header — for an empty list.
    if [[ -z "$output" ]]; then
        print_warning "⚠ No containers defined under ${lxc_path}"
        return 0
    fi

    local table=()
    mapfile -t table <<< "$output"

    printf '%sPROTECTED\n' "${table[0]}"

    local row name i
    for (( i = 1; i < ${#table[@]}; i++ )); do
        row="${table[i]}"
        name="${row%% *}"
        if lxc_is_protected "${lxc_path}/${name}/config"; then
            printf '%s%byes%b\n' "$row" "$GREEN" "$NC"
        else
            printf '%sno\n' "$row"
        fi
    done
}

watch_loop() {
    local lxc_path="$1"

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
        render_container_table "$lxc_path"
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

    local LXC_PATH
    LXC_PATH="$(lxc_resolve_path)"
    watch_loop "$LXC_PATH"
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
