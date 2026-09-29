#!/bin/bash -e

# The machine ID identifies the station, but the root filesystem is an overlay on
# tmpfs: whatever systemd writes to /etc is gone at the next boot. Keep it on the
# data partition and restore it from the initramfs, early enough for systemd's
# own first boot detection to work.

# our initramfs script runs after the one that sets the overlay up
if [ ! -e "${ROOTFS_DIR}/usr/share/initramfs-tools/scripts/init-bottom/overlayroot" ]; then
	echo "The overlayroot initramfs script is missing: the machine ID cannot be restored." >&2
	exit 1
fi

install -m 644 files/machine-id-defaults "${ROOTFS_DIR}/etc/default/machine-id"

install -d "${ROOTFS_DIR}/etc/initramfs-tools/scripts/init-bottom"
install -m 755 files/initramfs-machine-id.sh \
	"${ROOTFS_DIR}/etc/initramfs-tools/scripts/init-bottom/machine-id"

install -m 755 files/save-machine-id.sh "${ROOTFS_DIR}/usr/local/sbin/save-machine-id"
install -m 644 files/save-machine-id.service "${ROOTFS_DIR}/etc/systemd/system/save-machine-id.service"

on_chroot << EOF
systemctl enable save-machine-id.service
EOF
