#!/bin/bash

if [[ $updated -eq 0 || -z $updated ]]; then
	TEMP_SCRIPT_FILE=/tmp/_download-ollama-scripts.sh

	rm $TEMP_SCRIPT_FILE
	curl -o $TEMP_SCRIPT_FILE https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/llm/_download-ollama-scripts.sh

	RED='\033[1;31m'
	NC='\033[0m'
	echo -e "\n${RED}------------------------------------------------------------------------------------------"
	cat $TEMP_SCRIPT_FILE
	echo -e "------------------------------------------------------------------------------------------${NC}\n"

	read -p "This file will be executed. Does this look safe to run?: (y/n [n]) " continueExec
	if [[ $continueExec == [Yy] ]]; then
		chmod +x $TEMP_SCRIPT_FILE
		$(export updated=1; $TEMP_SCRIPT_FILE)
		mv $TEMP_SCRIPT_FILE ${BASH_SOURCE[0]}
	fi

	exit 0
fi

curl --remote-name-all --remote-time\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/llm/ollama-remote.sh\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/llm/ollama-screen.sh

chmod -vv +x\
	ollama-remote.sh\
	ollama-screen.sh
