#!/bin/bash
set -euo pipefail

# A host loads only its own vendor's module, so removing the other one fails.
modprobe -r kvm_intel || true
modprobe -r kvm_amd || true
modprobe -r kvm
