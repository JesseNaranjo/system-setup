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

./stop-lxc.sh ${CONTAINER_NAME}
sleep 1s
echo
./start-lxc.sh ${CONTAINER_NAME}
