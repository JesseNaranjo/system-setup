#! /bin/bash

# Pre-start config
sudo swapoff -a
sudo sysctl net.ipv4.conf.all.forwarding=1

# Start crio first
sudo systemctl start crio kubelet

sudo systemctl status kubelet crio
