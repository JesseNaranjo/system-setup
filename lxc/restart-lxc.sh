#!/bin/bash

set -euo pipefail

## No touchy
## =========

if [[ $# -eq 0 || -z ${1-} ]]; then
	# No LXCs specified, so stop all running LXCs
	lxc-ls --running
	RUNNING=( $(/usr/bin/lxc-ls --running) )
else
	RUNNING=("$@")
fi

./stop-lxc.sh "${RUNNING[@]}"
sleep 1s
./start-lxc.sh "${RUNNING[@]}"
