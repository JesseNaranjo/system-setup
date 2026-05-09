#!/usr/bin/env bash

# services-check.sh - Check availability of local services
#
# Usage: ./services-check.sh [--watch [seconds]] [service ...]
#
# Checks if services are installed (binary or systemd detection) and whether
# their ports are responding. With no arguments, checks all installed services.
# With arguments, checks only the named services (case-insensitive).
#
# Options:
#   --watch [N]  Continuously monitor services, refreshing every N seconds
#                (default: 10). Press Ctrl+C to stop.

set -euo pipefail

readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

readonly TIMEOUT=2

# Self-update configuration
readonly REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/utils"
DOWNLOAD_CMD=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Service definitions: "DisplayName:server_binary:port:systemd_unit"
# - DisplayName: Human-readable name (used for output and argument matching)
# - server_binary: Binary to detect via command -v (server process name preferred)
# - port: TCP port to check for availability
# - systemd_unit: systemd service unit name (fallback detection + status context)
readonly SERVICES=(
    "Elasticsearch:elasticsearch:9200:elasticsearch"
    "Grafana:grafana-server:3000:grafana-server"
    "Kafka:kafka-server-start.sh:9092:kafka"
    "Memcached:memcached:11211:memcached"
    "MongoDB:mongod:27017:mongod"
    "MSSQL:sqlservr:1433:mssql-server"
    "MySQL:mysqld:3306:mysql"
    "PostgreSQL:postgres:5432:postgresql"
    "Prometheus:prometheus:9090:prometheus"
    "RabbitMQ:rabbitmq-server:5672:rabbitmq-server"
    "RabbitMQ-WebUI:rabbitmq-server:15672:rabbitmq-server"
    "Redis:redis-server:6379:redis-server"
    "Valkey:valkey-server:6379:valkey-server"
)

# ============================================================================
# Standard Output Functions
# ============================================================================

print_error()   { echo -e "${RED}[ ERROR   ]${NC} $1" >&2; if [[ -t 2 ]]; then printf '\a' >&2; sleep 2; fi; }
print_info()    { echo -e "${BLUE}[ INFO    ]${NC} $1"; }
print_success() { echo -e "${GREEN}[ SUCCESS ]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[ WARNING ]${NC} $1"; }

# Usage: print_warning_box "line1" "line2" "line3" ...
print_warning_box() {
    local box_width=77
    local padding=8
    local content_width=$((box_width - padding - 1))

    echo ""
    echo -e "            ${YELLOW}╔$(printf '═%.0s' $(seq 1 $box_width))╗${NC}"
    echo -e "            ${YELLOW}║$(printf ' %.0s' $(seq 1 $box_width))║${NC}"

    for line in "$@"; do
        local line_len=${#line}
        local right_pad=$((content_width - line_len))
        if [[ $right_pad -lt 0 ]]; then
            right_pad=0
            line="${line:0:$content_width}"
        fi
        printf -v padded_line "%-${content_width}s" "$line"
        echo -e "            ${YELLOW}║        ${padded_line}║${NC}"
    done

    echo -e "            ${YELLOW}║$(printf ' %.0s' $(seq 1 $box_width))║${NC}"
    echo -e "            ${YELLOW}╚$(printf '═%.0s' $(seq 1 $box_width))╝${NC}"
    echo ""
}

# ============================================================================
# Utility Functions
# ============================================================================

# Prompt user for yes/no confirmation
# Usage: prompt_yes_no "message" [default]
#   default: "y" or "n" (optional, defaults to "n")
# Returns: 0 for yes, 1 for no
prompt_yes_no() {
    local prompt_message="$1"
    local default="${2:-n}"
    local prompt_suffix
    local user_reply

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

# ============================================================================
# Self-Update Functionality
# ============================================================================

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
            "Self-updating functionality requires one of these tools."
        return 1
    fi
}

download_script() {
    local script_file="$1"
    local output_file="$2"
    local http_status=""

    print_info "Fetching ${script_file}..."
    print_info "  → ${REMOTE_BASE}/${script_file}"

    if [[ "$DOWNLOAD_CMD" == "curl" ]]; then
        http_status=$(curl -H 'Cache-Control: no-cache, no-store' \
            --max-time 15 \
            -o "${output_file}" -w "%{http_code}" -sSL \
            "${REMOTE_BASE}/${script_file}" 2>/dev/null || true)
        [[ -z "$http_status" ]] && http_status="000"
        case "$http_status" in
            200) ;;
            429) print_error "✖ Rate limited by GitHub (HTTP 429)"; rm -f "${output_file}"; return 1 ;;
            000) print_error "✖ Download failed (network/timeout)"; rm -f "${output_file}"; return 1 ;;
            *)   print_error "✖ HTTP ${http_status} error"; rm -f "${output_file}"; return 1 ;;
        esac
        if head -n 10 "${output_file}" | grep -q "^#!/"; then
            return 0
        else
            print_error "✖ Invalid content received (not a script)"
            rm -f "${output_file}"
            return 1
        fi
    elif [[ "$DOWNLOAD_CMD" == "wget" ]]; then
        local wget_exit=0
        wget --no-cache --no-cookies \
            --timeout=15 \
            -O "${output_file}" -q "${REMOTE_BASE}/${script_file}" 2>/dev/null \
            || wget_exit=$?
        [[ "$wget_exit" -ne 0 ]] && { print_error "✖ Download failed (wget exit ${wget_exit})"; rm -f "${output_file}"; return 1; }
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

self_update() {
    local SCRIPT_FILE="services-check.sh"
    local LOCAL_SCRIPT="${SCRIPT_DIR}/${SCRIPT_FILE}"
    local TEMP_SCRIPT_FILE
    TEMP_SCRIPT_FILE=$(mktemp "${SCRIPT_DIR}/~${SCRIPT_FILE}.tmp.XXXXXX")
    TEMP_FILES+=("$TEMP_SCRIPT_FILE")

    if ! download_script "${SCRIPT_FILE}" "${TEMP_SCRIPT_FILE}"; then
        rm -f "$TEMP_SCRIPT_FILE"
        return 1
    fi

    if diff -q "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" > /dev/null 2>&1; then
        print_success "- Script is already up-to-date"
        rm -f "$TEMP_SCRIPT_FILE"
        return 0
    fi

    show_diff_box "${LOCAL_SCRIPT}" "${TEMP_SCRIPT_FILE}" "${SCRIPT_FILE}"

    if prompt_yes_no "→ Overwrite and restart with updated ${SCRIPT_FILE}?" "y"; then
        chmod +x "${TEMP_SCRIPT_FILE}"
        if ! mv -f "${TEMP_SCRIPT_FILE}" "${LOCAL_SCRIPT}"; then
            rm -f "$TEMP_SCRIPT_FILE"
            print_error "✖ Failed to install update — keeping local version"
            return 1
        fi
        print_success "✓ Updated ${SCRIPT_FILE} - restarting..."
        echo ""
        export scriptUpdated=1
        exec "${LOCAL_SCRIPT}" "$@"
        exit 0
    else
        rm -f "$TEMP_SCRIPT_FILE"
        print_warning "⚠ Skipped update - continuing with local version"
    fi
    echo ""
}

# ============================================================================
# Port Check Functions
# ============================================================================

PORT_CHECK_CMD=""

detect_port_checker() {
    if command -v nc &>/dev/null; then
        PORT_CHECK_CMD="nc"
    elif command -v timeout &>/dev/null; then
        PORT_CHECK_CMD="tcp"
    else
        print_error "✖ Neither 'nc' (netcat) nor 'timeout' found"
        echo "Install netcat (sudo apt install netcat-openbsd) or coreutils (sudo apt install coreutils)" >&2
        exit 1
    fi
}

check_port() {
    local port="$1"
    if [[ "$PORT_CHECK_CMD" == "nc" ]]; then
        nc -z -w "$TIMEOUT" localhost "$port" &>/dev/null
    else
        timeout "$TIMEOUT" bash -c "echo >/dev/tcp/localhost/$port" &>/dev/null
    fi
}

# ============================================================================
# systemd Functions
# ============================================================================

HAS_SYSTEMCTL=false

detect_systemctl() {
    if command -v systemctl &>/dev/null; then
        HAS_SYSTEMCTL=true
    fi
}

# Check if a systemd unit exists (is known to systemd)
systemd_unit_exists() {
    local unit="$1"
    [[ "$HAS_SYSTEMCTL" == true ]] || return 1
    local load_state
    load_state=$(systemctl show "${unit}.service" --property=LoadState --value 2>/dev/null)
    [[ "$load_state" == "loaded" ]]
}

# Get the active state of a systemd unit (active, inactive, failed, etc.)
systemd_active_state() {
    local unit="$1"
    [[ "$HAS_SYSTEMCTL" == true ]] || return 1
    systemctl is-active "${unit}.service" 2>/dev/null
}

# ============================================================================
# Service Detection
# ============================================================================

is_installed() {
    local binary="$1"
    local unit="$2"
    command -v "$binary" &>/dev/null && return 0
    systemd_unit_exists "$unit" && return 0
    return 1
}

# ============================================================================
# Output Functions
# ============================================================================

print_service_up() {
    local name="$1"
    local port="$2"
    local pad="$3"
    printf "${GREEN}✓ %-${pad}s :${port}${NC}\n" "$name"
}

print_service_down() {
    local name="$1"
    local port="$2"
    local pad="$3"
    local status="$4"
    if [[ -n "$status" ]]; then
        printf "${RED}✗ %-${pad}s :${port} (${status})${NC}\n" "$name"
    else
        printf "${RED}✗ %-${pad}s :${port}${NC}\n" "$name"
    fi
}

print_service_not_installed() {
    local name="$1"
    local pad="$2"
    printf "${GRAY}- %-${pad}s (not installed)${NC}\n" "$name"
}

# ============================================================================
# Filter Functions
# ============================================================================

# Case-insensitive check if a name matches any filter
matches_filter() {
    local name="$1"
    shift
    local filters=("$@")
    local name_lower="${name,,}"
    local f
    for f in "${filters[@]}"; do
        [[ "${f,,}" == "$name_lower" ]] && return 0
    done
    return 1
}

# ============================================================================
# Core Check Logic
# ============================================================================

run_checks() {
    local filters=("$@")
    local has_filters=false
    [[ ${#filters[@]} -gt 0 ]] && has_filters=true

    # Calculate column width from all service names
    local max_len=0
    local entry name binary port unit
    for entry in "${SERVICES[@]}"; do
        name="${entry%%:*}"
        [[ ${#name} -gt $max_len ]] && max_len=${#name}
    done

    local total=0
    local up=0

    for entry in "${SERVICES[@]}"; do
        IFS=':' read -r name binary port unit <<< "$entry"

        # Apply filter if arguments were provided
        if [[ "$has_filters" == true ]]; then
            if ! matches_filter "$name" "${filters[@]}"; then
                continue
            fi
        fi

        if ! is_installed "$binary" "$unit"; then
            if [[ "$has_filters" == true ]]; then
                print_service_not_installed "$name" "$max_len"
            fi
            continue
        fi

        (( total += 1 ))

        if check_port "$port"; then
            print_service_up "$name" "$port" "$max_len"
            (( up += 1 ))
        else
            local status=""
            if [[ "$HAS_SYSTEMCTL" == true ]] && systemd_unit_exists "$unit"; then
                status=$(systemd_active_state "$unit" || true)
            fi
            print_service_down "$name" "$port" "$max_len" "$status"
        fi
    done

    if [[ $total -eq 0 ]]; then
        echo "No installed services found"
        return 0
    fi

    echo ""
    echo "${up}/${total} services available"

    [[ $up -eq $total ]]
}

validate_filters() {
    [[ $# -eq 0 ]] && return 0

    local all_names=()
    local entry
    local has_unknown=false
    for entry in "${SERVICES[@]}"; do
        all_names+=("${entry%%:*}")
    done
    for filter in "$@"; do
        if ! matches_filter "$filter" "${all_names[@]}"; then
            echo -e "${RED}Unknown service: ${filter}${NC}" >&2
            has_unknown=true
        fi
    done
    [[ "$has_unknown" == false ]]
}

watch_services() {
    local interval="$1"
    shift
    local filters=("$@")
    local resize=0

    trap 'echo ""; exit 130' INT
    trap 'echo ""; exit 143' TERM
    trap 'resize=1' WINCH

    clear
    while true; do
        if (( resize )); then
            clear
            resize=0
        else
            tput cup 0 0
            tput ed
        fi

        echo "Services ($(date '+%Y-%m-%d %H:%M:%S'))"
        echo ""
        run_checks "${filters[@]}" || true
        echo ""
        echo -e "${GRAY}[Watching every ${interval}s - Ctrl+C to stop]${NC}"
        sleep "$interval"
    done
}

main() {
    local original_args=("$@")
    local watch_mode=false
    local watch_interval=10
    local filters=()

    # Parse arguments: --watch [seconds] [service ...]
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --watch)
                watch_mode=true
                if [[ $# -gt 1 ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
                    watch_interval="$2"
                    shift
                fi
                ;;
            *)
                filters+=("$1")
                ;;
        esac
        shift
    done

    # Enforce minimum watch interval to prevent busy loops
    [[ "$watch_interval" -lt 1 ]] && watch_interval=1

    # Defense-in-depth: reap stale atomic-rename temps from prior interrupted
    # runs. Catch-all glob covers any ~*.tmp.?????? in $SCRIPT_DIR.
    sweep_stale_temps '~*.tmp.??????'

    # Self-update check
    if detect_download_cmd && [[ ${scriptUpdated:-0} -eq 0 ]]; then
        self_update "${original_args[@]}" || true
        echo ""
    fi

    detect_port_checker
    detect_systemctl
    validate_filters "${filters[@]}"

    if [[ "$watch_mode" == true ]]; then
        watch_services "$watch_interval" "${filters[@]}"
    else
        run_checks "${filters[@]}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
