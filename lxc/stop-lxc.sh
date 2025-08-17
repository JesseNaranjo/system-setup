#!/bin/bash

set -euo pipefail

if [[ $# -eq 0 || -z ${1-} ]]; then
	# No LXCs specified, so stop all running LXCs
	lxc-ls --running
	RUNNING=( $(/usr/bin/lxc-ls --running) )
else
	RUNNING=$@
fi

for lxcName in "${RUNNING[@]}"; do
	echo; echo "Stopping LXC ${lxcName}..."
	lxc-stop --name "${lxcName}"
	sleep 1s
done

echo
lxc-ls --fancy
