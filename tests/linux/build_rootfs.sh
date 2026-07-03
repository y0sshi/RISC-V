#!/bin/bash
# =============================================================================
# build_rootfs.sh - Build the RV64GC glibc rootfs (bash) with Buildroot and
#                   emit an initramfs cpio for the kernel to embed.
#
# Run inside the buildroot-rv64 docker (see Dockerfile.buildroot), with a NATIVE
# (non-bind-mount) build dir mounted at /br -- see `make rootfs-buildroot`.
#
# Produces tests/linux/work/buildroot-rootfs.cpio, which build.sh points
# CONFIG_INITRAMFS_SOURCE at (ROOTFS=buildroot).
#
# *** Why the build tree lives OUTSIDE /workspace ***
# Buildroot's glibc build does thousands of parallel file creates/renames.  On a
# Windows-host Docker bind mount (9p/virtiofs) those race and produce spurious
# "Directory nonexistent" errors + a broken ld.so partial-link (undefined refs to
# getenv / __lll_lock_*).  Same class as the OpenSBI "clone inside docker (CRLF)"
# workaround.  So BR_BUILD_DIR points at a native docker volume (/br); only the
# final small rootfs.cpio is copied back to the bind-mounted work dir.  The
# volume also caches the ~40-min toolchain across runs.
#
# Idempotent: re-uses the cloned Buildroot tree + build output in the volume.
# FORCE_ROOTFS=1 re-runs the Buildroot build (after editing defconfig/overlay),
# FORCE_DL=1 re-clones Buildroot.
# =============================================================================
set -e
HERE=$(pwd)                                  # /workspace/tests/linux
W=$HERE/work
mkdir -p "$W"

BUILDROOT_REF=${BUILDROOT_REF:-2025.02.15}
BUILDROOT_URL=${BUILDROOT_URL:-https://github.com/buildroot/buildroot.git}
# Native build dir (docker volume); falls back to /tmp if not mounted.
BR_BUILD_DIR=${BR_BUILD_DIR:-/tmp/buildroot-build}
mkdir -p "$BR_BUILD_DIR"
BR=$BR_BUILD_DIR/buildroot
DEFCONFIG=$HERE/buildroot_rvsoc_defconfig
OUT_CPIO=$W/buildroot-rootfs.cpio
NPROC=$(nproc)

# autoconf refuses to configure as root without this (we run as root in docker).
export FORCE_UNSAFE_CONFIGURE=1

echo "== [1/4] Buildroot source ($BUILDROOT_REF) =="
if [ "${FORCE_DL:-0}" = "1" ]; then rm -rf "$BR"; fi
if [ ! -d "$BR/.git" ]; then
    echo "   cloning Buildroot $BUILDROOT_REF ..."
    git clone --depth 1 -b "$BUILDROOT_REF" "$BUILDROOT_URL" "$BR"
fi
echo "   buildroot: $BR"

echo "== [2/4] apply defconfig =="
make -C "$BR" BR2_DEFCONFIG="$DEFCONFIG" defconfig

echo "== [3/4] build rootfs (first run compiles a glibc toolchain; ~30-60 min) =="
if [ "${FORCE_ROOTFS:-0}" = "1" ] || [ ! -f "$BR/output/images/rootfs.cpio" ]; then
    make -C "$BR" -j"$NPROC"
fi

echo "== [4/4] stage initramfs cpio =="
cp "$BR/output/images/rootfs.cpio" "$OUT_CPIO"
echo "   rootfs.cpio: $(stat -c %s "$OUT_CPIO") bytes -> $OUT_CPIO"
echo "DONE"
