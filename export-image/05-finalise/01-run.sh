#!/bin/bash -e

IMG_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.img"
INFO_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.info"
SBOM_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.sbom"
BMAP_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.bmap"
CACHE_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.pipcache.tar.xz"

on_chroot <<- EOF
	update-initramfs -k all -c
	if hash hardlink 2>/dev/null; then
		hardlink -t /usr/share/doc
	fi
	if [ -f /usr/lib/systemd/system/apt-listchanges.service ]; then
		python3 -m apt_listchanges.populate_database --profile apt
		systemctl disable apt-listchanges.timer
	fi
	install -m 755 -o systemd-timesync -g systemd-timesync -d /var/lib/systemd/timesync
	install -m 644 -o systemd-timesync -g systemd-timesync /dev/null /var/lib/systemd/timesync/clock
EOF

if [ -f "${ROOTFS_DIR}/etc/initramfs-tools/update-initramfs.conf" ]; then
	sed -i 's/^update_initramfs=.*/update_initramfs=yes/' "${ROOTFS_DIR}/etc/initramfs-tools/update-initramfs.conf"
	sed -i 's/^MODULES=.*/MODULES=dep/' "${ROOTFS_DIR}/etc/initramfs-tools/initramfs.conf"
fi

if [ -d "${ROOTFS_DIR}/home/${FIRST_USER_NAME}/.config" ]; then
	chmod 700 "${ROOTFS_DIR}/home/${FIRST_USER_NAME}/.config"
fi

rm -f "${ROOTFS_DIR}/usr/bin/qemu-arm-static"

if [ "${USE_QEMU}" != "1" ]; then
	if [ -e "${ROOTFS_DIR}/etc/ld.so.preload.disabled" ]; then
		mv "${ROOTFS_DIR}/etc/ld.so.preload.disabled" "${ROOTFS_DIR}/etc/ld.so.preload"
	fi
fi

rm -f "${ROOTFS_DIR}/etc/network/interfaces.dpkg-old"

rm -f "${ROOTFS_DIR}/etc/apt/sources.list~"
rm -f "${ROOTFS_DIR}/etc/apt/trusted.gpg~"

rm -f "${ROOTFS_DIR}/etc/passwd-"
rm -f "${ROOTFS_DIR}/etc/group-"
rm -f "${ROOTFS_DIR}/etc/shadow-"
rm -f "${ROOTFS_DIR}/etc/gshadow-"
rm -f "${ROOTFS_DIR}/etc/subuid-"
rm -f "${ROOTFS_DIR}/etc/subgid-"

rm -f "${ROOTFS_DIR}"/var/cache/debconf/*-old
rm -f "${ROOTFS_DIR}"/var/lib/dpkg/*-old

rm -f "${ROOTFS_DIR}"/usr/share/icons/*/icon-theme.cache

rm -f "${ROOTFS_DIR}/var/lib/dbus/machine-id"

echo "uninitialized" > "${ROOTFS_DIR}/etc/machine-id"

ln -nsf /proc/mounts "${ROOTFS_DIR}/etc/mtab"

find "${ROOTFS_DIR}/var/log/" -type f -exec cp /dev/null {} \;

rm -f "${ROOTFS_DIR}/root/.vnc/private.key"
rm -f "${ROOTFS_DIR}/etc/vnc/updateid"

update_issue "$(basename "${EXPORT_DIR}")"
install -m 644 "${ROOTFS_DIR}/etc/rpi-issue" "${ROOTFS_DIR}/boot/firmware/issue.txt"
if ! [ -L "${ROOTFS_DIR}/boot/issue.txt" ]; then
	ln -s firmware/issue.txt "${ROOTFS_DIR}/boot/issue.txt"
fi

# os_prefix gives each slot its own kernel, initramfs, dtbs and cmdline.txt here.
BOOT_DIR="${ROOTFS_DIR}/boot/firmware"

if [ -z "${ROOT_SLOT_PREFIX:-}" ]; then
	echo "ERROR: ROOT_SLOT_PREFIX is not set" >&2
	exit 1
fi

SLOT_DIR="${BOOT_DIR}/${ROOT_SLOT_PREFIX%/}"

install -d -m 755 "${SLOT_DIR}"

shopt -s nullglob
MOVED=0
# move kernel, initramfs and blobs into the boot slot directory
for ENTRY in "${BOOT_DIR}"/kernel*.img "${BOOT_DIR}"/initramfs* \
	"${BOOT_DIR}"/*.dtb "${BOOT_DIR}"/overlays "${BOOT_DIR}"/cmdline.txt; do
	[ -e "${ENTRY}" ] || continue
	mv "${ENTRY}" "${SLOT_DIR}/"
	MOVED=$((MOVED + 1))
done
shopt -u nullglob

if [ "${MOVED}" = 0 ]; then
	echo "ERROR: no boot files to move into ${ROOT_SLOT_PREFIX}" >&2
	exit 1
fi

BOOTDATA="${ROOTFS_DIR}/usr/lib/bootdata"

install -d -m 755 "${BOOTDATA}"
sed -E -e 's/(^|[[:space:]])root=[^[:space:]]*/\1root=ROOTDEV/' \
	-e 's/(^|[[:space:]])rauc\.slot=[^[:space:]]*/\1rauc.slot=SLOTNAME/' \
	"${SLOT_DIR}/cmdline.txt" > "${BOOTDATA}/cmdline.txt"
chmod 644 "${BOOTDATA}/cmdline.txt"

CONFIG="${BOOT_DIR}/config.txt"

# ahead of every conditional filter, so that it applies to all models
if grep -qE '^[[:space:]]*os_prefix=' "${CONFIG}"; then
	sed -i -E "s|^[[:space:]]*os_prefix=.*|os_prefix=${ROOT_SLOT_PREFIX}|" "${CONFIG}"
else
	sed -i "1i # Active root slot: its kernel, initramfs, dtbs, overlays and cmdline.txt\\nos_prefix=${ROOT_SLOT_PREFIX}\\n" "${CONFIG}"
fi

echo "Boot payload moved into ${ROOT_SLOT_PREFIX} (${MOVED} entries)"

cp "$ROOTFS_DIR/etc/rpi-issue" "$INFO_FILE"

{
	if [ -f "$ROOTFS_DIR/usr/share/doc/raspberrypi-kernel/changelog.Debian.gz" ]; then
		firmware=$(zgrep "firmware as of" \
			"$ROOTFS_DIR/usr/share/doc/raspberrypi-kernel/changelog.Debian.gz" | \
			head -n1 | sed  -n 's|.* \([^ ]*\)$|\1|p')
		printf "\nFirmware: https://github.com/raspberrypi/firmware/tree/%s\n" "$firmware"

		kernel="$(curl -s -L "https://github.com/raspberrypi/firmware/raw/$firmware/extra/git_hash")"
		printf "Kernel: https://github.com/raspberrypi/linux/tree/%s\n" "$kernel"

		uname="$(curl -s -L "https://github.com/raspberrypi/firmware/raw/$firmware/extra/uname_string7")"
		printf "Uname string: %s\n" "$uname"
	fi

	printf "\nPackages:\n"
	dpkg -l --root "$ROOTFS_DIR"
} >> "$INFO_FILE"

if hash syft 2>/dev/null; then
	syft scan dir:"${ROOTFS_DIR}" \
		--base-path="${ROOTFS_DIR}" \
		--source-name="${IMG_NAME}${IMG_SUFFIX}" \
		--source-version="${IMG_DATE}" \
		-o spdx-json="${SBOM_FILE}"
fi

# Prefer fstrim (holes -> sparse bmap); fall back to zerofree if discard is unsupported.
if fstrim -v "${ROOTFS_DIR}"; then
	unmount "${ROOTFS_DIR}"
else
	ROOT_DEV="$(awk "\$2 == \"${ROOTFS_DIR}\" {print \$1}" /etc/mtab)"
	unmount "${ROOTFS_DIR}"
	zerofree "${ROOT_DEV}"
fi

unmount_image "${IMG_FILE}"

if hash bmaptool 2>/dev/null; then
	bmaptool create \
		-o "${BMAP_FILE}" \
		"${IMG_FILE}"
fi

mkdir -p "${DEPLOY_DIR}"

# delete any file with the same prefix
rm -f "${DEPLOY_DIR}/${IMG_FILENAME}${IMG_SUFFIX}."*

case "${DEPLOY_COMPRESSION}" in
zip)
	pushd "${STAGE_WORK_DIR}" > /dev/null
	zip -"${COMPRESSION_LEVEL}" \
	"${DEPLOY_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.zip" "$(basename "${IMG_FILE}")"
	popd > /dev/null
	;;
gz)
	pigz --force -"${COMPRESSION_LEVEL}" "$IMG_FILE" --stdout > \
	"${DEPLOY_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.img.gz"
	;;
xz)
	xz --compress --force --threads 0 --memlimit-compress=50% -"${COMPRESSION_LEVEL}" \
	--stdout "$IMG_FILE" > "${DEPLOY_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.img.xz"
	;;
none | *)
	cp "$IMG_FILE" "$DEPLOY_DIR/"
;;
esac

if [ -f "${SBOM_FILE}" ]; then
	xz -c "${SBOM_FILE}" > "$DEPLOY_DIR/$(basename "${SBOM_FILE}").xz"
fi
if [ -f "${BMAP_FILE}" ]; then
	cp "$BMAP_FILE" "$DEPLOY_DIR/"
fi
cp "$INFO_FILE" "$DEPLOY_DIR/"
[ -f "$CACHE_FILE" ] && cp "$CACHE_FILE" "$DEPLOY_DIR/"
