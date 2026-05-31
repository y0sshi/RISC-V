# =============================================================================
# Makefile - RISCOF architectural compliance runner for this core
# =============================================================================
# Quick start:
#   make setup            # build images + clone arch-test suite (one time)
#   make run EXT=C        # run the C suite vs Spike
#   make run              # run ALL applicable extensions (I/M/A/F/D/C)
#   make run REF=sail_cSim EXT=C   # use Sail reference instead of Spike
#   make debug EXT=I NAME=jal-01   # run one test on the DUT only (no compare)
#   make report           # print the HTML report path
#   make clean            # remove run artifacts
# Run from this directory (tests/riscof) or via `make -C tests/riscof <target>`.
# =============================================================================

# --- Paths ----------------------------------------------------------------
MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
PARENT_DIR   := $(shell dirname $(MAKEFILE_DIR))
PROJECT_ROOT := $(shell dirname $(PARENT_DIR))

# --- Images ---------------------------------------------------------------
RUN_IMG   := riscof_run:latest
SPIKE_IMG := spike:latest
SAIL_IMG  := sail:latest

# MSYS_NO_PATHCONV=1 stops Git-bash/MSYS from rewriting container paths like
# /workspace and /tmp into Windows paths (harmless if the var is unset elsewhere).
DOCKER_RUN := MSYS_NO_PATHCONV=1 docker run --rm -v $(PROJECT_ROOT):/workspace \
                -w /workspace/tests/riscof $(RUN_IMG)

# --- Test selection -------------------------------------------------------
SUITE := arch-test-suite/riscv-test-suite
ENVD  := $(SUITE)/env
REF   ?= spike          # spike | sail_cSim
EXT   ?=                # empty = all extensions; else I/M/A/F/D/C
MARCH ?= rv64imafdc     # used only by `make debug`

ifeq ($(strip $(EXT)),)
RUN_SUITE := $(SUITE)
else
RUN_SUITE := $(SUITE)/rv64i_m/$(EXT)
endif

ARCH_TEST_REV ?= 3.9.1

.PHONY: help setup images spike-image runner-image sail-image suite \
        validate testlist run run-all debug report clean

help:
	@echo "RISCOF runner targets:"
	@echo "  make setup                 build spike+runner images and clone the arch-test suite"
	@echo "  make run [EXT=C] [REF=..]  run a suite (default: all extensions, REF=spike)"
	@echo "  make run REF=sail_cSim     use the Sail reference (needs 'make sail-image' + sail in runner)"
	@echo "  make debug EXT=I NAME=jal-01   run one test on the DUT only"
	@echo "  make validate              riscof validateyaml"
	@echo "  make testlist              generate the applicable test list"
	@echo "  make report                show the HTML report path"
	@echo "  make clean                 remove riscof_work + temp configs"

# --- One-time setup -------------------------------------------------------
setup: spike-image runner-image suite

images: spike-image runner-image

spike-image:
	docker build -t $(SPIKE_IMG) spike

runner-image:
	docker build -t $(RUN_IMG) -f Dockerfile.run .

# Sail reference (heavy; see README for the sail-riscv legacy-build caveat)
sail-image:
	docker build -t $(SAIL_IMG) sail_cSim

# Clone a RISCOF-compatible arch-test suite (classic riscv-test-suite/ layout)
suite:
	@if [ -d arch-test-suite/riscv-test-suite ]; then \
		echo "arch-test-suite already present"; \
	else \
		git clone --depth 1 -b $(ARCH_TEST_REV) \
			https://github.com/riscv-non-isa/riscv-arch-test.git arch-test-suite; \
	fi

# --- Checks ---------------------------------------------------------------
validate:
	$(DOCKER_RUN) riscof validateyaml --config=config.ini

testlist:
	$(DOCKER_RUN) riscof testlist --config=config.ini \
		--suite=$(RUN_SUITE) --env=$(ENVD)

# --- Run ------------------------------------------------------------------
# Derives a temp config selecting the requested reference plugin (REF).
run:
	@sed -e 's,^ReferencePlugin=.*,ReferencePlugin=$(REF),' \
	     -e 's,^ReferencePluginPath=.*,ReferencePluginPath=./$(REF),' \
	     config.ini > .run-config.ini
	$(DOCKER_RUN) riscof run --config=.run-config.ini \
		--suite=$(RUN_SUITE) --env=$(ENVD) --no-browser

run-all: ; $(MAKE) run EXT=

# DUT-only single-test debug (compile -> iverilog ACT -> vvp); prints TEST PASSED/TIMEOUT
debug:
	@test -n "$(EXT)" && test -n "$(NAME)" || { echo "usage: make debug EXT=I NAME=jal-01"; exit 1; }
	$(DOCKER_RUN) bash rvcore/run_dut.sh $(MARCH) lp64 "-DTEST_CASE_1=True -DXLEN=64" \
		$(SUITE)/rv64i_m/$(EXT)/src/$(NAME).S /tmp/d.elf /tmp/d.hex /tmp/d.sig \
		/workspace rvcore/env $(ENVD) -DRV_XLEN_64

report:
	@echo "HTML report: tests/riscof/riscof_work/report.html"

clean:
	rm -rf riscof_work .run-config.ini
