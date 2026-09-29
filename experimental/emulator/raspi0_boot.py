#!/usr/bin/env python3
"""
Boot a Raspberry Pi Zero W image under QEMU (-M raspi0), standing in for the
VideoCore firmware that QEMU does not run.

Per boot cycle it:
  1. exposes the qcow2 overlay through qemu-nbd,
  2. picks the boot partition (autoboot.txt / tryboot marker, or a single one),
  3. extracts kernel, DTB, initramfs and cmdline.txt from that partition,
  4. optionally strips the Bluetooth node from the DTB,
  5. runs QEMU and waits,
  6. loops on guest reset, exits on guest poweroff.

Serial mapping is the same as on real hardware with Bluetooth enabled:
QEMU wires serial_hd(0) to the PL011 (ttyAMA0, the BT HCI link) and
serial_hd(1) to the AUX mini UART (ttyS0, the console).

Tryboot: QEMU has no usable firmware mailbox, so the guest signals a tryboot
request by creating a marker file on the autoboot partition instead of calling
reboot "0 tryboot". Keep that call behind a single wrapper in the updater so
only the wrapper differs between test and field.

Requires: qemu-system-arm, qemu-img, qemu-nbd (root), mtools, optionally
device-tree-compiler for --disable-bt.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

log = logging.getLogger("raspi0")

TRYBOOT_MARKER = "TRYBOOT"          # file on the autoboot partition
DEFAULT_KERNEL = "kernel.img"       # armv6 kernel shipped by pi-gen for Pi 1/Zero
DEFAULT_DTB = "bcm2708-rpi-zero-w.dtb"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    log.debug("run: %s", " ".join(cmd))
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def require(tool: str) -> None:
    if shutil.which(tool) is None:
        sys.exit(f"missing required tool: {tool}")


def next_power_of_two(n: int) -> int:
    p = 1
    while p < n:
        p <<= 1
    return p


def make_overlay(base: Path, overlay: Path, force: bool) -> None:
    """Create a qcow2 overlay sized to a power of two (required by QEMU's SD model)."""
    if overlay.exists():
        if not force:
            log.info("reusing existing overlay %s", overlay)
            return
        overlay.unlink()
    size = next_power_of_two(base.stat().st_size)
    run(["qemu-img", "create", "-f", "qcow2", "-b", str(base.resolve()),
         "-F", "raw", str(overlay), str(size)])
    log.info("created overlay %s (%d MiB)", overlay, size >> 20)


class Nbd:
    """Expose a qcow2 image as /dev/nbdN for the duration of a with-block."""

    def __init__(self, image: Path, device: str) -> None:
        self.image = image
        self.device = device

    def __enter__(self) -> str:
        subprocess.run(["modprobe", "nbd", "max_part=16"], check=False,
                       capture_output=True)
        run(["qemu-nbd", "--connect", self.device, "-f", "qcow2", str(self.image)])
        # udev needs a moment to create the partition nodes
        for _ in range(50):
            if Path(self.device + "p1").exists():
                break
            time.sleep(0.1)
        else:
            self.__exit__(None, None, None)
            sys.exit(f"{self.device}p1 never appeared; is the image partitioned?")
        return self.device

    def __exit__(self, *exc) -> None:
        subprocess.run(["qemu-nbd", "--disconnect", self.device],
                       check=False, capture_output=True)


def partitions(device: str) -> list[dict]:
    out = run(["sfdisk", "-J", device]).stdout
    return json.loads(out)["partitiontable"]["partitions"]


def mdir_exists(part: str, name: str) -> bool:
    env = {**os.environ, "MTOOLS_SKIP_CHECK": "1"}
    r = subprocess.run(["mdir", "-i", part, f"::{name}"],
                       capture_output=True, text=True, env=env)
    return r.returncode == 0


def mread(part: str, name: str, dest: Path) -> bool:
    env = {**os.environ, "MTOOLS_SKIP_CHECK": "1"}
    r = subprocess.run(["mcopy", "-n", "-i", part, f"::{name}", str(dest)],
                       capture_output=True, text=True, env=env)
    return r.returncode == 0


def mdelete(part: str, name: str) -> None:
    env = {**os.environ, "MTOOLS_SKIP_CHECK": "1"}
    subprocess.run(["mdel", "-i", part, f"::{name}"],
                   check=False, capture_output=True, env=env)


# ---------------------------------------------------------------------------
# Firmware stub: slot selection and boot artifacts
# ---------------------------------------------------------------------------

def select_boot_partition(device: str, workdir: Path) -> str:
    """Return the partition node to boot from, honouring autoboot.txt + tryboot."""
    parts = partitions(device)
    first = device + "p1"

    autoboot = workdir / "autoboot.txt"
    if not mread(first, "autoboot.txt", autoboot):
        log.info("no autoboot.txt: classic layout, booting from %s", first)
        return first

    tryboot = mdir_exists(first, TRYBOOT_MARKER)
    if tryboot:
        # One-shot, like the real flag: consume it before booting.
        mdelete(first, TRYBOOT_MARKER)
        log.warning("tryboot marker found and consumed")

    section = None
    chosen = None
    for line in autoboot.read_text(errors="replace").splitlines():
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].lower()
            continue
        m = re.match(r"boot_partition\s*=\s*(\d+)", line, re.I)
        if not m:
            continue
        want = "tryboot" if tryboot else "all"
        if section in (want, None) or (not tryboot and section == "none"):
            if section == want or chosen is None:
                chosen = int(m.group(1))
    if chosen is None:
        sys.exit("autoboot.txt present but no boot_partition found")

    node = f"{device}p{chosen}"
    if not any(p["node"] == node for p in parts):
        sys.exit(f"autoboot.txt selects partition {chosen}, which does not exist")
    log.info("autoboot: slot %s%s", node, " (TRYBOOT)" if tryboot else "")
    return node


def parse_config_txt(text: str) -> dict[str, str]:
    """Flatten config.txt, ignoring conditional filter sections other than [all]."""
    values: dict[str, str] = {}
    active = True
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            active = line[1:-1].lower() in ("all", "none") or "pi0" in line.lower()
            continue
        if active and "=" in line:
            k, v = line.split("=", 1)
            values[k.strip()] = v.strip()
        elif active and line.lower().startswith("initramfs"):
            values["initramfs"] = line.split(None, 1)[1] if " " in line else ""
    return values


class BootArtifacts:
    def __init__(self, kernel: Path, dtb: Path, cmdline: str, initrd: Path | None):
        self.kernel, self.dtb, self.cmdline, self.initrd = kernel, dtb, cmdline, initrd


def extract_boot(part: str, workdir: Path, console: str,
                 dtb_name: str, kernel_name: str | None,
                 extra_cmdline: str) -> BootArtifacts:
    cfg_file = workdir / "config.txt"
    cfg = parse_config_txt(cfg_file.read_text(errors="replace")) \
        if mread(part, "config.txt", cfg_file) else {}

    kernel_file = kernel_name or cfg.get("kernel", DEFAULT_KERNEL)
    kernel = workdir / "kernel"
    if not mread(part, kernel_file, kernel):
        sys.exit(f"kernel {kernel_file} not found on {part}")

    dtb = workdir / "dtb"
    if not mread(part, dtb_name, dtb):
        sys.exit(f"device tree {dtb_name} not found on {part}")

    initrd = None
    if "initramfs" in cfg:
        # "initramfs initrd.img followkernel"
        name = cfg["initramfs"].split()[0]
        candidate = workdir / "initrd"
        if mread(part, name, candidate):
            initrd = candidate
        else:
            log.warning("config.txt references initramfs %s but it is missing", name)

    cmdline_file = workdir / "cmdline.txt"
    cmdline = cmdline_file.read_text(errors="replace").strip().replace("\n", " ") \
        if mread(part, "cmdline.txt", cmdline_file) else ""
    # serial0 is a firmware-created alias and does not exist here.
    cmdline = re.sub(r"console=serial\d+,\S*", "", cmdline)
    cmdline = re.sub(r"console=tty1\b", "", cmdline)
    cmdline = f"console={console} {cmdline} {extra_cmdline}".strip()
    cmdline = re.sub(r"\s+", " ", cmdline)

    log.info("kernel=%s dtb=%s initrd=%s", kernel_file, dtb_name,
             "yes" if initrd else "no")
    log.info("cmdline: %s", cmdline)
    return BootArtifacts(kernel, dtb, cmdline, initrd)


def strip_bluetooth(dtb: Path) -> None:
    """Remove the on-board BT node so hci_bcm does not try to bring up absent hardware."""
    if shutil.which("fdtput") is None:
        log.warning("fdtput not available, leaving DTB untouched")
        return
    for path in ("/soc/serial@7e201000/bluetooth", "/soc/uart0/bluetooth"):
        r = subprocess.run(["fdtput", "-r", str(dtb), path],
                           capture_output=True, text=True)
        if r.returncode == 0:
            log.info("removed %s from DTB", path)
            return
    log.warning("no bluetooth node found in DTB; nothing removed")


# ---------------------------------------------------------------------------
# QEMU
# ---------------------------------------------------------------------------

class QmpWatcher(threading.Thread):
    """Read QMP events so we can tell a guest reset from a guest poweroff."""

    def __init__(self, path: str) -> None:
        super().__init__(daemon=True)
        self.path = path
        self.reason: str | None = None

    def run(self) -> None:
        sock = socket.socket(socket.AF_UNIX)
        for _ in range(100):
            try:
                sock.connect(self.path)
                break
            except OSError:
                time.sleep(0.05)
        else:
            log.warning("could not connect to QMP socket")
            return
        try:
            f = sock.makefile("rw")
            f.readline()  # greeting
            f.write('{"execute":"qmp_capabilities"}\n')
            f.flush()
            for line in f:
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if msg.get("event") == "SHUTDOWN":
                    self.reason = msg.get("data", {}).get("reason", "unknown")
        except OSError:
            pass
        finally:
            sock.close()


def qemu_command(a, art: BootArtifacts, overlay: Path, qmp_path: str) -> list[str]:
    net = f"user,id=n0,hostfwd=tcp::{a.ssh_port}-:22"
    if a.offline:
        net += ",restrict=on"

    cmd = [
        "qemu-system-arm", "-M", "raspi0", "-m", "512",
        "-kernel", str(art.kernel), "-dtb", str(art.dtb),
        "-append", art.cmdline,
        "-drive", f"file={overlay},format=qcow2,if=sd",
        "-netdev", net, "-device", "usb-net,netdev=n0",
        "-qmp", f"unix:{qmp_path},server=on,wait=off",
        "-no-reboot",
        # serial_hd(0) -> PL011 (ttyAMA0): the Bluetooth HCI link
        "-chardev", f"socket,id=bt0,host={a.bt_host},port={a.bt_port},"
                    f"server=on,wait=off",
        "-serial", "chardev:bt0",
        # serial_hd(1) -> AUX mini UART (ttyS0): the console
        "-serial", "mon:stdio",
        "-display", "none",
    ]
    if art.initrd:
        cmd += ["-initrd", str(art.initrd)]
    if a.qemu_arg:
        cmd += a.qemu_arg
    return cmd


def boot_once(a, overlay: Path, workdir: Path) -> str:
    with Nbd(overlay, a.nbd) as dev:
        part = select_boot_partition(dev, workdir)
        art = extract_boot(part, workdir, a.console, a.dtb, a.kernel, a.append)
        if a.disable_bt:
            strip_bluetooth(art.dtb)
    # NBD must be disconnected before QEMU opens the image for writing.

    qmp_path = str(workdir / "qmp.sock")
    cmd = qemu_command(a, art, overlay, qmp_path)
    log.debug("qemu: %s", " ".join(cmd))

    watcher = QmpWatcher(qmp_path)
    proc = subprocess.Popen(cmd)
    watcher.start()

    killer = None
    if a.kill_after:
        def kill_it() -> None:
            log.warning("fault injection: killing QEMU after %.1fs", a.kill_after)
            proc.kill()
        killer = threading.Timer(a.kill_after, kill_it)
        killer.start()

    proc.wait()
    if killer:
        killer.cancel()
    watcher.join(timeout=2)

    reason = watcher.reason or ("killed" if a.kill_after else "unknown")
    log.info("QEMU exited (reason: %s)", reason)
    return reason


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("image", type=Path, help="raw pi-gen image (never modified)")
    p.add_argument("--overlay", type=Path, default=Path("run.qcow2"))
    p.add_argument("--fresh", action="store_true", help="recreate the overlay")
    p.add_argument("--nbd", default="/dev/nbd0")
    p.add_argument("--dtb", default=DEFAULT_DTB)
    p.add_argument("--kernel", help="override the kernel file name on the boot partition")
    p.add_argument("--console", default="ttyS0,115200")
    p.add_argument("--append", default="", help="extra kernel command line")
    p.add_argument("--disable-bt", action="store_true",
                   help="remove the BT node from the DTB (use btattach in the guest)")
    p.add_argument("--bt-host", default="127.0.0.1")
    p.add_argument("--bt-port", type=int, default=9000,
                   help="TCP port for the HCI link on ttyAMA0")
    p.add_argument("--ssh-port", type=int, default=2222)
    p.add_argument("--offline", action="store_true",
                   help="no outbound network, only the forwarded SSH port")
    p.add_argument("--max-boots", type=int, default=10)
    p.add_argument("--kill-after", type=float,
                   help="fault injection: kill QEMU after N seconds")
    p.add_argument("--qemu-arg", action="append", default=[],
                   help="extra argument passed through to QEMU (repeatable)")
    p.add_argument("-v", "--verbose", action="store_true")
    a = p.parse_args()

    logging.basicConfig(level=logging.DEBUG if a.verbose else logging.INFO,
                        format="%(levelname)s [stub] %(message)s")

    for tool in ("qemu-system-arm", "qemu-img", "qemu-nbd", "sfdisk", "mcopy", "mdir"):
        require(tool)
    if os.geteuid() != 0:
        sys.exit("qemu-nbd needs root; re-run with sudo")
    if not a.image.is_file():
        sys.exit(f"no such image: {a.image}")

    make_overlay(a.image, a.overlay, a.fresh)

    with tempfile.TemporaryDirectory(prefix="raspi0-stub-") as tmp:
        workdir = Path(tmp)
        for n in range(1, a.max_boots + 1):
            log.info("=== boot cycle %d/%d ===", n, a.max_boots)
            reason = boot_once(a, a.overlay, workdir)
            if reason in ("guest-reset", "host-signal"):
                continue
            break
        else:
            log.warning("reached --max-boots, stopping")


if __name__ == "__main__":
    main()
