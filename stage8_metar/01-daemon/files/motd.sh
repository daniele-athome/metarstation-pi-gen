#!/bin/sh

[ -r /etc/rpi-issue ] && cat /etc/rpi-issue
[ -r /etc/metar-issue ] && tail -n 1 /etc/metar-issue
exit 0
