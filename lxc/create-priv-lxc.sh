#!/usr/bin/env bash

echo "USING PRIVILEGED CONTAINERS IS UNSAFE"

## Input parameters
## ================

CONTAINER_NAME=$1
ID_NO=${2:-100000}

## No touchy
## =========

SUB_ENTRY="root:${ID_NO}:65536"

if ! grep -q "${SUB_ENTRY}" "/etc/subuid";
then
    echo "Adding \"${SUB_ENTRY} # LXC ${CONTAINER_NAME}\" to /etc/subuid..."
    echo "# LXC ${CONTAINER_NAME}" | sudo tee -a /etc/subuid > /dev/null
    echo "${SUB_ENTRY}" | sudo tee -a /etc/subuid > /dev/null
fi

if ! grep -q "${SUB_ENTRY}" "/etc/subgid";
then
    echo "Adding \"${SUB_ENTRY} # LXC ${CONTAINER_NAME}\" to /etc/subgid..."
    echo "# LXC ${CONTAINER_NAME}" | sudo tee -a /etc/subgid > /dev/null
    echo "${SUB_ENTRY}" | sudo tee -a /etc/subgid > /dev/null
fi

sudo cp -av /etc/lxc/default.conf "/etc/lxc/${CONTAINER_NAME}.conf"

echo "Adding \"lxc.idmap = u 0 ${ID_NO} 65536\" to /etc/lxc/${CONTAINER_NAME}.conf..."
echo "lxc.idmap = u 0 ${ID_NO} 65536" | sudo tee -a /etc/lxc/${CONTAINER_NAME}.conf > /dev/null

echo "Adding \"lxc.idmap = g 0 ${ID_NO} 65536\" to /etc/lxc/${CONTAINER_NAME}.conf..."
echo "lxc.idmap = g 0 ${ID_NO} 65536" | sudo tee -a /etc/lxc/${CONTAINER_NAME}.conf > /dev/null

sudo lxc-create --config "/etc/lxc/${CONTAINER_NAME}.conf" --name "${CONTAINER_NAME}" --template download

sudo rm -v "/etc/lxc/${CONTAINER_NAME}.conf"

sudo lxc-ls --fancy
