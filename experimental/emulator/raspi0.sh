#!/usr/bin/env bash
# Boot a Raspberry Pi Zero W image under QEMU (-M raspi0).
#
# Kernel and DTB must already be on the host: copy them out of the image's boot
# partition once, e.g.
#   mcopy -i pigen.img@@$((16384*512)) ::kernel.img ::bcm2708-rpi-zero-w.dtb boot/
#
# Serial mapping matches real hardware with Bluetooth enabled:
#   serial_hd(0) -> PL011  (ttyAMA0) -> TCP socket, for an HCI controller
#   serial_hd(1) -> AUX    (ttyS0)   -> console on stdio
#
# Quit with Ctrl-A X.
set -euo pipefail

IMAGE="${1:?usage: $0 <image.img>}"
OVERLAY="${OVERLAY:-raspi0.qcow2}"
KERNEL="${KERNEL:-boot/kernel.img}"
DTB="${DTB:-boot/bcm2708-rpi-zero.dtb}"
INITRD="${INITRD:-}"                       # optional, e.g. boot/initrd.img
ROOT="${ROOT:-/dev/mmcblk0p2}"
CMDLINE="${CMDLINE:-root=$ROOT rw rootfstype=ext4 rootwait arm_boost=1 panic=1 initcall_blacklist=bcm2835_pm_driver_init dwc_otg.nak_holdoff=0 dwc_otg.fiq_fsm_enable=0 dwc_otg.fiq_enable=0 fsck.repair=yes}"
BT_PORT="${BT_PORT:-9000}"                 # HCI link on ttyAMA0
SSH_PORT="${SSH_PORT:-2222}"
OFFLINE="${OFFLINE:-0}"                    # 1 = no outbound traffic, SSH only

# The SD model needs a power-of-two size, so the overlay is created larger than
# the base image. The base image itself is never written to.
if [ ! -e "$OVERLAY" ]; then
    size=$(stat -c %s "$IMAGE")
    target=1
    while [ "$target" -lt "$size" ]; do target=$((target * 2)); done
    qemu-img create -f qcow2 -b "$(realpath "$IMAGE")" -F raw "$OVERLAY" "$target" >/dev/null
    echo "created overlay $OVERLAY ($((target / 1024 / 1024)) MiB)" >&2
fi

netdev="user,id=n0,hostfwd=tcp::${SSH_PORT}-:22"
[ "$OFFLINE" = "1" ] && netdev="${netdev},restrict=on"

# -drive "file=${IMAGE},format=raw,index=0,media=disk"
# -drive "file=${OVERLAY},format=qcow2,if=sd"

# shellcheck disable=SC2054
args=(
    -M raspi0 -m 512 -cpu arm1176 -smp 1
    -d guest_errors
    -kernel "$KERNEL"
    -dtb "$DTB"
    -append "$CMDLINE"
    -drive "file=$IMAGE,format=raw,index=0,media=disk"
    -netdev "$netdev"
    -device usb-net,netdev=n0
    -chardev "socket,id=bt0,host=127.0.0.1,port=${BT_PORT},server=on,wait=off"
    -serial chardev:bt0
    -serial mon:stdio
    -k it-it
    -device usb-kbd
    -display gtk
    -no-reboot
)
[ -n "$INITRD" ] && args+=(-initrd "$INITRD")

echo "ssh: localhost:${SSH_PORT}   hci: tcp 127.0.0.1:${BT_PORT}" >&2
exec qemu-system-arm "${args[@]}"
