#!/bin/bash

curl --remote-name-all --remote-time\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/lxc/create-priv-lxc.sh\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/lxc/setup-lxc.sh\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/lxc/start-lxc.sh\
	https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/lxc/stop-lxc.sh

chmod -vv +x\
	create-priv-lxc.sh\
	setup-lxc.sh\
	start-lxc.sh\
	stop-lxc.sh
