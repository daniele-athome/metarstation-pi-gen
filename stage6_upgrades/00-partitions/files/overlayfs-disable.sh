#!/bin/sh
# Disable the overlay root filesystem, making the root partition writable again.
#
# A reboot is needed for the change to take effect.

set -e

BOOT_DIR="/boot/firmware"
CMDLINE="${BOOT_DIR}/cmdline.txt"

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

echo "overlayfs-disable: overlay filesystem disabled, reboot to apply"
