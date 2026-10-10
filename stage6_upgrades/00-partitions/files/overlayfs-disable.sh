#!/bin/sh
# Disable the overlay root filesystem, making the root partition writable again.
#
# A reboot is needed for the change to take effect.

set -e

BOOT_DIR="/boot/firmware"
CONFIG="${BOOT_DIR}/config.txt"

# the live cmdline.txt sits under os_prefix, next to the active slot's kernel
active_cmdline() {
	prefix=""
	if [ -r "${CONFIG}" ]; then
		prefix="$(sed -nE 's/^[[:space:]]*os_prefix=([^[:space:]]*).*/\1/p' "${CONFIG}" |
			tr -d '\r' | head -n1)"
	fi

	printf '%s' "${BOOT_DIR}/${prefix}cmdline.txt"
}

CMDLINE="$(active_cmdline)"

if [ ! -f "${CMDLINE}" ]; then
	echo "$0: ${CMDLINE} does not exist" >&2
	exit 1
fi

REMOUNT_RO=no

restore_boot() {
	if [ "${REMOUNT_RO}" = "yes" ]; then
		mount -o remount,ro "${BOOT_DIR}"
	fi
}

trap restore_boot EXIT

if findmnt -no OPTIONS "${BOOT_DIR}" | grep -qE '(^|,)ro(,|$)'; then
	mount -o remount,rw "${BOOT_DIR}"
	REMOUNT_RO=yes
fi

sed -i -E -e 's/(^|[[:space:]])overlayroot=[^[:space:]]*[[:space:]]?/\1/g' \
          -e 's/(^|[[:space:]])rw([[:space:]]|$)/\1/g' \
          -e "s|^|rw |" \
          "${CMDLINE}"

echo "$0: overlay filesystem disabled, reboot to apply"
