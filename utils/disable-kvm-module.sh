#!/bin/bash
set -euo pipefail

# modprobe -r succeeds on a module that is not loaded, so these fail only when
# the kernel lacks the module or cannot unload it (in use, or not root). Try
# every removal either way; the last one's status is the script's exit status.
modprobe -r kvm_intel || true
modprobe -r kvm_amd || true
modprobe -r kvm
