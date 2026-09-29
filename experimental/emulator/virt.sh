#!/usr/bin/env bash
# Boot the pi-gen rootfs under QEMU (-M virt) with a generic armhf kernel.
#
# Much faster than -M raspi0, at the cost of fidelity: generic kernel, virtio
# devices, /dev/vdaN instead of /dev/mmcblk0pN. Use it for application work;
# use raspi0 for anything that depends on the real kernel, boot chain or A/B.
#
# One-time preparation (installs a virt-capable kernel INTO the image, so the
# modules and the initrd match the rootfs):
#
#   sudo apt install qemu-user systemd-container
#   LOOP=$(sudo losetup -Pf --show pigen.img)
#   sudo mount "${LOOP}p2" /mnt && sudo mount "${LOOP}p1" /mnt/boot
#   sudo systemd-nspawn -D /mnt --bind-ro=/usr/bin/qemu-arm \
#       apt-get install -y linux-image-armmp
#   sudo cp /mnt/boot/vmlinuz-*-armmp /mnt/boot/initrd.img-*-armmp ./virt/
#   sudo umount /mnt/boot /mnt && sudo losetup -d "$LOOP"
#
# Serial mapping:
#   ttyAMA0 (PL011)     -> console on stdio
#   ttyS0   (pci-serial)-> TCP socket, for an HCI controller
#
# Quit with Ctrl-A X.
set -euo pipefail

IMAGE="${1:?usage: $0 <image.img>}"
OVERLAY="${OVERLAY:-virt.qcow2}"
KERNEL="${KERNEL:-virt/vmlinuz}"
INITRD="${INITRD:-virt/initrd.img}"
CPU="${CPU:-cortex-a7}"                    # armv7, runs armv6 userland fine
SMP="${SMP:-4}"
MEM="${MEM:-512}"                         # set 512 to match the real board
ROOT="${ROOT:-/dev/vda2}"
CMDLINE="${CMDLINE:-console=ttyAMA0 root=$ROOT rootfstype=ext4 rootwait systemd.default_device_timeout_sec=600}"
BT_PORT="${BT_PORT:-9000}"
SSH_PORT="${SSH_PORT:-2222}"
OFFLINE="${OFFLINE:-0}"

if [ ! -e "$OVERLAY" ]; then
    qemu-img create -f qcow2 -b "$(realpath "$IMAGE")" -F raw "$OVERLAY" >/dev/null
    [ -n "${DISK_SIZE:-}" ] && qemu-img resize "$OVERLAY" "$DISK_SIZE" >/dev/null
    echo "created overlay $OVERLAY" >&2
fi

netdev="user,id=n0,hostfwd=tcp::${SSH_PORT}-:22"
[ "$OFFLINE" = "1" ] && netdev="${netdev},restrict=on"

echo "ssh: localhost:${SSH_PORT}   hci: tcp 127.0.0.1:${BT_PORT}" >&2
exec qemu-system-arm \
    -M virt -cpu "$CPU" -smp "$SMP" -m "$MEM" \
    -accel tcg,thread=multi,tb-size=512 \
    -kernel "$KERNEL" -initrd "$INITRD" -append "$CMDLINE" \
    -drive "file=${OVERLAY},format=qcow2,if=none,id=d0" \
    -device virtio-blk-device,drive=d0 \
    -netdev "$netdev" -device virtio-net-device,netdev=n0 \
    -serial mon:stdio \
    -display none -no-reboot

# for emulated bluetooth adapter:
#    -chardev "socket,id=bt0,host=127.0.0.1,port=${BT_PORT},server=on,wait=off" \
#    -device pci-serial,chardev=bt0 \
