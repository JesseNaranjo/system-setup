#!/bin/bash

## Input parameters

CONTAINER_NAME=$1

## No touchy

echo "Stopping LXC ${CONTAINER_NAME}..."
sudo lxc-stop --name ${CONTAINER_NAME}

sleep 1s

sudo lxc-ls --fancy
