#!/usr/bin/env bash
# One-time preparation for virt.sh: install a Debian ARMv7 multiplatform kernel
# into a Raspberry Pi OS image and extract vmlinuz + initrd for QEMU -M virt.
#
# Raspberry Pi OS only ships bcm2835/bcm2711 kernels, which cannot boot on the
# virt machine, so the kernel comes from Debian. Only the kernel .deb is taken
# from Debian: the Raspbian archive is an ARMv6 rebuild and must not be mixed
# with Debian's armhf archive at the apt level.
#
# The installed kernel and its modules are ARMv7 binaries. They run on the
# emulated cortex-a7 but NOT on a real Pi Zero W, so do this on a copy of the
# image, never on the one you flash.
#
# Requires: qemu-user-static, systemd-container, curl, losetup (root).
set -euo pipefail

IMAGE="${1:?usage: $0 <image.img> [outdir]}"
OUTDIR="${2:-virt}"
SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-https://deb.debian.org/debian}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
mkdir -p "$OUTDIR"

# --- find the current linux-image-<version>-armmp (skip -rt, -lpae, -dbg) ----
echo ">> resolving kernel package from Debian $SUITE" >&2
# In awk, ^ and $ anchor to the whole record, and with RS='' the record is the
# entire stanza -- so match on the field instead of on the record text.
filename=$(curl -fsSL "$MIRROR/dists/$SUITE/main/binary-armhf/Packages.gz" \
    | zcat \
    | awk -v RS='' '$1 == "Package:" && $2 ~ /^linux-image-[0-9][^ ]*-armmp$/ &&
                    $2 !~ /-rt-/ {
          for (i = 1; i <= NF; i++) if ($i == "Filename:") print $(i+1) }' \
    | sort -V | tail -1)
[ -n "$filename" ] || { echo "no armmp kernel found" >&2; exit 1; }

deb="$OUTDIR/$(basename "$filename")"
[ -e "$deb" ] || curl -fL# -o "$deb" "$MIRROR/$filename"
echo ">> using $(basename "$deb")" >&2

# --- install it into the image rootfs ---------------------------------------
loop=$(losetup -Pf --show "$IMAGE")
mnt=$(mktemp -d)
cleanup() { umount -R "$mnt" 2>/dev/null || true; rmdir "$mnt"; losetup -d "$loop"; }
trap cleanup EXIT

mount "${loop}p2" "$mnt"

# Do NOT copy the .deb into the rootfs /tmp: systemd-nspawn mounts a fresh
# tmpfs over /tmp, so the container would see an empty directory.
nspawn=(systemd-nspawn -q -D "$mnt" --bind-ro="$(realpath "$deb")":/kernel.deb)
[ -e /usr/bin/qemu-arm-static ] && nspawn+=(--bind-ro=/usr/bin/qemu-arm-static)

"${nspawn[@]}" /bin/sh -eux -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends initramfs-tools linux-base kmod
    # MODULES=most keeps virtio_blk, but NOT the virtio transports: virtio_mmio
    # and virtio_pci live in kernel/drivers/virtio/ and are left out, so the
    # disk never appears. List them explicitly.
    sed -i "s/^MODULES=.*/MODULES=most/" /etc/initramfs-tools/initramfs.conf
    truncate -s0 /etc/initramfs-tools/modules
    for m in virtio virtio_ring virtio_mmio virtio_pci virtio_blk virtio_net; do
        grep -qx "$m" /etc/initramfs-tools/modules || echo "$m" >> /etc/initramfs-tools/modules
    done
    dpkg -i /kernel.deb
    update-initramfs -u -k all
'

cp "$mnt"/boot/vmlinuz-*-armmp "$OUTDIR/vmlinuz"
cp "$mnt"/boot/initrd.img-*-armmp "$OUTDIR/initrd.img"
echo ">> wrote $OUTDIR/vmlinuz and $OUTDIR/initrd.img" >&2
