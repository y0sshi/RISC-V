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
DTS=$HERE/../../docs/opensbi/rv_soc.dts
XTOOL=riscv64-unknown-elf-

echo "== [1/4] S-mode payload =="
${XTOOL}gcc -march=rv64imac_zicsr -mabi=lp64 -nostdlib -nostartfiles -ffreestanding \
    -T $HERE/payload.ld $HERE/payload.S -o $W/payload.elf
${XTOOL}objcopy -O binary $W/payload.elf $W/payload.bin
echo "   payload.bin: $(stat -c %s $W/payload.bin) bytes"

echo "== [2/4] Device tree blob =="
dtc -I dts -O dtb -o $W/rv_soc.dtb $DTS
echo "   rv_soc.dtb:  $(stat -c %s $W/rv_soc.dtb) bytes"

echo "== [3/4] OpenSBI generic fw_payload =="
# OpenSBI v1.2: builds non-PIE by default (-fno-pie), so the bare-metal (elf)
# linker -- which lacks -pie support -- works.  We load at the fixed link address
# FW_TEXT_START=0x80000000 (= RST_ADDR).
make -C $W/opensbi PLATFORM=generic CROSS_COMPILE=$XTOOL \
    PLATFORM_RISCV_XLEN=64 PLATFORM_RISCV_ISA=rv64imac_zicsr_zifencei PLATFORM_RISCV_ABI=lp64 \
    FW_TEXT_START=0x80000000 \
    FW_PAYLOAD=y FW_PAYLOAD_PATH=$W/payload.bin FW_FDT_PATH=$W/rv_soc.dtb \
    -j1 2>&1 | tail -12

echo "== [4/4] -> base-relative verilog hex =="
FW=$W/opensbi/build/platform/generic/firmware/fw_payload
${XTOOL}objcopy -O binary $FW.elf $W/fw_payload.bin
${XTOOL}objcopy -I binary -O verilog $W/fw_payload.bin $W/fw_payload.hex
echo "   fw_payload.bin: $(stat -c %s $W/fw_payload.bin) bytes"
echo "   fw_payload.hex: $W/fw_payload.hex"
echo "DONE"
