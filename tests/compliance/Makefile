# =============================================================================
# Makefile - RISC-V Architectural Test runner for rv_soc
# =============================================================================

# --- Toolchain ---
RISCV_PREFIX ?= riscv64-unknown-elf-
CC       = $(RISCV_PREFIX)gcc
OBJCOPY  = $(RISCV_PREFIX)objcopy
OBJDUMP  = $(RISCV_PREFIX)objdump

# --- Directories ---
ROOT_DIR    := $(abspath ../..)
ENV_DIR     := $(ROOT_DIR)/tests/env
ARCH_TEST   := $(ROOT_DIR)/tests/riscv-arch-test
RISCV_TESTS := $(ROOT_DIR)/tests/riscv-tests
RESULTS_DIR := $(ROOT_DIR)/tests/results
SIM_DIR     := $(ROOT_DIR)/src/sim

# --- Target ISA ---
ISA    ?= rv64imafdc
ABI    ?= lp64d
TARGET ?= rv64gc

# --- Compile flags ---
CFLAGS  = -march=$(ISA) -mabi=$(ABI) -mcmodel=medany \
          -static -nostdlib -nostartfiles -fno-common \
          -I$(ENV_DIR) -I$(ARCH_TEST)/riscv-test-suite/env

LDFLAGS = -T$(ENV_DIR)/link_act.ld

# --- Common sources ---
CRT = $(ENV_DIR)/crt_act.S

# --- ACT suites ---
ACT_SUITES  = rv64i_m/I rv64i_m/M rv64i_m/A \
              rv64i_m/F rv64i_m/D rv64i_m/C \
              rv64i_m/Zicsr rv64i_m/privilege

# =============================================================================
# Default target
# =============================================================================
.PHONY: all clean act riscv-tests help

all: act

help:
	@echo "Usage:"
	@echo "  make act		 - Run riscv-arch-test (ACT)"
	@echo "  make riscv-tests - Run riscv-tests"
	@echo "  make TEST=<path> - Run single test"
	@echo "  make clean	   - Clean results"

# =============================================================================
# ACT: riscv-arch-test runner
# =============================================================================
act: $(RESULTS_DIR)
	@echo "=== Running riscv-arch-test ==="
	@total=0; pass=0; fail=0; \
	for suite in $(ACT_SUITES); do \
		for src in $(ARCH_TEST)/riscv-test-suite/$$suite/src/*.S; do \
			[ -f "$$src" ] || continue; \
			name=$$(basename $$src .S); \
			total=$$((total+1)); \
			if $(MAKE) --no-print-directory run-single \
				TEST_SRC=$$src TEST_NAME=$$name SUITE=$$suite \
				> $(RESULTS_DIR)/$$name.log 2>&1; then \
				pass=$$((pass+1)); \
				echo "  [PASS] $$suite/$$name"; \
			else \
				fail=$$((fail+1)); \
				echo "  [FAIL] $$suite/$$name"; \
			fi; \
		done; \
	done; \
	echo ""; \
	echo "=== Summary: $$pass/$$total passed, $$fail failed ==="

# =============================================================================
# Single-test runner (internal target)
#   1. Assemble -> ELF
#   2. ELF -> hex
#   3. Run simulation -> signature.output
#   4. Compare with reference.output
# =============================================================================
run-single:
	@mkdir -p $(RESULTS_DIR)/$(TEST_NAME)
	@# 1. Compile
	$(CC) $(CFLAGS) $(LDFLAGS) \
		-DXLEN=64 -DTEST_CASE_1=True \
		$(CRT) $(TEST_SRC) \
		-o $(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).elf
	@# 2. Generate hex (Verilog readmemh format)
	$(OBJCOPY) -O verilog \
		$(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).elf \
		$(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).hex
	@# 2.5 Disassembly (for debugging)
	$(OBJDUMP) -D $(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).elf \
		> $(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).dump
	@# 3. Run simulation
	cd $(SIM_DIR) && \
	$(MAKE) sim-act \
		HEX=$(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).hex \
		SIG=$(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).signature
	@# 4. Compare with reference
	@ref=$(ARCH_TEST)/riscv-test-suite/$(SUITE)/references/$(TEST_NAME).reference_output; \
	if [ -f "$$ref" ]; then \
		diff -w $$ref $(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).signature; \
	else \
		echo "WARN: reference not found: $$ref"; \
	fi

# =============================================================================
# riscv-tests: per-instruction tests
# =============================================================================
RISCV_TEST_LIST = rv64ui-p-add rv64ui-p-addi rv64ui-p-and rv64ui-p-andi \
				  rv64ui-p-auipc rv64ui-p-beq rv64ui-p-bge rv64ui-p-bgeu \
				  rv64ui-p-blt rv64ui-p-bltu rv64ui-p-bne rv64ui-p-jal \
				  rv64ui-p-jalr rv64ui-p-lb rv64ui-p-lbu rv64ui-p-lh \
				  rv64ui-p-lhu rv64ui-p-lw rv64ui-p-lwu rv64ui-p-ld \
				  rv64ui-p-or rv64ui-p-ori rv64ui-p-sb rv64ui-p-sh \
				  rv64ui-p-sw rv64ui-p-sd rv64ui-p-sll rv64ui-p-slli \
				  rv64ui-p-slt rv64ui-p-slti rv64ui-p-sltiu rv64ui-p-sltu \
				  rv64ui-p-sra rv64ui-p-srai rv64ui-p-srl rv64ui-p-srli \
				  rv64ui-p-sub rv64ui-p-xor rv64ui-p-xori \
				  rv64um-p-mul rv64um-p-mulh rv64um-p-mulhsu rv64um-p-mulhu \
				  rv64um-p-div rv64um-p-divu rv64um-p-rem rv64um-p-remu

riscv-tests: $(RESULTS_DIR)
	@echo "=== Running riscv-tests ==="
	@cd $(RISCV_TESTS) && [ -f Makefile ] || (autoconf && ./configure)
	@cd $(RISCV_TESTS) && $(MAKE) XLEN=64
	@total=0; pass=0; fail=0; \
	for t in $(RISCV_TEST_LIST); do \
		elf=$(RISCV_TESTS)/isa/$$t; \
		[ -f "$$elf" ] || continue; \
		total=$$((total+1)); \
		$(OBJCOPY) -O verilog $$elf $(RESULTS_DIR)/$$t.hex; \
		if cd $(SIM_DIR) && $(MAKE) sim-act \
			HEX=$(RESULTS_DIR)/$$t.hex \
			SIG=$(RESULTS_DIR)/$$t.sig \
			> $(RESULTS_DIR)/$$t.log 2>&1; then \
			if grep -q "PASS" $(RESULTS_DIR)/$$t.log; then \
				pass=$$((pass+1)); echo "  [PASS] $$t"; \
			else \
				fail=$$((fail+1)); echo "  [FAIL] $$t"; \
			fi; \
		else \
			fail=$$((fail+1)); echo "  [FAIL] $$t (sim error)"; \
		fi; \
	done; \
	echo "=== Summary: $$pass/$$total passed ==="

# =============================================================================
# Utility
# =============================================================================
$(RESULTS_DIR):
	mkdir -p $@

clean:
	rm -rf $(RESULTS_DIR)

