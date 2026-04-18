#!/usr/bin/env bash

# dig-all.sh - Query all common DNS record types for one or more domains
#
# Usage: ./dig-all.sh [--resolver SERVER] [-h|--help] [domain ...]
#
# Queries 16 DNS record types (A, AAAA, CNAME, MX, NS, SOA, TXT, SRV, CAA,
# PTR, DNSKEY, DS, NAPTR, SPF, TLSA, SSHFP) against one or more domains.
# With a single domain, prints per-type detail only. With 2+ domains,
# appends a summary-count table after all details.
#
# Options:
#   --resolver SERVER  Query SERVER instead of the system default (forwarded
#                      to dig as @SERVER).
#   -h, --help         Show this help and exit.

set -euo pipefail

readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly GRAY='\033[0;90m'
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

readonly RECORD_TYPES=(A AAAA CNAME MX NS SOA TXT SRV CAA PTR DNSKEY DS NAPTR SPF TLSA SSHFP)

declare -gA COUNTS_BY_TYPE=()

# ============================================================================
# Standard Output Functions
# ============================================================================

print_info() {
    echo -e "${BLUE}[ INFO    ]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[ SUCCESS ]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[ WARNING ]${NC} $1"
}

print_error() {
    echo -e "${RED}[ ERROR   ]${NC} $1"
}

# ============================================================================
# Usage
# ============================================================================

show_usage() {
    cat <<EOF
${GREEN}dig-all.sh${NC} - Query all common DNS record types for one or more domains

${BLUE}Usage:${NC}
  ./dig-all.sh [--resolver SERVER] [-h|--help] [domain ...]

${BLUE}Options:${NC}
  --resolver SERVER  Query SERVER instead of the system default (forwarded
                     to dig as @SERVER).
  -h, --help         Show this help and exit.

${BLUE}Examples:${NC}
  ./dig-all.sh example.com
  ./dig-all.sh --resolver 1.1.1.1 example.com
  ./dig-all.sh example.com google.com anthropic.com
EOF
}

# ============================================================================
# Prerequisite Detection
# ============================================================================

detect_dig() {
    command -v dig &>/dev/null && return 0
    print_error "✖ 'dig' not found."
    case "$OSTYPE" in
        linux-gnu*)
            if command -v apt &>/dev/null; then
                echo "Install with: sudo apt install dnsutils" >&2
            elif command -v dnf &>/dev/null; then
                echo "Install with: sudo dnf install bind-utils" >&2
            elif command -v pacman &>/dev/null; then
                echo "Install with: sudo pacman -S bind" >&2
            else
                echo "Install your distribution's DNS utilities package." >&2
            fi
            ;;
        darwin*)
            echo "Install with: brew install bind" >&2
            ;;
        *)
            echo "Install the DNS utilities package for your platform." >&2
            ;;
    esac
    exit 1
}
