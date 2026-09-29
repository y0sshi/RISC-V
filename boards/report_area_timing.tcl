# =============================================================================
# report_area_timing.tcl - Quick per-module AREA + TIMING estimate for rv_soc
# =============================================================================
# Out-of-context (OOC) synthesis of rv_soc ONLY (no PS / no block design / no
# board files), then emit:
#   - HIERARCHICAL utilization (LUT/FF/DSP/BRAM per module instance)
#   - flat utilization summary
#   - timing summary (estimated; OOC synth has no routing, so this is an early
#     WNS signal, not sign-off) + the worst critical paths
#
# Area numbers are produced even if timing does NOT meet -- synthesis area is
# independent of timing closure.  Use this to find which modules dominate
# (expect rv_muldiv DSPs and the combinational FPU on the critical path).
#
# Usage (from repo root):
#   vivado -mode batch -source boards/report_area_timing.tcl
#   vivado -mode batch -source boards/report_area_timing.tcl -tclargs xc7z020clg400-1 10.0 0
#       tclargs: <part> <clk_period_ns> <xlen64(0|1)>
#
# Outputs: boards/reports/*.rpt
# =============================================================================

set part      "xc7z020clg400-1"   ;# Zybo Z7-20 (KV260: xck26-sfvc784-2LV-c)
set period_ns 10.0                ;# 10 ns = 100 MHz target (estimate)
set xlen64    0
if {$argc >= 1} { set part      [lindex $argv 0] }
if {$argc >= 2} { set period_ns [lindex $argv 1] }
if {$argc >= 3} { set xlen64    [lindex $argv 2] }

set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize "$script_dir/.."]
set rtl        "$repo/src/rtl"
set rpt        "$script_dir/reports"
file mkdir $rpt

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

# ---- Read RTL ----
read_verilog -sv $src_files
set_property include_dirs "$rtl/include" [current_fileset]
if {$xlen64} { set_property verilog_define {RV_XLEN_64} [current_fileset] }

# ---- OOC synthesis (keep hierarchy so per-module reports are clean) ----
# -flatten_hierarchy rebuilt : optimize across boundaries but REBUILD the
#   hierarchy afterwards so report_utilization -hierarchical attributes cells
#   back to their source module.
synth_design -top rv_soc -part $part -mode out_of_context \
    -flatten_hierarchy rebuilt

# ---- Timing constraint (so the timing report is meaningful) ----
# OOC: define the primary clock on clk; this is an ESTIMATE (no routing yet).
create_clock -name clk -period $period_ns [get_ports clk]

# ---- Reports (all written even if WNS < 0) ----
report_utilization              -file "$rpt/util_flat.rpt"
report_utilization -hierarchical -hierarchical_depth 4 \
                                -file "$rpt/util_hierarchical.rpt"
report_timing_summary -delay_type max -report_unconstrained \
                                -file "$rpt/timing_summary.rpt"
report_timing -delay_type max -max_paths 25 -sort_by slack \
              -path_type full_clock_expanded \
                                -file "$rpt/timing_worst_paths.rpt"
# DSP/BRAM/CARRY heavy spots + design complexity (congestion/critical-path hints)
report_design_analysis -timing -setup -max_paths 25 \
                                -file "$rpt/design_analysis.rpt"

# ---- Console one-line summary ----
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
puts "============================================================"
puts "  rv_soc OOC synth done.  part=$part  target=${period_ns}ns"
puts "  Estimated WNS (no routing yet) = $wns ns"
puts "  Reports in: $rpt/"
puts "    util_hierarchical.rpt  <- per-module LUT/FF/DSP/BRAM"
puts "    timing_worst_paths.rpt <- worst critical paths (FPU/muldiv?)"
puts "============================================================"
