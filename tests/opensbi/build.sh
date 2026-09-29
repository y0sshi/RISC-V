#!/bin/bash
# =============================================================================
# build.sh - Build a real OpenSBI fw_payload image for the sim boot harness.
# Run inside the riscof_run docker (has riscv64-unknown-elf-gcc, dtc, make):
#   docker run --rm -v <repo>:/workspace -w /workspace/tests/opensbi \
#       riscof_run:latest bash build.sh
# Produces work/fw_payload.hex (base-relative verilog) -> load with:
#   cd src/sim && make sim_boot BOOT_HEX=/workspace/tests/opensbi/work/fw_payload.hex
# =============================================================================
set -e
HERE=$(pwd)                       # /workspace/tests/opensbi
W=$HERE/work
# FW_BASE = firmware/DDR base (= RST_ADDR = BFM BASE_ADDR).  Default 0x80000000
# reproduces every prior artifact byte-identically (proven non-destructive).
# Pass FW_BASE=0x00200000 (+ a base-matched DTS) to re-link for the real-HW
# PS-DDR base; OUT renames the hex so both can coexist in work/.
FW_BASE=${FW_BASE:-0x80000000}
OUT=${OUT:-fw_payload}
DTS=${DTS:-$HERE/../../docs/opensbi/rv_soc.dts}
XTOOL=riscv64-unknown-elf-
# payload link = FW_BASE + FW_PAYLOAD_OFFSET(0x200000); TOHOST = FW_BASE + 0x2000.
FW_LINK=$(printf '0x%x' $(( FW_BASE + 0x200000 )))
echo "== FW_BASE=$FW_BASE  FW_LINK=$FW_LINK  DTS=$(basename $DTS)  OUT=$OUT.hex =="

echo "== [1/4] S-mode payload =="
${XTOOL}gcc -march=rv64imac_zicsr -mabi=lp64 -nostdlib -nostartfiles -ffreestanding \
    -DFW_BASE=$FW_BASE -Wl,--defsym=FW_LINK=$FW_LINK \
    -T $HERE/payload.ld $HERE/payload.S -o $W/payload.elf
${XTOOL}objcopy -O binary $W/payload.elf $W/payload.bin
echo "   payload.bin: $(stat -c %s $W/payload.bin) bytes"

echo "== [2/4] Device tree blob =="
dtc -I dts -O dtb -o $W/rv_soc.dtb $DTS
echo "   rv_soc.dtb:  $(stat -c %s $W/rv_soc.dtb) bytes"

echo "== [3/4] OpenSBI generic fw_payload =="
# OpenSBI v1.2: builds non-PIE by default (-fno-pie), so the bare-metal (elf)
# linker -- which lacks -pie support -- works.  We load at the fixed link address
# FW_TEXT_START=$FW_BASE (= RST_ADDR).  distclean so a changed FW_TEXT_START
# fully re-links (the address is baked into the generated linker script).
make -C $W/opensbi distclean >/dev/null 2>&1 || true
make -C $W/opensbi PLATFORM=generic CROSS_COMPILE=$XTOOL \
    PLATFORM_RISCV_XLEN=64 PLATFORM_RISCV_ISA=rv64imac_zicsr_zifencei PLATFORM_RISCV_ABI=lp64 \
    FW_TEXT_START=$FW_BASE \
    FW_PAYLOAD=y FW_PAYLOAD_PATH=$W/payload.bin FW_FDT_PATH=$W/rv_soc.dtb \
    -j1 2>&1 | tail -12

echo "== [4/4] -> base-relative verilog hex =="
FW=$W/opensbi/build/platform/generic/firmware/fw_payload
${XTOOL}objcopy -O binary $FW.elf $W/$OUT.bin
${XTOOL}objcopy -I binary -O verilog $W/$OUT.bin $W/$OUT.hex
echo "   $OUT.bin: $(stat -c %s $W/$OUT.bin) bytes"
echo "   $OUT.hex: $W/$OUT.hex"
echo "DONE"
