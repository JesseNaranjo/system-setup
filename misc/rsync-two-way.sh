#!/usr/bin/env bash
#
#  bidirsync.sh — minimal two-way directory synchroniser using rsync
#  Usage:   bidirsync.sh  LOCAL_DIR   REMOTE_SPEC
#           REMOTE_SPEC := user@host:/absolute/path
#  Exit codes: 0 OK | 1 usage | 2 rsync error
#
set -euo pipefail

[[ $# -ne 2 ]] && { echo "Usage: $0 LOCAL_DIR user@host:/path"; exit 1; }

LOCAL="$1"           # e.g. /srv/share/
REMOTE="$2"          # e.g. alice@backup.example.com:/srv/share/
STAMP=$(date +%F_%H-%M-%S)

# Patterns you never want to copy
EXCLUDES=(
  ".DS_Store" ".git/" "node_modules/" "Thumbs.db"
)

# Core rsync switches (see man rsync)
OPTS=(
  --archive       # -a: recurse; preserve mode, owner, times, links…
  --verbose       # -v
  --human-readable
  --hard-links
  --delete        # mirror deletions
  --update        # do NOT overwrite newer files on receiver
  --partial       # keep temp files if transfer interrupted
  --inplace
  #--backup        # keep overwritten/deleted files
  #--backup-dir=".$STAMP.bak"   # quarantined here on each side
  #--delay-updates # batch replace at end
  --itemize-changes
)

for e in "${EXCLUDES[@]}"; do OPTS+=(--exclude="$e"); done

# ---------- Pass 1: push LOCAL ➜ REMOTE ----------
rsync "${OPTS[@]}" "$LOCAL/"  "$REMOTE"  || exit 2

# ---------- Pass 2: pull REMOTE ➜ LOCAL ----------
rsync "${OPTS[@]}" "$REMOTE/" "$LOCAL"   || exit 2
