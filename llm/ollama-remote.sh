#!/usr/bin/env bash

set -euo pipefail

# Configuration
readonly SCREEN_DOTFILE=".screenrc-ollama-remote"
export OLLAMA_HOST="${OLLAMA_HOST:-0.0.0.0:11434}"

# Check if screen is installed
if ! command -v screen &> /dev/null; then
    echo "Error: GNU screen is not installed" >&2
    exit 1
fi

# Check if ollama is installed
if ! command -v ollama &> /dev/null; then
    echo "Error: ollama is not installed" >&2
    exit 1
fi

# Create or overwrite screen configuration
if [[ ! -f "$SCREEN_DOTFILE" || "${1:-}" == '--overwrite' ]]; then
    cat <<'EOF' > "$SCREEN_DOTFILE"
# GNU Screen configuration for Ollama remote server
startup_message off
defscrollback 10000

# Split screen into two columns
split -v

# Left column - monitoring panes
# Top-left: nvtop (GPU monitoring)
screen nvtop
# Middle-left: htop (CPU/memory monitoring)
split
focus down
screen htop
# Bottom-left: shell for ollama commands
split
focus down
screen -t "shell"

# Right column - ollama server
focus right
screen -t "ollama serve ${OLLAMA_HOST}" ollama serve

# Move to bottom-left shell and run status commands
focus left
focus down
focus down
sleep 3
stuff "clear; ollama ps; ollama list | { IFS= read -r header; print -r \$header; sort -k1,1 }\n"
EOF
    echo "Screen configuration: $SCREEN_DOTFILE"
fi

# Launch screen session
exec screen -Uamc "$SCREEN_DOTFILE" -T "${TERM:-screen-256color}"
