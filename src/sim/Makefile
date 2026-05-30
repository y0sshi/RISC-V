# =============================================================================
# Makefile - iverilog Simulation
# =============================================================================
# Usage:
#   make sim_alu          Run ALU testbench
#   make sim_csr          Run CSR unit testbench
#   make sim_rv64i        Run RV64I W-type ALU testbench (XLEN=64)
#   make sim_mext         Run M-extension testbench (XLEN=32)
#   make sim_mext64       Run M-extension testbench (XLEN=64, W-type ops)
#   make sim_amo          Run A-extension AMO compute unit testbench (XLEN=32)
#   make sim_amo64        Run A-extension AMO compute unit testbench (XLEN=64)
#   make sim_mmu          Run MMU testbench (Sv32, XLEN=32)
#   make sim_mmu64        Run MMU testbench (Sv39, XLEN=64)
#   make sim_sv           Run Supervisor-mode CSR testbench (XLEN=32)
#   make sim_sv64         Run Supervisor-mode CSR testbench (XLEN=64)
#   make sim_timer        Run Machine Timer (CLINT) testbench (XLEN=32)
#   make sim_timer64      Run Machine Timer (CLINT) testbench (XLEN=64)
#   make sim_uart         Run UART (8N1) testbench
#   make sim_gpio         Run GPIO testbench (4-bit, OUT/IN/DIR/IRQ_EN)
#   make sim_plic         Run PLIC testbench (8 sources, 2 contexts)
#   make sim_pipeline     Run pipeline integration testbench (forwarding/stall/branch/CSR)
#   make sim_intr         Run interrupt integration testbench (MTIP/MEIP/MSIP/priority/MRET)
#   make sim_core         Run core integration testbench
#   make sim_core PROG=path/to/program.hex
#   make wave_alu         Open ALU waveform in GTKWave
#   make wave_csr         Open CSR waveform in GTKWave
#   make wave_rv64i       Open RV64I waveform in GTKWave
#   make wave_mext        Open M-extension waveform in GTKWave
#   make wave_mext64      Open M-extension (64-bit) waveform in GTKWave
#   make wave_amo         Open A-extension waveform in GTKWave
#   make wave_amo64       Open A-extension (64-bit) waveform in GTKWave
#   make wave_mmu         Open MMU (Sv32) waveform in GTKWave
#   make wave_mmu64       Open MMU (Sv39) waveform in GTKWave
#   make wave_sv          Open Supervisor-mode (32-bit) waveform in GTKWave
#   make wave_sv64        Open Supervisor-mode (64-bit) waveform in GTKWave
#   make wave_timer       Open Machine Timer waveform in GTKWave
#   make wave_uart        Open UART waveform in GTKWave
#   make wave_gpio        Open GPIO waveform in GTKWave
#   make wave_plic        Open PLIC waveform in GTKWave
#   make wave_pipeline    Open pipeline testbench waveform in GTKWave
#   make wave_intr        Open interrupt testbench waveform in GTKWave
#   make wave_core        Open core waveform in GTKWave
#   make all              Run all testbenches
#   make clean            Remove generated files
# =============================================================================
## Directory Path
MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
PARENT_DIR   := $(shell dirname $(MAKEFILE_DIR))
PROJECT_ROOT := $(shell dirname $(PARENT_DIR))

# Docker image
DOCKER_IMAGE := iverilog:13.0
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
                -w /workspace/src/sim \
                $(DOCKER_IMAGE)

# Tool configuration
IVERILOG  = iverilog
VVP       = vvp
GTKWAVE   = gtkwave

# Source directories
RTL_DIR   = ../rtl
INC_DIR   = $(RTL_DIR)/include
CORE_DIR  = $(RTL_DIR)/core
ALU_DIR   = $(RTL_DIR)/alu
MEM_DIR   = $(RTL_DIR)/memory
SOC_DIR   = $(RTL_DIR)/soc
PERI_DIR  = $(RTL_DIR)/peripherals
FPU_DIR   = $(RTL_DIR)/fpu
TB_DIR    = tb

# Output directory
OUT_DIR   = out
WAVE_DIR  = wave

# Common flags
IVFLAGS   = -g2012 -Wall
IVFLAGS  += -I$(INC_DIR)
IVFLAGS  += -DRISCV_FORMAL

# Default program hex file
PROG     ?= ../software/tests/test_basic.hex

# Source file lists
PKG_SRC   = $(INC_DIR)/rv_pkg.sv
CSR_SRC   = $(PKG_SRC) $(CORE_DIR)/rv_csr.sv

FPU_SRC   = $(FPU_DIR)/rv_fpu_add.sv \
            $(FPU_DIR)/rv_fpu_mul.sv \
            $(FPU_DIR)/rv_fpu_div.sv \
            $(FPU_DIR)/rv_fpu_sqrt.sv \
            $(FPU_DIR)/rv_fpu_misc.sv \
            $(FPU_DIR)/rv_fpu_add_d.sv \
            $(FPU_DIR)/rv_fpu_mul_d.sv \
            $(FPU_DIR)/rv_fpu_div_d.sv \
            $(FPU_DIR)/rv_fpu_sqrt_d.sv \
            $(FPU_DIR)/rv_fpu_misc_d.sv \
            $(FPU_DIR)/rv_fpu.sv

CORE_SRC  = $(PKG_SRC) \
            $(CORE_DIR)/rv_regfile.sv \
            $(CORE_DIR)/rv_fregfile.sv \
            $(CORE_DIR)/rv_decode.sv \
            $(CORE_DIR)/rv_branch.sv \
            $(ALU_DIR)/rv_alu.sv \
            $(CORE_DIR)/rv_muldiv.sv \
            $(CORE_DIR)/rv_amo.sv \
            $(CORE_DIR)/rv_forward.sv \
            $(CORE_DIR)/rv_csr.sv \
            $(CORE_DIR)/rv_hazard.sv \
            $(CORE_DIR)/rv_mmu.sv \
            $(FPU_SRC) \
            $(CORE_DIR)/rv_core.sv

SOC_SRC   = $(CORE_SRC) \
            $(MEM_DIR)/rv_imem.sv \
            $(MEM_DIR)/rv_dmem.sv \
            $(PERI_DIR)/clint/rv_timer.sv \
            $(PERI_DIR)/uart/rv_uart.sv \
            $(PERI_DIR)/gpio/rv_gpio.sv \
            $(PERI_DIR)/plic/rv_plic.sv \
            $(SOC_DIR)/rv_soc.sv

# Peripheral-only source lists (for individual testbenches)
PLIC_SRC  = $(PKG_SRC) $(PERI_DIR)/plic/rv_plic.sv
UART_SRC  = $(PERI_DIR)/uart/rv_uart.sv
GPIO_SRC  = $(PKG_SRC) $(PERI_DIR)/gpio/rv_gpio.sv
TIMER_SRC = $(CSR_SRC)


# =============================================================================
# Targets
# =============================================================================

.PHONY: all image \
            sim_alu sim_csr sim_rv64i sim_mext sim_mext64 sim_amo sim_amo64 \
            sim_mmu sim_mmu64 sim_sv sim_sv64 sim_timer sim_timer64 \
            sim_uart sim_gpio sim_plic sim_core sim_soc sim_bm \
            sim_pipeline sim_intr sim_fpu sim_fpu_d sim_fpu_pipe sim_mal \
            wave_alu wave_csr wave_rv64i wave_mext wave_mext64 wave_amo wave_amo64 \
            wave_mmu wave_mmu64 wave_sv wave_sv64 wave_timer wave_timer64 \
            wave_uart wave_gpio wave_plic wave_core wave_soc wave_bm \
            wave_pipeline wave_intr wave_fpu wave_fpu_pipe wave_mal \
            sim_act sim_act_internal wave_act \
            clean dirs

all: image \
     sim_alu sim_csr sim_rv64i sim_mext sim_mext64 sim_amo sim_amo64 \
     sim_mmu sim_mmu64 sim_sv sim_sv64 sim_timer sim_timer64 \
     sim_uart sim_gpio sim_plic sim_core sim_soc \
     sim_pipeline sim_intr sim_fpu sim_fpu_d sim_fpu_pipe sim_mal

dirs:
	mkdir -p $(OUT_DIR) $(WAVE_DIR)

image:
	docker build -t $(DOCKER_IMAGE) --build-arg IVERILOG_VER=v13_0 .

# --- ALU testbench ---
sim_alu: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_alu.vvp \
		$(PKG_SRC) $(ALU_DIR)/rv_alu.sv $(TB_DIR)/tb_rv_alu.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_alu.vvp

wave_alu: sim_alu
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_alu.vcd &

# --- CSR testbench ---
sim_csr: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_csr.vvp \
		$(CSR_SRC) $(TB_DIR)/tb_rv_csr.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_csr.vvp

wave_csr: sim_csr
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_csr.vcd &

# --- RV64I W-type ALU testbench (compiled with XLEN=64) ---
sim_rv64i: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 -o $(OUT_DIR)/tb_rv64i.vvp \
		$(PKG_SRC) $(ALU_DIR)/rv_alu.sv $(TB_DIR)/tb_rv64i.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv64i.vvp

wave_rv64i: sim_rv64i
	$(GTKWAVE) $(WAVE_DIR)/tb_rv64i.vcd &

# --- M-extension testbench (XLEN=32: RV32M, XLEN=64: includes W-type) ---
MEXT_SRC  = $(PKG_SRC) $(CORE_DIR)/rv_muldiv.sv

# --- A-extension AMO compute unit testbench ---
AMO_SRC   = $(PKG_SRC) $(CORE_DIR)/rv_amo.sv

# --- MMU testbench ---
MMU_SRC   = $(PKG_SRC) $(CORE_DIR)/rv_mmu.sv

# --- Supervisor-mode testbench ---
SV_SRC    = $(CSR_SRC)

sim_mext: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_mext.vvp \
		$(MEXT_SRC) $(TB_DIR)/tb_rv_mext.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_mext.vvp

wave_mext: sim_mext
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_mext.vcd &

sim_mext64: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 -o $(OUT_DIR)/tb_rv_mext64.vvp \
		$(MEXT_SRC) $(TB_DIR)/tb_rv_mext.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_mext64.vvp

wave_mext64: sim_mext64
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_mext64.vcd &

sim_amo: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_amo.vvp \
		$(AMO_SRC) $(TB_DIR)/tb_rv_amo.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_amo.vvp

wave_amo: sim_amo
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_amo.vcd &

sim_amo64: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 -o $(OUT_DIR)/tb_rv_amo64.vvp \
		$(AMO_SRC) $(TB_DIR)/tb_rv_amo.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_amo64.vvp

wave_amo64: sim_amo64
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_amo64.vcd &

sim_mmu: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_mmu.vvp \
		$(MMU_SRC) $(TB_DIR)/tb_rv_mmu.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_mmu.vvp

wave_mmu: sim_mmu
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_mmu.vcd &

sim_mmu64: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 -o $(OUT_DIR)/tb_rv_mmu64.vvp \
		$(MMU_SRC) $(TB_DIR)/tb_rv_mmu.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_mmu64.vvp

wave_mmu64: sim_mmu64
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_mmu64.vcd &

sim_sv: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_supervisor.vvp \
		$(SV_SRC) $(TB_DIR)/tb_rv_supervisor.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_supervisor.vvp

wave_sv: sim_sv
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_supervisor.vcd &

sim_sv64: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 -o $(OUT_DIR)/tb_rv_supervisor64.vvp \
		$(SV_SRC) $(TB_DIR)/tb_rv_supervisor.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_supervisor64.vvp

wave_sv64: sim_sv64
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_supervisor.vcd &

# --- Machine Timer interrupt testbench ---
TIMER_SRC = $(CSR_SRC)

sim_timer: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_timer.vvp \
		$(TIMER_SRC) $(TB_DIR)/tb_rv_timer.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_timer.vvp

wave_timer: sim_timer
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_timer.vcd &

sim_timer64: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 -o $(OUT_DIR)/tb_rv_timer64.vvp \
		$(TIMER_SRC) $(TB_DIR)/tb_rv_timer.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_timer64.vvp

wave_timer64: sim_timer64
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_timer64.vcd &

# --- UART testbench ---
sim_uart: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_uart.vvp \
		$(UART_SRC) $(TB_DIR)/tb_rv_uart.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_uart.vvp

wave_uart: sim_uart
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_uart.vcd &

# --- GPIO testbench ---
sim_gpio: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_gpio.vvp \
		$(GPIO_SRC) $(TB_DIR)/tb_rv_gpio.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_gpio.vvp

wave_gpio: sim_gpio
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_gpio.vcd &

# --- PLIC testbench ---
sim_plic: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_plic.vvp \
		$(PLIC_SRC) $(TB_DIR)/tb_rv_plic.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_plic.vvp

wave_plic: sim_plic
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_plic.vcd &

# --- Core testbench ---
sim_core: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_core.vvp \
		-PIMEM_FILE=\"$(PROG)\" \
		$(SOC_SRC) $(TB_DIR)/tb_rv_core.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_core.vvp

wave_core: sim_core
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_core.vcd &

# --- SoC integration testbench ---
# 基本統合テスト (手書き hex)
#   make sim_soc
# C ベアメタルプログラム実行 (IMEM + DMEM hex 指定)
#   make sim_soc SOC_PROG=path/imem.hex SOC_DMEM=path/dmem.hex

SOC_PROG ?= tests/test_soc_integ.hex
SOC_DMEM ?=

# DMEM_FILE が指定されていれば -PDMEM_FILE を追加
ifneq ($(SOC_DMEM),)
SOC_DMEM_FLAG = -PDMEM_FILE=\"$(SOC_DMEM)\"
else
SOC_DMEM_FLAG =
endif

sim_soc: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_soc.vvp \
		-PIMEM_FILE=\"$(SOC_PROG)\" \
		$(SOC_DMEM_FLAG) \
		$(SOC_SRC) $(TB_DIR)/tb_rv_soc.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_soc.vvp

wave_soc: sim_soc
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_soc.vcd &

# --- ベアメタル C プログラム実行テストベンチ ---
# make sim_bm IMEM_FILE=path/imem.hex DMEM_FILE=path/dmem.hex
BM_IMEM ?=
BM_DMEM ?=

sim_bm: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_bm.vvp \
		-Ptb_rv_bm.IMEM_FILE=\"$(BM_IMEM)\" \
		-Ptb_rv_bm.DMEM_FILE=\"$(BM_DMEM)\" \
		$(SOC_SRC) $(TB_DIR)/tb_rv_bm.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_bm.vvp

wave_bm: sim_bm
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_bm.vcd &

# --- FPU standalone testbench ---
sim_fpu: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_fpu.vvp \
		$(PKG_SRC) $(FPU_SRC) $(TB_DIR)/tb_rv_fpu.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_fpu.vvp

wave_fpu: sim_fpu
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_fpu.vcd &

# --- D-extension FPU standalone testbench ---
sim_fpu_d: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 -o $(OUT_DIR)/tb_rv_fpu_d.vvp \
		$(PKG_SRC) $(FPU_SRC) $(TB_DIR)/tb_rv_fpu_d.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_fpu_d.vvp

wave_fpu_d: sim_fpu_d
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_fpu_d.vcd &

# --- FP pipeline integration testbench ---
# Validates FP forwarding (EX/MEM, MEM/WB), FSW forwarding, FLW load-use stall,
# and FMADD rs3 forwarding through the full rv_core pipeline.
sim_fpu_pipe: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_fpu_pipe.vvp \
		$(CORE_SRC) $(TB_DIR)/tb_rv_fpu_pipe.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_fpu_pipe.vvp

wave_fpu_pipe: sim_fpu_pipe
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_fpu_pipe.vcd &

# --- Pipeline integration testbench ---
# Exercises forwarding, stalls, branches, loads/stores, LUI/AUIPC, ECALL, CSR
# through rv_core with a behavioral IMEM/DMEM.
sim_pipeline: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_pipeline.vvp \
		$(CORE_SRC) $(TB_DIR)/tb_rv_pipeline.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_pipeline.vvp

wave_pipeline: sim_pipeline
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_pipeline.vcd &

# --- Interrupt integration testbench ---
# Exercises MTIP/MEIP/MSIP delivery, priority, masking, and MRET re-enable
# through rv_core with a behavioral IMEM/DMEM.
sim_intr: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_intr.vvp \
		$(CORE_SRC) $(TB_DIR)/tb_rv_intr.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_intr.vvp

wave_intr: sim_intr
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_intr.vcd &

# --- Misaligned memory access testbench ---
# Exercises all hardware fixes for misaligned access:
#   mem_wb_byte_offset widening, rv_dmem word_addr fix, non-crossing store wdata,
#   crossing load combine, crossing store, SD+LD pipeline (flush_ex suppression),
#   crossing LD + dependent ALU.
MAL_SRC = $(CORE_SRC) $(MEM_DIR)/rv_dmem.sv

sim_mal: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 -o $(OUT_DIR)/tb_rv_mal.vvp \
		$(MAL_SRC) $(TB_DIR)/tb_rv_mal.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_mal.vvp

wave_mal: sim_mal
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_mal.vcd &

# =============================================================================
# riscv-arch-test / riscv-tests runner target
#   Called from tests/compliance/Makefile
#   Args:
#     HEX_FILE    : Input hex file (Verilog format from objcopy -O verilog)
#     SIG_FILE    : Output signature file path
#     BEGIN_SIG   : begin_signature address (hex, no 0x prefix)
#     END_SIG     : end_signature address (hex, no 0x prefix)
#     TOHOST_ADDR : tohost address (default 80001000)
# =============================================================================
# Default addresses (overridden by caller)
HEX_FILE    ?=
SIG_FILE    ?=
BEGIN_SIG   ?= 80002000
END_SIG     ?= 80003000
TOHOST_ADDR ?= 80001000

ACT_TB_SRC = $(TB_DIR)/tb_rv_act.sv

sim_act: dirs
	@if [ -z "$(HEX_FILE)" ] || [ -z "$(SIG_FILE)" ]; then \
		echo "ERROR: HEX and SIG must be specified"; exit 1; \
	fi
	$(DOCKER_RUN) $(MAKE) -f /workspace/src/sim/Makefile sim_act_internal \
		HEX_FILE=$(HEX_FILE) SIG_FILE=$(SIG_FILE) \
		BEGIN_SIG=$(BEGIN_SIG) END_SIG=$(END_SIG) TOHOST_ADDR=$(TOHOST_ADDR)

sim_act_internal:
	@if [ -z "$(HEX_FILE)" ] || [ -z "$(SIG_FILE)" ]; then \
		echo "ERROR: HEX and SIG must be specified"; exit 1; \
	fi
	$(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 \
		-DHEX_FILE=\"$(HEX_FILE)\"       \
		-DSIG_FILE=\"$(SIG_FILE)\"       \
		-DBEGIN_SIG=\"$(BEGIN_SIG)\"     \
		-DEND_SIG=\"$(END_SIG)\"         \
		-DTOHOST_ADDR=\"$(TOHOST_ADDR)\" \
		-o $(OUT_DIR)/tb_rv_act.vvp      \
		$(CORE_SRC) $(TB_DIR)/tb_rv_act.sv
	$(VVP) $(OUT_DIR)/tb_rv_act.vvp

sim_act_debug_internal:
	$(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 \
		-DHEX_FILE=\"$(HEX_FILE)\"       \
		-DTOHOST_ADDR=\"$(TOHOST_ADDR)\" \
		-o $(OUT_DIR)/tb_rv_act_debug.vvp \
		$(CORE_SRC) $(TB_DIR)/tb_rv_act_debug.sv
	$(VVP) $(OUT_DIR)/tb_rv_act_debug.vvp

wave_act:
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_act.vcd

# --- Clean ---
clean:
	rm -rf $(OUT_DIR) $(WAVE_DIR)

