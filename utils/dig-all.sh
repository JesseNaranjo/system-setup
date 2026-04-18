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
