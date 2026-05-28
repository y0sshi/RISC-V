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

.PHONY: hello sim_hello

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
