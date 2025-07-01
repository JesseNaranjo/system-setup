#!/bin/bash

if [[ $updated -eq 0 || -z $updated ]]; then
	SCRIPT_FILE=_download-k8s-scripts.sh
	TEMP_SCRIPT_FILE=/tmp/$SCRIPT_FILE

	rm $TEMP_SCRIPT_FILE
	curl --header 'Cache-Control: no-cache' --output $TEMP_SCRIPT_FILE https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/kubernetes/$SCRIPT_FILE

	LINE_COLOR='\033[0;33m'
	CODE_COLOR='\033[40m'
	RESET_COLOR='\033[0m'
	echo -e "${LINE_COLOR}-------------------------------------------------- CODE --------------------------------------------------${RESET_COLOR}${CODE_COLOR}"
	cat $TEMP_SCRIPT_FILE
		echo -e "${RESET_COLOR}${LINE_COLOR}--------------------------------------------- ^ CODE / DIFF v --------------------------------------------${RESET_COLOR}"
	diff --color ${BASH_SOURCE[0]} $TEMP_SCRIPT_FILE
	echo -e "${LINE_COLOR}-------------------------------------------------- DIFF --------------------------------------------------${RESET_COLOR}\n"

	read -p "This file will be executed. Does this look safe to run?: (y/n [n]) " continueExec
	echo ""

	if [[ $continueExec == [Yy] ]]; then
		chmod +x $TEMP_SCRIPT_FILE
		export updated=1
		$TEMP_SCRIPT_FILE
		unset updated
		mv $TEMP_SCRIPT_FILE ${BASH_SOURCE[0]}
	else
		rm $TEMP_SCRIPT_FILE
	fi

	exit 0
fi

curl --header 'Cache-Control: no-cache' --remote-name-all --remote-time\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/kubernetes/install-update-helm.sh\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/kubernetes/start-k8s.sh\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/kubernetes/stop-k8s.sh\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/kubernetes/update-k8s-repos.sh

chmod -vv +x\
	install-update-helm.sh\
	start-k8s.sh\
	stop-k8s.sh\
	update-k8s-repos.sh
