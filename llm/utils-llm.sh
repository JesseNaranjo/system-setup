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

print_error()   { echo -e "${RED}[ ERROR   ]${NC} $1" >&2; if [[ -t 2 ]]; then printf '\a' >&2; sleep 2; fi; }
print_info()    { echo -e "${BLUE}[ INFO    ]${NC} $1"; }
print_success() { echo -e "${GREEN}[ SUCCESS ]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[ WARNING ]${NC} $1"; }

# ── Cleanup & defense-in-depth ────────────────────────────────────────────────
TEMP_FILES=()

# cleanup runs on normal exit, SIGINT, SIGTERM. Hoisted to file scope so the
# trap is wired the moment the script is loaded — a top-level guard that exits
# before main still reaps tracked temps.
cleanup() {
    local f
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        rm -f "$f" 2>/dev/null
    done
}
trap cleanup EXIT

# Defense-in-depth: at startup, reap any same-FS temp files (e.g., from a
# prior SIGKILL / power-loss / interrupted self-update) older than a normal
# run window. The EXIT trap above handles in-flight cleanup; this function
# handles what the trap couldn't fire for. TTY-aware so cron/ssh -T runs
# don't block on the prompt.
sweep_stale_temps() {
    local pattern="$1"
    local stale_files=()
    while IFS= read -r -d '' f; do
        stale_files+=("$f")
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -name "$pattern" -type f -mmin +10 -print0 2>/dev/null)

    [[ ${#stale_files[@]} -eq 0 ]] && return 0

    print_warning "⚠ Found ${#stale_files[@]} stale temp file(s) from a prior interrupted run:"
    for f in "${stale_files[@]}"; do
        print_warning "  - $f"
    done

    # `[[ -r /dev/tty ]]` only checks file permissions; under setsid the device
    # is world-readable but `open(2)` fails with ENXIO, so a subsequent
    # `read </dev/tty` aborts under set -e. Probe with a no-op stdin redirect
    # to detect actual openability.
    if { : </dev/tty; } 2>/dev/null; then
        # `|| true` swallows EOF (Ctrl+D) so set -e doesn't abort mid-cleanup.
        read -p "Press any key to delete and continue, Ctrl+C to abort: " -n 1 -r </dev/tty || true
        echo ""
    else
        print_warning "⚠ Non-interactive context — deleting and continuing without prompt."
    fi

    for f in "${stale_files[@]}"; do
        rm -f "$f"
    done
    print_success "✓ Cleaned up ${#stale_files[@]} stale temp file(s)"
}

# Render a unified diff between two files inside a labeled box. Pages through
# `less -RFX` when stdout is a TTY (-R passes ANSI through, -F exits if content
# fits one screen, -X skips alt-screen so output stays in scrollback); falls
# back to inline `diff` when piped or `less` is missing. `--color=always`
# forces ANSI even when piped.
show_diff_box() {
    local local_file="$1"
    local temp_file="$2"
    local label="$3"
    echo ""
    echo -e "${CYAN}╭────────────────────── Δ detected in ${label} ──────────────────────╮${NC}"
    if [[ -t 1 ]] && command -v less &>/dev/null; then
        diff -u --color=always "${local_file}" "${temp_file}" | less -RFX || true
    else
        diff -u --color=always "${local_file}" "${temp_file}" || true
    fi
    echo -e "${CYAN}╰─────────────────────────── ${label} ──────────────────────────────╯${NC}"
    echo ""
}

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

    # Non-TTY context (cron, systemd, ssh -T, CI): signal "no" rather than fall
    # through to the empty-reply branch and silently auto-accept the default.
    [[ -r /dev/tty ]] || return 1

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
        http_status=$(curl -H 'Cache-Control: no-cache, no-store' \
            --max-time 15 \
            -o "${output_file}" -w "%{http_code}" -sSL \
            "${REMOTE_BASE}/${script_file}" 2>/dev/null || true)
        [[ -z "$http_status" ]] && http_status="000"
        case "$http_status" in
            200)
                if head -n 10 "${output_file}" | grep -q "^#!/"; then
                    return 0
                else
                    print_error "✖ Invalid content received (not a script)"
                    rm -f "${output_file}"
                    return 1
                fi
                ;;
            429) print_error "✖ Rate limited by GitHub (HTTP 429)"; rm -f "${output_file}"; return 1 ;;
            000) print_error "✖ Download failed (network/timeout)"; rm -f "${output_file}"; return 1 ;;
            *)   print_error "✖ HTTP ${http_status} error"; rm -f "${output_file}"; return 1 ;;
        esac
    elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
        local wget_exit=0
        wget --no-cache --no-cookies \
            --timeout=15 \
            -O "${output_file}" -q "${REMOTE_BASE}/${script_file}" 2>/dev/null \
            || wget_exit=$?
        if [[ "$wget_exit" -ne 0 ]]; then
            print_error "✖ Download failed (wget exit ${wget_exit})"
            rm -f "${output_file}"
            return 1
        fi
        if head -n 10 "${output_file}" | grep -q "^#!/"; then
            return 0
        else
            print_error "✖ Invalid content received (not a script)"
            rm -f "${output_file}"
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
    temp_file=$(mktemp "${_UTILS_DIR}/~${utils_basename}.tmp.XXXXXX")
    TEMP_FILES+=("$temp_file")
    if download_script "$utils_basename" "$temp_file"; then
        if ! diff -q "${_UTILS_DIR}/${utils_basename}" "$temp_file" > /dev/null 2>&1; then
            show_diff_box "${_UTILS_DIR}/${utils_basename}" "$temp_file" "$utils_basename"
            if prompt_yes_no "→ Update ${utils_basename}?" "y"; then
                chmod +x "$temp_file"
                if ! mv -f "$temp_file" "${_UTILS_DIR}/${utils_basename}"; then
                    rm -f "$temp_file"
                    print_error "✖ Failed to install update — keeping local version"
                    return 1
                fi
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

    # Check calling script. Use caller_abs (already resolved) for path-sensitive
    # operations — the raw ${BASH_SOURCE[0]} caller_script may be a bare basename
    # when invoked via PATH or bash <name>, breaking ${caller_script%/*} dirname
    # extraction and PATH-resolved exec.
    temp_file=$(mktemp "$(dirname "$caller_abs")/~$(basename "$caller_abs").tmp.XXXXXX")
    TEMP_FILES+=("$temp_file")
    if download_script "$caller_relpath" "$temp_file"; then
        if ! diff -q "$caller_abs" "$temp_file" > /dev/null 2>&1; then
            show_diff_box "$caller_abs" "$temp_file" "$caller_relpath"
            if prompt_yes_no "→ Update ${caller_relpath}?" "y"; then
                chmod +x "$temp_file"
                if ! mv -f "$temp_file" "$caller_abs"; then
                    rm -f "$temp_file"
                    print_error "✖ Failed to install update — keeping local version"
                    return 1
                fi
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
        exec "$caller_abs" "$@"
    fi
}
