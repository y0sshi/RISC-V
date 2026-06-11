# =============================================================================
# build_kv260.tcl - Reproducible Vivado project + block design for KV260
# =============================================================================
# Connects the RISC-V SoC (rv_soc: AXI/DDR + peripherals) as AXI4 master(s) to the
# Zynq UltraScale+ PS (PS8) DDR via an AXI SmartConnect and an S_AXI_HP port.
# Fully scripted (no GUI) for version control / reproducibility.
#
# Usage (from the repo root or anywhere):
#   vivado -mode batch -source boards/kv260/vivado/build_kv260.tcl
#   # optional args (via -tclargs): <build_to>   where build_to in {bd|synth|bit}
#   vivado -mode batch -source boards/kv260/vivado/build_kv260.tcl -tclargs bit
#
# Notes / knobs you may need to adjust for your exact setup:
#   - PART / BOARD_PART: KV260 K26 SOM part. Adjust if your install differs.
#   - HP data width: set to 64 to match XLEN=64 (RV64). For RV32 use 32.
#   - DDR base / address segment: the core uses 0x8000_0000 as its data base
#     (see rv_pkg / memory map). The HP address segment below is set to cover
#     that range; the loaded program's linker layout and rv_soc RST_ADDR must
#     agree with the DDR region the PS exposes.
#   - Verilog define: RV_XLEN_64 for RV64 (rv_soc selects the AXI/DDR SoC by name).
# =============================================================================

# ---- Arguments ----
set build_to "bd"
if {$argc >= 1} { set build_to [lindex $argv 0] }

# ---- Paths ----
set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize "$script_dir/../../.."]
set rtl        "$repo/src/rtl"
set proj_name  "rv_riscv_kv260"
set proj_dir   "$script_dir/$proj_name"

# ---- Device ----
# KV260 / K26 SOM (Zynq UltraScale+ XCK26). Adjust to match your install.
set PART  "xck26-sfvc784-2LV-c"
set XLEN64 1            ;# 1 = RV64 (DATA_WIDTH 64), 0 = RV32 (DATA_WIDTH 32)

# ---- (Re)create project ----
create_project $proj_name $proj_dir -part $PART -force
set_property target_language Verilog [current_project]

# ---- Source files (rv_soc = AXI/DDR SoC + dependencies) ----
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

# ---- Verilog defines: RV64 (rv_soc is the AXI/DDR SoC by module choice; no
#      build-mode define needed since the file split) ----
if {$XLEN64} { set_property verilog_define {RV_XLEN_64} [get_filesets sources_1] }
set_property include_dirs "$rtl/include" [get_filesets sources_1]

# =============================================================================
# Block design
# =============================================================================
set bd_name "bd_riscv"
create_bd_design $bd_name

# ---- Zynq UltraScale+ PS (PS8) ----
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* zynq_ps]
# Apply default board preset if a board part is set; otherwise configure minimally.
# Enable: one PL clock (pl_clk0), one PL reset, and one HP slave (S_AXI_HP0_FPD).
set hp_dw [expr {$XLEN64 ? 64 : 32}]
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {0} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH $hp_dw \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
] $ps
# (CONFIG keys above follow PS8 conventions; if a board file is installed you
#  may prefer: apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
#                 -config {apply_board_preset 1} $ps  then enable S_AXI_HP0.)

# ---- RISC-V SoC (RTL module reference; AXI master inferred from m_axi_* ports)
set riscv [create_bd_cell -type module -reference rv_soc rv_soc_0]
# Tie off GPIO/UART inputs (outputs left open for a headless DDR bring-up).
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
set ps_clk  [get_bd_pins zynq_ps/pl_clk0]
set ps_rstn [get_bd_pins zynq_ps/pl_resetn0]
connect_bd_net $ps_clk  [get_bd_pins proc_rst/slowest_sync_clk]
connect_bd_net $ps_rstn [get_bd_pins proc_rst/ext_reset_in]
connect_bd_net $ps_clk  [get_bd_pins rv_soc_0/clk]
connect_bd_net [get_bd_pins proc_rst/peripheral_aresetn] [get_bd_pins rv_soc_0/rst_n]
connect_bd_net $ps_clk  [get_bd_pins axi_smc/aclk]
connect_bd_net [get_bd_pins proc_rst/interconnect_aresetn] [get_bd_pins axi_smc/aresetn]
connect_bd_net $ps_clk  [get_bd_pins zynq_ps/saxihp0_fpd_aclk]
connect_bd_net $ps_clk  [get_bd_pins zynq_ps/maxihpm0_fpd_aclk]

# ---- AXI paths: rv_soc data + instruction masters -> SmartConnect -> PS HP0 ----
# The discrete m_axi_*/m_axi_if_* ports are inferred by Vivado as master
# interfaces "m_axi" (data, read/write) and "m_axi_if" (instruction, read-only).
connect_bd_intf_net [get_bd_intf_pins rv_soc_0/m_axi]    [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins rv_soc_0/m_axi_if] [get_bd_intf_pins axi_smc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI]   [get_bd_intf_pins zynq_ps/S_AXI_HP0_FPD]

# ---- Address assignment ----
# Map the core's DDR window so the HP port reaches PS DDR. The core uses
# 0x8000_0000 as its data base; assign a segment covering it.
assign_bd_address
# If auto-assignment does not cover 0x8000_0000, set it explicitly, e.g.:
#   assign_bd_address -offset 0x80000000 -range 0x40000000 \
#       [get_bd_addr_segs {zynq_ps/SAXIGP2/HP0_DDR_LOW}]

regenerate_bd_layout
validate_bd_design
save_bd_design

if {$build_to eq "bd"} {
    puts "INFO: Block design created. Stop (build_to=bd)."
    return
}

# ---- Wrapper + top ----
set bd_file [get_files "$bd_name.bd"]
make_wrapper -files $bd_file -top
set wrapper "$proj_dir/$proj_name.gen/sources_1/bd/$bd_name/hdl/${bd_name}_wrapper.v"
add_files -norecurse $wrapper
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

if {$build_to eq "synth"} {
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    puts "INFO: Synthesis done (build_to=synth)."
    return
}

# ---- Bitstream ----
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts "INFO: Bitstream generation done."
