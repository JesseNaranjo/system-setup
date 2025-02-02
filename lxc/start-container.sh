#!/bin/bash

## Input parameters

CONTAINER_NAME=$1

## No touchy

echo "Starting LXC ${CONTAINER_NAME}..."
sudo lxc-start --name ${CONTAINER_NAME}

x=5; while  [ $x -gt 0 ]; do echo "Attaching in $(( x-- ))..."; sleep 1s; done

sudo lxc-attach --name ${CONTAINER_NAME}
