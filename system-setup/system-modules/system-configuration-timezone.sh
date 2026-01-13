#!/usr/bin/env bash

# system-configuration-timezone.sh - Configure system timezone
# Part of the system-setup suite
#
# This script:
# - Checks if the system timezone is set to UTC
# - Prompts the user to select a new timezone if UTC is detected
# - Offers common US timezones plus an "Other" option for custom input
# - Supports both Linux (timedatectl) and macOS (systemsetup)

set -euo pipefail

# Get the directory where this script is located
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Source utilities
# shellcheck source=../utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# Timezone Configuration
# ============================================================================

# Get the current system timezone
# Returns: timezone string (e.g., "America/New_York", "UTC")
get_current_timezone() {
    if [[ "$DETECTED_OS" == "macos" ]]; then
        # macOS: read from /etc/localtime symlink (doesn't require admin)
        # The symlink points to /var/db/timezone/zoneinfo/<timezone>
        if [[ -L /etc/localtime ]]; then
            readlink /etc/localtime | sed 's|.*/zoneinfo/||'
        else
            # Fallback to systemsetup (requires admin)
            run_elevated systemsetup -gettimezone 2>/dev/null | sed 's/Time Zone: //' || echo "unknown"
        fi
    else
        # Linux: timedatectl show returns just the timezone
        timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown"
    fi
}

# List all available timezones
# Outputs: one timezone per line
list_all_timezones() {
    if [[ "$DETECTED_OS" == "macos" ]]; then
        # macOS: first line is a header, skip it
        systemsetup -listtimezones 2>/dev/null | tail -n +2 | sed 's/^[[:space:]]*//'
    else
        # Linux: timedatectl list-timezones outputs one per line
        timedatectl list-timezones 2>/dev/null
    fi
}

# Set the system timezone
# Args: $1 = timezone string (e.g., "America/New_York")
# Note: No validation - passes input directly to system command
set_timezone() {
    local tz="$1"

    if [[ "$DETECTED_OS" == "macos" ]]; then
        run_elevated systemsetup -settimezone "$tz"
    else
        run_elevated timedatectl set-timezone "$tz"
    fi
}

# Configure timezone interactively
# Only prompts if current timezone is UTC
configure_timezone() {
    local current_tz
    current_tz=$(get_current_timezone)

    print_info "Checking timezone configuration..."

    # Check if timezone contains UTC (handles "UTC", "Etc/UTC", etc.)
    if [[ "$current_tz" != *"UTC"* ]]; then
        print_success "Timezone is already configured: $current_tz"
        return 0
    fi

    print_warning "System timezone is set to UTC: $current_tz"
    echo ""

    if ! prompt_yes_no "Would you like to update the timezone?" "n"; then
        print_info "Keeping timezone as UTC"
        return 0
    fi

    echo ""
    print_info "Select a timezone:"
    echo "            1) Eastern  (America/New_York)"
    echo "            2) Central  (America/Chicago)"
    echo "            3) Mountain (America/Denver)"
    echo "            4) Pacific  (America/Los_Angeles)"
    echo "            5) Other    (show all timezones)"
    echo ""

    local tz_choice
    read -p "            Enter choice (1-5): " -r tz_choice </dev/tty

    local new_tz=""
    case "$tz_choice" in
        1) new_tz="America/New_York" ;;
        2) new_tz="America/Chicago" ;;
        3) new_tz="America/Denver" ;;
        4) new_tz="America/Los_Angeles" ;;
        5)
            echo ""
            print_info "Available timezones:"
            echo ""
            list_all_timezones
            echo ""
            read -p "            Enter timezone (e.g., Europe/London): " -r new_tz </dev/tty
            ;;
        *)
            print_error "Invalid choice. Keeping timezone as UTC."
            return 1
            ;;
    esac

    if [[ -z "$new_tz" ]]; then
        print_error "No timezone entered. Keeping timezone as UTC."
        return 1
    fi

    echo ""
    print_info "Setting timezone to: $new_tz"

    if set_timezone "$new_tz"; then
        local verified_tz
        verified_tz=$(get_current_timezone)
        print_success "Timezone updated to: $verified_tz"
    else
        print_error "Failed to set timezone"
        return 1
    fi
}

# ============================================================================
# Main Entry Point
# ============================================================================

main_configure_timezone() {
    # Ensure environment is detected
    detect_environment

    configure_timezone
}

# Run main function if script is executed directly (for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_configure_timezone "$@"
fi
