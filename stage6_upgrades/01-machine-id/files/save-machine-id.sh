#!/bin/bash
# Save the machine ID on the data partition, where the initramfs picks it up at
# the next boot (see /etc/initramfs-tools/scripts/init-bottom/machine-id).

set -eu

DEFAULTS=/etc/default/machine-id
MACHINE_ID=/etc/machine-id

# A machine ID is 32 lowercase hexadecimal digits, anything else is not one.
is_machine_id() {
	case "$1" in
		*[!0-9a-f]*) return 1 ;;
	esac

	[ "${#1}" -eq 32 ]
}

. "${DEFAULTS}"

STATE_FILE="${DATA_MOUNT}/${STATE_REL}"

read -r CURRENT < "${MACHINE_ID}" || CURRENT=""

if ! is_machine_id "${CURRENT}"; then
	echo "save-machine-id: ${MACHINE_ID} does not hold a machine ID" >&2
	exit 1
fi

SAVED=""
if [ -r "${STATE_FILE}" ]; then
	read -r SAVED < "${STATE_FILE}" || SAVED=""
fi

if is_machine_id "${SAVED}"; then
	if [ "${SAVED}" = "${CURRENT}" ]; then
		exit 0
	fi

	echo "save-machine-id: ${STATE_FILE} holds ${SAVED} but the system booted as ${CURRENT}" >&2
	echo "save-machine-id: the initramfs did not restore it, refusing to overwrite" >&2
	exit 1
fi

install -d -m 0755 "${DATA_MOUNT}/$(dirname "${STATE_REL}")"

# write and rename, so that the file is either absent or complete
printf '%s\n' "${CURRENT}" > "${STATE_FILE}.new"
chmod 0444 "${STATE_FILE}.new"
mv "${STATE_FILE}.new" "${STATE_FILE}"
sync -f "${STATE_FILE}"

echo "save-machine-id: saved ${CURRENT} to ${STATE_FILE}"
