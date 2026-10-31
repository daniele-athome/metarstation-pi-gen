#!/bin/bash -e

# remove useless message from motd
echo "path-exclude=/etc/update-motd.d/97-overlayroot" >"${ROOTFS_DIR}/etc/dpkg/dpkg.cfg.d/excl-overlaymotd"
