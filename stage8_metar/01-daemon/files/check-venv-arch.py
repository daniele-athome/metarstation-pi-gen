#!/usr/bin/env python3
"""
Checks for wrongly compiled wheels in a given virtualenv, i.e., those
that would not work on a Pi Zero and produce SIGILL/Illegal instruction.

Usage: check-venv-arch.py /path/to/venv > rebuild.txt
Needs: readelf (binutils)
"""

import re
import subprocess
import sys
from pathlib import Path

OK_CPU = {"Pre-v4", "v4", "v4T", "v5T", "v5TE", "v5TEJ", "v6", "v6K", "v6KZ"}
OK_FP = {"VFPv1", "VFPv2"}
SO_RE = re.compile(r"\.so(\.\d+)*$")


def problems(so: Path):
    out = subprocess.run(["readelf", "-A", str(so)], capture_output=True, text=True).stdout
    tags = dict(l.strip().split(":", 1) for l in out.splitlines() if l.strip().startswith("Tag_"))
    tags = {k: v.strip() for k, v in tags.items()}
    found = []
    if tags.get("Tag_CPU_arch", "v6") not in OK_CPU:
        found.append(f"CPU={tags['Tag_CPU_arch']}")
    if tags.get("Tag_FP_arch", "VFPv2") not in OK_FP:
        found.append(f"FP={tags['Tag_FP_arch']}")
    if "Tag_Advanced_SIMD_arch" in tags:
        found.append(f"SIMD={tags['Tag_Advanced_SIMD_arch']}")
    if "Thumb-2" in tags.get("Tag_THUMB_ISA_use", ""):
        found.append("Thumb-2")
    return found


def meta(dist_info: Path):
    name = version = None
    for line in (dist_info / "METADATA").read_text(errors="replace").splitlines():
        if line.startswith("Name:"):
            name = line.split(":", 1)[1].strip()
        elif line.startswith("Version:"):
            version = line.split(":", 1)[1].strip()
        if name and version:
            break
    return name, version


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    venv = Path(sys.argv[1])
    sites = list(venv.glob("lib/python*/site-packages")) or [venv]
    for site in sites:
        for dist_info in sorted(site.glob("*.dist-info")):
            record = dist_info / "RECORD"
            if not record.exists():
                continue
            bad = []
            for row in record.read_text(errors="replace").splitlines():
                rel = row.split(",", 1)[0]
                if SO_RE.search(rel):
                    so = (site / rel).resolve()
                    if so.exists() and (p := problems(so)):
                        bad.append(f"    {rel}: {', '.join(p)}")
            if bad:
                name, version = meta(dist_info)
                print(f"{name}=={version}")
                print(f"{name} {version}", *bad, sep="\n", file=sys.stderr)


if __name__ == "__main__":
    main()
