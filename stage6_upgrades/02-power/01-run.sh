#!/bin/bash -e

# Install PiSugar services

curl -s -L -o "${ROOTFS_DIR}/tmp/pisugar-poweroff.deb" \
  "https://github.com/PiSugar/pisugar-power-manager-rs/releases/download/v2.3.5/pisugar-poweroff_2.3.5-1_armhf.deb"
curl -s -L -o "${ROOTFS_DIR}/tmp/pisugar-server.deb" \
  "https://github.com/PiSugar/pisugar-power-manager-rs/releases/download/v2.3.5/pisugar-server_2.3.5-1_armhf.deb"

on_chroot << EOF
debconf-set-selections << EOF2
pisugar-server pisugar-server/model select PiSugar 3
pisugar-server pisugar-server/auth-username string metar
pisugar-server pisugar-server/auth-password password metar
pisugar-poweroff pisugar-poweroff/model select PiSugar 3
EOF2
DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/pisugar-poweroff.deb /tmp/pisugar-server.deb
EOF

install -d -m 0755 "${ROOTFS_DIR}/etc/pisugar-server"
install -m 0644 files/pisugar.config.json "${ROOTFS_DIR}/etc/pisugar-server/config.json"

rm -f "${ROOTFS_DIR}/tmp/pisugar-poweroff.deb" "${ROOTFS_DIR}/tmp/pisugar-server.deb"
