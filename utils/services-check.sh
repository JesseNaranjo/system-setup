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
        echo "Install netcat: sudo apt install netcat-openbsd" >&2
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

main() {
    detect_port_checker
    if check_port 22; then
        echo -e "${GREEN}Port 22 is open${NC}"
    else
        echo -e "${RED}Port 22 is closed${NC}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
