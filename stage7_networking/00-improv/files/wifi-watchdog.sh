#!/usr/bin/env bash

INTERFACE_NAME=${INTERFACE_NAME:-$1}
PING_TARGET=${PING_TARGET:-$2}

set -euo pipefail

if [[ -z "$INTERFACE_NAME" ]]; then
  echo "Parameters missing. Exiting."
  exit 1
fi

test_ping() {
  local target
  target="${PING_TARGET}"
  if [[ -z "$target" ]]; then
    target=$(ip route show 0.0.0.0/0 dev "$INTERFACE_NAME" | cut -d' ' -f3)
    if [[ -z "$target" ]]; then
      # not connected??
      return 2
    fi
  fi
  ping -i5 -c3 "$target" > /dev/null
}

restart_network() {
  nmcli device up "$INTERFACE_NAME"
}

while true; do
  if ! test_ping; then
    echo "Ping failed, restarting interface"
    restart_network
  fi
  sleep 60s
done
