#! /bin/bash


echo_internal() {
	printf "\n$1\n"
}


# Stop and disable kubelet + cri-o

echo_internal "Stopping and disabling kubelet and cri-o services..."
(
	set -x
	sudo systemctl disable kubelet.service crio.service --now
)


# Pre-start config

echo_internal "Turning on swap..."
(
	set -x
	sudo swapon -a
)

echo_internal "Disabling IP forwarding..."
(
	set -x
	sudo sysctl net.ipv4.conf.all.forwarding=0
)


echo_internal ""
SYSCTL_STATUS_OUTPUT=$(
	sudo systemctl status crio.service kubelet.service
)
echo "${SYSCTL_STATUS_OUTPUT}"
