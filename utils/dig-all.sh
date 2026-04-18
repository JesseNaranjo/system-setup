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

declare -A RECORD_DESCRIPTIONS=(
    [A]="IPv4 address"
    [AAAA]="IPv6 address"
    [CNAME]="alias to another name"
    [MX]="mail server"
    [NS]="authoritative nameservers"
    [SOA]="zone authority info"
    [TXT]="arbitrary text (SPF, DKIM, verification)"
    [SRV]="service location (host:port)"
    [CAA]="allowed cert authorities"
    [PTR]="reverse DNS (IP → name)"
    [DNSKEY]="DNSSEC public key"
    [DS]="DNSSEC delegation signer"
    [NAPTR]="service-pointer rewriting (ENUM, SIP)"
    [SPF]="sender policy (legacy; use TXT)"
    [TLSA]="TLS cert pinning (DANE)"
    [SSHFP]="SSH host key fingerprint"
)
readonly RECORD_DESCRIPTIONS

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
    printf '%b\n\n' "${GREEN}dig-all.sh${NC} - Query all common DNS record types for one or more domains"
    printf '%b\n' "${BLUE}Usage:${NC}"
    printf '  ./dig-all.sh [--resolver SERVER] [-h|--help] [domain ...]\n\n'
    printf '%b\n' "${BLUE}Options:${NC}"
    printf '  --resolver SERVER  Query SERVER instead of the system default (forwarded\n'
    printf '                     to dig as @SERVER).\n'
    printf '  -h, --help         Show this help and exit.\n\n'
    printf '%b\n' "${BLUE}Examples:${NC}"
    printf '  ./dig-all.sh example.com\n'
    printf '  ./dig-all.sh --resolver 1.1.1.1 example.com\n'
    printf '  ./dig-all.sh example.com google.com anthropic.com\n'
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

# ============================================================================
# Validation
# ============================================================================

validate_resolver() {
    local server="$1"
    if [[ ! "$server" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; then
        print_error "✖ Invalid resolver: '$server'"
        exit 1
    fi
}

# ============================================================================
# Query Logic
# ============================================================================

# Queries every RECORD_TYPES entry for $1 via dig, populates
# COUNTS_BY_TYPE["${domain}|${type}"] with the answer count, and prints
# the per-type detail block only when answers exist. Prints a warning
# if every type returned zero answers for the domain.
#
# Args: $1 = domain, $2 = resolver (empty string for system default)
query_domain() {
    local domain="$1"
    local resolver="$2"
    local type answers count total=0
    local resolver_arg=()
    [[ -n "$resolver" ]] && resolver_arg=("@$resolver")

    echo ""
    echo -e "${CYAN}── ${domain} ──${NC}"

    for type in "${RECORD_TYPES[@]}"; do
        answers="$(dig +noall +answer +nocomments +additional \
            "${resolver_arg[@]}" "$type" "$domain" 2>/dev/null || true)"
        if [[ -n "$answers" ]]; then
            count=$(printf '%s\n' "$answers" | grep -c .)
            echo -e "${BLUE}[ ${type} — ${RECORD_DESCRIPTIONS[$type]} ]${NC}"
            printf '%s\n' "$answers"
        else
            count=0
        fi
        COUNTS_BY_TYPE["${domain}|${type}"]="$count"
        total=$((total + count))
    done

    if [[ $total -eq 0 ]]; then
        print_warning "No records found for ${domain}"
    fi
}

# ============================================================================
# Summary Rendering
# ============================================================================

render_summary_table() {
    local domains=("$@")
    local domain type count
    local max_domain_len=6  # len("domain")
    for domain in "${domains[@]}"; do
        [[ ${#domain} -gt $max_domain_len ]] && max_domain_len=${#domain}
    done

    echo ""
    printf "${BLUE}%-${max_domain_len}s${NC}" "domain"
    for type in "${RECORD_TYPES[@]}"; do
        printf " ${BLUE}%6s${NC}" "$type"
    done
    echo ""

    for domain in "${domains[@]}"; do
        printf "%-${max_domain_len}s" "$domain"
        for type in "${RECORD_TYPES[@]}"; do
            count="${COUNTS_BY_TYPE["${domain}|${type}"]:-0}"
            if [[ "$count" -eq 0 ]]; then
                printf " ${GRAY}%6s${NC}" "-"
            else
                printf " %6s" "$count"
            fi
        done
        echo ""
    done
}

# ============================================================================
# Main
# ============================================================================

main() {
    local resolver=""
    local domains=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            --resolver)
                if [[ $# -lt 2 ]] || [[ "$2" == -* ]]; then
                    print_error "✖ --resolver requires a non-flag argument"
                    show_usage >&2
                    exit 1
                fi
                resolver="$2"
                shift
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    domains+=("$1")
                    shift
                done
                break
                ;;
            -*)
                print_error "✖ Unknown option: $1"
                show_usage >&2
                exit 1
                ;;
            *)
                domains+=("$1")
                ;;
        esac
        shift
    done

    if [[ ${#domains[@]} -eq 0 ]]; then
        show_usage
        exit 0
    fi

    detect_dig
    [[ -n "$resolver" ]] && validate_resolver "$resolver"

    local domain
    for domain in "${domains[@]}"; do
        query_domain "$domain" "$resolver"
    done

    if [[ ${#domains[@]} -ge 2 ]]; then
        render_summary_table "${domains[@]}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
