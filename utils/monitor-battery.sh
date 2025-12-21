#!/usr/bin/env bash

while (true); do
    date +' %k:%M'
    upower -i /org/freedesktop/UPower/devices/battery_BAT1 | grep 'percentage'
    sleep 60s
done
