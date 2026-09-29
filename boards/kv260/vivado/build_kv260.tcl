# =============================================================================
# build_kv260.tcl - Reproducible Vivado project + block design for Kria KV260
# =============================================================================
# Connects the RISC-V SoC (rv_soc: AXI/DDR + peripherals) as AXI4 master(s) to the
# Zynq UltraScale+ PS (PS8) DDR4 via an AXI SmartConnect and an S_AXI_HP port.
# Fully scripted (no GUI) for version control / reproducibility.
#
# KV260 is a DIFFERENT PS architecture from Zybo Z7-20 / PYNQ-Z1/Z2 (Zynq-7000
# PS7): it is Zynq UltraScale+ (PS8, XCK26 on the K26 SOM). Reuses the same
# rv_soc RTL/rv_soc_wrap and the same overall stage-separated build structure
# as boards/zybo_z720/vivado/build_zybo.tcl, but the PS IP, board_part, clock
# knob and boot flow (see ../vitis/) are all PS8-specific.
#
# Usage:
#   vivado -mode batch -source boards/kv260/vivado/build_kv260.tcl
#   vivado -mode batch -source boards/kv260/vivado/build_kv260.tcl -tclargs bit
#
# Board part: this KV260 = "K26 SOM" (xck26-sfvc784-2LV-c) mounted on the
# "Vision AI Starter Kit" carrier card. Xilinx ships the board_part files
# (kv260_som, kv260_carrier) INSIDE the Vivado 2024.2 install itself
# (data/xhub/boards/XilinxBoardStore/boards/Xilinx/kv260_som,.../kv260_carrier)
# -- unlike Zybo/PYNQ this repo does NOT need to vendor board files.
# Empirically verified (2026-07-04, Vivado 2024.2): set_property board_part
# xilinx.com:kv260_som:part0:1.4 + apply_bd_automation ... apply_board_preset
# alone configures the DDR4 (PSU__DDRC__BUS_WIDTH=64bit) with zero warnings;
# the carrier card's own board_part/board_connections is NOT needed for our
# purposes because we do NOT use Vivado's board-interface auto-wiring for the
# UART (same manual make_bd_pins_external + XDC approach as Zybo/PYNQ) -- the
# only thing carrier-side we need (DDR4 timing, PS clocks) lives on the SOM.
#
# IMPORTANT address-map note: PS DDR4 (2GB on the KV260 K26 SOM) is reached
# through the PS8 S_AXI_HP port, same shape as Zybo/PYNQ's S_AXI_HP0 but a
# different port name (S_AXI_HP0_FPD) and CONFIG.PSU__SAXIGP2__DATA_WIDTH
# knob. rv_soc RST_ADDR / the loaded program's linker layout must agree with
# whatever DDR range assign_bd_address maps this port to.
# =============================================================================

set build_to "bd"
if {$argc >= 1} { set build_to [lindex $argv 0] }

set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize "$script_dir/../../.."]
set rtl        "$repo/src/rtl"
set proj_name  "rv_riscv_kv260"
set proj_dir   "$script_dir/$proj_name"
set bd_name    "bd_riscv"   ;# also (re)set in the create branch; needed early for reuse stages

# KV260 K26 SOM: Zynq UltraScale+ XCK26-SFVC784-2LV-C
set PART  "xck26-sfvc784-2LV-c"
set XLEN64 1           ;# 1 = RV64 (target for Linux); HP ports are 64-bit.

# PL clock (pl_clk0) target. DIFFERENT clock generator from Zynq-7000 (PS8's
# CRL_APB PLL tree, not the single "IO PLL / integer divisor" of PS7), so the
# Zybo/PYNQ set_pl_freq.py FCLK-divisor math does NOT apply here -- see
# ../set_pl_freq.py for how this knob is retargeted and how to read back the
# ACTUAL realized clock (from the generated report, not computed blind).
# Starting conservative at 50 MHz (same target already met on Zybo/PYNQ at
# this frequency on the SAME RTL, but PS8/DDR4 timing has not been
# independently re-measured on this chip yet).
set PL_FREQMHZ 50

# ---------------------------------------------------------------------------
# Stage dispatch. Project creation is its OWN stage; synth/impl/bit only OPEN
# the project already on disk, so no stage ever recreates it and there is no
# `create_project -force` (no stage silently destroys synth/impl results). A
# build can resume from any point:
#   project : create project + block design + sources (idempotent: reuse if present)
#   synth   : open project -> synthesize                -> synth_1
#   impl    : open project -> place + route (REUSE synth_1) -> routed impl_1
#   bit     : open project -> write_bitstream + XSA     (REUSE routed impl_1)
#   all     : project + synth + impl + bit
# `bd` is accepted as an alias for `project`. build_all.py maps its
# --stage {synth,impl,bit} 1:1 onto these (fpga -> all).
# ---------------------------------------------------------------------------
if {$build_to eq "bd"} { set build_to "project" }
if {$build_to ni {project synth impl bit all}} {
    error "unknown stage '$build_to' (use: project | synth | impl | bit | all)"
}
set proj_xpr   "$proj_dir/$proj_name.xpr"
set do_project [expr {$build_to in {project all}}]
set do_synth   [expr {$build_to in {synth all}}]
set do_impl    [expr {$build_to in {impl all}}]
set do_bit     [expr {$build_to in {bit all}}]

# ---- PROJECT: create (no -force) or reuse an existing project --------------
if {$do_project} {
if {[file exists $proj_xpr]} {
    puts "INFO: reusing existing project $proj_xpr (delete $proj_dir to rebuild the BD/source list)."
    open_project $proj_xpr
} else {
create_project $proj_name $proj_dir -part $PART
set_property target_language Verilog [current_project]

# ---- Kria K26 SOM board part (built into the Vivado 2024.2 install; no
# board_part_repo_paths / vendoring needed, unlike Zybo/PYNQ). The DDR4/clock
# preset lives on the SOM itself (preset_s4.xml), so board_part alone (without
# also combining the kv260_carrier board_connections) is sufficient here.
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]

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
# SystemVerilog top file in a module reference). Shared with Zybo/PYNQ; see
# boards/zybo_z720/vivado/rv_soc_wrap.v for the rationale (single source, this
# copy is byte-identical -- board-agnostic).
add_files -norecurse "$script_dir/rv_soc_wrap.v"

# Physical pin constraints (UART console on the KV260's J2 Pmod-compatible
# header -- see kv260_uart.xdc for the pin-sourcing caveat). PS DDR4/MIO/
# FIXED_IO are auto-constrained by the board preset, so only the PL UART pins
# are listed here.
add_files -norecurse -fileset constrs_1 "$script_dir/kv260_uart.xdc"

if {$XLEN64} { set_property verilog_define {RV_XLEN_64} [get_filesets sources_1] }
set_property include_dirs "$rtl/include" [get_filesets sources_1]

# Parse/elaborate the SV sources so the module hierarchy (rv_soc) is known to the
# BD before referencing it. Without this, create_bd_cell -reference rv_soc fails
# with "[filemgmt 56-195] ... SystemVerilog ... not allowed as the top file in the
# reference" because the compile order has not yet identified rv_soc as a module.
update_compile_order -fileset sources_1

# =============================================================================
# Block design
# =============================================================================
set bd_name "bd_riscv"
create_bd_design $bd_name

# ---- Zynq UltraScale+ PS (PS8) ----
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* zynq_ps]
# Apply the K26 SOM board preset (DDR4 controller + clocks). Empirically
# verified (2026-07-04): this alone brings up DDR4 at 64-bit width with zero
# CRITICAL WARNINGs (cleaner than Zybo/PYNQ's DDR3 negative-DQS-skew warning).
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config { apply_board_preset "1" } $ps
# On top of the board preset: one PL clock (pl_clk0) at PL_FREQMHZ, one PL
# reset, and one 64-bit HP slave (S_AXI_HP0_FPD) for the PL master. No PS
# master AXI port is needed (we never issue transactions FROM the PS into the
# PL) so M_AXI_GP0/1/2 stay disabled.
set hp_dw [expr {$XLEN64 ? 64 : 32}]
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {0} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH $hp_dw \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $PL_FREQMHZ \
] $ps

# ---- RISC-V SoC (RTL module reference; AXI master inferred from m_axi_*) ----
set riscv [create_bd_cell -type module -reference rv_soc_wrap rv_soc_0]
# The BD discovers the module-reference parameters by elaborating rv_soc_wrap
# WITHOUT the fileset's RV_XLEN_64 define, so the wrapper's `ifdef defaults XLEN
# to 32 and the generated IP wrapper bakes XLEN=32 (forcing 32 down the whole
# SoC and breaking RV64 part-selects). Pin XLEN on the cell explicitly so the
# generated wrapper passes the intended width regardless of the define.
set XLEN_VAL [expr {$XLEN64 ? 64 : 32}]
set_property CONFIG.XLEN $XLEN_VAL $riscv
# RST_ADDR (core reset / firmware entry) is carried by the rv_soc_wrap default
# (0x0020_0000). The OpenSBI fw_payload + DTB must be re-linked to this base
# for the HW DDR boot flow (see CLAUDE.md "C-3" / docs/axi_ddr.md address map).
# GPIO input is still tied off (no board wiring yet); GPIO output is left open.
set c0 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:* const_gpio_in]
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] $c0
connect_bd_net [get_bd_pins $c0/dout] [get_bd_pins rv_soc_0/gpio_in]

# ---- UART -> external top-level ports (constrained to a J2 Pmod-compatible
#      pin pair in kv260_uart.xdc) ----
# uart_tx is an FPGA output, uart_rx an FPGA input. Making them external BD
# ports (named uart_tx / uart_rx) lets the .xdc pin them to physical pins so
# the real OpenSBI/Linux console is observable on a USB-UART adapter.
make_bd_pins_external  -name uart_tx [get_bd_pins rv_soc_0/uart_tx]
make_bd_pins_external  -name uart_rx [get_bd_pins rv_soc_0/uart_rx]

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
# No PS master AXI port is enabled (M_AXI_GP0/1/2 = 0), so there is no
# maxihpmX_fpd_aclk pin to clock; only the S_AXI_HP slave clock is needed.

# ---- AXI paths: rv_soc data + instruction masters -> SmartConnect -> PS HP0 ----
connect_bd_intf_net [get_bd_intf_pins rv_soc_0/m_axi]    [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins rv_soc_0/m_axi_if] [get_bd_intf_pins axi_smc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI]   [get_bd_intf_pins zynq_ps/S_AXI_HP0_FPD]

assign_bd_address
regenerate_bd_layout
validate_bd_design
save_bd_design

set bd_file [get_files "$bd_name.bd"]

# Synthesize the BD in GLOBAL (flat) mode rather than per-IP out-of-context.
# The rv_soc_wrap module reference selects RV64 via the RV_XLEN_64 `ifdef, and
# rv_pkg::XLEN depends on the same define. That define is set only on the
# sources_1 fileset (the top synth_1 run); a per-IP OOC synth run for the BD
# cell does NOT inherit it, leaving XLEN=32 inside the SoC and breaking RV64-only
# part-selects (e.g. int_a[63:0] in rv_fpu_misc). Global mode folds the BD into
# synth_1 so the fileset define applies uniformly.
set_property synth_checkpoint_mode None $bd_file

make_wrapper -files $bd_file -top
set wrapper "$proj_dir/$proj_name.gen/sources_1/bd/$bd_name/hdl/${bd_name}_wrapper.v"
add_files -norecurse $wrapper
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1
}  ;# end create-new-project (else branch of file-exists)
if {$build_to eq "project"} {
    puts "INFO: project ready ($proj_xpr)."
    return
}
}  ;# end do_project

# Stages that did NOT run the project step open the existing project now.
if {!$do_project} {
    if {![file exists $proj_xpr]} {
        error "project not found: $proj_xpr  (run the 'project' stage first)"
    }
    open_project $proj_xpr
}

# ---- SYNTH: synthesize (synth / all) ---------------------------------------
# A completed run cannot be re-launched without reset_run (Vivado errors "needs to
# be reset"), so: reuse synth_1 only if it is complete AND current (NEEDS_REFRESH
# 0); otherwise reset (when an out-of-date result exists) and synthesize. This
# makes RTL edits get picked up while an unchanged project resumes instantly.
if {$do_synth} {
    if {[get_property PROGRESS [get_runs synth_1]] eq "100%"
        && ![get_property NEEDS_REFRESH [get_runs synth_1]]} {
        puts "INFO: synth_1 already complete and current; reused."
    } else {
        catch {reset_run synth_1}
        launch_runs synth_1 -jobs 4
        wait_on_run synth_1
        puts "INFO: Synthesis done."
    }
    if {$build_to eq "synth"} { return }
}

# ---- IMPL: place + route, REUSING synth_1 (stops BEFORE bitstream) ----------
# launch_runs ... -to_step route_design runs opt/place/route only; write_bitstream
# is deferred to the 'bit' stage so the two roles are separable / resumable. Reuse
# a routed impl_1 only if current; else reset (when stale) and re-route.
if {$do_impl} {
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"
        || [get_property NEEDS_REFRESH [get_runs synth_1]]} {
        error "synth_1 is not complete/current; run the 'synth' stage first"
    }
    if {[get_property PROGRESS [get_runs impl_1]] eq "100%"
        && ![get_property NEEDS_REFRESH [get_runs impl_1]]} {
        puts "INFO: impl_1 already routed and current; reused."
    } else {
        catch {reset_run impl_1}
        launch_runs impl_1 -to_step route_design -jobs 4
        wait_on_run impl_1
        puts "INFO: Implementation (place+route) done."
    }
    open_run impl_1
    set wns [get_property SLACK [get_timing_paths -delay_type max -nworst 1 -max_paths 1]]
    puts "==== IMPL routed setup WNS = $wns ns ===="
    report_timing_summary -delay_type max -max_paths 1 \
        -file "$script_dir/../../../boards/reports/build_kv260_impl_timing.rpt"
    close_design  ;# release the in-memory design so the 'bit' step can relaunch the run
    if {$build_to eq "impl"} { return }
}

# ---- BIT: write_bitstream from the routed impl_1, then export the XSA --------
# Advances the routed impl_1 to write_bitstream (no reset needed: a later step is
# allowed without reset; reset only when impl_1 is stale). The XSA bundles the
# PS8 init (psu_init) + the implemented bitstream and is the hand-off Vitis
# consumes (FSBL+PMUFW/BOOT.bin/JTAG). To (re-)emit only the XSA from an
# existing build, use export_xsa.tcl instead.
if {$do_bit} {
    set bitfiles [glob -nocomplain "$proj_dir/$proj_name.runs/impl_1/*.bit"]
    if {[llength $bitfiles] > 0 && ![get_property NEEDS_REFRESH [get_runs impl_1]]} {
        puts "INFO: bitstream already present and current; reused."
    } else {
        if {[get_property NEEDS_REFRESH [get_runs impl_1]]} { catch {reset_run impl_1} }
        launch_runs impl_1 -to_step write_bitstream -jobs 4
        wait_on_run impl_1
        puts "INFO: Bitstream generation done."
    }
    open_run impl_1
    write_hw_platform -fixed -include_bit -force "$proj_dir/$proj_name.xsa"
    puts "INFO: Wrote HW platform $proj_dir/$proj_name.xsa"
}
