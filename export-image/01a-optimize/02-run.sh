#!/bin/bash -e

# mpris-proxy is part of bluez
ln -sf /dev/null "${ROOTFS_DIR}/etc/systemd/user/mpris-proxy.service"

# disable some other useless services
on_chroot << EOF
systemctl disable \
  dpkg-db-backup.timer \
  apt-daily.timer \
  apt-daily-upgrade.timer \
  sshswitch.service
systemctl mask \
  dpkg-db-backup.timer \
  apt-daily.timer \
  apt-daily-upgrade.timer \
  sshswitch.service
EOF
