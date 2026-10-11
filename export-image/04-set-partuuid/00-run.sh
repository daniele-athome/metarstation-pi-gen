#!/bin/bash -e

IMG_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.img"

IMGID="$(dd if="${IMG_FILE}" skip=440 bs=1 count=4 2>/dev/null | xxd -e | cut -f 2 -d' ')"

BOOT_PARTUUID="${IMGID}-01"
ROOT_A_PARTUUID="${IMGID}-02"
ROOT_B_PARTUUID="${IMGID}-03"
DATA_PARTUUID="${IMGID}-04"

sed -i "s/BOOTDEV/PARTUUID=${BOOT_PARTUUID}/" "${ROOTFS_DIR}/etc/fstab"
# no more ROOTDEV: the root device is handled in cmdline.txt now
sed -i "s/DATADEV/PARTUUID=${DATA_PARTUUID}/" "${ROOTFS_DIR}/etc/fstab"

sed -i "s/ROOTDEV/PARTUUID=${ROOT_A_PARTUUID}/" "${ROOTFS_DIR}/boot/firmware/cmdline.txt"

RAUC_SYSTEM_CONF="${ROOTFS_DIR}/etc/rauc/system.conf"
if [ -f "${RAUC_SYSTEM_CONF}" ]; then
	sed -i "s|SLOTADEV|/dev/disk/by-partuuid/${ROOT_A_PARTUUID}|" "${RAUC_SYSTEM_CONF}"
	sed -i "s|SLOTBDEV|/dev/disk/by-partuuid/${ROOT_B_PARTUUID}|" "${RAUC_SYSTEM_CONF}"
fi
