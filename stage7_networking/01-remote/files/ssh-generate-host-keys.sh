#!/bin/bash

set -euo pipefail

if [ -r /etc/default/ssh-host-keys ]; then
	. /etc/default/ssh-host-keys
fi

install -d -m 0755 "${KEY_DIR}"

for TYPE in ${KEY_TYPES}; do
	KEY="${KEY_DIR}/ssh_host_${TYPE}_key"

	if [ -f "${KEY}" ]; then
		continue
	fi

	echo "ssh-host-keys-generate: generating the ${TYPE} host key"
	ssh-keygen -q -t "${TYPE}" -f "${KEY}" -N ''
done
