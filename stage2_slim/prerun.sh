#!/bin/bash -e

if [ ! -d "${ROOTFS_DIR}" ]; then
	copy_previous
fi

source "${SCRIPT_DIR}/patch_packages"

# remove useless packages
while read -r package_name; do
  remove_package 01-sys-tweaks/00-packages "$package_name"
  remove_package 01-sys-tweaks/00-packages-nr "$package_name"
done < packages-prepurge

echo "============= 01-sys-tweaks/00-packages"
cat 01-sys-tweaks/00-packages
echo "============= 01-sys-tweaks/00-packages-nr"
cat 01-sys-tweaks/00-packages-nr
