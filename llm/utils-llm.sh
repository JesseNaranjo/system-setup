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

print_error()   { printf '%b[ ERROR   ]%b %s\n' "$RED" "$NC" "$1" >&2; if [[ -t 2 ]]; then printf '\a' >&2; sleep 2; fi; }
print_info()    { printf '%b[ INFO    ]%b %s\n' "$BLUE" "$NC" "$1"; }
print_success() { printf '%b[ SUCCESS ]%b %s\n' "$GREEN" "$NC" "$1"; }
print_warning() { printf '%b[ WARNING ]%b %s\n' "$YELLOW" "$NC" "$1"; }

# ── Cleanup & defense-in-depth ────────────────────────────────────────────────
TEMP_FILES=()

# cleanup runs on normal exit, SIGINT, SIGTERM. Hoisted to file scope so the
# trap is wired the moment the script is loaded — a top-level guard that exits
# before main still reaps tracked temps.
cleanup() {
    local f
    for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
        rm -f "$f" 2>/dev/null || true
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
    local f   # bash is dynamically scoped: an undeclared loop var leaks to the caller
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
        rm -f "$f" || true
    done
    print_success "✓ Cleaned up ${#stale_files[@]} stale temp file(s)"
}

# Strip every ANSI escape sequence except SGR colour.
# Defends against terminal injection: the diff preview renders the CONTENT of a
# file just downloaded, and a hostile file could otherwise repaint the screen
# over the default-yes overwrite prompt that follows — drawing a fake "no
# changes detected" line and turning one keypress into acceptance. The
# expressions run in this order, and the order matters:
#   1. OSC strings (\e]…) terminated by BEL or by ST (ESC \) — set-title and
#      friends.
#   2. The other ST-terminated string types: DCS (\eP), SOS (\eX), PM (\e^),
#      APC (\e_). Their payloads are consumed raw by a terminal.
#   3. CSI sequences (\e[…) whose final byte is NOT `m` — cursor moves
#      (\e[A, \e[2K, \e[H, …) and mode toggles (\e[?25l, …) go, while SGR
#      colour (\e[31m, \e[1;32m, \e[0m) survives, which is the point of the box.
#   4. A CSI truncated by end-of-line, which would otherwise swallow the start
#      of the next line as its parameters.
#   5. Every remaining ESC not followed by `[` — the two-byte forms. This is
#      the class the first version missed, and it held the worst of them:
#      \ec (RIS) resets and clears the entire terminal, \e7/\e8 save and
#      restore the cursor, \eM scrolls. Runs after 1-2 so it cannot eat the
#      introducer of a string sequence those are still matching.
#   6. A bare ESC at end of line.
# Uses literal ESC/BEL bytes from bash $'…' so the regexes are portable between
# GNU sed and BSD sed (which lacks \xNN support).
_sanitize_ansi() {
    local esc=$'\033' bel=$'\007'
    sed -E -e "s/${esc}\\][^${esc}${bel}]*(${bel}|${esc}\\\\)//g" \
           -e "s/${esc}[P^_X][^${esc}]*${esc}\\\\//g" \
           -e "s/${esc}\\[[0-9;?]*[^0-9;?m]//g" \
           -e "s/${esc}\\[[0-9;?]*$//" \
           -e "s/${esc}[^[]//g" \
           -e "s/${esc}$//"
}

# Render a unified diff between two files inside a labeled box. Pages through
# `less -RFX` when stdout is a TTY (-R passes ANSI through, -F exits if content
# fits one screen, -X skips alt-screen so output stays in scrollback); falls
# back to inline `diff` when piped or `less` is missing. The diff is the content
# of a file just downloaded, so it is untrusted and goes through _sanitize_ansi
# before it reaches the terminal.
show_diff_box() {
    local local_file="$1"
    local temp_file="$2"
    local label="$3"
    echo ""
    echo -e "${CYAN}╭────────────────────── Δ detected in ${label} ──────────────────────╮${NC}"
    # Probe for --color rather than assuming it: macOS 26's diff supports it, but
    # older BSD/macOS diff did not, and there it errors into an empty box.
    # "${arr[@]+"${arr[@]}"}" rather than a bare "${diff_color[@]}": the two are
    # equivalent from bash 4.4 on, but the guarded form is the repo-wide way of
    # expanding a possibly-empty array under `set -u` and every other site uses it.
    local diff_color=()
    diff --color=always /dev/null /dev/null >/dev/null 2>&1 && diff_color=(--color=always)
    if [[ -t 1 ]] && command -v less &>/dev/null; then
        diff -u "${diff_color[@]+"${diff_color[@]}"}" "${local_file}" "${temp_file}" | _sanitize_ansi | less -RFX || true
    else
        diff -u "${diff_color[@]+"${diff_color[@]}"}" "${local_file}" "${temp_file}" | _sanitize_ansi || true
    fi
    echo -e "${CYAN}╰─────────────────────────── ${label} ───────────────────────────────╯${NC}"
    echo ""
}

# Display a formatted warning box
# Usage: print_warning_box "line1" "line2" "line3" ...
# Each line will be padded to fit within the box
print_warning_box() {
    local box_width=77
    local content_width=$((box_width - 8))   # 8 = the indent inside the left border

    echo ""
    echo -e "            ${YELLOW}╔$(printf '═%.0s' $(seq 1 $box_width))╗${NC}"
    echo -e "            ${YELLOW}║$(printf ' %.0s' $(seq 1 $box_width))║${NC}"

    # Pad on CHARACTER count, not printf's "%-Ns", which pads by BYTES. Box
    # content carries multi-byte glyphs (•, —, ✓), so byte padding rendered
    # those rows narrower than the border — measured at 89 columns against a
    # 91-column border. ${#line} counts characters and ${line:0:N} cuts on
    # character boundaries in a UTF-8 locale, so an over-long line is truncated
    # without splitting a glyph into invalid UTF-8; the slice is a no-op on a
    # line that already fits. Under a non-UTF-8 locale both fall back to bytes,
    # which is the previous behaviour and no worse.
    # %b for the colour constants (they are literal '\033…' in most copies),
    # %s for the caller's text so a backslash escape in it stays literal.
    local line pad
    for line in "$@"; do
        line="${line:0:content_width}"
        pad=$((content_width - ${#line}))
        printf '            %b║        %s%*s║%b\n' "$YELLOW" "$line" "$pad" '' "$NC"
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

    # Non-interactive context (cron, systemd, ssh -T, CI, setsid): signal "no"
    # rather than fall through to the empty-reply branch and silently auto-accept
    # the default. Use the `{ : </dev/tty; }` open(2) probe, NOT `[[ -r /dev/tty ]]`
    # — the latter only checks permissions and stays true under setsid while
    # open() fails with ENXIO, so the read below would then misbehave.
    { : </dev/tty; } 2>/dev/null || return 1

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
                # Validate that we got a script, not an error page.
                # Stricter than the previous first-ten-lines shebang grep, which
                # accepted a shebang on ANY of the first 10 lines - so an HTML 4xx
                # page that merely quotes a shebang in a code snippet no longer
                # passes. Also reject CRLF - `exec` would fail with `bash\r: not
                # found`, after the file has already replaced the original on disk.
                # `|| true` lets an empty file reach the explicit checks below rather
                # than blowing up under set -e.
                local first_line
                IFS= read -r first_line < "${output_file}" || true
                if [[ "$first_line" != "#!"* ]]; then
                    print_error "✖ Invalid content (no shebang on line 1)"
                    rm -f "${output_file}"
                    return 1
                fi
                if [[ "$first_line" == *$'\r' ]]; then
                    print_error "✖ Invalid content (CRLF line endings)"
                    rm -f "${output_file}"
                    return 1
                fi
                return 0
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
        # Validate that we got a script, not an error page.
        # Stricter than the previous first-ten-lines shebang grep, which
        # accepted a shebang on ANY of the first 10 lines - so an HTML 4xx
        # page that merely quotes a shebang in a code snippet no longer
        # passes. Also reject CRLF - `exec` would fail with `bash\r: not
        # found`, after the file has already replaced the original on disk.
        # `|| true` lets an empty file reach the explicit checks below rather
        # than blowing up under set -e.
        local first_line
        IFS= read -r first_line < "${output_file}" || true
        if [[ "$first_line" != "#!"* ]]; then
            print_error "✖ Invalid content (no shebang on line 1)"
            rm -f "${output_file}"
            return 1
        fi
        if [[ "$first_line" == *$'\r' ]]; then
            print_error "✖ Invalid content (CRLF line endings)"
            rm -f "${output_file}"
            return 1
        fi
        return 0
    fi

    return 1
}

# Check for updates to the utils file and the calling script, then exec-restart
# the caller if either was replaced.
# Usage: check_for_updates "${BASH_SOURCE[0]}" "$@"
# Never returns non-zero. Every caller invokes this bare under `set -euo
# pipefail`, so returning 1 for an update that could not be installed would
# abort the whole tool at the exact moment the message says "keeping local
# version". Failures are reported and the run continues with the copy on disk.
#
# PARITY COPY — byte-identical in all 5 libraries (AGENTS.md §Helper Library
# Duplication). It has no per-suite input; never inline a suite name here.
check_for_updates() {
    local caller_script="$1"
    shift

    # Detect BEFORE the restart guard. The exec'd process sources this library
    # fresh (DOWNLOAD_CMD=""), and the orchestrators and _download-*-scripts.sh
    # gate update_modules on DOWNLOAD_CMD right after this call — so the
    # restarted process must populate it too (AGENTS.md §check_for_updates
    # Pattern).
    detect_download_cmd || return 0

    # One-shot restart guard: the process that exec'd us already checked both
    # files and replaced at least one. Consume it so no child of this run
    # inherits it and skips its own check.
    if [[ -n "${SCRIPTS_UPDATED:-}" ]]; then
        unset SCRIPTS_UPDATED
        return 0
    fi

    local utils_basename
    utils_basename=$(basename "${BASH_SOURCE[0]}")
    local caller_abs
    caller_abs="$(cd "$(dirname "$caller_script")" && pwd)/$(basename "$caller_script")"
    local caller_relpath="${caller_abs#"${_UTILS_DIR}/"}"
    local any_updated=false
    local temp_file

    print_info "Checking for updates..."

    # Check utils file
    # mktemp adjacent to destination so `mv` is atomic rename(2) on the same FS;
    # ~filename.tmp.XXXXXX naming convention makes the sweep glob unambiguous.
    temp_file=$(mktemp "${_UTILS_DIR}/~${utils_basename}.tmp.XXXXXX")
    TEMP_FILES+=("$temp_file")
    if download_script "$utils_basename" "$temp_file"; then
        if ! diff -q "${_UTILS_DIR}/${utils_basename}" "$temp_file" > /dev/null 2>&1; then
            show_diff_box "${_UTILS_DIR}/${utils_basename}" "$temp_file" "$utils_basename"
            if prompt_yes_no "→ Update ${utils_basename}?" "y"; then
                chmod 644 "$temp_file"
                if mv -f "$temp_file" "${_UTILS_DIR}/${utils_basename}"; then
                    print_success "✓ Updated ${utils_basename}"
                    any_updated=true
                else
                    rm -f "$temp_file"
                    print_error "✖ Failed to install update — keeping local version"
                fi
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
                if mv -f "$temp_file" "$caller_abs"; then
                    print_success "✓ Updated ${caller_relpath}"
                    any_updated=true
                else
                    rm -f "$temp_file"
                    print_error "✖ Failed to install update — keeping local version"
                fi
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
        export SCRIPTS_UPDATED=1
        exec "$caller_abs" "$@"
    fi
}
