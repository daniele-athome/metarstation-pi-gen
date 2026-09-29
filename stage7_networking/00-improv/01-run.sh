#!/bin/bash -e

# Install the improv-wifi service for Wi-Fi provisioning

# TODO build bestool (warning: cargo requires Docker to cross-compile)

install -m 755 "files/bestool" "${ROOTFS_DIR}/usr/local/bin/bestool"
install -m 644 "files/improv-wifi.service" "${ROOTFS_DIR}/etc/systemd/system/improv-wifi.service"

on_chroot << EOF
systemctl enable improv-wifi.service
EOF

install -v -m 644 files/nm-default.conf "${ROOTFS_DIR}/etc/NetworkManager/conf.d/99-wifi-default.conf"
install -v -m 644 files/nm-config-path.conf "${ROOTFS_DIR}/etc/NetworkManager/conf.d/99-config-path.conf"
install -v -m 644 files/tmpfiles.data-networkmanager.conf "${ROOTFS_DIR}/etc/tmpfiles.d/data-networkmanager.conf"
