#! /bin/bash

if [[ ! -f ~/.screenrc-ollama || $1 == '--overwrite' ]]
then
  cat <<EOF > ~/.screenrc-ollama

  # Create a new screen session
  screen -t 'LLM Screens'

  # Split screen into two columns
  split -v

  # Left column: horizontal split for top-left and bottom-right screens
  split
  focus down
  screen

  # Move to the top-right pane and run nvtop
  focus right
  screen nvtop

  # Right column: horizontal split (2 screens)
  split
  focus down
  screen htop

  # Right column: horizontal split (3 screens)
  split
  focus down
  screen ollama serve

  # Move top-left
  focus left
  focus up
  stuff "ollama list | sort\n"

  # Move bottom-left
  focus down

EOF
fi

screen -Uamc ~/.screenrc-ollama
