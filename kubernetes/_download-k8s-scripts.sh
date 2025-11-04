#!/usr/bin/env bash

# _download-k8s-scripts.sh - Kubernetes Script Management and Auto-Updater
#
# Usage: ./_download-k8s-scripts.sh
#
# This script:
# - Self-updates from the remote repository before running
# - Downloads the latest versions of all Kubernetes management scripts
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
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Diff display colors
readonly LINE_COLOR="\033[0;33m"
readonly CODE_COLOR="\033[40m"

# Remote repository configuration
readonly REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/kubernetes"
readonly FILES=( "install-update-helm.sh" "start-k8s.sh" "stop-k8s.sh" "update-k8s-repos.sh" )

# Print colored output
print_info() {
    echo -e "${BLUE}[   INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[  ERROR]${NC} $1"
}

# ============================================================================
# Self-Update Section
# ============================================================================
# This section checks for updates to this script itself before proceeding.
# It downloads the latest version from GitHub and offers to replace the local
# copy if changes are detected.

if [[ ${scriptUpdated:-0} -eq 0 ]]; then
    readonly SCRIPT_FILE="_download-k8s-scripts.sh"
    TEMP_SCRIPT_FILE="$(mktemp)"
    trap 'rm -f "${TEMP_SCRIPT_FILE}"' RETURN     # ensure cleanup even on exit/interrupt

    # Check for curl or wget availability
    DOWNLOAD_CMD=""
    if command -v curl &>/dev/null; then
        DOWNLOAD_CMD="curl"
    elif command -v wget &>/dev/null; then
        DOWNLOAD_CMD="wget"
    else
        # Display large error message if neither curl nor wget is available
        echo ""
        echo "╔═════════════════════════════════════════════════════════════════════╗"
        echo "║                                                                     ║"
        echo "║                  ⚠️   SELF-UPDATE NOT AVAILABLE  ⚠️                   ║"  # the extra space is intentional for alignment due to the ⚠️  character
        echo "║                                                                     ║"
        echo "║    Neither 'curl' nor 'wget' is installed on this system.           ║"
        echo "║    Self-updating functionality requires one of these tools.         ║"
        echo "║                                                                     ║"
        echo "║    To enable self-updating, please install one of the following:    ║"
        echo "║      • curl  (recommended)                                          ║"
        echo "║      • wget                                                         ║"
        echo "║                                                                     ║"
        echo "║    Installation commands:                                           ║"
        echo "║      macOS:    brew install curl                                    ║"
        echo "║      Debian:   sudo apt install curl                                ║"
        echo "║      RHEL:     sudo yum install curl                                ║"
        echo "║                                                                     ║"
        echo "║    Continuing with local version of the script...                   ║"
        echo "║                                                                     ║"
        echo "╚═════════════════════════════════════════════════════════════════════╝"
        echo ""
    fi

    # Proceed with self-update if a download command is available
    if [[ -n "$DOWNLOAD_CMD" ]]; then
        print_info "Checking for updates to ${SCRIPT_FILE}..."
        echo "          ▶ Fetching ${REMOTE_BASE}/${SCRIPT_FILE}..."

        DOWNLOAD_SUCCESS=false
        if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
            # -H header, -o file path, -f fail-on-HTTP-error, -s silent, -S show errors, -L follow redirects
            if curl -H 'Cache-Control: no-cache, no-store' -o "${TEMP_SCRIPT_FILE}" -fsSL "${REMOTE_BASE}/${SCRIPT_FILE}"; then
                DOWNLOAD_SUCCESS=true
            fi
        elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
            # --no-cache, -O output file, -q quiet, --show-progress
            if wget --no-cache --no-cookies -O "${TEMP_SCRIPT_FILE}" -q "${REMOTE_BASE}/${SCRIPT_FILE}"; then
                DOWNLOAD_SUCCESS=true
            fi
        fi

        if [[ "$DOWNLOAD_SUCCESS" == true ]]; then
            if diff -u "${BASH_SOURCE[0]}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
                print_success "- ${SCRIPT_FILE} is already up-to-date"
                echo ""
            else
                echo -e "${LINE_COLOR}╭───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╮${NC}${CODE_COLOR}"
                cat "${TEMP_SCRIPT_FILE}"
                echo -e "${NC}${LINE_COLOR}╰────────────────────────────────────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────────────────────────────────╮${NC}"
                diff -u --color "${BASH_SOURCE[0]}" "${TEMP_SCRIPT_FILE}" || true
                echo -e "${LINE_COLOR}╰───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╯${NC}"; echo

                read -p "→ Overwrite and run updated ${SCRIPT_FILE}?: [y/N] " continueExec
                echo ""

                if [[ $continueExec == [Yy] ]]; then
                    chmod +x "${TEMP_SCRIPT_FILE}"
                    export scriptUpdated=1
                    "${TEMP_SCRIPT_FILE}"
                    unset scriptUpdated
                    mv "${TEMP_SCRIPT_FILE}" "${BASH_SOURCE[0]}"
                    exit 0
                else
                    rm -f "${TEMP_SCRIPT_FILE}"
                    print_info "Running local unmodified copy..."
                    echo ""
                fi
            fi
        else
            print_error "Download failed — skipping $SCRIPT_FILE"
            print_info "Running local unmodified copy..."
            echo ""
        fi
    fi
fi

# ============================================================================
# Download Kubernetes Scripts Section
# ============================================================================
# This section downloads all Kubernetes management scripts from the remote repository.
# For each script, it shows a diff if changes are detected and prompts for
# confirmation before overwriting.

print_info "Starting Kubernetes scripts download..."
echo ""

# Track statistics
UPDATED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

for fname in "${FILES[@]}"; do
    tmp="$(mktemp)"                 # secure, race-free temp file
    trap 'rm -f "${tmp}"' RETURN    # ensure cleanup even on exit/interrupt

    print_info "Checking ${fname}..."
    echo "          ▶ Fetching ${REMOTE_BASE}/${fname}..."

    DOWNLOAD_SUCCESS=false
    if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
        # -H header, -o file path, -f fail-on-HTTP-error, -s silent, -S show errors, -L follow redirects
        if curl -H 'Cache-Control: no-cache, no-store' -o "${tmp}" -fsSL "${REMOTE_BASE}/${fname}"; then
            DOWNLOAD_SUCCESS=true
        fi
    elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
        # --no-cache, -O output file, -q quiet
        if wget --no-cache --no-cookies -O "${tmp}" -q "${REMOTE_BASE}/${fname}"; then
            DOWNLOAD_SUCCESS=true
        fi
    fi

    if [[ "$DOWNLOAD_SUCCESS" != true ]]; then
        print_error "Download failed — skipping $fname"
        ((FAILED_COUNT++))
        echo ""
        continue
    fi

    # Create file if it doesn't exist
    if [[ ! -f "${fname}" ]]; then
        touch "${fname}"
    fi

    if diff -u "${fname}" "${tmp}" > /dev/null 2>&1; then
        print_success "${fname} is already up-to-date"
        echo ""
    else
        echo ""
        echo -e "${LINE_COLOR}╭────────────────────────────────────────────────── Δ detected in ${fname} ──────────────────────────────────────────────────╮${NC}"
        diff -u --color "${fname}" "${tmp}" || true
        echo -e "${LINE_COLOR}╰───────────────────────────────────────────────────────── ${fname} ─────────────────────────────────────────────────────────╯${NC}"
        echo ""

        read -rp "→ Overwrite local ${fname} with remote copy? [y/N] " continueOverwrite
        echo ""

        if [[ $continueOverwrite =~ ^[Yy]$ ]]; then
            chmod +x "${tmp}"
            mv "${tmp}" "${fname}"
            print_success "Replaced ${fname}"
            ((UPDATED_COUNT++))
        else
            print_warning "Skipped ${fname}"
            ((SKIPPED_COUNT++))
            rm -f "${tmp}"
        fi
        echo ""
    fi
done

# ============================================================================
# Summary Section
# ============================================================================
# Display final statistics of the download operation

echo ""
echo "============================================================================"
print_info "Download Summary"
echo "============================================================================"
echo -e "${GREEN}Updated:${NC}  ${UPDATED_COUNT} file(s)"
echo -e "${YELLOW}Skipped:${NC}  ${SKIPPED_COUNT} file(s)"
echo -e "${RED}Failed:${NC}   ${FAILED_COUNT} file(s)"
echo "============================================================================"
echo ""

if [[ $FAILED_COUNT -gt 0 ]]; then
    exit 1
fi
