#!/bin/bash -e

# Raspberry Pi OS grows the root filesystem to the end of the card on first boot, eating everything we have created.
# So we need to disable that process.

# Idempotently remove the "resize" instruction from the kernel command line
sed -i -E 's/(^|[[:space:]])resize([[:space:]]|$)/\1/g' "${ROOTFS_DIR}/boot/firmware/cmdline.txt"

on_chroot << EOF
systemctl mask rpi-resize
EOF
