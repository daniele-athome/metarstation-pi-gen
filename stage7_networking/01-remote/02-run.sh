#!/bin/bash -e

# Install the Cloudflare daemon for the SSH tunnel

curl -s -L -o "$STAGE_WORK_DIR/cloudflared" \
  "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"

install -m 755 "$STAGE_WORK_DIR/cloudflared" "${ROOTFS_DIR}/usr/local/bin/cloudflared"
install -m 0644 files/cloudflared.service "${ROOTFS_DIR}/etc/systemd/system/cloudflared.service"

on_chroot << EOF
systemctl enable cloudflared.service
EOF
