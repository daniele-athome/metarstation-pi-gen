#!/bin/sh
# shellcheck shell=dash
# Put the saved machine ID back in place before init runs.

PREREQ="overlayroot"

prereqs() {
	echo "${PREREQ}"
}

case "$1" in
	prereqs)
		prereqs
		exit 0
		;;
esac

. /scripts/functions

DEFAULTS="${rootmnt}/etc/default/machine-id"
MACHINE_ID="${rootmnt}/etc/machine-id"
FSTAB="${rootmnt}/etc/fstab"
MNT="/run/machine-id-restore"

# The data partition is whatever fstab mounts on ${DATA_MOUNT}: overlayroot only
# rewrites the entry for /, so this is still the line the image was built with
# (a PARTUUID= filled in at image export time).
data_device() {
	local spec mp rest

	while read -r spec mp rest; do
		case "${spec}" in
			"" | \#*) continue ;;
		esac
		[ "${mp}" = "${DATA_MOUNT}" ] || continue
		resolve_device "${spec}"
		return
	done < "${FSTAB}"

	return 1
}

# The options of the last /proc/mounts entry for a mount point, empty if none.
mount_options() {
	local dev mp fstype opts rest found=""

	while read -r dev mp fstype opts rest; do
		[ "${mp}" = "$1" ] && found="${opts}"
	done < /proc/mounts

	printf '%s' "${found}"
}

# A machine ID is 32 lowercase hexadecimal digits, anything else is not one.
is_machine_id() {
	case "$1" in
		*[!0-9a-f]*) return 1 ;;
	esac

	[ "${#1}" -eq 32 ]
}

if [ ! -r "${DEFAULTS}" ] || [ ! -r "${FSTAB}" ]; then
	log_warning_msg "machine-id: no ${DEFAULTS} or ${FSTAB} on the root filesystem"
	exit 0
fi

. "${DEFAULTS}"

DEV="$(data_device)" || DEV=""
if [ -z "${DEV}" ]; then
	log_warning_msg "machine-id: no usable ${DATA_MOUNT} entry in fstab"
	exit 0
fi

mkdir -p "${MNT}"
if ! mount -t ext4 -o ro "${DEV}" "${MNT}"; then
	log_warning_msg "machine-id: cannot mount ${DEV} read-only"
	rmdir "${MNT}" 2>/dev/null || :
	exit 0
fi

ID=""
if [ -r "${MNT}/${STATE_REL}" ]; then
	read -r ID < "${MNT}/${STATE_REL}" || ID=""
fi

umount "${MNT}"
rmdir "${MNT}" 2>/dev/null || :

if ! is_machine_id "${ID}"; then
	log_success_msg "machine-id: nothing saved on ${DATA_MOUNT} yet, this is a first boot"
	exit 0
fi

# the overlay is mounted read-write unless the kernel command line says 'ro',
# but make the write work either way
REMOUNTED=no
case ",$(mount_options "${rootmnt}")," in
	*,ro,*)
		if ! mount -o remount,rw "${rootmnt}"; then
			log_warning_msg "machine-id: ${rootmnt} is read-only, cannot restore the machine ID"
			exit 0
		fi
		REMOUNTED=yes
		;;
esac

if printf '%s\n' "${ID}" > "${MACHINE_ID}"; then
	chmod 0444 "${MACHINE_ID}"
	log_success_msg "machine-id: restored ${ID}"
else
	log_warning_msg "machine-id: cannot write ${MACHINE_ID}"
fi

[ "${REMOUNTED}" = "no" ] || mount -o remount,ro "${rootmnt}"

exit 0
