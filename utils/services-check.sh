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

readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly GRAY='\033[0;90m'
readonly NC='\033[0m'

readonly TIMEOUT=2

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
    "Redis:redis-server:6379:redis-server"
    "Valkey:valkey-server:6379:valkey-server"
)

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
        echo -e "${RED}Error: Neither 'nc' (netcat) nor 'timeout' found.${NC}" >&2
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

    trap 'echo ""; exit 0' INT TERM

    while true; do
        clear
        echo "Services ($(date '+%Y-%m-%d %H:%M:%S'))"
        echo ""
        run_checks "${filters[@]}" || true
        echo ""
        echo -e "${GRAY}[Watching every ${interval}s - Ctrl+C to stop]${NC}"
        sleep "$interval"
    done
}

main() {
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
