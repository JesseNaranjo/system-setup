#!/bin/bash

curl --remote-name-all --remote-time\
		https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/llm/ollama-remote.sh\
		https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/llm/ollama-screen.sh

chmod +x\
		ollama-remote.sh\
		ollama-screen.sh
  
