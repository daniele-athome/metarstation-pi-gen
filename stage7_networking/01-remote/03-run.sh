#!/bin/bash -e

# install IP accounting for all services

mkdir -p "${ROOTFS_DIR}/etc/systemd/system.conf.d"

cat >"${ROOTFS_DIR}/etc/systemd/system.conf.d/ip-accounting.conf" << EOF
[Manager]
DefaultIPAccounting=yes
EOF
