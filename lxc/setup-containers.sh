#!/bin/bash


## Input parameters
## ================

if [[ $# -eq 0 || -z ${1-} ]]; then
	printf 'Usage:  %s <username> [sid]\n' "${0##*/}" >&2
	exit 64  # 64 - EX_USAGE (sysexits.h)
fi
LIMITED_USER=$1

if ! id -u "$LIMITED_USER" >/dev/null 2>&1; then
	printf 'Error: user “%s” does not exist on this system.\n' "$LIMITED_USER" >&2
	exit 67  # 67 - EX_NOUSER
fi

ID_NO=${2:-100000}


## No touchy
## =========

# Backup default.conf

if [[ ! -f /etc/lxc/default.conf.original ]] then
	echo "Backing up /etc/lxc/default.conf as default.conf.original..."
	sudo cp -av /etc/lxc/default.conf /etc/lxc/default.conf.original
	echo ""
fi


# Ensure user is allowed to have veth interfaces

VETH_ENTRY="$LIMITED_USER veth lxcbr0 10"

if ! grep -q "$VETH_ENTRY" /etc/lxc/lxc-usernet; then
	echo "Adding \"$VETH_ENTRY\" to /etc/lxc/lxc-usernet..."
	echo "$VETH_ENTRY" | sudo tee -a /etc/lxc/lxc-usernet > /dev/null
	echo ""
fi


# Add subuid and subgid entries

SUB_ENTRY="$LIMITED_USER:$ID_NO:65535"

if ! grep -q "$SUB_ENTRY" /etc/subuid; then
	echo "Adding \"$SUB_ENTRY\" to /etc/subuid..."
	echo "$SUB_ENTRY" | sudo tee -a /etc/subuid > /dev/null
	echo ""
fi

if ! grep -q "$SUB_ENTRY" /etc/subgid; then
	echo "Adding \"$SUB_ENTRY\" to /etc/subgid..."
	echo "$SUB_ENTRY" | sudo tee -a /etc/subgid > /dev/null
	echo ""
fi


# Output value confirming if user-namespace supposed is enabled

echo "Verifying user-namespace is enabled..."
USER_NAMESPACE_ENABLED=$(sudo sysctl -n kernel.unprivileged_userns_clone)
sudo sysctl kernel.unprivileged_userns_clone

if [[ "$USER_NAMESPACE_ENABLED" -eq 0 ]]; then
	echo "- User-namespace not enabled, enabling permanently..."
	sudo sysctl -w kernel.unprivileged_userns_clone=1
	echo "kernel.unprivileged_userns_clone = 1" | sudo tee /etc/sysctl.d/99-lxc.conf
	sudo sysctl --system # reload all sysctl settings
fi
echo ""


# Prepare ${LIMITED_USER}'s default LXC configuration

LIMITED_USER_HOME="/home/$LIMITED_USER"
LIMITED_USER_CONFIG_LXC="$LIMITED_USER_HOME/.config/lxc"

echo "Creating user's default LXC config..."
echo "$LIMITED_USER_CONFIG_LXC/default.conf"
sudo mkdir -p "$LIMITED_USER_CONFIG_LXC"

sudo tee "$LIMITED_USER_CONFIG_LXC/default.conf" > /dev/null <<EOF
# ID Map must match range found in /etc/subuid and /etc/subgid for "$LIMITED_USER"
lxc.idmap = u 0 $ID_NO 65535
lxc.idmap = g 0 $ID_NO 65535

# AppArmor Profile "unconfined" is necessary for networking to work (as of 2025-06-21)
lxc.apparmor.profile = unconfined

lxc.net.0.name = eth0
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
EOF

echo ""

sudo chmod -v +x "$LIMITED_USER_HOME"
if [[ -d "$LIMITED_USER_HOME/.local" ]]; then
	sudo chmod -v +x "$LIMITED_USER_HOME/.local"
	if [[ -d "$LIMITED_USER_HOME/.local/share" ]]; then
		sudo chmod -v +x "$LIMITED_USER_HOME/.local/share"
		if [[ -d "$LIMITED_USER_HOME/.local/share/lxc" ]]; then
			sudo chmod -v +x "$LIMITED_USER_HOME/.local/share/lxc"
		fi
	fi
fi
sudo chown -v ${LIMITED_USER}:${LIMITED_USER} "$LIMITED_USER_CONFIG_LXC"
sudo chown -v ${LIMITED_USER}:${LIMITED_USER} "$LIMITED_USER_CONFIG_LXC/default.conf"
