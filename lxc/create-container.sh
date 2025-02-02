#!/bin/bash

## Input parameters

CONTAINER_NAME=$1
ID_NO=${2:-100000}

## No touchy

SUB_ENTRY="root:${ID_NO}:65536"

if ! grep -q "${SUB_ENTRY}" "/etc/subuid";
then
	echo "Adding \"${SUB_ENTRY} # LXC ${CONTAINER_NAME}\" to /etc/subuid..."
	sudo echo "# LXC ${CONTAINER_NAME}" >> /etc/subuid
	sudo echo "${SUB_ENTRY}" >> /etc/subuid
fi

if ! grep -q "${SUB_ENTRY}" "/etc/subgid";
then
	echo "Adding \"${SUB_ENTRY} # LXC ${CONTAINER_NAME}\" to /etc/subgid..."
	sudo echo "# LXC ${CONTAINER_NAME}" >> /etc/subgid
	sudo echo "${SUB_ENTRY}" >> /etc/subgid
fi

sudo cp -av /etc/lxc/default.conf "/etc/lxc/${CONTAINER_NAME}.conf"

echo "Adding \"lxc.idmap = u 0 ${ID_NO} 65536\" to /etc/lxc/${CONTAINER_NAME}.conf..."
sudo echo "lxc.idmap = u 0 ${ID_NO} 65536" >> /etc/lxc/${CONTAINER_NAME}.conf

echo "Adding \"lxc.idmap = g 0 ${ID_NO} 65536\" to /etc/lxc/${CONTAINER_NAME}.conf..."
sudo echo "lxc.idmap = g 0 ${ID_NO} 65536" >> /etc/lxc/${CONTAINER_NAME}.conf

sudo lxc-create --config "/etc/lxc/${CONTAINER_NAME}.conf" --name "${CONTAINER_NAME}" --template download

sudo rm -v "/etc/lxc/${CONTAINER_NAME}.conf"

sudo lxc-ls --fancy
