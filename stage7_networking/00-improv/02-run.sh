#!/bin/bash -e

# Install Wi-Fi watchdog service

install -m 755 files/wifi-watchdog.sh "${ROOTFS_DIR}/usr/local/sbin/wifi-watchdog"
install -m 644 files/wifi-watchdog.service "${ROOTFS_DIR}/etc/systemd/system/wifi-watchdog.service"

cat >"${ROOTFS_DIR}/etc/default/wifi-watchdog" << EOF
INTERFACE_NAME=wlan0
EOF

on_chroot << EOF
systemctl enable wifi-watchdog.service
EOF
