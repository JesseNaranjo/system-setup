#!/bin/bash

## Input parameters
## ================

if [[ $# -eq 0 || -z ${1-} ]]; then
	printf 'Usage:  %s <container name>\n' "${0##*/}" >&2
	exit 64  # 64 - EX_USAGE (sysexits.h)
fi
CONTAINER_NAME=$1

## No touchy
## =========

echo "Starting LXC $CONTAINER_NAME..."
lxc-unpriv-start --name ${CONTAINER_NAME}

echo ""
x=3; while  [ $x -gt 0 ]; do echo "Attaching in $(( x-- ))..."; sleep 1s; done

echo ""
lxc-ls --fancy

echo ""
lxc-unpriv-attach --name ${CONTAINER_NAME}
