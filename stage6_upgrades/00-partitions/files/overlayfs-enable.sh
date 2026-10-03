#!/bin/sh
# Enable the overlay root filesystem, making the root partition not writable.
#
# A reboot is needed for the change to take effect.

set -e

BOOT_DIR="/boot/firmware"
CMDLINE="${BOOT_DIR}/cmdline.txt"

if [ ! -e /usr/share/initramfs-tools/scripts/init-bottom/overlayroot ]; then
	echo "overlayfs-enable: the overlayroot package is not installed" >&2
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

# drop any overlayroot= parameter already there, ours is the only supported one
sed -i -E -e 's/(^|[[:space:]])overlayroot=[^[:space:]]*[[:space:]]?/\1/g' \
          -e 's/(^|[[:space:]])rw([[:space:]]|$)/\1/g' \
          -e "s|^|overlayroot=tmpfs:recurse=0 |" \
          "${CMDLINE}"

echo "overlayfs-enable: overlay filesystem enabled, reboot to apply"
