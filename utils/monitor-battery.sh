#!/usr/bin/env bash
set -euo pipefail

while (true); do
    date +' %k:%M'
    # No percentage line (no battery, or upower missing) prints nothing and keeps looping.
    upower -i /org/freedesktop/UPower/devices/battery_BAT1 | grep 'percentage' || true
    sleep 60s
done
