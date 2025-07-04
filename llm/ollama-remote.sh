#! /bin/bash

if [[ ! -f .screenrc-ollama-rmt || $1 == '--overwrite' ]]
then
  cat <<'EOF' > .screenrc-ollama-rmt

  # Split screen into two columns
  split -v

  # Left column:
  #  - Top-left: nvtop
  screen nvtop
  #  - Middle: htop
  split
  focus down
  screen htop
  #  - Bottom: screen
  split
  focus down
  screen -t "shell"

  # Move Right: ollama serve
  focus right
  screen -t "ollama serve"
  stuff "clear; export OLLAMA_HOST=0.0.0.0:11434; ollama serve\n"

  # Move bottom-left
  focus left
  focus down
  focus down
  sleep 3
  stuff "clear; ollama ps; ollama list | { IFS= read -r header; print -r \$header; sort -k1,1 }\n"

EOF
fi

screen -Uamc .screenrc-ollama-rmt -T $TERM
