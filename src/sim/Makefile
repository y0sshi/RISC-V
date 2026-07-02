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
EXEC_DIR  = $(RTL_DIR)/exec
MEM_DIR   = $(RTL_DIR)/memory
SOC_DIR   = $(RTL_DIR)/soc
PERI_DIR  = $(RTL_DIR)/peripherals
FPU_DIR   = $(RTL_DIR)/fpu
BUS_DIR   = $(RTL_DIR)/bus
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
            $(CORE_DIR)/rv_cdecode.sv \
            $(CORE_DIR)/rv_decode.sv \
            $(EXEC_DIR)/rv_branch.sv \
            $(EXEC_DIR)/rv_alu.sv \
            $(EXEC_DIR)/rv_muldiv.sv \
            $(EXEC_DIR)/rv_amo.sv \
            $(CORE_DIR)/rv_forward.sv \
            $(CORE_DIR)/rv_csr.sv \
            $(CORE_DIR)/rv_hazard.sv \
            $(CORE_DIR)/rv_mmu.sv \
            $(FPU_SRC) \
            $(CORE_DIR)/rv_core.sv \
            $(CORE_DIR)/rv_cpu.sv

SOC_SRC   = $(CORE_SRC) \
            $(MEM_DIR)/rv_imem.sv \
            $(MEM_DIR)/rv_dmem.sv \
            $(PERI_DIR)/clint/rv_timer.sv \
            $(PERI_DIR)/uart/rv_uart.sv \
            $(PERI_DIR)/gpio/rv_gpio.sv \
            $(PERI_DIR)/plic/rv_plic.sv \
            $(PERI_DIR)/rv_periph.sv \
            $(SOC_DIR)/rv_soc_bram.sv

# ACT compliance: rv_soc_act (rv_unified_mem + rv_cpu, no peripherals)
ACT_SRC   = $(CORE_SRC) \
            $(MEM_DIR)/rv_unified_mem.sv \
            $(SOC_DIR)/rv_soc_act.sv

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
            sim_cdecode sim_cdecode64 sim_axi sim_axi_core sim_axi_soc \
            sim_axi_burst sim_axi_ifetch sim_dcache sim_dcache64 \
            sim_icache sim_icache64 sim_cache_soc sim_cache_soc64 sim_boot \
            vl_boot image_verilator \
            wave_alu wave_csr wave_rv64i wave_mext wave_mext64 wave_amo wave_amo64 \
            wave_cdecode \
            wave_mmu wave_mmu64 wave_sv wave_sv64 wave_timer wave_timer64 \
            wave_uart wave_gpio wave_plic wave_core wave_soc wave_bm \
            wave_pipeline wave_intr wave_fpu wave_fpu_pipe wave_mal \
            sim_act sim_act_internal wave_act \
            clean dirs

all: image \
     sim_alu sim_csr sim_rv64i sim_mext sim_mext64 sim_amo sim_amo64 \
     sim_mmu sim_mmu64 sim_sv sim_sv64 sim_timer sim_timer64 \
     sim_uart sim_gpio sim_plic sim_core sim_soc \
     sim_pipeline sim_intr sim_fpu sim_fpu_d sim_fpu_pipe sim_mal \
     sim_cdecode sim_cdecode64 \
     sim_axi sim_axi_burst sim_axi_core sim_axi_ifetch sim_axi_soc \
     sim_dcache sim_dcache64 sim_icache sim_icache64 sim_cache_soc sim_cache_soc64

dirs:
	mkdir -p $(OUT_DIR) $(WAVE_DIR)

image:
	docker build -t $(DOCKER_IMAGE) --build-arg IVERILOG_VER=v13_0 .

# --- ALU testbench ---
sim_alu: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_alu.vvp \
		$(PKG_SRC) $(EXEC_DIR)/rv_alu.sv $(TB_DIR)/tb_rv_alu.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_alu.vvp

wave_alu: sim_alu
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_alu.vcd &

# --- C-extension compressed decoder (rv_cdecode) unit testbench ---
CDEC_SRC = $(PKG_SRC) $(CORE_DIR)/rv_cdecode.sv

# RV32C expansion
sim_cdecode: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_cdecode.vvp \
		$(CDEC_SRC) $(TB_DIR)/tb_rv_cdecode.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_cdecode.vvp

# RV64C expansion
sim_cdecode64: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 -o $(OUT_DIR)/tb_rv_cdecode64.vvp \
		$(CDEC_SRC) $(TB_DIR)/tb_rv_cdecode.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_cdecode64.vvp

wave_cdecode: sim_cdecode
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_cdecode.vcd &

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
		$(PKG_SRC) $(EXEC_DIR)/rv_alu.sv $(TB_DIR)/tb_rv64i.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv64i.vvp

wave_rv64i: sim_rv64i
	$(GTKWAVE) $(WAVE_DIR)/tb_rv64i.vcd &

# --- M-extension testbench (XLEN=32: RV32M, XLEN=64: includes W-type) ---
MEXT_SRC  = $(PKG_SRC) $(EXEC_DIR)/rv_muldiv.sv

# --- A-extension AMO compute unit testbench ---
AMO_SRC   = $(PKG_SRC) $(EXEC_DIR)/rv_amo.sv

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

sim_mdrand: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_muldiv_rand.vvp \
		$(MEXT_SRC) $(TB_DIR)/tb_rv_muldiv_rand.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_muldiv_rand.vvp

sim_mdrand64: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 -o $(OUT_DIR)/tb_rv_muldiv_rand64.vvp \
		$(MEXT_SRC) $(TB_DIR)/tb_rv_muldiv_rand.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_muldiv_rand64.vvp

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

# --- AXI4 bridge unit testbench (simple-bus <-> AXI4 master + slave BFM) ---
# Validates rv_axi_bridge protocol conversion under variable memory latency.
AXI_BRIDGE_SRC = $(BUS_DIR)/rv_axi_bridge.sv $(TB_DIR)/rv_axi_slave_bfm.sv

sim_axi: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_axi_bridge.vvp \
		$(AXI_BRIDGE_SRC) $(TB_DIR)/tb_rv_axi_bridge.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_axi_bridge.vvp

wave_axi: sim_axi
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_axi_bridge.vcd &

# --- AXI4 burst bridge unit testbench (line-fill bursts + single write) ---
AXI_BURST_SRC = $(BUS_DIR)/rv_axi_burst_bridge.sv $(TB_DIR)/rv_axi_slave_bfm.sv

sim_axi_burst: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_axi_burst.vvp \
		$(AXI_BURST_SRC) $(TB_DIR)/tb_rv_axi_burst.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_axi_burst.vvp

wave_axi_burst: sim_axi_burst
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_axi_burst.vcd &

# --- D-cache unit testbench (rv_dcache + burst bridge + slave BFM) ---
CACHE_DIR = $(RTL_DIR)/cache
DCACHE_SRC = $(CACHE_DIR)/rv_dcache.sv $(BUS_DIR)/rv_axi_burst_bridge.sv $(TB_DIR)/rv_axi_slave_bfm.sv

sim_dcache: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_dcache.vvp \
		$(DCACHE_SRC) $(TB_DIR)/tb_rv_dcache.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_dcache.vvp

sim_dcache64: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 -o $(OUT_DIR)/tb_rv_dcache64.vvp \
		$(DCACHE_SRC) $(TB_DIR)/tb_rv_dcache.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_dcache64.vvp

wave_dcache: sim_dcache
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_dcache.vcd &

# --- I-cache unit testbench (rv_icache + read-only burst bridge + slave BFM) ---
ICACHE_SRC = $(CACHE_DIR)/rv_icache.sv $(BUS_DIR)/rv_axi_burst_bridge.sv $(TB_DIR)/rv_axi_slave_bfm.sv

sim_icache: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_icache.vvp \
		$(ICACHE_SRC) $(TB_DIR)/tb_rv_icache.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_icache.vvp

sim_icache64: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 -o $(OUT_DIR)/tb_rv_icache64.vvp \
		$(ICACHE_SRC) $(TB_DIR)/tb_rv_icache.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_icache64.vvp

wave_icache: sim_icache
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_icache.vcd &

# --- rv_core data port over AXI (variable latency) integration testbench ---
# Runs the proven pipeline test programs with the DATA port routed through
# rv_axi_bridge + rv_axi_slave_bfm at randomized latency (IF stays behavioral).
AXI_CORE_SRC = $(CORE_SRC) $(BUS_DIR)/rv_axi_bridge.sv $(TB_DIR)/rv_axi_slave_bfm.sv

sim_axi_core: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_axi_core.vvp \
		$(AXI_CORE_SRC) $(TB_DIR)/tb_rv_axi_core.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_axi_core.vvp

wave_axi_core: sim_axi_core
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_axi_core.vcd &

# --- rv_soc AXI_MODE integration testbench (data path over AXI -> DDR model) ---
AXI_SOC_SRC = $(CORE_SRC) \
              $(BUS_DIR)/rv_axi_bridge.sv \
              $(BUS_DIR)/rv_axi_burst_bridge.sv \
              $(CACHE_DIR)/rv_icache.sv \
              $(CACHE_DIR)/rv_dcache.sv \
              $(PERI_DIR)/clint/rv_timer.sv \
              $(PERI_DIR)/uart/rv_uart.sv \
              $(PERI_DIR)/gpio/rv_gpio.sv \
              $(PERI_DIR)/plic/rv_plic.sv \
              $(PERI_DIR)/rv_periph.sv \
              $(SOC_DIR)/rv_soc.sv \
              $(TB_DIR)/rv_axi_slave_bfm.sv

sim_axi_soc: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_axi_soc.vvp \
		$(AXI_SOC_SRC) $(TB_DIR)/tb_rv_axi_soc.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_axi_soc.vvp

wave_axi_soc: sim_axi_soc
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_axi_soc.vcd &

# --- Cache effectiveness + transparency integration testbench ---
# Two rv_soc instances (caches on / off) run the same program; verifies identical
# results and fewer AXI read transactions with caches enabled.
sim_cache_soc: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_cache_soc.vvp \
		$(AXI_SOC_SRC) $(TB_DIR)/tb_rv_cache_soc.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_cache_soc.vvp

sim_cache_soc64: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 -o $(OUT_DIR)/tb_rv_cache_soc64.vvp \
		$(AXI_SOC_SRC) $(TB_DIR)/tb_rv_cache_soc.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_cache_soc64.vvp

wave_cache_soc: sim_cache_soc
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_cache_soc.vcd &

# --- OpenSBI-style boot harness over a SHARED DDR image -------------------
# Boots a firmware image (mini-SBI stand-in by default, or a real OpenSBI
# fw_payload hex via BOOT_HEX=) on rv_soc (caches on) with instructions + data
# + page tables all in one shared DDR (rv_axi_dualport_mem_bfm).
#   make sim_boot
#   make sim_boot BOOT_HEX=/abs/path/fw_payload.hex
BOOT_SRC = $(AXI_SOC_SRC) $(TB_DIR)/rv_axi_dualport_mem_bfm.sv

ifneq ($(BOOT_HEX),)
BOOT_HEX_FLAG = -DBOOT_HEX=\"$(BOOT_HEX)\"
else
BOOT_HEX_FLAG =
endif

# Optional: override the run length, e.g. make sim_boot BOOT_MAX=8000000
ifneq ($(BOOT_MAX),)
BOOT_MAX_FLAG = -DBOOT_MAX_CYCLES=$(BOOT_MAX)
else
BOOT_MAX_FLAG =
endif

# Optional: shared-DDR base (= RST_ADDR = BFM BASE_ADDR), decimal.  Default
# 0x8000_0000 (= 2147483648).  Set to 2097152 (= 0x0020_0000) together with a
# firmware linked at that base (src/software: make boot_lo -> sbi_boot_lo.hex) to
# sanity-check the Zybo PS-DDR re-link in sim:
#   make vl_boot BOOT_HEX=../software/boot/sbi_boot_lo.hex BOOT_MEM_BASE=2097152
ifneq ($(BOOT_MEM_BASE),)
BOOT_MEMBASE_FLAG = -DBOOT_MEM_BASE=$(BOOT_MEM_BASE)
else
BOOT_MEMBASE_FLAG =
endif

# CLINT mtime prescaler (1 = +1/cycle).  Linux boots should use
# BOOT_MTIME_DIV=64: with mtime at +1/cycle the 250 Hz tick fires every 4000
# cycles, which is LESS than the tick handler costs -> the kernel livelocks in
# tick_handle_periodic catch-up.  DIV=64 emulates a 64 MHz core with the 1 MHz
# device-tree timebase.
ifneq ($(BOOT_MTIME_DIV),)
BOOT_MTIME_FLAG = -DBOOT_MTIME_DIV=$(BOOT_MTIME_DIV)
else
BOOT_MTIME_FLAG =
endif
# Diagnostic: drive mtime from RETIRED-INSTRUCTION count instead of cycles, so a
# baseline (single-cycle divide) and C-2a (multi-cycle divide) run get IDENTICAL
# rdtime entropy + timer-interrupt instants -> identical execution iff no real HW
# bug (separates a HW bug from benign RNG-divergence/roulette).
ifneq ($(BOOT_MTIME_INSTR),)
BOOT_MTIME_FLAG += -DMTIME_INSTR
endif

# Optional: -DBOOT_TRACE early divergence trace (make sim_boot BOOT_TRACE=1)
ifneq ($(BOOT_TRACE),)
BOOT_TRACE_FLAG = -DBOOT_TRACE
ifneq ($(BOOT_CYCTRACE),)
BOOT_TRACE_FLAG += -DBOOT_CYCTRACE
endif
ifneq ($(BOOT_EXEC),)
BOOT_TRACE_FLAG += -DBOOT_EXEC
endif
ifneq ($(BOOT_WIN),)
BOOT_TRACE_FLAG += -DBOOT_WIN=$(BOOT_WIN)
endif
# BOOT_HANG_PC: pass a DECIMAL fetch_pc value (a single quote in 64'h.. breaks the
# docker sh -c recipe).  e.g. 0x800004e0 -> BOOT_HANG_PC=2147485408
ifneq ($(BOOT_HANG_PC),)
BOOT_TRACE_FLAG += -DBOOT_HANG_PC=$(BOOT_HANG_PC)
endif
ifneq ($(BOOT_DUMP_AT),)
BOOT_TRACE_FLAG += -DBOOT_DUMP_AT=$(BOOT_DUMP_AT)
endif
ifneq ($(BOOT_EXEC_LO),)
BOOT_TRACE_FLAG += -DBOOT_EXEC_LO=$(BOOT_EXEC_LO)
endif
ifneq ($(BOOT_IPROBE),)
BOOT_TRACE_FLAG += -DBOOT_IPROBE
endif
ifneq ($(BOOT_PTWLO),)
BOOT_TRACE_FLAG += -DBOOT_PTWLO=$(BOOT_PTWLO)
endif
# Cycle floor for the trustworthy fetch/load/store detectors (skip early-boot
# false positives that exhaust the caps; see tb_rv_boot_soc.sv BOOT_DET_LO).
ifneq ($(BOOT_DET_LO),)
BOOT_TRACE_FLAG += -DBOOT_DET_LO=$(BOOT_DET_LO)
endif
ifneq ($(BOOT_DCWIN),)
BOOT_TRACE_FLAG += -DBOOT_DCWIN=$(BOOT_DCWIN)
endif
ifneq ($(BOOT_FETCHWIN),)
BOOT_TRACE_FLAG += -DBOOT_FETCHWIN=$(BOOT_FETCHWIN)
endif
ifneq ($(BOOT_CTRPROBE),)
BOOT_TRACE_FLAG += -DBOOT_CTRPROBE
endif
# Differential store-sequence hash (baseline vs C-2a corruption hunt)
ifneq ($(BOOT_STHASH),)
BOOT_TRACE_FLAG += -DBFM_STORE_HASH
endif
ifneq ($(BOOT_STLO),)
BOOT_TRACE_FLAG += -DSTLO=$(BOOT_STLO)
endif
# Physical-address write watch (one 8-byte word), e.g. BOOT_WATCH_PA="64'h818690e8"
ifneq ($(BOOT_WATCH_PA),)
BOOT_TRACE_FLAG += -DBOOT_WATCH_PA="$(BOOT_WATCH_PA)"
endif
# udelay entry PC for the [UDELAY] probe (vmlinux-layout dependent), e.g.
#   make vl_boot ... BOOT_TRACE=1 BOOT_UDELAY_PC="64'hffffffff8094f5b4"
ifneq ($(BOOT_UDELAY_PC),)
BOOT_TRACE_FLAG += -DBOOT_UDELAY_PC="$(BOOT_UDELAY_PC)"
endif
else
BOOT_TRACE_FLAG =
endif

# Optional cache bypass for debug: make sim_boot BOOT_NO_DCACHE=1 / BOOT_NO_ICACHE=1
BOOT_DBG_FLAG =
ifneq ($(BOOT_NO_DCACHE),)
BOOT_DBG_FLAG += -DBOOT_NO_DCACHE
endif
ifneq ($(BOOT_NO_ICACHE),)
BOOT_DBG_FLAG += -DBOOT_NO_ICACHE
endif
# Model the board's AXI SmartConnect -> ONE PS DDR: serialize the BFM's IF / data
# / write channels (only one in flight at a time) so I$-vs-data contention -- the
# real-HW difference the parallel-port BFM cannot show -- is exercised.
ifneq ($(BOOT_SERIALIZE),)
BOOT_DBG_FLAG += -DBFM_SERIALIZE
endif
# Per-transaction VARIABLE BFM latency: de-phase the IF / data / write ports with
# independent LFSR streams so the I$-fill-vs-PTW interleavings real concurrent
# masters produce (and the step-8 block fetch hits on hardware) are exercised.
# BOOT_RANDLAT=1 enables; BOOT_SEED=<n> picks the stream; BOOT_RAND_SPREAD=<n> the
# max extra cycles.  Deterministic per seed.  e.g.
#   make vl_boot BOOT_HEX=... BOOT_RANDLAT=1 BOOT_SEED=3
ifneq ($(BOOT_RANDLAT),)
BOOT_DBG_FLAG += -DBFM_RANDLAT
endif
# Differential store-sequence hash, standalone (no full BOOT_TRACE).  Prints
# [STHASH] every 20000 memory-changing kernel-VA-valued stores BY INDEX, which is
# latency-INDEPENDENT -- so a baseline run and a randlat run agree until the first
# corrupting/squashed store, localizing the bug.  BOOT_STLO=<n> dumps detailed
# [ST] lines around index n.
ifneq ($(BOOT_STOREHASH),)
BOOT_DBG_FLAG += -DBFM_STORE_HASH
endif
# Divide-result golden check (muldiv retire vs software /,%): catches a divide that
# retires with a wrong/stale result -- the #14 muldiv-timing class, UNCHECKED by the
# load/store/forward detectors.  Standalone (was only under BOOT_TRACE before).
ifneq ($(BOOT_DIVCHK),)
BOOT_DBG_FLAG += -DBOOT_DIVCHK
endif
# ISS co-sim: independent integer shadow regfile, checks the core's forwarded
# operands against the architecturally-correct value at each EX-commit (catches a
# wrong-forward / wrong-register-value the other detectors miss).  [ISS] line = bug.
ifneq ($(BOOT_ISS),)
BOOT_DBG_FLAG += -DBOOT_ISS
endif
ifneq ($(BOOT_STLO),)
BOOT_DBG_FLAG += -DSTLO=$(BOOT_STLO)
endif
ifneq ($(BOOT_SEED),)
BOOT_DBG_FLAG += -DBFM_SEED=$(BOOT_SEED)
endif
ifneq ($(BOOT_RAND_SPREAD),)
BOOT_DBG_FLAG += -DBFM_RAND_SPREAD=$(BOOT_RAND_SPREAD)
endif
ifneq ($(BOOT_ICACHE_SETS),)
BOOT_DBG_FLAG += -DBOOT_ICACHE_SETS=$(BOOT_ICACHE_SETS)
endif
ifneq ($(BOOT_DCACHE_SETS),)
BOOT_DBG_FLAG += -DBOOT_DCACHE_SETS=$(BOOT_DCACHE_SETS)
endif
# Opt-in VCD dump (off by default: the 64 MiB shared-DDR array makes the VCD
# huge and the run much slower).  wave_boot sets this automatically.
ifneq ($(BOOT_VCD),)
BOOT_DBG_FLAG += -DBOOT_VCD
endif

# Optional: AXI BFM latency injection (cycles) to emulate real-HW DDR/SmartConnect
# timing.  Default 0 (strict no-op = proven baseline).  Widens the imem_ready/
# dmem_wait stall windows that mask variable-latency atomic/LR-SC races on the
# otherwise near-combinational (0-delay) BFM.  e.g. BOOT_AR_DELAY=8 BOOT_R_DELAY=4
BOOT_DELAY_FLAG =
ifneq ($(BOOT_AR_DELAY),)
BOOT_DELAY_FLAG += -DBOOT_AR_DELAY=$(BOOT_AR_DELAY)
endif
ifneq ($(BOOT_R_DELAY),)
BOOT_DELAY_FLAG += -DBOOT_R_DELAY=$(BOOT_R_DELAY)
endif
ifneq ($(BOOT_AW_DELAY),)
BOOT_DELAY_FLAG += -DBOOT_AW_DELAY=$(BOOT_AW_DELAY)
endif
ifneq ($(BOOT_W_DELAY),)
BOOT_DELAY_FLAG += -DBOOT_W_DELAY=$(BOOT_W_DELAY)
endif
ifneq ($(BOOT_B_DELAY),)
BOOT_DELAY_FLAG += -DBOOT_B_DELAY=$(BOOT_B_DELAY)
endif

sim_boot: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -DRV_XLEN_64 $(BOOT_HEX_FLAG) $(BOOT_MAX_FLAG) $(BOOT_MEMBASE_FLAG) $(BOOT_MTIME_FLAG) $(BOOT_TRACE_FLAG) $(BOOT_DBG_FLAG) $(BOOT_DELAY_FLAG) \
		-o $(OUT_DIR)/tb_rv_boot_soc.vvp \
		$(BOOT_SRC) $(TB_DIR)/tb_rv_boot_soc.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_boot_soc.vvp

wave_boot:
	$(MAKE) sim_boot BOOT_VCD=1
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_boot_soc.vcd &

# --- Verilator fast boot harness (same RTL/TB as sim_boot, ~100x faster) ---
# iverilog runs the OpenSBI full boot (~8M cycles) in ~15-20 min; Verilator does
# it in ~8 s, which is what makes the multi-10M..100M-cycle Linux boot tractable.
# Uses the SAME BOOT_* knobs as sim_boot (all are compile-time -D defines, so a
# config change rebuilds the model -- the build is only ~7 s):
#   make image_verilator                         # build verilator:5.020 image (once)
#   make vl_boot                                 # mini-SBI stand-in (default)
#   make vl_boot BOOT_HEX=/abs/fw_payload.hex BOOT_MAX=200000000
#   make vl_boot BOOT_HEX=... BOOT_TRACE=1 BOOT_EXEC=1 BOOT_EXEC_LO=8000000
# See docs/verilator_sim.md.
VL_IMAGE := verilator:5.020
VL_DOCKER_RUN := docker run --rm -i $(DOCKER_TTY) \
                -v $(PROJECT_ROOT):/workspace \
                -w /workspace/src/sim \
                $(VL_IMAGE)
VL_BOOT_MDIR = $(OUT_DIR)/vl_boot
# --timing handles the TB's #-delay clock; -Wno-fatal keeps WIDTH/LATCH warnings
# non-fatal (the RTL is iverilog-clean and these are known benign).
VL_FLAGS = --binary -j 0 --timing -Wno-fatal -O3 -CFLAGS -O2 -DRISCV_FORMAL

image_verilator:
	cd $(MAKEFILE_DIR) && docker build -t $(VL_IMAGE) -f Dockerfile.verilator .

vl_boot: dirs
	$(VL_DOCKER_RUN) verilator $(VL_FLAGS) -DRV_XLEN_64 \
		$(BOOT_HEX_FLAG) $(BOOT_MAX_FLAG) $(BOOT_MEMBASE_FLAG) $(BOOT_MTIME_FLAG) $(BOOT_TRACE_FLAG) $(BOOT_DBG_FLAG) $(BOOT_DELAY_FLAG) \
		-I$(INC_DIR) --top-module tb_rv_boot_soc --Mdir $(VL_BOOT_MDIR) -o tb_rv_boot_soc \
		$(BOOT_SRC) $(TB_DIR)/tb_rv_boot_soc.sv
	$(VL_DOCKER_RUN) ./$(VL_BOOT_MDIR)/tb_rv_boot_soc

# --- rv_core instruction port over AXI (variable latency) integration TB ---
AXI_IF_SRC = $(CORE_SRC) $(BUS_DIR)/rv_axi_bridge.sv $(TB_DIR)/rv_axi_slave_bfm.sv

sim_axi_ifetch: dirs
	$(DOCKER_RUN) $(IVERILOG) $(IVFLAGS) -o $(OUT_DIR)/tb_rv_axi_ifetch.vvp \
		$(AXI_IF_SRC) $(TB_DIR)/tb_rv_axi_ifetch.sv
	$(DOCKER_RUN) $(VVP) $(OUT_DIR)/tb_rv_axi_ifetch.vvp

wave_axi_ifetch: sim_axi_ifetch
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_axi_ifetch.vcd &

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

# XLEN selection for ACT runs.  Default RV64 (-DRV_XLEN_64); the compliance
# Makefile passes XLEN_DEF= (empty) to build the RV32 (XLEN=32) variant for
# rv32uc-p etc.
XLEN_DEF ?= -DRV_XLEN_64

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
	$(IVERILOG) $(IVFLAGS) $(XLEN_DEF) \
		-DHEX_FILE=\"$(HEX_FILE)\"       \
		-DSIG_FILE=\"$(SIG_FILE)\"       \
		-DBEGIN_SIG=\"$(BEGIN_SIG)\"     \
		-DEND_SIG=\"$(END_SIG)\"         \
		-DTOHOST_ADDR=\"$(TOHOST_ADDR)\" \
		-o $(OUT_DIR)/tb_rv_act.vvp      \
		$(ACT_SRC) $(TB_DIR)/tb_rv_act.sv
	$(VVP) $(OUT_DIR)/tb_rv_act.vvp

sim_act_debug_internal:
	$(IVERILOG) $(IVFLAGS) $(XLEN_DEF) \
		-DHEX_FILE=\"$(HEX_FILE)\"       \
		-DTOHOST_ADDR=\"$(TOHOST_ADDR)\" \
		-o $(OUT_DIR)/tb_rv_act_debug.vvp \
		$(ACT_SRC) $(TB_DIR)/tb_rv_act_debug.sv
	$(VVP) $(OUT_DIR)/tb_rv_act_debug.vvp

wave_act:
	$(GTKWAVE) $(WAVE_DIR)/tb_rv_act.vcd

# --- Clean ---
clean:
	rm -rf $(OUT_DIR) $(WAVE_DIR)

