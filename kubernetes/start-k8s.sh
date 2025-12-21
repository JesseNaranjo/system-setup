#!/usr/bin/env bash


echo_internal() {
    printf "\n$1\n"
}


# Pre-start config

echo_internal "Turning off swap..."
(
    set -x
    sudo swapoff -a
)

echo_internal "Setting IP forwarding..."
(
    set -x
    sudo sysctl net.ipv4.conf.all.forwarding=1
)


# Enable crio + kubelet

echo_internal "Enabling cri-o and kubelet services..."
(
    set -x
    sudo systemctl enable crio.service kubelet.service
)


# Start cri-o + kubelet

echo_internal "Starting cri-o and kubelet services..."
(
    set -x
    sudo systemctl start crio.service kubelet.service
)

echo_internal ""
SYSCTL_STATUS_OUTPUT=$(
    sudo systemctl status crio.service kubelet.service
)
echo -e "${SYSCTL_STATUS_OUTPUT}"

echo_internal ""
sleep 5s
(
    set -x
    kubectl get all --all-namespaces
)
