#!/usr/bin/env bash

set -euo pipefail

# Configuration
readonly SCREEN_DOTFILE=".screenrc-ollama"

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
# GNU Screen configuration for Ollama local server
startup_message off
defscrollback 10000

# Split screen into two columns
split -v

# Left column - shell panes
# Top-left: primary shell
screen -t "shell"
split
resize 35%
focus down
# Bottom-left: secondary shell
screen -t "shell"

# Right column - monitoring and server
# Top-right: nvtop (GPU monitoring)
focus right
screen nvtop
# Middle-right: htop (CPU/memory monitoring)
split
focus down
screen htop
# Bottom-right: ollama server
split
focus down
screen -t "ollama serve" ollama serve

# Move to top-left shell and run status commands
focus top
sleep 3
stuff "clear; ollama ps; ollama list | { IFS= read -r header; print -r \$header; sort -k1,1 }\n"

# Move to bottom-left shell for user input
focus down
EOF
    echo "Created screen configuration: $SCREEN_DOTFILE"
fi

# Launch screen session
exec screen -Uamc "$SCREEN_DOTFILE" -T "${TERM:-screen-256color}"
