#!/bin/bash -e
# Stub out update-initramfs for the whole build: every kernel package hook
# would otherwise regenerate it, ~65-90s per run under qemu. The real binary
# is restored in export-image/05a-restore-initramfs, so the single generation
# done by export-image/05-finalise produces the final initramfs.
on_chroot << EOF
dpkg-divert --local --rename --add /usr/sbin/update-initramfs
ln -sf /bin/true /usr/sbin/update-initramfs
EOF
