#!/usr/bin/env bash

# destroy-lxc.sh - Destroy an LXC container
#
# Usage: ./destroy-lxc.sh <container_name>
#
# Permanently destroys a container: stops it if running, destroys it with
# lxc-destroy, then cleans up its systemd service instance and drop-ins.
# Refuses a protected container — run unprotect-lxc.sh first.
#
# When run as root (e.g., via sudo), the script operates on privileged
# (system-scope) containers. Otherwise, it operates on unprivileged
# (user-scope) containers.
#
# Examples:
#   ./destroy-lxc.sh mycontainer            # Destroy a specific container
#   sudo ./destroy-lxc.sh web               # Destroy a privileged container

set -euo pipefail

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck source=utils-lxc.sh
source "${SCRIPT_DIR}/utils-lxc.sh"

# ============================================================================
# Main Script
# ============================================================================

show_usage() {
    echo "Usage: ${0##*/} <container_name>"
    echo ""
    echo "Permanently destroys a container: stops it if running, destroys it"
    echo "with lxc-destroy, then cleans up its systemd service instance and"
    echo "drop-ins. Refuses a protected container — run unprotect-lxc.sh first."
    echo ""
    echo "Options:"
    echo "  --help, -h    Show this help"
    echo ""
    echo "Run as root (sudo) for privileged containers, or as a regular user"
    echo "for unprivileged ones — the scope follows the invoking EUID."
}

main() {
    check_for_updates "${BASH_SOURCE[0]}" "$@"

    local CONTAINER_NAME=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_usage
                exit 0
                ;;
            -*)
                print_error "✖ Unknown option: $1"
                show_usage
                exit 64  # EX_USAGE
                ;;
            *)
                if [[ -n "$CONTAINER_NAME" ]]; then
                    print_error "✖ One container at a time: $1"
                    show_usage
                    exit 64  # EX_USAGE
                fi
                CONTAINER_NAME="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$CONTAINER_NAME" ]]; then
        print_error "✖ Missing required container name argument"
        show_usage
        exit 64  # EX_USAGE
    fi

    if ! lxc_valid_name "$CONTAINER_NAME"; then
        print_error "✖ Invalid container name: ${CONTAINER_NAME}"
        exit 64  # EX_USAGE
    fi

    # Root = privileged (system-scope), non-root = unprivileged (user-scope).
    # Same names and drop-in base start-lxc.sh derives.
    local LXC_PATH SERVICE_PREFIX DROPIN_BASE
    local SYSTEMCTL_CMD=()
    LXC_PATH="$(lxc_resolve_path)"
    if [[ $EUID == 0 ]]; then
        SERVICE_PREFIX="lxc-priv-bg-start"
        SYSTEMCTL_CMD=(systemctl)
        DROPIN_BASE="/etc/systemd/system"
    else
        SERVICE_PREFIX="lxc-bg-start"
        SYSTEMCTL_CMD=(systemctl --user)
        DROPIN_BASE="${HOME}/.config/systemd/user"
    fi

    local CONFIG_FILE="${LXC_PATH}/${CONTAINER_NAME}/config"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "✖ No such container: ${CONTAINER_NAME} (looked for ${CONFIG_FILE})"
        exit 66  # EX_NOINPUT
    fi

    if lxc_is_protected "$CONFIG_FILE"; then
        print_error "✖ ${CONTAINER_NAME} is protected (since $(lxc_protected_since "$CONFIG_FILE"))"
        print_info "Run: $( [[ $EUID == 0 ]] && echo "sudo " )./unprotect-lxc.sh ${CONTAINER_NAME}"
        exit 77  # EX_NOPERM
    fi

    print_warning "⚠ This permanently destroys ${CONTAINER_NAME} and everything in its rootfs."
    print_warning "⚠ This container is NOT protected."
    echo ""
    if ! prompt_yes_no "            Destroy ${CONTAINER_NAME}?" "n"; then
        print_info "Operation cancelled by user"
        exit 75  # EX_TEMPFAIL
    fi
    echo ""

    print_info "Step 1/3: Stopping container..."
    # Same running check backup-lxc.sh and restore-lxc.sh make before calling
    # stop-lxc.sh: on an already-stopped container stop-lxc.sh prints an ERROR
    # line (with print_error's bell and 2-second pause) and still exits 0.
    if lxc-info -n "${CONTAINER_NAME}" -s 2>/dev/null | grep -q "RUNNING"; then
        "${SCRIPT_DIR}/stop-lxc.sh" "$CONTAINER_NAME"
    else
        print_success "- Container is not running"
    fi
    echo ""

    print_info "Step 2/3: Destroying container..."
    # No -f and no -s on purpose. stop-lxc.sh exits 0 even when lxc-stop fails,
    # so this call is the backstop: a container still running, or one with
    # snapshots, fails here with liblxc's own message instead of being forced.
    if lxc-destroy --name "$CONTAINER_NAME"; then
        print_success "✓ Container destroyed: ${CONTAINER_NAME}"
    else
        print_error "✖ Failed to destroy container: ${CONTAINER_NAME}"
        exit 1
    fi
    echo ""

    # Cleaned LAST on purpose: a destroy that failed above leaves a live
    # container, which must keep the delegation / no-swap drop-ins that
    # start-lxc.sh --k8s persisted and its auto-start enablement.
    print_info "Step 3/3: Cleaning up systemd state..."
    # The per-container INSTANCE only — never the ${SERVICE_PREFIX}@.service
    # template that setup-lxc.sh installs once for every container.
    # `stop` first: the template is RemainAfterExit=yes and lxc-start
    # daemonises, so a guest that shut itself down (or was stopped with a bare
    # lxc-stop) leaves the instance `active (exited)`. The RUNNING gate above
    # then skipped stop-lxc.sh, `disable` never stops a unit, and `systemctl
    # start` on an active unit is a no-op — the next same-name container would
    # silently never start. Every call is `|| true`: most containers were never
    # enabled (setup-lxc.sh only prints the enable command as a manual step),
    # and a user-scope call fails outright when no user manager is running —
    # none of which may turn a completed destroy into a non-zero exit. The
    # drop-in removal below warns for the same reason: the container is already
    # gone by then, so a leftover drop-in directory is a cleanup note, not a
    # failed destroy.
    local SERVICE="${SERVICE_PREFIX}@${CONTAINER_NAME}.service"
    "${SYSTEMCTL_CMD[@]}" stop "$SERVICE" 2>/dev/null || true
    # The stop's ExecStop (lxc-stop) runs against a container that no longer
    # exists, so an active instance lands in `failed`; reset-failed clears it so
    # the destroyed container leaves no residue in `systemctl --failed`.
    "${SYSTEMCTL_CMD[@]}" reset-failed "$SERVICE" 2>/dev/null || true
    "${SYSTEMCTL_CMD[@]}" disable "$SERVICE" 2>/dev/null || true
    local DROPIN_DIR="${DROPIN_BASE}/${SERVICE}.d"
    if [[ -d "$DROPIN_DIR" ]]; then
        if rm -rf "$DROPIN_DIR"; then
            "${SYSTEMCTL_CMD[@]}" daemon-reload 2>/dev/null \
                || print_warning "⚠ daemon-reload failed — run '${SYSTEMCTL_CMD[*]} daemon-reload' by hand"
            print_success "✓ Drop-ins removed: ${DROPIN_DIR}"
        else
            print_warning "⚠ Failed to remove drop-ins — remove '${DROPIN_DIR}' by hand"
        fi
    else
        print_success "- No drop-ins to remove"
    fi
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
