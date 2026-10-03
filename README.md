# metarstation-pi-gen

Image builder for the **METAR Station**: an unattended Raspberry Pi Zero W weather
station that reads an Ecowitt WS90 over Bluetooth LE and publishes weather data to a
server.

This is a fork of [RPI-Distro/pi-gen](https://github.com/RPI-Distro/pi-gen). The
upstream build machinery is kept as-is, so upstream's documentation still applies for
everything not covered here. The target is **armhf / ARMv6** (Raspberry Pi Zero W).

## How it differs from upstream pi-gen

* **Four partitions instead of two.** `bootfs`, two fixed-size root slots (A and B, for
  future in-place upgrades) and a `data` partition. Only the `data` partition grows, on
  first boot.
* **Read-only system.** `/` is an `overlayroot` tmpfs overlay and `/boot/firmware` is
  mounted read-only: nothing written outside `/data` survives a reboot. Everything that
  must persist — machine ID, sshd host keys, Wi-Fi credentials, application config —
  lives on the data partition.
* **Headless by design.** No desktop stage is built. Wi-Fi is provisioned over BLE with
  [Improv Wi-Fi](https://www.improv-wifi.com/), remote access goes through a Cloudflare
  Tunnel, and SSH accepts only certificates signed by a trusted CA.
* **Slimmer and faster.** A reduced package set, a purge pass before image export, and a
  cached build of the daemon's Python dependencies (compiling them from source on ARMv6
  takes hours).

## Stages

Upstream stages 0–2 are used mostly unchanged; stages 3–5 (desktop, full image) are left
in the tree for easier merges but never built.

| Stage               | Purpose                                                                                                                                                                                                                      |
|---------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `stage0`            | Bootstrap: minimal filesystem via `debootstrap`, apt configuration.                                                                                                                                                          |
| `stage1`            | Minimal bootable system: fstab, bootloader, networking, `raspi-config`.                                                                                                                                                      |
| `stage2_slim`       | Replaces upstream `stage2` (the Lite system) with the same sub-stages minus cloud-init, and a trimmed package list.                                                                                                          |
| `stage6_upgrades`   | Runtime support for the A/B layout: the `/data` mount, read-only boot and root, first-boot growth of the data partition, and persistence of the machine ID across reboots.                                                   |
| `stage7_networking` | Connectivity: Improv Wi-Fi provisioning over BLE, NetworkManager with its connections stored on `/data`, a Wi-Fi watchdog, SSH configuration, and a Cloudflare Tunnel for remote access.                                     |
| `stage8_metar`      | The application: installs [metarstation-daemon](https://github.com/daniele-athome/metarstation-daemon) in a virtualenv, plus the weather daemon and the HTTP server serving the dashboard. This is the exported image stage. |

## New environment variables

Everything upstream pi-gen supports in `config` still applies. This fork adds:

* `PUBKEY_SSH_CA` (**required**)

  An SSH certificate authority public key. It is installed as `/etc/ssh/ssh_ca.pub` and
  referenced from sshd's `TrustedUserCAKeys`, so only users presenting a certificate
  signed by this CA can log in; password authentication is disabled.

* `CACHE_OUTPUT` (Default: unset)

  Directory used to carry the pip wheel cache across builds, mainly for CI. If
  `$CACHE_OUTPUT/pip-wheels` exists it is reused instead of rebuilding the wheels; the
  cache produced by the build is written back there. Independently of this variable, the
  cache is always deployed alongside the image as
  `<IMG_FILENAME><IMG_SUFFIX>.pipcache.tar.xz`.

* `DEPLOY_ROOTFS_SLOT` (Default: `1`)

  Also deploy the contents of the first root slot on its own, as
  `<IMG_FILENAME><IMG_SUFFIX>.rootfs.img` (compressed with `DEPLOY_COMPRESSION`,
  plus a `.rootfs.bmap` when `bmaptool` is available). It is carved out of the
  finished image, so it is byte-for-byte what the image ships, and it can be
  written to either root slot of a deployed card — the slot is only ever named on
  the kernel command line, never inside the filesystem. Set to `0` to skip it and
  save the extra compression pass.

Two upstream variables behave differently here:

* `ARCHIVE_FILENAME` is **gone**. Compressed artifacts are named after `IMG_FILENAME`.
* `STAGE_LIST` is effectively **mandatory**: the stages of this fork must be selected
  explicitly.

## Example config

```bash
ARCH=armhf
RELEASE=trixie
IMG_NAME="raspios-metar-$RELEASE-$ARCH"
PI_GEN_RELEASE="Raspberry Pi METAR Station"

# Mandatory: stage2_slim replaces stage2, and the desktop stages are skipped.
STAGE_LIST="stage0 stage1 stage2_slim stage6_upgrades stage7_networking stage8_metar"

# The image is headless: keep the user name and set a password.
FIRST_USER_NAME='pi'
FIRST_USER_PASS='<password>'
DISABLE_FIRST_BOOT_USER_RENAME=1

TARGET_HOSTNAME='metarstation'
LOCALE_DEFAULT='en_GB.UTF-8'
TIMEZONE_DEFAULT='Europe/Rome'
KEYBOARD_KEYMAP='it'
KEYBOARD_LAYOUT='Italian'
WPA_COUNTRY='IT'
ENABLE_CLOUD_INIT=0

ENABLE_SSH=1
# Required: only certificates signed by this CA may log in.
PUBKEY_SSH_CA='ssh-ed25519 AAAA... metarstation-ca'

DEPLOY_COMPRESSION='xz'
COMPRESSION_LEVEL=6

# Optional: reuse and refresh the pip wheel cache between builds.
# CACHE_OUTPUT="${PWD}/cache"

# mandatory internal detail
export PUBKEY_SSH_CA
```

Build natively with `sudo ./build.sh`, or in a container with `./build-docker.sh`.
Artifacts land in `deploy/`.

## Runtime configuration

The image boots without any configuration, but the services stay inactive until their
files exist on the data partition:

```
/data/metarstation/config.toml      # weather daemon configuration
/data/system/cloudflared.env        # TUNNEL_TOKEN=<cloudflare tunnel token>
/data/system/ssh/                   # sshd host keys, generated on first boot
/data/system/NetworkManager/        # Wi-Fi connections written by Improv provisioning
/data/system/machine-id             # persisted machine ID
```

Wi-Fi is provisioned by pairing with any Improv Wi-Fi client during the first five
minutes after boot. The dashboard is served on port `9321`.

Since `/` is read-only, changing the running system requires disabling the overlay and
rebooting:

```bash
sudo overlayfs-disable && sudo reboot   # make root writable
sudo overlayfs-enable  && sudo reboot   # back to read-only root
```

## License

Same as upstream pi-gen — see [LICENSE](LICENSE).
