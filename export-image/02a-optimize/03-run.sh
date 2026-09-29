#!/bin/bash -e

CONFIG="${ROOTFS_DIR}/boot/firmware/config.txt"

ARM_FREQ_VALUE=900

if grep -qE '^arm_freq=' "${CONFIG}"; then
  # if we find an existing property, just overwrite the value
	sed -i -E "s|^arm_freq=.*|arm_freq=${ARM_FREQ_VALUE}|" "${CONFIG}"
else
  # otherwise add our own nice comment :)
	cat >>"${CONFIG}" << EOF
# Safe CPU frequency
arm_freq=${ARM_FREQ_VALUE}
EOF
fi
