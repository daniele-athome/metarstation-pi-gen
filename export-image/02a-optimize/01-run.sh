#!/bin/bash -e

PACKAGES="$(sed -f "${SCRIPT_DIR}/remove-comments.sed" < "files/packages-purge")"
if [ -n "$PACKAGES" ]; then
    on_chroot << EOF
apt-get purge -y $PACKAGES
apt-get autopurge -y
EOF
fi
