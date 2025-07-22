#!/bin/bash

SCREEN_DOTFILE=".screenrc-ollama"

if [[ ! -f $SCREEN_DOTFILE || $1 == '--overwrite' ]]
then
  cat <<'EOF' > $SCREEN_DOTFILE

  # Split screen into two columns
  split -v

  # Left column:
  #  - Horizontal split for top and bottom-left screens
  screen -t "shell"
  split
  resize 35%
  focus down
  screen -t "shell"

  # Right column:
  #  - Top-right: nvtop
  focus right
  screen nvtop
  #  - Middle: htop
  split
  focus down
  screen htop
  #  - Bottom: ollama serve
  split
  focus down
  screen ollama serve

  # Move top-left
  focus top
  sleep 3
  stuff "clear; ollama ps; ollama list | { IFS= read -r header; print -r \$header; sort -k1,1 }\n"

  # Move bottom-left
  focus down

EOF
fi

screen -Uamc $SCREEN_DOTFILE -T $TERM
