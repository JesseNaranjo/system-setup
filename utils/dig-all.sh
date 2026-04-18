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
