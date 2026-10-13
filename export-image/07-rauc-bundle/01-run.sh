#!/bin/bash -e

# Wrap the root slot image into a signed RAUC bundle. Skipped unless a signing
# certificate and key are given.

if [ -z "${RAUC_CERT_FILE}" ] || [ -z "${RAUC_KEY_FILE}" ]; then
	log "RAUC_CERT_FILE/RAUC_KEY_FILE unset: no update bundle built"
	exit 0
fi

for KEYFILE in "${RAUC_CERT_FILE}" "${RAUC_KEY_FILE}"; do
	if [ ! -r "${KEYFILE}" ]; then
		echo "ERROR: cannot read ${KEYFILE}" >&2
		exit 1
	fi
done

# the bundle is carved out of what 06-rootfs-slot leaves behind
if [ "${DEPLOY_ROOTFS_SLOT}" != "1" ]; then
	echo "ERROR: the bundle needs the root slot image, so DEPLOY_ROOTFS_SLOT=1 is required" >&2
	exit 1
fi

SLOT_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.rootfs.img"

if [ ! -f "${SLOT_FILE}" ]; then
	echo "ERROR: ${SLOT_FILE} does not exist" >&2
	exit 1
fi

BUNDLE_DIR="${STAGE_WORK_DIR}/bundle"
BUNDLE="${DEPLOY_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.raucb"

rm -rf "${BUNDLE_DIR}"
rm -f "${BUNDLE}"
install -d -m 0755 "${BUNDLE_DIR}"

# a hard link: mksquashfs only reads it, so copying the slot again buys nothing
ln "${SLOT_FILE}" "${BUNDLE_DIR}/rootfs.ext4"

# the date alone is not a version: two builds a day would be indistinguishable
cat > "${BUNDLE_DIR}/manifest.raucm" << EOF
[update]
compatible=${RAUC_COMPATIBLE}
version=${IMG_DATE}${GIT_HASH:+-${GIT_HASH:0:7}}

[bundle]
format=verity

[image.rootfs]
filename=rootfs.ext4
adaptive=block-hash-index
EOF

mkdir -p "${DEPLOY_DIR}"

RAUC_ARGS=(--cert="${RAUC_CERT_FILE}" --key="${RAUC_KEY_FILE}")

if [ -n "${RAUC_KEYRING_FILE}" ]; then
	RAUC_ARGS+=(--keyring="${RAUC_KEYRING_FILE}")
else
	log "RAUC_KEYRING_FILE unset: the bundle signature is not checked against it"
fi

# TODO test optimal block size on production
rauc bundle \
	"${RAUC_ARGS[@]}" \
	--mksquashfs-args="-comp zstd -Xcompression-level 19 -b 64k" \
	"${BUNDLE_DIR}" "${BUNDLE}"

rm -rf "${BUNDLE_DIR}"

log "RAUC bundle: $(du -h "${BUNDLE}" | cut -f1) $(basename "${BUNDLE}")"
