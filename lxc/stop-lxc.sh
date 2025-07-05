#!/bin/bash


## Input parameters
## ================

if [[ $# -eq 0 || -z ${1-} ]]; then
	printf 'Usage:  %s <container name> [[container name], ...]\n' "${0##*/}" >&2
	exit 64  # 64 - EX_USAGE (sysexits.h)
fi


## No touchy
## =========

for lxcName in "$@"; do
	echo; echo "Stopping LXC ${lxcName}..."
	lxc-stop --name "${lxcName}"
	sleep 1s
done

echo
lxc-ls --fancy
