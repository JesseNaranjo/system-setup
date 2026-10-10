#!/usr/bin/env bash
set -euo pipefail

while (true); do
    date +' %k:%M'
    # No percentage line when this host has no battery_BAT1 (no battery, or another name); keep looping.
    upower -i /org/freedesktop/UPower/devices/battery_BAT1 | grep 'percentage' || true
    sleep 60s
done
