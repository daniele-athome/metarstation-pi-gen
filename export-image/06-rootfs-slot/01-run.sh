#!/bin/bash -e
# Carve the root slot out of the finished image, so that it can be written to
# either root slot of a deployed card without reflashing the whole thing.

if [ "${DEPLOY_ROOTFS_SLOT}" != "1" ]; then
	exit 0
fi

IMG_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.img"
SLOT_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.rootfs.img"
SLOT_BMAP="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.rootfs.bmap"

# partition 2 is the first root slot: read its geometry instead of recomputing it
SLOT_START=""
SLOT_SIZE=""
eval "$(parted -m -s "${IMG_FILE}" unit B print |
	awk -F: '$1 == 2 { gsub(/B/, ""); print "SLOT_START=" $2 " SLOT_SIZE=" $4 }')"

if [ -z "${SLOT_START}" ] || [ -z "${SLOT_SIZE}" ]; then
	echo "ERROR: cannot read the root slot geometry from ${IMG_FILE}" >&2
	exit 1
fi

rm -f "${SLOT_FILE}"

# conv=sparse keeps the holes that the fstrim in 05-finalise left behind
dd if="${IMG_FILE}" of="${SLOT_FILE}" bs=4M \
	iflag=skip_bytes,count_bytes skip="${SLOT_START}" count="${SLOT_SIZE}" \
	conv=sparse status=none

# the bmap carries per-range checksums: bmaptool skips the holes and verifies
if hash bmaptool 2>/dev/null; then
	bmaptool create \
		-o "${SLOT_BMAP}" \
		"${SLOT_FILE}"
fi

mkdir -p "${DEPLOY_DIR}"

case "${DEPLOY_COMPRESSION}" in
zip)
	pushd "${STAGE_WORK_DIR}" > /dev/null
	zip -"${COMPRESSION_LEVEL}" \
	"${DEPLOY_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.rootfs.zip" "$(basename "${SLOT_FILE}")"
	popd > /dev/null
	;;
gz)
	pigz --force -"${COMPRESSION_LEVEL}" "$SLOT_FILE" --stdout > \
	"${DEPLOY_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.rootfs.img.gz"
	;;
xz)
	xz --compress --force --threads 0 --memlimit-compress=50% -"${COMPRESSION_LEVEL}" \
	--stdout "$SLOT_FILE" > "${DEPLOY_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.rootfs.img.xz"
	;;
none | *)
	cp "$SLOT_FILE" "$DEPLOY_DIR/"
;;
esac

if [ -f "${SLOT_BMAP}" ]; then
	cp "$SLOT_BMAP" "$DEPLOY_DIR/"
fi
