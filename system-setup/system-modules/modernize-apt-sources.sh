#!/usr/bin/env bash

# modernize-apt-sources.sh - Modernize APT sources configuration
# Part of the system-setup suite
#
# This script:
# - Converts old sources.list format to DEB822 format
# - Configures non-free components for Debian
# - Consolidates updates and backports into main sources file

# Get the directory where this script is located
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Source utilities
# shellcheck source=utils.sh
source "${SCRIPT_DIR}/utils.sh"

# ============================================================================
# APT Sources Modernization
# ============================================================================

# Modernize APT sources configuration (Debian/Ubuntu)
# Converts old sources.list format to DEB822 format and configures non-free components
modernize_apt_sources() {
    # Only run on Linux systems with apt
    if [[ "$DETECTED_OS" != "linux" ]] || ! command -v apt &>/dev/null; then
        return 0
    fi

    # Requires root privileges on Linux
    if ! check_privileges "apt_operations"; then
        print_warning "Skipping APT sources modernization (requires root privileges)"
        return 0
    fi

    print_info "Modernizing APT sources configuration..."

    # 1. Run apt modernize-sources
    if ! apt modernize-sources 2>/dev/null; then
        print_warning "apt modernize-sources failed or is not available. Skipping."
        return 0
    fi

    # 2. Remove backup file
    if [[ -f /etc/apt/sources.list.bak ]]; then
        rm -f /etc/apt/sources.list.bak
        print_success "✓ Removed /etc/apt/sources.list.bak"
    fi

    local sources_file="/etc/apt/sources.list.d/debian.sources"
    if [[ ! -f "$sources_file" ]]; then
        print_warning "DEB822 sources file not found at $sources_file. Skipping."
        return 0
    fi

    # Extract the release name (e.g., "bookworm")
    local release=$(grep -m 1 "^Suites:" "$sources_file" | sed -E 's/^Suites:\s*([a-z]+).*/\1/')

    if [[ -z "$release" ]]; then
        print_warning "Could not determine Debian release from $sources_file. Skipping."
        return 0
    fi

    print_info "Detected Debian release: $release"

    # Create a temporary file for the new, cleaned-up content
    local temp_sources=$(mktemp)

    # Use a robust awk script to parse and modify the stanzas
    awk -v release="$release" '
        # Use blank lines as the record separator to process stanza by stanza
        BEGIN { RS = "" }

        {
            # Skip empty records that can result from multiple blank lines
            if (NF == 0) { next }

            # --- Pass 1: Parse the stanza into an associative array ---
            # This preserves all key-value pairs for logic, and raw lines for reconstruction
            delete stanza_kv
            delete raw_lines
            num_lines = 0
            has_components = 0
            # Use FS="\n" to iterate over lines within the record
            n = split($0, lines, "\n")
            for (i = 1; i <= n; i++) {
                line = lines[i]
                raw_lines[++num_lines] = line
                if (split(line, parts, /:[[:space:]]+/) == 2) {
                    key = parts[1]
                    value = parts[2]
                    stanza_kv[key] = value
                    if (key == "Components") {
                        has_components = 1
                    }
                }
            }

            # into the main release stanza. We identify the main stanza by checking that
            # it is for the detected release and is NOT a security or other special URI.
            is_main_release_stanza = 0
            if (stanza_kv["Suites"] == release && stanza_kv["URIs"] ~ /deb\.debian\.org\/debian\/?$/ && stanza_kv["URIs"] !~ /security/) {
                is_main_release_stanza = 1
            }

            if (!is_main_release_stanza && (stanza_kv["Suites"] == release "-updates" || stanza_kv["Suites"] == release "-backports")) {
                next # Skip standalone updates/backports records
            }

            # --- Pass 3: Reconstruct and Print the Stanza ---
            # Iterate through the original raw lines to preserve order, comments, and formatting.
            # Modify specific lines as needed.
            components_modified = 0
            for (i = 1; i <= num_lines; i++) {
                line = raw_lines[i]

                if (is_main_release_stanza && line ~ /^Suites:/) {
                    # Modify the Suites line for the main stanza
                    print "Suites: " release " " release "-updates " release "-backports"
                } else if (line ~ /^Components:/) {
                    # Modify any existing Components line
                    print "Components: main contrib non-free non-free-firmware"
                    components_modified = 1
                } else {
                    # Print all other lines unchanged
                    print line
                }
            }

            # If a stanza that we are processing did not have a Components line, add one.
            # This ensures, for example, that the security stanza also gets non-free.
            if (has_components == 0) {
                print "Components: main contrib non-free non-free-firmware"
            }

            # Print a blank line to separate this stanza from the next one
            print ""
        }
    ' "$sources_file" > "$temp_sources"


    # Replace the original file if changes were made
    if ! diff -q "$sources_file" "$temp_sources" >/dev/null; then
        # Backup the original sources file before making changes
        backup_file "$sources_file"
        # Use cat to avoid permission issues with mv
        cat "$temp_sources" > "$sources_file"
        rm "$temp_sources"
        print_success "✓ APT sources file ($sources_file) modernized successfully."
    else
        rm "$temp_sources"
        print_success "- APT sources file ($sources_file) is already modern."
    fi
    echo ""

    # Offer to manually edit the sources file
    if prompt_yes_no "Would you like to manually edit $sources_file with nano?" "n"; then
        if command -v nano &>/dev/null; then
            nano "$sources_file"
            print_info "Manual edit completed"
        else
            print_warning "nano is not installed"
        fi
    fi
}

# ============================================================================
# Main Execution
# ============================================================================

main_modernize_apt_sources() {
    detect_environment

    modernize_apt_sources
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_modernize_apt_sources "$@"
fi
