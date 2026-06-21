# =============================================================================
# build_zybo.tcl - Reproducible Vivado project + block design for Zybo Z7-20
# =============================================================================
# Connects the RISC-V SoC (rv_soc: AXI/DDR + peripherals) as AXI4 master(s) to the
# Zynq-7000 PS (PS7) DDR via an AXI SmartConnect and an S_AXI_HP port.
# Fully scripted (no GUI) for version control / reproducibility.
#
# Usage:
#   vivado -mode batch -source boards/zybo_z720/vivado/build_zybo.tcl
#   vivado -mode batch -source boards/zybo_z720/vivado/build_zybo.tcl -tclargs bit
#
# IMPORTANT address-map note (Zynq-7000): PS DDR lives at 0x0000_0000..0x3FFF_FFFF
# (1 GB on Zybo Z7-20).  The S_AXI_HP port forwards incoming addresses into the
# PS memory map, so the *program's* load/store addresses (and rv_soc RST_ADDR)
# must target the DDR range.  rv_soc has no internal data memory (no internal
# decode for the DDR region -- those accesses go straight to the HP port -- so link the
# program's data into the PS DDR region.  See boards/vivado_README.md.
# =============================================================================

set build_to "bd"
if {$argc >= 1} { set build_to [lindex $argv 0] }

set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize "$script_dir/../../.."]
set rtl        "$repo/src/rtl"
set proj_name  "rv_riscv_zybo"
set proj_dir   "$script_dir/$proj_name"

# Zybo Z7-20: Zynq-7000 XC7Z020-1CLG400C
set PART  "xc7z020clg400-1"
set XLEN64 1           ;# 1 = RV64 (target for Linux); HP ports are 64-bit.

# PL clock (FCLK_CLK0) target.  OOC est (C-2d) WNS -20.246 ns @100 MHz => path
# ~30.2 ns => max Fmax ~33 MHz.  Started conservative at 25 MHz to close on the
# first P&R pass.  After the 50MHz-roadmap timing work (steps: D$/MMU/fetch/FPU/MUL
# pipelining) the routed worst path fell to ~30.7 ns (WNS +7.859 @25 MHz), so the
# clock is raised here.  PL_FREQMHZ=30 -> PCW realizes FCLK_CLK0 = IO PLL (1000 MHz)
# / 33 = 30.303 MHz (33.0 ns); routed WNS = +3.478 ns (timing met) for ~21% faster
# real-HW boot while the full 50 MHz push continues.  The mtime / UART-baud / DT
# constants follow the ACTUAL realized PL clock (rv_soc_linux_hw.dts +
# docs/opensbi/rv_soc_hw.dts: timebase-frequency + serial clock-frequency =
# 30303030; baud divisor = round(PL/(16*baud))); keep them in sync with the
# realized FCLK, not the request.
set PL_FREQMHZ 30

create_project $proj_name $proj_dir -part $PART -force
set_property target_language Verilog [current_project]

# ---- Digilent Zybo Z7-20 board part (vendored; no Vivado-install pollution) ----
# The board files (DDR3/MIO/clock preset) live in the repo and are referenced via
# board_part_repo_paths so apply_board_preset configures the PS7 to match the real
# board.  Required for the PS to boot and for PS DDR to be reachable over S_AXI_HP.
set board_repo "$repo/boards/zybo_z720/board_files"
set_property board_part_repo_paths [list $board_repo] [current_project]
set_property board_part digilentinc.com:zybo-z7-20:part0:1.2 [current_project]

set src_files [list \
    "$rtl/include/rv_pkg.sv" \
    "$rtl/core/rv_regfile.sv" \
    "$rtl/core/rv_fregfile.sv" \
    "$rtl/core/rv_cdecode.sv" \
    "$rtl/core/rv_decode.sv" \
    "$rtl/exec/rv_branch.sv" \
    "$rtl/exec/rv_alu.sv" \
    "$rtl/exec/rv_muldiv.sv" \
    "$rtl/exec/rv_amo.sv" \
    "$rtl/core/rv_forward.sv" \
    "$rtl/core/rv_csr.sv" \
    "$rtl/core/rv_hazard.sv" \
    "$rtl/core/rv_mmu.sv" \
    "$rtl/fpu/rv_fpu_add.sv" \
    "$rtl/fpu/rv_fpu_mul.sv" \
    "$rtl/fpu/rv_fpu_div.sv" \
    "$rtl/fpu/rv_fpu_sqrt.sv" \
    "$rtl/fpu/rv_fpu_misc.sv" \
    "$rtl/fpu/rv_fpu_add_d.sv" \
    "$rtl/fpu/rv_fpu_mul_d.sv" \
    "$rtl/fpu/rv_fpu_div_d.sv" \
    "$rtl/fpu/rv_fpu_sqrt_d.sv" \
    "$rtl/fpu/rv_fpu_misc_d.sv" \
    "$rtl/fpu/rv_fpu.sv" \
    "$rtl/core/rv_core.sv" \
    "$rtl/core/rv_cpu.sv" \
    "$rtl/peripherals/clint/rv_timer.sv" \
    "$rtl/peripherals/uart/rv_uart.sv" \
    "$rtl/peripherals/gpio/rv_gpio.sv" \
    "$rtl/peripherals/plic/rv_plic.sv" \
    "$rtl/peripherals/rv_periph.sv" \
    "$rtl/bus/rv_axi_bridge.sv" \
    "$rtl/bus/rv_axi_burst_bridge.sv" \
    "$rtl/cache/rv_icache.sv" \
    "$rtl/cache/rv_dcache.sv" \
    "$rtl/soc/rv_soc.sv" \
]
add_files -norecurse $src_files
set_property file_type {SystemVerilog} [get_files *.sv]

# Plain-Verilog top wrapper so the BD can reference the SoC (Vivado forbids a
# SystemVerilog top file in a module reference; see rv_soc_wrap.v).
add_files -norecurse "$script_dir/rv_soc_wrap.v"

# Physical pin constraints (UART console on Pmod JC).  PS DDR/MIO/FIXED_IO are
# auto-constrained by the board preset, so only the PL UART pins are listed here.
add_files -norecurse -fileset constrs_1 "$script_dir/zybo_uart.xdc"

if {$XLEN64} { set_property verilog_define {RV_XLEN_64} [get_filesets sources_1] }
set_property include_dirs "$rtl/include" [get_filesets sources_1]

# Parse/elaborate the SV sources so the module hierarchy (rv_soc) is known to the
# BD before referencing it.  Without this, create_bd_cell -reference rv_soc fails
# with "[filemgmt 56-195] ... SystemVerilog ... not allowed as the top file in the
# reference" because the compile order has not yet identified rv_soc as a module.
update_compile_order -fileset sources_1

# =============================================================================
# Block design
# =============================================================================
set bd_name "bd_riscv"
create_bd_design $bd_name

# ---- Zynq-7000 PS (PS7) ----
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:* zynq_ps]
# Apply the Zybo Z7-20 board preset (DDR3 controller + MIO map + clocks) and make
# the PS dedicated I/O external: FIXED_IO (MIO/JTAG/clk/reset) and the DDR pins
# become top-level ports.  Without this the PS7 keeps a generic default config that
# does not match the board -> the PS will not boot and PS DDR is unusable.
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config { make_external "FIXED_IO, DDR" apply_board_preset "1" \
              Master "Disable" Slave "Disable" } $ps
# On top of the board preset: enable one 64-bit HP slave port for the PL master,
# a PL clock (FCLK_CLK0) at PL_FREQMHZ and a PL reset; the board preset leaves
# M_AXI_GP0 on, which we do not use.
set_property -dict [list \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_USE_M_AXI_GP0 {0} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $PL_FREQMHZ \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_RST0_PORT {1} \
] $ps

# ---- RISC-V SoC (RTL module reference; AXI master inferred from m_axi_*) ----
set riscv [create_bd_cell -type module -reference rv_soc_wrap rv_soc_0]
# The BD discovers the module-reference parameters by elaborating rv_soc_wrap
# WITHOUT the fileset's RV_XLEN_64 define, so the wrapper's `ifdef defaults XLEN
# to 32 and the generated IP wrapper bakes XLEN=32 (forcing 32 down the whole
# SoC and breaking RV64 part-selects).  Pin XLEN on the cell explicitly so the
# generated wrapper passes the intended width regardless of the define.
set XLEN_VAL [expr {$XLEN64 ? 64 : 32}]
set_property CONFIG.XLEN $XLEN_VAL $riscv
# RST_ADDR (core reset / firmware entry) is carried by the rv_soc_wrap default
# (0x0020_0000, a PS-DDR-resident, 2 MiB-aligned base inside the HP0 window).  It is
# NOT set via CONFIG here on purpose: a 64-bit param through the BD module-ref can be
# truncated, and the wrapper default is small (fits 32 bits) and unconditional, so the
# BD bakes it correctly.  The OpenSBI fw_payload + DTB must be re-linked to this base
# for the HW DDR boot flow (see CLAUDE.md "C-3" / docs/axi_ddr.md address map).
# GPIO input is still tied off (no board wiring yet); GPIO output is left open.
set c0 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:* const_gpio_in]
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] $c0
connect_bd_net [get_bd_pins $c0/dout] [get_bd_pins rv_soc_0/gpio_in]

# ---- UART -> external top-level ports (constrained to Pmod JC in zybo_uart.xdc) ----
# uart_tx is an FPGA output, uart_rx an FPGA input.  Making them external BD ports
# (named uart_tx / uart_rx) lets the .xdc pin them to physical Pmod pins so the real
# OpenSBI/Linux console is observable on a USB-UART adapter.
make_bd_pins_external  -name uart_tx [get_bd_pins rv_soc_0/uart_tx]
make_bd_pins_external  -name uart_rx [get_bd_pins rv_soc_0/uart_rx]

# ---- AXI SmartConnect (2 masters [data, instruction] -> 1 slave) ----
set smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_smc]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $smc

# ---- Processor System Reset ----
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* proc_rst]

# ---- Clocks / resets ----
set ps_clk  [get_bd_pins zynq_ps/FCLK_CLK0]
set ps_rstn [get_bd_pins zynq_ps/FCLK_RESET0_N]
connect_bd_net $ps_clk  [get_bd_pins proc_rst/slowest_sync_clk]
connect_bd_net $ps_rstn [get_bd_pins proc_rst/ext_reset_in]
connect_bd_net $ps_clk  [get_bd_pins rv_soc_0/clk]
connect_bd_net [get_bd_pins proc_rst/peripheral_aresetn] [get_bd_pins rv_soc_0/rst_n]
connect_bd_net $ps_clk  [get_bd_pins axi_smc/aclk]
connect_bd_net [get_bd_pins proc_rst/interconnect_aresetn] [get_bd_pins axi_smc/aresetn]
connect_bd_net $ps_clk  [get_bd_pins zynq_ps/S_AXI_HP0_ACLK]

# ---- AXI paths: rv_soc data + instruction masters -> SmartConnect -> PS HP0 ----
connect_bd_intf_net [get_bd_intf_pins rv_soc_0/m_axi]    [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins rv_soc_0/m_axi_if] [get_bd_intf_pins axi_smc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI]   [get_bd_intf_pins zynq_ps/S_AXI_HP0]

assign_bd_address
regenerate_bd_layout
validate_bd_design
save_bd_design

if {$build_to eq "bd"} {
    puts "INFO: Block design created. Stop (build_to=bd)."
    return
}

set bd_file [get_files "$bd_name.bd"]

# Synthesize the BD in GLOBAL (flat) mode rather than per-IP out-of-context.
# The rv_soc_wrap module reference selects RV64 via the RV_XLEN_64 `ifdef, and
# rv_pkg::XLEN depends on the same define.  That define is set only on the
# sources_1 fileset (the top synth_1 run); a per-IP OOC synth run for the BD
# cell does NOT inherit it, leaving XLEN=32 inside the SoC and breaking RV64-only
# part-selects (e.g. int_a[63:0] in rv_fpu_misc).  Global mode folds the BD into
# synth_1 so the fileset define applies uniformly.
set_property synth_checkpoint_mode None $bd_file

make_wrapper -files $bd_file -top
set wrapper "$proj_dir/$proj_name.gen/sources_1/bd/$bd_name/hdl/${bd_name}_wrapper.v"
add_files -norecurse $wrapper
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

if {$build_to eq "synth"} {
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    puts "INFO: Synthesis done."
    return
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts "INFO: Bitstream generation done."

# ---- Export a fixed HW platform (.xsa) for Vitis (FSBL/BOOT.bin/JTAG) ----
# Bundles ps7_init (PS DDR/MIO/clock bring-up) + the implemented bitstream.  This
# is the hand-off Vitis consumes (prep-C/D).  To (re-)emit the XSA from an existing
# build without re-running impl, use export_xsa.tcl instead.
open_run impl_1
write_hw_platform -fixed -include_bit -force "$proj_dir/$proj_name.xsa"
puts "INFO: Wrote HW platform $proj_dir/$proj_name.xsa"
