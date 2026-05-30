# =============================================================================
# Makefile - RISC-V Architectural Test runner for rv_soc (Docker version)
# =============================================================================

# --- Directory Path ---
MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
PARENT_DIR   := $(shell dirname $(MAKEFILE_DIR))
PROJECT_ROOT := $(shell dirname $(PARENT_DIR))

# --- Docker ---
DOCKER_IMAGE := riscv_act:latest
# Attach a pseudo-TTY only when stdout is connected to a real terminal.
# This allows `make` to work both interactively (-it) and in non-TTY
# environments such as CI pipelines or tool invocations (-i only).
ifeq ($(OS),Windows_NT)
DOCKER_TTY := $(shell powershell -Command "if (-not [Console]::IsInputRedirected) { Write-Output '-t' }")
else
DOCKER_TTY := $(shell test -t 0 && echo -t)
endif
DOCKER_RUN := docker run --rm -i $(DOCKER_TTY) \
                -v $(PROJECT_ROOT):/workspace \
                -w /workspace/tests/compliance \
                $(DOCKER_IMAGE)

# --- Toolchain (executed inside container) ---
RISCV_PREFIX ?= riscv64-unknown-elf-
CC           := $(RISCV_PREFIX)gcc
OBJCOPY      := $(RISCV_PREFIX)objcopy
OBJDUMP      := $(RISCV_PREFIX)objdump

# --- Directories (host paths, mounted as /workspace inside container) ---
ROOT_DIR    := /workspace
ENV_DIR     := $(ROOT_DIR)/tests/env
ARCH_TEST   := $(ROOT_DIR)/tests/riscv-arch-test
RISCV_TESTS := $(ROOT_DIR)/tests/riscv-tests
RESULTS_DIR := $(ROOT_DIR)/tests/results
SIM_DIR     := $(ROOT_DIR)/src/sim

# --- Target ISA ---
ISA ?= rv64imafdc
ABI ?= lp64d

# --- Compile flags ---
CFLAGS = -march=$(ISA) -mabi=$(ABI) -mcmodel=medany \
         -static -nostdlib -nostartfiles -fno-common \
         -I$(ENV_DIR) -I$(ARCH_TEST)/riscv-test-suite/env

LDFLAGS = -T$(ENV_DIR)/link_act.ld

CRT = $(ENV_DIR)/crt_act.S

ACT_SUITES = rv64i_m/I rv64i_m/M rv64i_m/A \
             rv64i_m/F rv64i_m/D rv64i_m/C \
             rv64i_m/Zicsr rv64i_m/privilege

# =============================================================================
# Targets
# =============================================================================
.PHONY: all clean act riscv-tests riscv-tests-build riscv-tests-run help shell image

all: act

help:
	@echo "Usage:"
	@echo "  make act               - Run riscv-arch-test (ACT)"
	@echo "  make riscv-tests       - Build ELFs then run simulation (rv64ui/um/ua/uf/ud/si-p)"
	@echo "  make riscv-tests-build - Build ELFs only (compile inside container)"
	@echo "  make riscv-tests-run   - Run simulation only (requires pre-built ELFs)"
	@echo "  make run-single        - Run single test (TEST_SRC, TEST_NAME, SUITE)"
	@echo "  make shell             - Open shell inside container (for debugging)"
	@echo "  make clean             - Clean results"

# Open container shell for manual debugging
shell:
	docker run --rm -it \
		-v $(PROJECT_ROOT):/workspace \
		-w /workspace/tests/compliance \
		$(DOCKER_IMAGE) bash

image:
	docker build -t $(DOCKER_IMAGE) .

# =============================================================================
# ACT runner
# =============================================================================
act:
	@mkdir -p $(PROJECT_ROOT)/tests/results
	$(DOCKER_RUN) bash -c '\
		total=0; pass=0; fail=0; \
		for suite in $(ACT_SUITES); do \
			for src in $(ARCH_TEST)/riscv-test-suite/$$suite/src/*.S; do \
				[ -f "$$src" ] || continue; \
				name=$$(basename $$src .S); \
				total=$$(($$total+1)); \
				if make -f /workspace/tests/compliance/Makefile \
					--no-print-directory run-single-internal \
					TEST_SRC=$$src TEST_NAME=$$name SUITE=$$suite \
					> $(RESULTS_DIR)/$$name.log 2>&1; then \
					pass=$$(($$pass+1)); \
					echo "  [PASS] $$suite/$$name"; \
				else \
					fail=$$(($$fail+1)); \
					echo "  [FAIL] $$suite/$$name"; \
				fi; \
			done; \
		done; \
		echo ""; \
		echo "=== Summary: $$pass/$$total passed, $$fail failed ===" \
	'

# --- Single-test runner (host entry point - re-enters container) ---
run-single:
	@mkdir -p $(PROJECT_ROOT)/tests/results
	$(DOCKER_RUN) make -f /workspace/tests/compliance/Makefile \
		run-single-internal \
		TEST_SRC=$(TEST_SRC) TEST_NAME=$(TEST_NAME) SUITE=$(SUITE)

# --- Internal: actual build/sim steps (executed inside container) ---
run-single-internal:
	@mkdir -p $(RESULTS_DIR)/$(TEST_NAME)
	$(CC) $(CFLAGS) $(LDFLAGS) \
		-DXLEN=64 -DTEST_CASE_1=True \
		$(CRT) $(TEST_SRC) \
		-o $(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).elf
	$(OBJCOPY) -O verilog --change-addresses -0x80000000 \
		$(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).elf \
		$(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).hex
	$(OBJDUMP) -D $(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).elf \
		> $(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).dump
	@BEGIN_SIG=$$( $(OBJDUMP) -t $(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).elf | grep " begin_signature" | awk "{print \$$1}" ); \
	END_SIG=$$( $(OBJDUMP) -t $(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).elf | grep " end_signature" | awk "{print \$$1}" ); \
	cd $(SIM_DIR) && \
		make sim_act_internal \
			HEX=$(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).hex \
			SIG=$(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).signature \
			BEGIN_SIG=$$BEGIN_SIG \
			END_SIG=$$END_SIG
	@ref=$(ARCH_TEST)/riscv-test-suite/$(SUITE)/references/$(TEST_NAME).reference_output; \
	if [ -f "$$ref" ]; then \
		diff -w $$ref $(RESULTS_DIR)/$(TEST_NAME)/$(TEST_NAME).signature; \
	else \
		echo "WARN: Reference not found: $$ref"; \
	fi

# =============================================================================
# riscv-tests runner
# =============================================================================

# Build ELFs inside container.
# isa/Makefile is pre-committed so no configure step is needed.
# -k keeps going past v-variant failures (need picolibc for string.h);
# p-variants (-nostdlib/-nostartfiles) always succeed.
riscv-tests-build:
	$(DOCKER_RUN) bash -c '\
		find $(RISCV_TESTS) -type f \( -name "*.S" -o -name "*.c" -o -name "*.h" \
			-o -name "*.ld" -o -name "Makefile*" \) \
			-exec sed -i "s/\r//" {} +; \
		cd $(RISCV_TESTS)/isa && \
		make -k XLEN=64 || true; \
	'

# Run simulation using pre-built ELFs
# Groups: rv64ui (I), rv64um (M), rv64ua (A), rv64uf (F), rv64ud (D),
#         rv64uc (C), rv64si (S-mode)
# Override GROUPS / XLEN_DEF to run other ISA widths (see riscv-tests-run32).
GROUPS   ?= rv64ui-p rv64um-p rv64ua-p rv64uf-p rv64ud-p rv64uc-p rv64si-p
XLEN_DEF ?= -DRV_XLEN_64
riscv-tests-run:
	@mkdir -p $(PROJECT_ROOT)/tests/results
	$(DOCKER_RUN) bash -c '\
		total=0; pass=0; fail=0; \
		for group in $(GROUPS); do \
			grp_total=0; grp_pass=0; grp_fail=0; \
			echo "--- $$group ---"; \
			for elf in $(RISCV_TESTS)/isa/$$group-*; do \
				[ -f "$$elf" ] && [ ! "$${elf##*.}" = "dump" ] || continue; \
				name=$$(basename $$elf); \
				total=$$(($$total+1)); \
				grp_total=$$(($$grp_total+1)); \
				$(OBJCOPY) -O verilog --change-addresses -0x80000000 \
					$$elf $(RESULTS_DIR)/$$name.hex; \
				BEGIN_SIG=$$( $(OBJDUMP) -t $$elf | grep " begin_signature" | awk "{print \$$1}" ); \
				END_SIG=$$( $(OBJDUMP) -t $$elf | grep " end_signature" | awk "{print \$$1}" ); \
				TOHOST=$$( $(OBJDUMP) -t $$elf | grep " tohost$$" | awk "{print \$$1}" ); \
				[ -z "$$TOHOST" ] && TOHOST=80001000; \
				cd $(SIM_DIR) && \
					make sim_act_internal \
						HEX_FILE=$(RESULTS_DIR)/$$name.hex \
						SIG_FILE=$(RESULTS_DIR)/$$name.sig \
						BEGIN_SIG=$$BEGIN_SIG \
						END_SIG=$$END_SIG \
						TOHOST_ADDR=$$TOHOST \
						XLEN_DEF="$(XLEN_DEF)" \
						> $(RESULTS_DIR)/$$name.log 2>&1; \
				if grep -q "TEST PASSED" $(RESULTS_DIR)/$$name.log; then \
					pass=$$(($$pass+1)); grp_pass=$$(($$grp_pass+1)); \
					echo "  [PASS] $$name"; \
				else \
					fail=$$(($$fail+1)); grp_fail=$$(($$grp_fail+1)); \
					echo "  [FAIL] $$name"; \
				fi; \
			done; \
			echo "  $$group: $$grp_pass/$$grp_total passed, $$grp_fail failed"; \
			echo ""; \
		done; \
		echo "=== Summary: $$pass/$$total passed, $$fail failed ===" \
	'

# Debug: run single riscv-test with verbose debug testbench
# Usage: make riscv-tests-debug TEST=rv64ua-p-lrsc
TEST ?= rv64ua-p-lrsc
riscv-tests-debug:
	@mkdir -p $(PROJECT_ROOT)/tests/results
	$(DOCKER_RUN) bash -c '\
		elf=$(RISCV_TESTS)/isa/$(TEST); \
		$(OBJCOPY) -O verilog --change-addresses -0x80000000 \
			$$elf $(RESULTS_DIR)/$(TEST).hex; \
		TOHOST=$$( $(OBJDUMP) -t $$elf | grep " tohost$$" | awk "{print \$$1}" ); \
		[ -z "$$TOHOST" ] && TOHOST=80001000; \
		cd $(SIM_DIR) && \
			make sim_act_debug_internal \
				HEX_FILE=$(RESULTS_DIR)/$(TEST).hex \
				TOHOST_ADDR=$$TOHOST \
				XLEN_DEF="$(XLEN_DEF)"; \
	'

# Convenience: build then run
riscv-tests: riscv-tests-build riscv-tests-run

# =============================================================================
# RV32 (XLEN=32) variants — build and run rv32* ELFs (e.g. rv32uc-p-rvc).
#   make riscv-tests-build32          # build rv32 ELFs in isa/
#   make riscv-tests-run32            # run default RV32 user groups
#   make riscv-tests-run32 GROUPS32="rv32uc-p"   # run a single group
# =============================================================================
GROUPS32 ?= rv32ui-p rv32um-p rv32ua-p rv32uc-p

riscv-tests-build32:
	$(DOCKER_RUN) bash -c '\
		find $(RISCV_TESTS) -type f \( -name "*.S" -o -name "*.c" -o -name "*.h" \
			-o -name "*.ld" -o -name "Makefile*" \) \
			-exec sed -i "s/\r//" {} +; \
		cd $(RISCV_TESTS)/isa && \
		make -k XLEN=32 || true; \
	'

# Run RV32 groups by reusing riscv-tests-run with XLEN_DEF empty (XLEN=32 RTL).
# Use target-specific variables (not recursive make) so PROJECT_ROOT etc. stay
# correct and to avoid Windows path/space issues with $(MAKE).
riscv-tests-run32: GROUPS   := $(GROUPS32)
riscv-tests-run32: XLEN_DEF :=
riscv-tests-run32: riscv-tests-run
	@true

riscv-tests32: riscv-tests-build32 riscv-tests-run32

# =============================================================================
# Utility
# =============================================================================
clean:
	rm -rf $(PROJECT_ROOT)/tests/results

