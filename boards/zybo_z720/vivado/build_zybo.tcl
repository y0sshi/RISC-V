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
set XLEN64 0           ;# Zynq-7000 HP ports are 64-bit; RV32 (XLEN=32) shown here.

create_project $proj_name $proj_dir -part $PART -force
set_property target_language Verilog [current_project]

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

if {$XLEN64} { set_property verilog_define {RV_XLEN_64} [get_filesets sources_1] }
set_property include_dirs "$rtl/include" [get_filesets sources_1]

# =============================================================================
# Block design
# =============================================================================
set bd_name "bd_riscv"
create_bd_design $bd_name

# ---- Zynq-7000 PS (PS7) ----
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:* zynq_ps]
# Enable one HP slave port, a PL clock (FCLK_CLK0) and PL reset.
set_property -dict [list \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_USE_M_AXI_GP0 {0} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_RST0_PORT {1} \
] $ps
# (If the Zybo board files are installed you may instead run:
#   apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
#       -config {make_external "FIXED_IO, DDR" apply_board_preset 1 } $ps
#  then enable S_AXI_HP0.)

# ---- RISC-V SoC (RTL module reference; AXI master inferred from m_axi_*) ----
set riscv [create_bd_cell -type module -reference rv_soc rv_soc_0]
set c0 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:* const_gpio_in]
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] $c0
set c1 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:* const_uart_rx]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $c1
connect_bd_net [get_bd_pins $c0/dout] [get_bd_pins rv_soc_0/gpio_in]
connect_bd_net [get_bd_pins $c1/dout] [get_bd_pins rv_soc_0/uart_rx]

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
