#!/bin/bash
# Grow the data partition (and its filesystem) to the end of the storage device.

set -e

MOUNTPOINT="${1:-/data}"

if ! DEV="$(findmnt -no SOURCE "${MOUNTPOINT}")"; then
	echo "expand-data-partition: ${MOUNTPOINT} is not mounted, nothing to do" >&2
	exit 0
fi

SYSFS="/sys/class/block/$(basename "${DEV}")"

if [ ! -r "${SYSFS}/partition" ]; then
	echo "expand-data-partition: ${DEV} is not a partition, refusing to grow it" >&2
	exit 1
fi

PARTNUM="$(cat "${SYSFS}/partition")"
DISK="/dev/$(basename "$(readlink -f "${SYSFS}/..")")"

echo "expand-data-partition: growing ${DISK} partition ${PARTNUM} (${MOUNTPOINT})"

# exit status 2 means "nothing to do": the partition already fills the device
growpart "${DISK}" "${PARTNUM}" || [ $? -eq 2 ]

# grow the filesystem into whatever space the partition gained
resize2fs "${DEV}"
