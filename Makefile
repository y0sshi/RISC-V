# =============================================================================
# Top-level Makefile - single entry point for the bash/docker-side flows.
# =============================================================================
# This is a THIN dispatcher: it does not re-implement anything, it just gives the
# scattered firmware / sim / test / dependency commands one discoverable home and
# hides the long `docker run ...` invocations.  Run `make help` for the list.
#
#   Two command families (by hard constraint):
#     - bash / docker  -> THIS Makefile  (firmware builds, verilator boot, tests)
#     - FPGA (Vivado/Vitis MUST run from PowerShell; Bash/MSYS crashes synth)
#                      -> boards/zybo_z720/build_all.ps1  (+ bringup_jtag.tcl)
#
# Docker mounts the repo at /workspace using the same $(abspath)/dirname idiom as
# src/sim/Makefile (proven to produce a Docker-acceptable host path on this setup).
# =============================================================================

# MAKEFILE_DIR keeps its trailing slash; strip exactly that (do NOT use dirname --
# this Makefile is at the repo root, so dirname would drop a real path component).
MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
REPO         := $(patsubst %/,%,$(MAKEFILE_DIR))

# Pinned external dependency versions (reproducibility WITHOUT submodules: these
# are large / docker-built / CRLF-sensitive build inputs, so they live in
# gitignored work dirs cloned at a fixed ref -- see `make deps`).
OPENSBI_REF   := v1.2
OPENSBI_URL   := https://github.com/riscv-software-src/opensbi.git

# Docker images.  `make images` (below) builds these in dependency order;
# riscv_act is layered FROM iverilog (see tests/compliance/Dockerfile).
IMG_IVERILOG  := iverilog:13.0
IMG_VERILATOR := verilator:5.020
IMG_ACT       := riscv_act:latest
IMG_GCC       := riscv_gcc:latest
IMG_RISCOF    := riscof_run:latest
IMG_LINUX     := linux-rv64:latest

# Re-linked real-HW firmware base (PS DDR, 2 MiB aligned) and device trees.
HW_BASE       := 0x00200000
DTS_OPENSBI_HW := /workspace/docs/opensbi/rv_soc_hw.dts
DTS_LINUX_HW   := /workspace/tests/linux/rv_soc_linux_hw.dts

DRUN          := docker run --rm -v $(REPO):/workspace

# MSYS/Git-Bash rewrites POSIX-looking args (e.g. `docker -w /workspace/...` ->
# `C:/msys64/workspace/...`), which breaks the docker working-dir and volume
# paths.  Disable that conversion for every recipe shell.  On a real Linux host
# this is just an unused, harmless env var.
export MSYS_NO_PATHCONV := 1

.DEFAULT_GOAL := help

# -----------------------------------------------------------------------------
.PHONY: help
help:
	@echo "RISC-V SoC - bash/docker entry points (FPGA build is PowerShell: see below)"
	@echo ""
	@echo "Docker images (build once; iverilog is the shared base for riscv_act):"
	@echo "  make images             iverilog/verilator/riscv_act/riscv_gcc/linux-rv64"
	@echo ""
	@echo "Dependencies (pinned clone, no submodule):"
	@echo "  make deps               OpenSBI $(OPENSBI_REF) + arch-test-suite (+ riscof images)"
	@echo ""
	@echo "Firmware (docker; *-lo = 0x200000 sim base, *-hw = 0x200000 real-HW DTS):"
	@echo "  make fw-opensbi[-lo|-hw]   OpenSBI hello fw_payload"
	@echo "  make fw-linux[-lo|-hw]     Linux fw_payload (kernel cached after first build)"
	@echo ""
	@echo "Boot in simulation (verilator):"
	@echo "  make boot                  mini-SBI stand-in (fast sanity)"
	@echo "  make boot-opensbi          real OpenSBI hello (needs fw-opensbi-lo)"
	@echo "  make boot-linux            real Linux to userspace (needs fw-linux-lo; ~8 min)"
	@echo ""
	@echo "Tests:"
	@echo "  make compliance            riscv-tests RV64 (compliance32 for RV32)"
	@echo "  make riscof                arch-test vs Spike"
	@echo "  make sim-<name>            any src/sim target, e.g. make sim-pipeline"
	@echo ""
	@echo "FPGA / board (run from PowerShell - NOT make):"
	@echo "  boards/zybo_z720/build_all.ps1        bitstream -> XSA -> FSBL -> BOOT.bin"
	@echo "  boards/zybo_z720/vitis/bringup_jtag.tcl   on-board JTAG bring-up (xsct)"

# -----------------------------------------------------------------------------
# Dependencies: clone pinned external trees into their gitignored work dirs.
# OpenSBI is cloned INSIDE docker (host clone on Windows mangles line endings; the
# firmware build runs in docker anyway).  arch-test-suite reuses the existing,
# already-pinned tests/riscof setup target.
# -----------------------------------------------------------------------------
.PHONY: deps deps-opensbi deps-archtest
deps: deps-opensbi deps-archtest

deps-opensbi:
	@if [ -d tests/opensbi/work/opensbi/.git ]; then \
	    echo "opensbi already present ($(OPENSBI_REF)): tests/opensbi/work/opensbi"; \
	else \
	    echo "cloning OpenSBI $(OPENSBI_REF) ..."; \
	    $(DRUN) -w /workspace/tests/opensbi $(IMG_RISCOF) \
	        git clone --depth 1 -b $(OPENSBI_REF) $(OPENSBI_URL) work/opensbi; \
	fi

deps-archtest:
	"$(MAKE)" -C tests/riscof setup

# -----------------------------------------------------------------------------
# Docker images, built in dependency order.  iverilog:13.0 is the shared base
# (its ~10-min source build is reused by riscv_act instead of rebuilt).  The
# heavy riscof images (spike + riscof_run) are built by `make deps` instead.
# -----------------------------------------------------------------------------
.PHONY: images
images:
	cd src/sim          && docker build -t $(IMG_IVERILOG) --build-arg IVERILOG_VER=v13_0 .
	cd src/sim          && docker build -t $(IMG_VERILATOR) -f Dockerfile.verilator .
	cd tests/compliance && docker build -t $(IMG_ACT) .
	cd src/software     && docker build -t $(IMG_GCC) .
	cd tests/linux      && docker build -t $(IMG_LINUX) .
	@echo "images built: $(IMG_IVERILOG) $(IMG_VERILATOR) $(IMG_ACT) $(IMG_GCC) $(IMG_LINUX)"

# -----------------------------------------------------------------------------
# Firmware builds (docker).  build.sh already parameterizes FW_BASE/DTS/OUT.
# The *-hw targets also stash the ELF under a stable name for the JTAG `dow`.
# -----------------------------------------------------------------------------
.PHONY: fw-opensbi fw-opensbi-lo fw-opensbi-hw
fw-opensbi:
	$(DRUN) -w /workspace/tests/opensbi $(IMG_RISCOF) bash build.sh

fw-opensbi-lo:
	$(DRUN) -w /workspace/tests/opensbi $(IMG_RISCOF) bash -c \
	    "FW_BASE=$(HW_BASE) DTS=/workspace/docs/opensbi/rv_soc_lo.dts OUT=fw_payload_lo bash build.sh"

fw-opensbi-hw:
	$(DRUN) -w /workspace/tests/opensbi $(IMG_RISCOF) bash -c \
	    "FW_BASE=$(HW_BASE) DTS=$(DTS_OPENSBI_HW) OUT=fw_payload_hw bash build.sh"
	cp tests/opensbi/work/opensbi/build/platform/generic/firmware/fw_payload.elf \
	   tests/opensbi/work/fw_payload_hw.elf
	@echo "stashed tests/opensbi/work/fw_payload_hw.elf (entry 0x200000, for JTAG dow)"

# Linux build.sh is checked out CRLF -> strip CR before piping to bash.
.PHONY: fw-linux fw-linux-lo fw-linux-hw
fw-linux:
	$(DRUN) -w /workspace/tests/linux $(IMG_LINUX) bash -c "tr -d '\015' < build.sh | bash -s"

fw-linux-lo:
	$(DRUN) -w /workspace/tests/linux $(IMG_LINUX) bash -c \
	    "tr -d '\015' < build.sh | FW_BASE=$(HW_BASE) DTS=/workspace/tests/linux/rv_soc_linux_lo.dts OUT=fw_payload_linux_lo bash -s"

fw-linux-hw:
	$(DRUN) -w /workspace/tests/linux $(IMG_LINUX) bash -c \
	    "tr -d '\015' < build.sh | FORCE_KERNEL=$(FORCE_KERNEL) FW_BASE=$(HW_BASE) DTS=$(DTS_LINUX_HW) OUT=fw_payload_linux_hw bash -s"
	cp tests/opensbi/work/opensbi/build/platform/generic/firmware/fw_payload.elf \
	   tests/linux/work/fw_payload_linux_hw.elf
	@echo "stashed tests/linux/work/fw_payload_linux_hw.elf (entry 0x200000, for JTAG dow)"

# -----------------------------------------------------------------------------
# Simulation boot (verilator).  Delegate to src/sim; clean the model dir first
# (BOOT_HEX is a compile-time define, so each image needs a fresh build).
# -----------------------------------------------------------------------------
.PHONY: boot boot-opensbi boot-linux
boot:
	rm -rf src/sim/out/vl_boot
	"$(MAKE)" -C src/sim vl_boot

boot-opensbi:
	rm -rf src/sim/out/vl_boot
	"$(MAKE)" -C src/sim vl_boot \
	    BOOT_HEX=../../tests/opensbi/work/fw_payload_lo.hex BOOT_MEM_BASE=2097152

boot-linux:
	rm -rf src/sim/out/vl_boot
	"$(MAKE)" -C src/sim vl_boot \
	    BOOT_HEX=../../tests/linux/work/fw_payload_linux_lo.hex BOOT_MEM_BASE=2097152 \
	    BOOT_MAX=480000000 BOOT_MTIME_DIV=64

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------
.PHONY: compliance compliance32 riscof
compliance:
	"$(MAKE)" -C tests/compliance riscv-tests-run

compliance32:
	"$(MAKE)" -C tests/compliance riscv-tests-build32
	"$(MAKE)" -C tests/compliance riscv-tests-run32 XLEN_DEF=

riscof:
	"$(MAKE)" -C tests/riscof run

# Pass-through to any src/sim unit/integration target: make sim-pipeline, sim-fpu_d ...
.PHONY: sim-%
sim-%:
	"$(MAKE)" -C src/sim sim_$*
