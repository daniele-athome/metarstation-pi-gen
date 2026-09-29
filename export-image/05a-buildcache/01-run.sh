#!/bin/bash -e

log "building pip cache"

CACHE_ROOT="${ROOTFS_DIR}/root/.cache"

if [ ! -d "${CACHE_ROOT}/pip/wheels" ]; then
  log "no pip wheel cache to save"
  # cleanup
  rm -rf "${CACHE_ROOT}/pip"
  exit 0
fi

CACHE_FILE="${STAGE_WORK_DIR}/${IMG_FILENAME}${IMG_SUFFIX}.pipcache.tar.xz"
CACHE_OUTPUT="${CACHE_OUTPUT:-}"

# copy the cache where requested (e.g., for CI use)
if [[ -n "${CACHE_OUTPUT}" ]]; then
  mkdir -p "${CACHE_OUTPUT}"
  rm -fr "${CACHE_OUTPUT}/pip-wheels"
  cp -r "${CACHE_ROOT}/pip/wheels" "${CACHE_OUTPUT}/pip-wheels"
fi

tar -C "${CACHE_ROOT}/pip/wheels" -cJf "${CACHE_FILE}" .

# cleanup
rm -rf "${CACHE_ROOT}/pip"
