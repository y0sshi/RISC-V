#!/bin/bash
# =============================================================================
# build.sh - Build a minimal RV64 Linux Image + initramfs and wrap it into an
#            OpenSBI fw_payload for the sim boot harness.
#
# Run inside the linux-rv64 docker (riscv64-linux-gnu gcc + kernel deps + dtc):
#   docker run --rm -v <repo>:/workspace -w /workspace/tests/linux \
#       linux-rv64:latest bash build.sh
#
# Produces work/fw_payload_linux.hex (base-relative verilog), boot it with:
#   cd src/sim && make vl_boot BOOT_HEX=../../tests/linux/work/fw_payload_linux.hex BOOT_MAX=200000000
#
# Idempotent: re-uses a downloaded/extracted/built kernel.  Set FORCE_KERNEL=1
# to reconfigure+rebuild the kernel, FORCE_DL=1 to re-download the source.
# =============================================================================
set -e
HERE=$(pwd)                                  # /workspace/tests/linux
W=$HERE/work
mkdir -p $W
KVER=${KVER:-6.12}
KDIR=$W/linux-$KVER
XK=riscv64-linux-gnu-                         # kernel/payload cross toolchain
NPROC=$(nproc)

# FW_BASE = firmware/DDR base (= RST_ADDR = BFM BASE_ADDR).  Default 0x80000000
# reproduces the proven baseline; pass FW_BASE=0x00200000 (with a base-matched
# DTS) to re-link the fw_payload for the real-HW PS-DDR base.  The kernel Image
# is position-independent (relocatable) and base-independent -- only the OpenSBI
# wrapper + DTB depend on FW_BASE -- so switching base only re-wraps (no kernel
# rebuild).  OUT renames the hex so both bases can coexist in work/.
FW_BASE=${FW_BASE:-0x80000000}
OUT=${OUT:-fw_payload_linux}

# ROOTFS selects what userspace the kernel embeds as its initramfs:
#   minimal   - the freestanding static init.c (proves kernel->userspace; P0-5).
#   buildroot - a real RV64GC glibc rootfs with bash, built separately by
#               `make rootfs-buildroot` (build_rootfs.sh) into
#               work/buildroot-rootfs.cpio.  Embedding only; no Buildroot build
#               happens here (that runs in its own docker to avoid nesting).
ROOTFS=${ROOTFS:-minimal}

OPENSBI=$HERE/../opensbi/work/opensbi          # reuse the cloned v1.2 tree
DTS=${DTS:-$HERE/rv_soc_linux.dts}

echo "== [1/6] initramfs source (ROOTFS=$ROOTFS) =="
if [ "$ROOTFS" = "buildroot" ]; then
    INITRAMFS_SRC=$W/buildroot-rootfs.cpio
    if [ ! -f "$INITRAMFS_SRC" ]; then
        echo "ERROR: $INITRAMFS_SRC not found."
        echo "       Build it first:  make image-buildroot && make rootfs-buildroot"
        exit 1
    fi
    echo "   rootfs.cpio: $(stat -c %s $INITRAMFS_SRC) bytes (Buildroot glibc + bash)"
else
    # Freestanding (no target libc needed): raw write() via ecall, custom _start.
    ${XK}gcc -static -nostdlib -ffreestanding -Os -o $W/init $HERE/init.c
    ${XK}strip $W/init
    cat > $W/initramfs.list <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
dir /bin 0755 0 0
file /init $W/init 0755 0 0
EOF
    INITRAMFS_SRC=$W/initramfs.list
    echo "   init: $(stat -c %s $W/init) bytes"
fi
# One-line fragment carrying the selected initramfs source, merged on top of the
# static kernel_fragment.config so the path is not hard-coded there.  Reused by
# the configure step (a change here forces reconfigure + Image rebuild below).
echo "CONFIG_INITRAMFS_SOURCE=\"$INITRAMFS_SRC\"" > $W/gen_initramfs.config

echo "== [2/6] Linux source v$KVER =="
if [ "${FORCE_DL:-0}" = "1" ]; then rm -f $W/linux-$KVER.tar.xz; rm -rf $KDIR; fi
if [ ! -d $KDIR ]; then
    if [ ! -f $W/linux-$KVER.tar.xz ]; then
        echo "   downloading linux-$KVER.tar.xz ..."
        wget -q -O $W/linux-$KVER.tar.xz \
            "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz"
    fi
    echo "   extracting ..."
    tar -C $W -xf $W/linux-$KVER.tar.xz
fi
echo "   kernel src: $KDIR"

echo "== [3/6] configure (defconfig + fragment) =="
# Reconfigure on FORCE_KERNEL, a missing .config, or an initramfs-source switch
# (e.g. ROOTFS=minimal<->buildroot) so the embedded rootfs actually changes.
WANT_SRC="CONFIG_INITRAMFS_SOURCE=\"$INITRAMFS_SRC\""
HAVE_SRC=$(grep -h '^CONFIG_INITRAMFS_SOURCE=' $KDIR/.config 2>/dev/null || true)
if [ "${FORCE_KERNEL:-0}" = "1" ] || [ ! -f $KDIR/.config ] || [ "$HAVE_SRC" != "$WANT_SRC" ]; then
    make -C $KDIR ARCH=riscv CROSS_COMPILE=$XK defconfig
    $KDIR/scripts/kconfig/merge_config.sh -m -O $KDIR \
        $KDIR/.config $HERE/kernel_fragment.config $W/gen_initramfs.config
    make -C $KDIR ARCH=riscv CROSS_COMPILE=$XK olddefconfig
    NEED_IMAGE=1
fi

echo "== [4/6] build Image =="
# Rebuild when reconfigured, when forced, when missing, or when the initramfs
# payload is newer than the last Image (the cpio is embedded INTO the Image).
if [ "${FORCE_KERNEL:-0}" = "1" ] || [ "${NEED_IMAGE:-0}" = "1" ] || \
   [ ! -f $KDIR/arch/riscv/boot/Image ] || [ "$INITRAMFS_SRC" -nt $KDIR/arch/riscv/boot/Image ]; then
    make -C $KDIR ARCH=riscv CROSS_COMPILE=$XK -j$NPROC Image
fi
cp $KDIR/arch/riscv/boot/Image $W/Image
echo "   Image: $(stat -c %s $W/Image) bytes"

echo "== [5/6] device tree blob =="
dtc -I dts -O dtb -o $W/rv_soc_linux.dtb $DTS
echo "   dtb: $(stat -c %s $W/rv_soc_linux.dtb) bytes"

echo "== [6/6] OpenSBI generic fw_payload (payload = Linux Image) =="
# Rebuild OpenSBI with the Linux toolchain (clean: prior build used elf gcc).
make -C $OPENSBI distclean >/dev/null 2>&1 || true
# OpenSBI is integer-only firmware; keep the proven rv64imac/lp64 build (the
# Linux payload is a separate binary, so its gc/lp64d ABI need not match).
make -C $OPENSBI PLATFORM=generic CROSS_COMPILE=$XK \
    PLATFORM_RISCV_XLEN=64 PLATFORM_RISCV_ISA=rv64imac_zicsr_zifencei PLATFORM_RISCV_ABI=lp64 \
    FW_TEXT_START=$FW_BASE \
    FW_PAYLOAD=y FW_PAYLOAD_PATH=$W/Image FW_PAYLOAD_OFFSET=0x200000 \
    FW_FDT_PATH=$W/rv_soc_linux.dtb \
    -j$NPROC 2>&1 | tail -8

FW=$OPENSBI/build/platform/generic/firmware/fw_payload
${XK}objcopy -O binary $FW.elf $W/$OUT.bin
${XK}objcopy -I binary -O verilog $W/$OUT.bin $W/$OUT.hex
echo "   $OUT.bin: $(stat -c %s $W/$OUT.bin) bytes"
echo "   $OUT.hex: $W/$OUT.hex"
echo "DONE"
