#!/usr/bin/env bash

# This script sets the MTU of the eth0 interface to 1200 to fix issues with git commands.

# The problem arises when the default MTU is too high for certain network configurations,
# leading to timeouts or failed connections when performing git operations.

# Simple commands like `git fetch` or `git clone` may fail due to packet fragmentation or loss.
# To resolve this, we adjust the MTU to a lower value.

sudo ip link set dev eth0 mtu 1200
