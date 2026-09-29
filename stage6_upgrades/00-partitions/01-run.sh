#!/bin/bash -e

install -d -m 755 "${ROOTFS_DIR}/data"

FSTAB="${ROOTFS_DIR}/etc/fstab"
# be sure to mount the data partition *before* tmpfiles are created
DATA_FSTAB_OPTS="defaults,noatime,nofail,x-systemd.growfs,x-systemd.before=systemd-tmpfiles-setup.service"
DATA_FSTAB_LINE="DATADEV  /data           ext4    ${DATA_FSTAB_OPTS}  0       2"

if grep -qE '^DATADEV[[:space:]]' "${FSTAB}"; then
  # replace the existing line with the device placeholder
	sed -i -E "s|^DATADEV[[:space:]].*|${DATA_FSTAB_LINE}|" "${FSTAB}"
else
  # add a new line
	printf '%s\n' "${DATA_FSTAB_LINE}" >>"${FSTAB}"
fi

# Configure the boot partition as read only
sed -i -E "s|^([^#[:space:]]+[[:space:]]+/boot/firmware[[:space:]]+vfat[[:space:]]+)[^[:space:]]+|\1defaults,ro|" "${FSTAB}"

install -m 755 files/expand-data-partition.sh "${ROOTFS_DIR}/usr/local/sbin/expand-data-partition"
install -m 755 files/overlayfs-enable.sh "${ROOTFS_DIR}/usr/local/sbin/overlayfs-enable"
install -m 755 files/overlayfs-disable.sh "${ROOTFS_DIR}/usr/local/sbin/overlayfs-disable"
install -m 644 files/tmpfiles.data.conf "${ROOTFS_DIR}/etc/tmpfiles.d/data.conf"

# Enable overlayroot immediately
sed -i -E -e 's/(^|[[:space:]])overlayroot=[^[:space:]]*[[:space:]]?/\1/g' \
          -e "s|^|overlayroot=tmpfs:recurse=0 |" \
          "${ROOTFS_DIR}/boot/firmware/cmdline.txt"

# grow the data partition at first boot
install -m 644 files/expand-data-partition.service "${ROOTFS_DIR}/etc/systemd/system/expand-data-partition.service"

on_chroot << EOF
systemctl enable expand-data-partition.service
EOF
