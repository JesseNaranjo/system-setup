#!/bin/bash

modprobe -r kvm_intel
modprobe -r kvm_amd
modprobe -r kvm
