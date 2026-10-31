#!/bin/bash -e

# clear the default motd and install our issue instead
install -m 0644 /dev/null "${ROOTFS_DIR}/etc/motd"
install -m 0755 files/motd.sh "${ROOTFS_DIR}/etc/update-motd.d/20-issue"
