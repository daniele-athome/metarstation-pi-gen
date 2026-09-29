#!/bin/bash -e

# Configure SSH

if [[ -z "${PUBKEY_SSH_CA}" ]]; then
	echo "Must set 'PUBKEY_SSH_CA' to a valid SSH CA public key."
	exit 1
fi

cat >"${ROOTFS_DIR}/etc/ssh/sshd_config.d/auth.conf" << EOF
PubkeyAuthentication yes
PasswordAuthentication no
TrustedUserCAKeys /etc/ssh/ssh_ca.pub
EOF

# install the CA ssh public key
echo "${PUBKEY_SSH_CA}" >"${ROOTFS_DIR}"/etc/ssh/ssh_ca.pub
chmod 0600 "${ROOTFS_DIR}"/etc/ssh/ssh_ca.pub

# Host keys on the data partition. Generated on first boot.
SSH_HOST_KEY_DIR="/data/system/ssh"
SSH_HOST_KEY_TYPES="ed25519 ecdsa rsa"

# the key directory and the key types are shared by the generator and sshd
cat >"${ROOTFS_DIR}/etc/default/ssh-host-keys" << EOF
KEY_DIR=${SSH_HOST_KEY_DIR}
KEY_TYPES="${SSH_HOST_KEY_TYPES}"
EOF

echo "d ${SSH_HOST_KEY_DIR} 0755 root root -" >"${ROOTFS_DIR}/etc/tmpfiles.d/data-ssh.conf"

for TYPE in ${SSH_HOST_KEY_TYPES}; do
  echo "HostKey ${SSH_HOST_KEY_DIR}/ssh_host_${TYPE}_key"
done >"${ROOTFS_DIR}/etc/ssh/sshd_config.d/hostkeys.conf"

install -m 755 files/ssh-generate-host-keys.sh "${ROOTFS_DIR}/usr/local/sbin/ssh-generate-host-keys"
install -v -D -m 644 files/sshd-keygen-data.conf "${ROOTFS_DIR}/etc/systemd/system/sshd-keygen.service.d/10-data.conf"

# raspberrypi-sys-mods ships its own generator, which wipes /etc/ssh/ssh_host_*
# and recreates the keys there on the first boot, before /data is mounted: they
# would land on the root overlay and be gone at the next boot.
on_chroot << EOF
systemctl mask regenerate_ssh_host_keys.service
EOF
