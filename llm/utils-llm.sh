#!/usr/bin/env bash
# utils-llm.sh — Shared functions for LLM scripts

# ── Source guard ───────────────────────────────────────────────────────────────
if [[ -n "${UTILS_LLM_SH_LOADED:-}" ]]; then
    return 0
fi
readonly UTILS_LLM_SH_LOADED=true

set -euo pipefail

# ── Output ────────────────────────────────────────────────────────────────────
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

print_info()    { echo -e "${BLUE}[ INFO    ]${NC} $1"; }
print_success() { echo -e "${GREEN}[ SUCCESS ]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[ WARNING ]${NC} $1"; }
print_error()   { echo -e "${RED}[ ERROR   ]${NC} $1"; }

# Display a formatted warning box
# Usage: print_warning_box "line1" "line2" "line3" ...
# Each line will be padded to fit within the box
print_warning_box() {
    local box_width=77
    local content_width=$((box_width - 8 - 1))

    echo ""
    echo -e "            ${YELLOW}╔$(printf '═%.0s' $(seq 1 $box_width))╗${NC}"
    echo -e "            ${YELLOW}║$(printf ' %.0s' $(seq 1 $box_width))║${NC}"

    local line
    for line in "$@"; do
        printf -v padded_line "%-${content_width}s" "$line"
        echo -e "            ${YELLOW}║        ${padded_line}║${NC}"
    done

    echo -e "            ${YELLOW}║$(printf ' %.0s' $(seq 1 $box_width))║${NC}"
    echo -e "            ${YELLOW}╚$(printf '═%.0s' $(seq 1 $box_width))╝${NC}"
    echo ""
}

# ── User Input ────────────────────────────────────────────────────────────────

prompt_yes_no() {
    local prompt_message="$1"
    local default="${2:-n}"
    local prompt_suffix user_reply

    if [[ "${default,,}" == "y" ]]; then
        prompt_suffix="(Y/n)"
    else
        prompt_suffix="(y/N)"
    fi

    read -p "$prompt_message $prompt_suffix: " -r user_reply </dev/tty

    if [[ -z "$user_reply" ]]; then
        [[ "${default,,}" == "y" ]]
    else
        [[ $user_reply =~ ^[Yy]$ ]]
    fi
}

# ── Cleanup ───────────────────────────────────────────────────────────────────

cleanup_obsolete_scripts() {
    local obsolete_script
    for obsolete_script in "${@+"$@"}"; do
        local script_path="${SCRIPT_DIR}/${obsolete_script}"
        if [[ -f "${script_path}" ]]; then
            echo -e "${RED}[ CLEANUP ]${NC} Found obsolete script: ${obsolete_script}"
            if prompt_yes_no "            → Delete ${obsolete_script}?" "n"; then
                rm -f "${script_path}"
                print_success "✓ Deleted ${obsolete_script}"
            else
                print_warning "⚠ Kept ${obsolete_script}"
            fi
        fi
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# Self-Update
# ══════════════════════════════════════════════════════════════════════════════
_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _UTILS_DIR
readonly REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/llm"
DOWNLOAD_CMD=""

detect_download_cmd() {
    if command -v curl &>/dev/null; then
        DOWNLOAD_CMD="curl"
        return 0
    elif command -v wget &>/dev/null; then
        DOWNLOAD_CMD="wget"
        return 0
    else
        DOWNLOAD_CMD=""
        print_warning_box \
            "UPDATES NOT AVAILABLE" \
            "" \
            "Neither 'curl' nor 'wget' is installed on this system." \
            "Self-updating functionality requires one of these tools." \
            "" \
            "To enable self-updating, please install one of the following:" \
            "  • curl  (recommended)" \
            "  • wget" \
            "" \
            "Installation commands:" \
            "  macOS:    brew install curl" \
            "  Debian:   apt install curl" \
            "  RHEL:     yum install curl" \
            "" \
            "Continuing with local version of the scripts..."
        return 1
    fi
}

download_script() {
    local script_file="$1"
    local output_file="$2"
    local http_status=""

    print_info "Fetching ${script_file}..."
    echo "            ▶ ${REMOTE_BASE}/${script_file}..."

    if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
        http_status=$(curl -H 'Cache-Control: no-cache, no-store' -o "${output_file}" -w "%{http_code}" -fsSL "${REMOTE_BASE}/${script_file}" 2>/dev/null || echo "000")
        if [[ "$http_status" == "200" ]]; then
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

check_for_updates() {
    local caller_script="$1"
    shift

    [[ -n "${LLM_SCRIPTS_UPDATED:-}" ]] && return 0

    detect_download_cmd || return 0

    local utils_basename
    utils_basename=$(basename "${BASH_SOURCE[0]}")
    local caller_abs
    caller_abs="$(cd "$(dirname "$caller_script")" && pwd)/$(basename "$caller_script")"
    local caller_relpath="${caller_abs#"${_UTILS_DIR}/"}"
    local any_updated=false
    local temp_file

    print_info "Checking for updates..."

    # Check utils file
    temp_file=$(mktemp)
    if download_script "$utils_basename" "$temp_file"; then
        if ! diff -q "${_UTILS_DIR}/${utils_basename}" "$temp_file" > /dev/null 2>&1; then
            echo ""
            echo -e "${CYAN}╭────────────────────── Δ detected in ${utils_basename} ──────────────────────╮${NC}"
            diff -u --color "${_UTILS_DIR}/${utils_basename}" "$temp_file" || true
            echo -e "${CYAN}╰─────────────────────────── ${utils_basename} ──────────────────────────────╯${NC}"
            echo ""
            if prompt_yes_no "→ Update ${utils_basename}?" "y"; then
                chmod +x "$temp_file"
                mv -f "$temp_file" "${_UTILS_DIR}/${utils_basename}"
                print_success "✓ Updated ${utils_basename}"
                any_updated=true
            else
                print_info "Skipped ${utils_basename}"
                rm -f "$temp_file"
            fi
        else
            print_success "- ${utils_basename} is up-to-date"
            rm -f "$temp_file"
        fi
    else
        rm -f "$temp_file"
    fi

    # Check calling script
    temp_file=$(mktemp)
    if download_script "$caller_relpath" "$temp_file"; then
        if ! diff -q "$caller_script" "$temp_file" > /dev/null 2>&1; then
            echo ""
            echo -e "${CYAN}╭────────────────────── Δ detected in ${caller_relpath} ──────────────────────╮${NC}"
            diff -u --color "$caller_script" "$temp_file" || true
            echo -e "${CYAN}╰─────────────────────────── ${caller_relpath} ──────────────────────────────╯${NC}"
            echo ""
            if prompt_yes_no "→ Update ${caller_relpath}?" "y"; then
                chmod +x "$temp_file"
                mv -f "$temp_file" "$caller_script"
                print_success "✓ Updated ${caller_relpath}"
                any_updated=true
            else
                print_info "Skipped ${caller_relpath}"
                rm -f "$temp_file"
            fi
        else
            print_success "- ${caller_relpath} is up-to-date"
            rm -f "$temp_file"
        fi
    else
        rm -f "$temp_file"
    fi

    if [[ "$any_updated" == "true" ]]; then
        print_success "Restarting with updated scripts..."
        export LLM_SCRIPTS_UPDATED=1
        exec "$caller_script" "$@"
    fi
}
