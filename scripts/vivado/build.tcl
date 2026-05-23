# =============================================================================
# build.tcl - Run Vivado Synthesis and Implementation
# =============================================================================
# Usage:
#   vivado -mode batch -source build.tcl -tclargs <board> [synth|impl|bit]
# =============================================================================

if {$argc < 1} {
    puts "ERROR: Specify board: zybo_z720 or kv260"
    exit 1
}
set board [lindex $argv 0]
set stage [expr {$argc > 1 ? [lindex $argv 1] : "bit"}]

set proj_dir "../../build/vivado_${board}"
set proj_file "${proj_dir}/riscv_${board}.xpr"

# Open project
if {![file exists $proj_file]} {
    puts "ERROR: Project not found. Run create_project.tcl first."
    exit 1
}
open_project $proj_file

# Synthesis
if {$stage eq "synth" || $stage eq "impl" || $stage eq "bit"} {
    puts "=== Running Synthesis ==="
    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
        puts "ERROR: Synthesis failed"
        exit 1
    }
    puts "=== Synthesis Complete ==="
}

# Implementation
if {$stage eq "impl" || $stage eq "bit"} {
    puts "=== Running Implementation ==="
    launch_runs impl_1 -jobs 4
    wait_on_run impl_1
    if {[get_property STATUS [get_runs impl_1]] ne "route_design Complete!"} {
        puts "ERROR: Implementation failed"
        exit 1
    }
    puts "=== Implementation Complete ==="
}

# Bitstream generation
if {$stage eq "bit"} {
    puts "=== Generating Bitstream ==="
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    puts "=== Bitstream Generated ==="
}

close_project
