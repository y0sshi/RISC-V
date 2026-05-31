#!/usr/bin/env bash
# DUT runner for one architectural test (invoked by riscof_rvcore.py make targets).
# Keeps all shell-level $(...) / $VAR out of the RISCOF-generated Makefile (where
# `$(...)` would be interpreted by make, not the shell).
#
# args: <march> <abi> <macros> <test.S> <elf> <hex> <sig> <rv_root> <plugin_env> <archtest_env> <xlen_def>
set -e
MARCH=$1; ABI=$2; MACROS=$3; TEST=$4; ELF=$5; HEXF=$6; SIG=$7
RVROOT=$8; PENV=$9; AENV=${10}; XLENDEF=${11}
PFX=riscv64-unknown-elf-
R="$RVROOT/src/rtl"

# 1. compile (MACROS is intentionally unquoted: it is a space-separated -D list)
${PFX}gcc -march="$MARCH" -mabi="$ABI" -mcmodel=medany -static -nostdlib -nostartfiles \
    -fno-common -T "$PENV/link.ld" -I "$PENV" -I "$AENV" $MACROS "$TEST" -o "$ELF"

# 2. ELF -> Verilog hex (relocate so rv_unified_mem loads at 0x8000_0000)
${PFX}objcopy -O verilog --change-addresses -0x80000000 "$ELF" "$HEXF"

# 3. signature region + tohost symbols
B=$(${PFX}objdump -t "$ELF" | grep " begin_signature" | awk '{print $1}')
E=$(${PFX}objdump -t "$ELF" | grep " end_signature"   | awk '{print $1}')
T=$(${PFX}objdump -t "$ELF" | grep " tohost$"         | awk '{print $1}'); T=${T:-80001000}

# 4. iverilog-compile the ACT testbench with the full RTL source list
iverilog -g2012 -I "$R/include" -DRISCV_FORMAL $XLENDEF -DACT_MODE \
    -DHEX_FILE=\""$HEXF"\" -DSIG_FILE=\""$SIG"\" \
    -DBEGIN_SIG=\""$B"\" -DEND_SIG=\""$E"\" -DTOHOST_ADDR=\""$T"\" \
    -o "$ELF.vvp" \
    "$R/include/rv_pkg.sv" \
    "$R/core/rv_regfile.sv" "$R/core/rv_fregfile.sv" "$R/core/rv_cdecode.sv" \
    "$R/core/rv_decode.sv" "$R/core/rv_branch.sv" "$R/alu/rv_alu.sv" \
    "$R/core/rv_muldiv.sv" "$R/core/rv_amo.sv" "$R/core/rv_forward.sv" \
    "$R/core/rv_csr.sv" "$R/core/rv_hazard.sv" "$R/core/rv_mmu.sv" \
    "$R/fpu/rv_fpu_add.sv" "$R/fpu/rv_fpu_mul.sv" "$R/fpu/rv_fpu_div.sv" \
    "$R/fpu/rv_fpu_sqrt.sv" "$R/fpu/rv_fpu_misc.sv" "$R/fpu/rv_fpu_add_d.sv" \
    "$R/fpu/rv_fpu_mul_d.sv" "$R/fpu/rv_fpu_div_d.sv" "$R/fpu/rv_fpu_sqrt_d.sv" \
    "$R/fpu/rv_fpu_misc_d.sv" "$R/fpu/rv_fpu.sv" \
    "$R/core/rv_core.sv" "$R/memory/rv_unified_mem.sv" "$R/soc/rv_soc.sv" \
    "$RVROOT/src/sim/tb/tb_rv_act.sv"

# 5. run
vvp "$ELF.vvp"
