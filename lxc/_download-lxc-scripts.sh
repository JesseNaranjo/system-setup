#!/bin/bash

if [[ $updated -eq 0 || -z $updated ]]; then
	TEMP_SCRIPT_FILE=/tmp/_download-lxc-scripts.sh

	rm $TEMP_SCRIPT_FILE
	curl --header 'Cache-Control: no-cache' --output $TEMP_SCRIPT_FILE https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/llm/_download-lxc-scripts.sh

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
	else
		rm $TEMP_SCRIPT_FILE
	fi

	exit 0
fi

curl --remote-name-all --remote-time\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/lxc/create-priv-lxc.sh\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/lxc/restart-lxc.sh\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/lxc/setup-lxc.sh\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/lxc/start-lxc.sh\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/lxc/stop-lxc.sh

chmod -vv +x\
	create-priv-lxc.sh\
	restart-lxc.sh\
	setup-lxc.sh\
	start-lxc.sh\
	stop-lxc.sh
