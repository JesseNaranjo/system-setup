#! /bin/bash

if [[ ! -f ~/.screenrc-ollama || $1 == '--overwrite' ]]
then
  cat <<'EOF' > ~/.screenrc-ollama

  # Split screen into two columns
  split -v

  # Left column:
  #  - Horizontal split for top and bottom-left screens
  screen -t "shell"
  split
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
  sleep 1
  stuff "clear; ollama ps; ollama list | { IFS= read -r header; print -r \$header; sort -k1,1 }\n"

  # Move bottom-left
  focus down

EOF
fi

screen -Uamc ~/.screenrc-ollama
