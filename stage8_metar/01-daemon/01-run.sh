#!/bin/bash -e

VENV_PATH="/opt/metarstation-daemon"

[ -d "${ROOTFS_DIR}/usr/src/metarstation-daemon" ] || \
  git clone https://github.com/daniele-athome/metarstation-daemon.git \
  "${ROOTFS_DIR}/usr/src/metarstation-daemon"

# install our pip cache (avoiding 6+ hours of 'pip install')
CACHE_OUTPUT="${CACHE_OUTPUT:-}"
if [[ -n "${CACHE_OUTPUT}" && -d "${CACHE_OUTPUT}/pip-wheels" ]]; then
  # copy the cache where requested (e.g., for CI use)
  log "Reusing pip cache"
  mkdir -p "${ROOTFS_DIR}/root/.cache/pip/wheels"
  cp -r "${CACHE_OUTPUT}/pip-wheels/." "${ROOTFS_DIR}/root/.cache/pip/wheels/"
else
   log "no pip cache found, building normally"
fi

# on the Rpi Zero, some dependencies don't work (Python crashes with "illegal instruction");
# so we do a first install pass with everything binary from pip
on_chroot << EOF
python3 -m venv --system-site-packages "${VENV_PATH}"
"${VENV_PATH}/bin/pip" install /usr/src/metarstation-daemon
EOF

# now we need to check if there are broken packages: copy over the utility script and execute it;
# the script will produce a report with the packages that we need to rebuild from sources.
install -m 0755 files/check-venv-arch.py "${ROOTFS_DIR}/usr/src/metarstation-daemon/check-venv-arch"
on_chroot << EOF
/usr/src/metarstation-daemon/check-venv-arch "${VENV_PATH}" >/usr/src/metarstation-daemon/rebuild.txt
"${VENV_PATH}/bin/pip" install --force-reinstall --no-deps \
  --no-binary "\$(cut -d= -f1 /usr/src/metarstation-daemon/rebuild.txt | paste -sd,)" \
  -r /usr/src/metarstation-daemon/rebuild.txt
EOF

# cleanup
rm -fr "${ROOTFS_DIR}/usr/src/metarstation-daemon"

export METARSTATION_USER="$FIRST_USER_NAME"
export METARSTATION_DASHBOARD_TMPDIR="/run/metarstation"
export METARSTATION_DASHBOARD_PUBROOT="$METARSTATION_DASHBOARD_TMPDIR/pubroot"

envsubst < files/weather-daemon.service.tpl > "${ROOTFS_DIR}/etc/systemd/system/weather-daemon.service"
envsubst < files/httpd.service.tpl > "${ROOTFS_DIR}/etc/systemd/system/httpd.service"
envsubst < files/tmpfiles.conf.tpl > "${ROOTFS_DIR}/etc/tmpfiles.d/metarstation.conf"

on_chroot << EOF
systemctl enable weather-daemon.service httpd.service
EOF
