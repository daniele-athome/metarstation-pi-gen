#!/bin/bash -e

# Build and install the PiSugar battery kernel module.
# The module will provide support for the power_supply class in sysfs.

# shellcheck source=pisugar-version
source ./pisugar-version

SRC_DIR="/usr/src/pisugar-power-manager-rs-${PISUGAR_VERSION}"
MODULE_DIR="${SRC_DIR}/pisugar-module/pisugar-battery"

rm -fr "${ROOTFS_DIR}/usr/src/pisugar-power-manager-rs-"*

curl -s -L -o "${ROOTFS_DIR}/tmp/pisugar-src.tar.gz" \
  "https://github.com/PiSugar/pisugar-power-manager-rs/archive/refs/tags/v${PISUGAR_VERSION}.tar.gz"
tar -C "${ROOTFS_DIR}/usr/src" -xaf "${ROOTFS_DIR}/tmp/pisugar-src.tar.gz"

shopt -s nullglob
BUILD_DIRS=("${ROOTFS_DIR}"/lib/modules/*/build)
shopt -u nullglob

if [ ${#BUILD_DIRS[@]} -eq 0 ]; then
  echo "No kernel header tree found under ${ROOTFS_DIR}/lib/modules" >&2
  exit 1
fi

for MODULES_DIR in "${ROOTFS_DIR}"/lib/modules/*/; do
  [ -d "${MODULES_DIR}build" ] || echo "WARNING: no headers for $(basename "${MODULES_DIR}"), skipped" >&2
done

# build the module for all installed kernels
for BUILD_DIR in "${BUILD_DIRS[@]}"; do
  KERNEL_RELEASE="$(cat "${BUILD_DIR}/include/config/kernel.release")"
  echo "Building pisugar_battery for ${KERNEL_RELEASE}"
  on_chroot << EOF
make -C "${MODULE_DIR}" KERNEL_DIR="/lib/modules/${KERNEL_RELEASE}/build"
install -D -m 0644 "${MODULE_DIR}/pisugar_battery.ko" \
  "/lib/modules/${KERNEL_RELEASE}/kernel/drivers/power/supply/pisugar_battery.ko"
make -C "${MODULE_DIR}" clean KERNEL_DIR="/lib/modules/${KERNEL_RELEASE}/build"
depmod -a "${KERNEL_RELEASE}"
EOF
done

# skip loading of the module at boot: pisugar-detect.service will load it if necessary
echo "options pisugar_battery i2c_bus=1 pisugar3_addr=0x57" \
  > "${ROOTFS_DIR}/etc/modprobe.d/pisugar-battery.conf"

# cleanup
rm -fr "${ROOTFS_DIR}${SRC_DIR}"
rm -f "${ROOTFS_DIR}/tmp/pisugar-src.tar.gz"
