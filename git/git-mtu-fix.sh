#!/usr/bin/env bash

MTU=1200

current_mtu=$(cat /sys/class/net/eth0/mtu)
if [[ "$current_mtu" == "$MTU" ]]; then
    echo "MTU is already set to $MTU"
    exit 0
fi

sudo ip link set dev eth0 mtu "$MTU"
