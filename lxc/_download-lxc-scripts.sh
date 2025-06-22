#!/bin/bash

curl --remote-name-all --remote-time\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/lxc/create-priv-container.sh\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/lxc/setup-containers.sh\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/lxc/start-container.sh\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/lxc/stop-container.sh

chmod -vv +x\
	create-priv-container.sh\
	setup-containers.sh\
	start-container.sh\
	stop-container.sh
