#!/bin/bash -e

# Install RAUC and describe the A/B layout to it. The slot devices are left as
# placeholders: export-image/04-set-partuuid fills them in from the disk
# signature of the finished image, which is the only place that knows it.

install -d -m 0755 "${ROOTFS_DIR}/etc/rauc"

if [[ -n "${RAUC_KEYRING_FILE}" ]]; then
	install -m 0644 "${RAUC_KEYRING_FILE}" "${ROOTFS_DIR}/etc/rauc/keyring.pem"
else
	log "RAUC_KEYRING_FILE unset: no keyring, bundles cannot be verified yet"
fi

if [[ "${DISK_ID:-}" == "random" ]]; then
	log "WARNING: DISK_ID=random, so a slot image is only valid on systems flashed from this build"
fi

{
	cat << EOF
[system]
compatible=${RAUC_COMPATIBLE}
bootloader=custom
data-directory=/data/rauc
bundle-formats=verity
activate-installed=false

[handlers]
bootloader-custom-backend=/usr/lib/rauc/os-prefix-backend
EOF

	if [[ -n "${RAUC_KEYRING_FILE}" ]]; then
		cat << EOF

[keyring]
path=/etc/rauc/keyring.pem
EOF
	fi

	cat << EOF

[slot.rootfs.0]
device=SLOTADEV
type=ext4
bootname=slot-a

[slot.rootfs.1]
device=SLOTBDEV
type=ext4
bootname=slot-b
EOF
} > "${ROOTFS_DIR}/etc/rauc/system.conf"

install -d -m 0755 "${ROOTFS_DIR}/usr/lib/rauc"
install -m 0755 files/os-prefix-backend "${ROOTFS_DIR}/usr/lib/rauc/os-prefix-backend"

BOOTNAME="${ROOT_SLOT_PREFIX%/}"

# must be one of the bootnames above, or RAUC finds no slot for the booted system
case "${BOOTNAME}" in
	slot-a | slot-b) ;;
	*) echo "ERROR: ROOT_SLOT_PREFIX=${ROOT_SLOT_PREFIX:-} is not a slot bootname" >&2; exit 1 ;;
esac

# RAUC matches root= with a regex that hits inside overlayroot= too: rauc.slot=
# is checked first and is the only reliable way to name the booted slot
# TODO starting ruac 1.15, the backend is queried if "ruac.slot" is not found in cmdline
sed -i -E -e 's/(^|[[:space:]])rauc\.slot=[^[:space:]]*[[:space:]]?/\1/g' \
          -e "s|^|rauc.slot=${BOOTNAME} |" \
          "${ROOTFS_DIR}/boot/firmware/cmdline.txt"

# persistent status directory for RAUC
install -m 0644 files/tmpfiles.data-rauc.conf "${ROOTFS_DIR}/etc/tmpfiles.d/data-rauc.conf"
