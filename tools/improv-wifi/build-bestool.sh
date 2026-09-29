#!/usr/bin/env bash
# Cross-compile bestool (only the `iti improv-wifi` subcommand) for Raspberry Pi Zero W
# (ARMv6, hard-float, glibc), with a local fix applied to the improv-wifi crate.
#
# Host requirements: rustup, cross (cargo install cross --git https://github.com/cross-rs/cross),
# Docker or Podman (export CROSS_CONTAINER_ENGINE=podman), curl, patch, readelf.
set -euo pipefail

BESTOOL_VERSION="${BESTOOL_VERSION:-2.2.0}"
IMPROV_VERSION="${IMPROV_VERSION:-0.1.2}"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-1.95.0}"   # sysinfo 0.39.x requires rustc >= 1.95
TARGET="arm-unknown-linux-gnueabihf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${PATCH_DIR:-$SCRIPT_DIR}"   # applies every improv-wifi-<version>-*.patch found here
WORKDIR="${WORKDIR:-$PWD/build}"
OUTDIR="${OUTDIR:-$PWD/dist}"

BESTOOL_DIR="$WORKDIR/bestool-$BESTOOL_VERSION"
IMPROV_DIR="$WORKDIR/improv-wifi-$IMPROV_VERSION"

log() { printf '\n== %s ==\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

fetch_crate() { # <name> <version> -> extracts into $WORKDIR/<name>-<version>
  curl -fsSL "https://static.crates.io/crates/$1/$1-$2.crate" | tar xz -C "$WORKDIR"
}

shopt -s nullglob
PATCHES=("$PATCH_DIR"/improv-wifi-"$IMPROV_VERSION"-*.patch)
shopt -u nullglob
log "Found ${#PATCHES[@]} patches to apply"
mkdir -p "$WORKDIR" "$OUTDIR"

log "Rust toolchain $RUST_TOOLCHAIN"
rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal

log "Sources"
[[ -d "$BESTOOL_DIR" ]] || fetch_crate bestool "$BESTOOL_VERSION"
# improv-wifi is always re-extracted so the patch is applied to pristine sources.
rm -rf "$IMPROV_DIR"
fetch_crate improv-wifi "$IMPROV_VERSION"

log "Patching improv-wifi"
for p in "${PATCHES[@]}"; do
  echo "Applying $(basename "$p")"
  patch -p1 -d "$IMPROV_DIR" < "$p"
done

log "Wiring patched improv-wifi into bestool"
if ! grep -q '^\[patch\.crates-io\]' "$BESTOOL_DIR/Cargo.toml"; then
  cat >> "$BESTOOL_DIR/Cargo.toml" <<TOML

[patch.crates-io]
improv-wifi = { path = "../improv-wifi-$IMPROV_VERSION" }
TOML
fi
# Rewrites only the improv-wifi entry of Cargo.lock (registry -> path);
# everything else stays pinned, so the build below can keep --locked.
(cd "$BESTOOL_DIR" && cargo "+$RUST_TOOLCHAIN" update -p improv-wifi)
if grep -A2 '^name = "improv-wifi"$' "$BESTOOL_DIR/Cargo.lock" | grep -q '^source = '; then
  die "Cargo.lock still resolves improv-wifi from the registry: patch not wired in"
fi

log "Building for $TARGET"
# The published crate carries no custom release profile: set it via env
# (cross forwards CARGO_* variables into the container).
export CARGO_PROFILE_RELEASE_LTO=true
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_STRIP=true
(cd "$BESTOOL_DIR" && cross "+$RUST_TOOLCHAIN" build --release --locked \
  --target "$TARGET" \
  --no-default-features --features iti-improv-wifi)

BIN="$BESTOOL_DIR/target/$TARGET/release/bestool"

log "Checks"
# ELF attributes reflect the highest architecture among all linked objects:
# a single ARMv7 object (e.g. from C code) would show up here.
readelf -A "$BIN" | grep -E 'Tag_CPU_arch|Tag_FP_arch|Tag_ABI_VFP_args'
if readelf -A "$BIN" | grep -E '^\s*Tag_CPU_arch:' | grep -qv 'v6'; then
  die "binary is not ARMv6: it would crash with SIGILL on a Pi Zero W"
fi
echo "Max glibc required: $(readelf -V "$BIN" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"

cp "$BIN" "$OUTDIR/bestool"
log "Done: $OUTDIR/bestool ($(du -h "$OUTDIR/bestool" | cut -f1))"
