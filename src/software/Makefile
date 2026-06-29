# =============================================================================
# Makefile - RISC-V Software Build
# =============================================================================
# Cross-compile assembly/C programs to hex files for loading into simulation.
#
# Requirements:
#   - riscv64-unknown-elf-gcc (or riscv32-unknown-elf-gcc) toolchain
#
# Usage:
#   make all          Build all test programs
#   make clean        Remove generated files
# =============================================================================
## Directory Path
MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
PARENT_DIR   := $(shell dirname $(MAKEFILE_DIR))
PROJECT_ROOT := $(shell dirname $(PARENT_DIR))

# Docker image
DOCKER_IMAGE := riscv_gcc:latest
# Attach a pseudo-TTY only when stdout is connected to a real terminal.
# This allows `make` to work both interactively (-it) and in non-TTY
# environments such as CI pipelines or tool invocations (-i only).
ifeq ($(OS),Windows_NT)
DOCKER_TTY := $(shell powershell -Command "if (-not [Console]::IsInputRedirected) { Write-Output '-t' }")
else
DOCKER_TTY := $(shell test -t 0 && echo -t)
endif
DOCKER_RUN := docker run --rm -i $(DOCKER_TTY) \
                -v $(MAKEFILE_DIR):/workspace \
                $(DOCKER_IMAGE)

# Toolchain prefix (adjust if using a different toolchain)
CROSS    ?= riscv64-unknown-elf-
CC        = $(CROSS)gcc
AS        = $(CROSS)as
LD        = $(CROSS)ld
OBJCOPY   = $(CROSS)objcopy
OBJDUMP   = $(CROSS)objdump

# Architecture flags
SPECS    ?= picolibc.specs
ARCH     ?= rv32i
ABI      ?= ilp32
CFLAGS    = --specs=$(SPECS) -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -ffreestanding
LDFLAGS   = -T link.ld -nostdlib

# Directories
TEST_DIR  = tests
BUILD_DIR = build

# Source files
TEST_SRCS = $(wildcard $(TEST_DIR)/*.s)
TEST_ELFS = $(patsubst $(TEST_DIR)/%.s,$(BUILD_DIR)/%.elf,$(TEST_SRCS))
TEST_HEXS = $(patsubst $(BUILD_DIR)/%.elf,$(TEST_DIR)/%.hex,$(TEST_ELFS))
TEST_DUMPS= $(patsubst $(BUILD_DIR)/%.elf,$(BUILD_DIR)/%.dump,$(TEST_ELFS))

# =============================================================================
# Targets
# =============================================================================

.PHONY: all image clean dirs

all: dirs $(TEST_HEXS) $(TEST_DUMPS)

dirs:
	@mkdir -p $(BUILD_DIR)

image:
	docker build -t $(DOCKER_IMAGE) .

# Assembly -> ELF
$(BUILD_DIR)/%.elf: $(TEST_DIR)/%.s link.ld
	$(DOCKER_RUN) $(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

# ELF -> HEX (for $readmemh)
$(TEST_DIR)/%.hex: $(BUILD_DIR)/%.elf
	$(DOCKER_RUN) $(OBJCOPY) -O verilog $< $@

# ELF -> Disassembly (for debugging)
$(BUILD_DIR)/%.dump: $(BUILD_DIR)/%.elf
	$(DOCKER_RUN) $(OBJDUMP) -d $< > $@

clean:
	$(DOCKER_RUN) rm -rf $(BUILD_DIR)
	$(DOCKER_RUN) rm -f $(TEST_DIR)/*.hex
	$(DOCKER_RUN) rm -f *.elf *.hex *.dump

# =============================================================================
# C / ベアメタルプログラム (newlib + crt0.S + rv_soc.ld)
# =============================================================================
# Usage:
#   make hello          Hello World ビルド → hello_imem.hex + hello_dmem.hex
#   make hello.dump     逆アセンブルリスト
#   make sim_hello      ビルド + iverilog シミュレーション実行
#
# 注意: -march=rv32im で RVC (C拡張) を無効化。rv_soc は C拡張未実装のため必須。

C_CROSS   = riscv64-unknown-elf
C_CC      = $(C_CROSS)-gcc
C_OBJCOPY = $(C_CROSS)-objcopy
C_OBJDUMP = $(C_CROSS)-objdump
C_SIZE    = $(C_CROSS)-size

C_ARCH    = rv32im_zicsr
C_ABI     = ilp32
C_STARTUP = startup

C_CFLAGS  = --specs=picolibc.specs
C_CFLAGS += -march=$(C_ARCH) -mabi=$(C_ABI)
C_CFLAGS += -nostartfiles
C_CFLAGS += -O1 -g -Wall -Wextra
C_CFLAGS += -ffunction-sections -fdata-sections

C_LDFLAGS = -T $(C_STARTUP)/rv_soc.ld
C_LDFLAGS += -Wl,--gc-sections
C_LIBS    = -lgcc

C_STARTUP_SRC = $(C_STARTUP)/crt0.S $(C_STARTUP)/syscalls.c $(C_STARTUP)/uart.c

SIM_DIR = ../sim

.PHONY: hello sim_hello boot boot_lo stack_test atomic_test lrsc_irq_test div_irq_test div_mem_irq_test div_cachemiss_test mal_cachemiss_test mal_load_irq_test ptw_amo_test skid_redirect_test skid_ptw_test skid_ptwfault_test

# ----- skid_ptwfault_test: redirect to a mod4==2 target that page-faults first
# The faithful repro: an instruction page fault on a mid-word redirect target,
# then a re-fetch after the handler maps the page, loses skip_low.  See memory
# userspace-compiled-binary-bug.
#   make skid_ptwfault_test  &&  (cd ../sim && rm -rf out/vl_boot && make vl_boot \
#     BOOT_HEX=../software/boot/skid_ptwfault_test.hex BOOT_MAX=2000000)
skid_ptwfault_test: boot/skid_ptwfault_test.hex

boot/skid_ptwfault_test.elf: boot/skid_ptwfault_test.S boot/boot.ld
	$(DOCKER_RUN) riscv64-unknown-elf-gcc -march=rv64imac_zicsr_zifencei -mabi=lp64 \
	    -nostdlib -nostartfiles -ffreestanding -T boot/boot.ld boot/skid_ptwfault_test.S -o boot/skid_ptwfault_test.elf

boot/skid_ptwfault_test.hex: boot/skid_ptwfault_test.elf
	$(DOCKER_RUN) riscv64-unknown-elf-objcopy -O verilog \
	    --adjust-vma=-0x80000000 boot/skid_ptwfault_test.elf boot/skid_ptwfault_test.hex
	@echo "  skid_ptwfault_test hex: $@"

# ----- skid_redirect_test: trap-return (mret) to a mod4==2 target ------------
# Reproducer for the userspace-compiled-binary bug: the step8 fetch skip_low
# (drop the leading halfword of the first post-redirect word for a mid-word
# target) is lost on a multi-cycle target fetch, so a redirect to a 2-byte-
# aligned PC executes the halfword 2 bytes early.  c.ebreak sits at target-2;
# a skid traps -> FAIL, correct skip_low -> DONE.  See memory
# userspace-compiled-binary-bug.
#   make skid_redirect_test  &&  (cd ../sim && rm -rf out/vl_boot && make vl_boot \
#     BOOT_HEX=../software/boot/skid_redirect_test.hex BOOT_MAX=2000000)
skid_redirect_test: boot/skid_redirect_test.hex

boot/skid_redirect_test.elf: boot/skid_redirect_test.S boot/boot.ld
	$(DOCKER_RUN) riscv64-unknown-elf-gcc -march=rv64imac_zicsr_zifencei -mabi=lp64 \
	    -nostdlib -nostartfiles -ffreestanding -T boot/boot.ld boot/skid_redirect_test.S -o boot/skid_redirect_test.elf

boot/skid_redirect_test.hex: boot/skid_redirect_test.elf
	$(DOCKER_RUN) riscv64-unknown-elf-objcopy -O verilog \
	    --adjust-vma=-0x80000000 boot/skid_redirect_test.elf boot/skid_redirect_test.hex
	@echo "  skid_redirect_test hex: $@"

# ----- skid_ptw_test: redirect to a mod4==2 target whose fetch IF-PTWs --------
# The MMU variant of skid_redirect_test (which PASSes): a cold-TLB IF-PTW on a
# mid-word redirect target is the trigger that loses skip_low (a plain I$ miss is
# not).  Mirrors Linux's first sret to a musl entry at mod4==2.  See memory
# userspace-compiled-binary-bug.
#   make skid_ptw_test  &&  (cd ../sim && rm -rf out/vl_boot && make vl_boot \
#     BOOT_HEX=../software/boot/skid_ptw_test.hex BOOT_MAX=2000000)
skid_ptw_test: boot/skid_ptw_test.hex

boot/skid_ptw_test.elf: boot/skid_ptw_test.S boot/boot.ld
	$(DOCKER_RUN) riscv64-unknown-elf-gcc -march=rv64imac_zicsr_zifencei -mabi=lp64 \
	    -nostdlib -nostartfiles -ffreestanding -T boot/boot.ld boot/skid_ptw_test.S -o boot/skid_ptw_test.elf

boot/skid_ptw_test.hex: boot/skid_ptw_test.elf
	$(DOCKER_RUN) riscv64-unknown-elf-objcopy -O verilog \
	    --adjust-vma=-0x80000000 boot/skid_ptw_test.elf boot/skid_ptw_test.hex
	@echo "  skid_ptw_test hex: $@"

# ----- ptw_amo_test: AMO write-loss when an IF-PTW masks the D$ wait -----
# Focused reproducer for the real-HW netlink atomic_dec loss (rv_soc.sv:364
# core_dmem_wait = ptw_req ? 0 : dc_c_wait masks an in-flight D$ access for ANY
# ptw_req, incl. an instruction-fetch PTW).  Sv39 ON, amoadd.w at a code-page
# end so the next fetch IF-PTWs during the AMO's D$ fill -> the write is lost
# and the counter invariant breaks.  MMU-gated, so all M-mode tests miss it.
#   make ptw_amo_test  &&  (cd ../sim && rm -rf out/vl_boot && make vl_boot \
#     BOOT_HEX=../software/boot/ptw_amo_test.hex \
#     VL_FLAGS="<defaults> -DBOOT_AR_DELAY=50 -DBOOT_R_DELAY=4")
ptw_amo_test: boot/ptw_amo_test.hex

boot/ptw_amo_test.elf: boot/ptw_amo_test.S boot/boot.ld
	$(DOCKER_RUN) riscv64-unknown-elf-gcc -march=rv64imac_zicsr -mabi=lp64 \
	    -nostdlib -nostartfiles -ffreestanding -T boot/boot.ld boot/ptw_amo_test.S -o boot/ptw_amo_test.elf

boot/ptw_amo_test.hex: boot/ptw_amo_test.elf
	$(DOCKER_RUN) riscv64-unknown-elf-objcopy -O verilog \
	    --adjust-vma=-0x80000000 boot/ptw_amo_test.elf boot/ptw_amo_test.hex
	@echo "  ptw_amo_test hex: $@"

# ----- mal_cachemiss_test: misaligned 8-byte access retiring while I$ not ready
# Reproducer for RTL bug #15 (mal_state restart-livelock): a misaligned 8-byte
# store/load completes its 2-phase access on a cycle ~imem_ready is low (the
# timer-IRQ handler entry is a cold I$ fetch -> line-fill), so the old RTL
# resets mal_state and restarts phase 0 forever.  Old RTL livelocks (timeout);
# fixed RTL PASS.
#   make mal_cachemiss_test  &&  (cd ../sim && make vl_boot \
#     BOOT_HEX=../software/boot/mal_cachemiss_test.hex)
mal_cachemiss_test: boot/mal_cachemiss_test.hex

boot/mal_cachemiss_test.elf: boot/mal_cachemiss_test.S boot/boot.ld
	$(DOCKER_RUN) riscv64-unknown-elf-gcc -march=rv64imac_zicsr -mabi=lp64 \
	    -nostdlib -nostartfiles -ffreestanding -T boot/boot.ld boot/mal_cachemiss_test.S -o boot/mal_cachemiss_test.elf

boot/mal_cachemiss_test.hex: boot/mal_cachemiss_test.elf
	$(DOCKER_RUN) riscv64-unknown-elf-objcopy -O verilog \
	    --adjust-vma=-0x80000000 boot/mal_cachemiss_test.elf boot/mal_cachemiss_test.hex
	@echo "  mal_cachemiss_test hex: $@"

# ----- mal_load_irq_test: misaligned 8-byte LOAD vs timer IRQ under a D$ miss --
# Candidate-bug reproducer (separate from #15, which is fixed): a timer interrupt
# landing on a misaligned 8-byte load while it takes a D$ miss appears to return
# a STALE value (previous iteration).  Data-verifies the main-loop load.
#   make mal_load_irq_test  &&  (cd ../sim && make vl_boot \
#     BOOT_HEX=../software/boot/mal_load_irq_test.hex)
mal_load_irq_test: boot/mal_load_irq_test.hex

boot/mal_load_irq_test.elf: boot/mal_load_irq_test.S boot/boot.ld
	$(DOCKER_RUN) riscv64-unknown-elf-gcc -march=rv64imac_zicsr -mabi=lp64 \
	    -nostdlib -nostartfiles -ffreestanding -T boot/boot.ld boot/mal_load_irq_test.S -o boot/mal_load_irq_test.elf

boot/mal_load_irq_test.hex: boot/mal_load_irq_test.elf
	$(DOCKER_RUN) riscv64-unknown-elf-objcopy -O verilog \
	    --adjust-vma=-0x80000000 boot/mal_load_irq_test.elf boot/mal_load_irq_test.hex
	@echo "  mal_load_irq_test hex: $@"

# ----- div_cachemiss_test: divide starting while a prior load/store dmem_waits -
div_cachemiss_test: boot/div_cachemiss_test.hex

boot/div_cachemiss_test.elf: boot/div_cachemiss_test.S boot/boot.ld
	$(DOCKER_RUN) riscv64-unknown-elf-gcc -march=rv64imac_zicsr -mabi=lp64 \
	    -nostdlib -nostartfiles -ffreestanding -T boot/boot.ld boot/div_cachemiss_test.S -o boot/div_cachemiss_test.elf

boot/div_cachemiss_test.hex: boot/div_cachemiss_test.elf
	$(DOCKER_RUN) riscv64-unknown-elf-objcopy -O verilog \
	    --adjust-vma=-0x80000000 boot/div_cachemiss_test.elf boot/div_cachemiss_test.hex
	@echo "  div_cachemiss_test hex: $@"

# ----- div_mem_irq_test: loads/stores adjacent to divides vs timer IRQ -----
div_mem_irq_test: boot/div_mem_irq_test.hex

boot/div_mem_irq_test.elf: boot/div_mem_irq_test.S boot/boot.ld
	$(DOCKER_RUN) riscv64-unknown-elf-gcc -march=rv64imac_zicsr -mabi=lp64 \
	    -nostdlib -nostartfiles -ffreestanding -T boot/boot.ld boot/div_mem_irq_test.S -o boot/div_mem_irq_test.elf

boot/div_mem_irq_test.hex: boot/div_mem_irq_test.elf
	$(DOCKER_RUN) riscv64-unknown-elf-objcopy -O verilog \
	    --adjust-vma=-0x80000000 boot/div_mem_irq_test.elf boot/div_mem_irq_test.hex
	@echo "  div_mem_irq_test hex: $@"

# ----- div_irq_test: multi-cycle divide vs timer interrupt (C-2a) -----
# Timer interrupt sweeps into a divide loop; the handler runs its own divide
# (dirtying the shared div_result register).  Every quotient/remainder must
# stay correct.  Fails if the interrupt-at-divide interaction corrupts a result.
#   make div_irq_test  &&  (cd ../sim && make vl_boot \
#     BOOT_HEX=../software/boot/div_irq_test.hex)
div_irq_test: boot/div_irq_test.hex

boot/div_irq_test.elf: boot/div_irq_test.S boot/boot.ld
	$(DOCKER_RUN) riscv64-unknown-elf-gcc -march=rv64imac_zicsr -mabi=lp64 \
	    -nostdlib -nostartfiles -ffreestanding -T boot/boot.ld boot/div_irq_test.S -o boot/div_irq_test.elf

boot/div_irq_test.hex: boot/div_irq_test.elf
	$(DOCKER_RUN) riscv64-unknown-elf-objcopy -O verilog \
	    --adjust-vma=-0x80000000 boot/div_irq_test.elf boot/div_irq_test.hex
	@echo "  div_irq_test hex: $@"

# ----- lrsc_irq_test: LR/SC reservation vs trap/interrupt (lost update) -----
# Timer interrupt lands between LR and SC; the handler AMOs the same address.
# Fails on RTL where the reservation survives traps/xRET (the SC then succeeds
# with the pre-trap value, losing the handler's update -- the Linux refcount
# corruption, 2026-06-10).
#   make lrsc_irq_test  &&  (cd ../sim && make vl_boot \
#     BOOT_HEX=../software/boot/lrsc_irq_test.hex)
lrsc_irq_test: boot/lrsc_irq_test.hex

boot/lrsc_irq_test.elf: boot/lrsc_irq_test.S boot/boot.ld
	$(DOCKER_RUN) riscv64-unknown-elf-gcc -march=rv64imac_zicsr -mabi=lp64 \
	    -nostdlib -nostartfiles -ffreestanding -T boot/boot.ld boot/lrsc_irq_test.S -o boot/lrsc_irq_test.elf

boot/lrsc_irq_test.hex: boot/lrsc_irq_test.elf
	$(DOCKER_RUN) riscv64-unknown-elf-objcopy -O verilog \
	    --adjust-vma=-0x80000000 boot/lrsc_irq_test.elf boot/lrsc_irq_test.hex
	@echo "  lrsc_irq_test hex: $@"

# ----- atomic_test: AMO / LR-SC stress under the cached path -----
# Per-iteration return-value checks on amoadd.d / lr.d-sc.d / amoxor.d with the
# counter line force-evicted each iteration (direct-mapped aliasing loads) and a
# write-through store draining right before the next AMO.  Repro harness for the
# Linux printk-ringbuffer/refcount atomic-corruption suspicion (2026-06-10).
#   make atomic_test  &&  (cd ../sim && make vl_boot \
#     BOOT_HEX=../software/boot/atomic_test.hex)
atomic_test: boot/atomic_test.hex

boot/atomic_test.elf: boot/atomic_test.S boot/boot.ld
	$(DOCKER_RUN) riscv64-unknown-elf-gcc -march=rv64imac_zicsr -mabi=lp64 \
	    -nostdlib -nostartfiles -ffreestanding -T boot/boot.ld boot/atomic_test.S -o boot/atomic_test.elf

boot/atomic_test.hex: boot/atomic_test.elf
	$(DOCKER_RUN) riscv64-unknown-elf-objcopy -O verilog \
	    --adjust-vma=-0x80000000 boot/atomic_test.elf boot/atomic_test.hex
	@echo "  atomic_test hex: $@"

# ----- stack_test: minimal reproducer for the variable-latency stack bug -----
# Hammers the prologue/epilogue (sd ra/s0 ; recursive call ; ld ra/s0 ; ret)
# pattern that corrupted the stack pointer under the AXI/cache path (the bug that
# blocked real OpenSBI; fixed 2026-06-05).  Boots in tb_rv_boot_soc like the
# firmware:  make stack_test  &&  (cd ../sim && make sim_boot \
#   BOOT_HEX=../software/boot/stack_test.hex)
stack_test: boot/stack_test.hex

boot/stack_test.elf: boot/stack_test.S boot/boot.ld
	$(DOCKER_RUN) riscv64-unknown-elf-gcc -march=rv64imac_zicsr -mabi=lp64 \
	    -nostdlib -nostartfiles -ffreestanding -T boot/boot.ld boot/stack_test.S -o boot/stack_test.elf

boot/stack_test.hex: boot/stack_test.elf
	$(DOCKER_RUN) riscv64-unknown-elf-objcopy -O verilog \
	    --adjust-vma=-0x80000000 boot/stack_test.elf boot/stack_test.hex
	@echo "  stack_test hex: $@"

# ----- mini-SBI boot firmware (OpenSBI stand-in for tb_rv_boot_soc) -----
# RV64, linked at the DDR base 0x8000_0000, emitted as a base-relative verilog
# hex (objcopy --adjust-vma) so rv_axi_dualport_mem_bfm can $readmemh it.
#   make boot   ->  boot/sbi_boot.hex   ;   then:  (cd ../sim && make sim_boot)
# FW_LINK_BASE = the DDR link/entry base (== RST_ADDR).  Defaults to the sim base
# 0x8000_0000; the `boot_lo` target overrides it to the Zybo PS-DDR base
# 0x0020_0000 so the SAME mini-SBI can be sanity-checked at the HW base in sim
# (run with: cd ../sim && make vl_boot BOOT_HEX=../software/boot/sbi_boot_lo.hex
#  VL_FLAGS="<defaults> -DBOOT_MEM_BASE=2097152").  FW_BASE (-> TOHOST), the link
# base (--defsym __BASE) and objcopy --adjust-vma all follow it.
FW_LINK_BASE ?= 0x80000000

boot: boot/sbi_boot.hex

boot/sbi_boot.elf: boot/sbi_boot.S boot/boot.ld
	$(DOCKER_RUN) riscv64-unknown-elf-gcc -march=rv64imac_zicsr -mabi=lp64 \
	    -nostdlib -nostartfiles -ffreestanding -DFW_BASE=$(FW_LINK_BASE) \
	    -Wl,--defsym,__BASE=$(FW_LINK_BASE) -T boot/boot.ld boot/sbi_boot.S -o boot/sbi_boot.elf

boot/sbi_boot.hex: boot/sbi_boot.elf
	$(DOCKER_RUN) riscv64-unknown-elf-objcopy -O verilog \
	    --adjust-vma=-$(FW_LINK_BASE) boot/sbi_boot.elf boot/sbi_boot.hex

# Same mini-SBI re-linked to the Zybo PS-DDR base (0x0020_0000) -> sbi_boot_lo.hex.
boot_lo: boot/sbi_boot_lo.hex

boot/sbi_boot_lo.elf: boot/sbi_boot.S boot/boot.ld
	$(DOCKER_RUN) riscv64-unknown-elf-gcc -march=rv64imac_zicsr -mabi=lp64 \
	    -nostdlib -nostartfiles -ffreestanding -DFW_BASE=0x00200000 \
	    -Wl,--defsym,__BASE=0x00200000 -T boot/boot.ld boot/sbi_boot.S -o boot/sbi_boot_lo.elf

boot/sbi_boot_lo.hex: boot/sbi_boot_lo.elf
	$(DOCKER_RUN) riscv64-unknown-elf-objcopy -O verilog \
	    --adjust-vma=-0x00200000 boot/sbi_boot_lo.elf boot/sbi_boot_lo.hex
	@echo "  boot firmware hex (Zybo DDR base 0x00200000): $@"
	@echo "  boot firmware hex: $@"



# ----- Hello World -----
hello: hello_imem.hex hello_dmem.hex

hello.elf: $(C_STARTUP_SRC) hello/main.c
	$(DOCKER_RUN) $(C_CC) $(C_CFLAGS) $(C_LDFLAGS) $^ $(C_LIBS) -o $@
	@echo "" && $(C_SIZE) $@ && echo ""

# IMEM hex: .text のみ抽出
hello_imem.hex: hello.elf
	$(DOCKER_RUN) $(C_OBJCOPY) -j .text \
	    -O verilog --verilog-data-width=4 $< $@
	@echo "  IMEM hex: $@"

# DMEM hex: .rodata + .data を抽出し VMA を -0x8000_0000 シフト
# (rv_dmem は word_addr = addr[13:2] で DMEM先頭=word0 になるため補正が必要)
hello_dmem.hex: hello.elf
	$(DOCKER_RUN) $(C_OBJCOPY) \
	    -j .rodata -j .srodata -j .data -j .sdata \
	    --adjust-vma=-0x80000000 \
	    -O verilog --verilog-data-width=4 $< $@ 2>/dev/null; \
	[ -s $@ ] || printf "/* empty */\n" > $@
	@echo "  DMEM hex: $@"

hello.dump: hello.elf
	$(DOCKER_RUN) $(C_OBJDUMP) -d -M no-aliases -S $< > $@
	@echo "  Disasm:   $@"

# ----- シミュレーション (tb_rv_bm.sv 使用: UART 出力モニター) -----
sim_hello: hello
	$(DOCKER_RUN) $(MAKE) -C $(SIM_DIR) sim_bm \
	    BM_IMEM=$(abspath hello_imem.hex) \
	    BM_DMEM=$(abspath hello_dmem.hex)
