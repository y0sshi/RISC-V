# =============================================================================
# report_exec_area.tcl - Per-OPERATOR area (standalone OOC synth of each exec unit)
# =============================================================================
# The whole-SoC hierarchical report folds combinational leaf operators (rv_alu,
# rv_branch, rv_amo) into their parent and lumps integer MUL+DIV into one
# rv_muldiv.  To see area at the OPERATOR granularity (int add/sub/logic vs MUL+DIV
# vs FP add/mul/div/sqrt/cvt, single vs double), synthesize each execution module
# standalone out-of-context and dump its utilization.
#
# Usage (from repo root):
#   vivado -mode batch -source boards/report_exec_area.tcl
#   vivado -mode batch -source boards/report_exec_area.tcl -tclargs xc7z020clg400-1 1
#       tclargs: <part> <xlen64(0|1)>
#
# Outputs: boards/reports/exec/util_<module>.rpt  (+ console one-line summary)
# =============================================================================

set part   "xc7z020clg400-1"
set xlen64  1
if {$argc >= 1} { set part   [lindex $argv 0] }
if {$argc >= 2} { set xlen64 [lindex $argv 1] }

set script_dir [file normalize [file dirname [info script]]]
set repo       [file normalize "$script_dir/.."]
set rtl        "$repo/src/rtl"
set rpt        "$script_dir/reports/exec"
file mkdir $rpt

# All leaf operator modules + their source files (repo-relative).  Each only needs
# rv_pkg.  mul_meas / div_meas split integer MUL vs DIV (measurement-only copies of
# the two rv_muldiv datapaths; see boards/area_meas/muldiv_split_meas.sv).
set pkg "$rtl/include/rv_pkg.sv"
set mods {
    rv_alu        src/rtl/exec/rv_alu.sv
    rv_muldiv     src/rtl/exec/rv_muldiv.sv
    mul_meas      boards/area_meas/muldiv_split_meas.sv
    div_meas      boards/area_meas/muldiv_split_meas.sv
    rv_branch     src/rtl/exec/rv_branch.sv
    rv_amo        src/rtl/exec/rv_amo.sv
    rv_fpu_add    src/rtl/fpu/rv_fpu_add.sv
    rv_fpu_mul    src/rtl/fpu/rv_fpu_mul.sv
    rv_fpu_div    src/rtl/fpu/rv_fpu_div.sv
    rv_fpu_sqrt   src/rtl/fpu/rv_fpu_sqrt.sv
    rv_fpu_misc   src/rtl/fpu/rv_fpu_misc.sv
    rv_fpu_add_d  src/rtl/fpu/rv_fpu_add_d.sv
    rv_fpu_mul_d  src/rtl/fpu/rv_fpu_mul_d.sv
    rv_fpu_div_d  src/rtl/fpu/rv_fpu_div_d.sv
    rv_fpu_sqrt_d src/rtl/fpu/rv_fpu_sqrt_d.sv
    rv_fpu_misc_d src/rtl/fpu/rv_fpu_misc_d.sv
}

set summary {}
foreach {mod src} $mods {
    # Fresh in-memory project per module so synth_design starts clean.
    create_project -in_memory -part $part -force
    read_verilog -sv [list $pkg "$repo/$src"]
    set_property include_dirs "$rtl/include" [current_fileset]
    if {$xlen64} { set_property verilog_define {RV_XLEN_64} [current_fileset] }

    if {[catch {synth_design -top $mod -part $part -mode out_of_context \
                    -flatten_hierarchy rebuilt} err]} {
        puts "WARN: synth $mod failed: $err"
        lappend summary [format "%-14s  (synth failed)" $mod]
        continue
    }
    report_utilization -file "$rpt/util_$mod.rpt"

    # Pull primitive counts straight from the netlist (robust vs report parsing).
    set luts [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
    set ffs  [llength [get_cells -hier -filter {REF_NAME =~ FD* }]]
    set dsps [llength [get_cells -hier -filter {REF_NAME =~ DSP*}]]
    set crys [llength [get_cells -hier -filter {REF_NAME =~ CARRY*}]]
    lappend summary [format "%-14s  LUT=%-6d FF=%-6d DSP=%-4d CARRY4=%-4d" \
                         $mod $luts $ffs $dsps $crys]
}

puts "============================================================"
puts "  Per-operator standalone OOC area  (part=$part  RV64=$xlen64)"
puts "  (LUT/FF/DSP/CARRY4 primitive counts; reports in $rpt/)"
puts "------------------------------------------------------------"
foreach line $summary { puts "  $line" }
puts "============================================================"
