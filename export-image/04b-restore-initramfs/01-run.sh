#!/bin/bash -e
# Restore the real update-initramfs so that 05-finalise can build the
# final initramfs (and trigger the raspi-firmware post-update hook that
# copies it into /boot/firmware).
on_chroot << EOF
rm -f /usr/sbin/update-initramfs
dpkg-divert --local --rename --remove /usr/sbin/update-initramfs
EOF
