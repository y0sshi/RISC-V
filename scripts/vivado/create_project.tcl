# =============================================================================
# create_project.tcl - Create Vivado Project
# =============================================================================
# Usage:
#   vivado -mode batch -source create_project.tcl -tclargs <board>
#   where <board> is "zybo_z720" or "kv260"
# =============================================================================

# Parse arguments
if {$argc < 1} {
    puts "ERROR: Specify board: zybo_z720 or kv260"
    exit 1
}
set board [lindex $argv 0]

# Project paths
set proj_dir   "../../build/vivado_${board}"
set rtl_dir    "../../src/rtl"
set board_dir  "../../src/boards/${board}"

# Board-specific settings
switch $board {
    "zybo_z720" {
        set part        "xc7z020clg400-1"
        set board_part  "digilentinc.com:zybo-z7-20:part0:1.2"
        set top_module  "zybo_z7_top"
    }
    "kv260" {
        set part        "xck26-sfvc784-2LV-c"
        set board_part  "xilinx.com:kv260_som:part0:1.4"
        set top_module  "kv260_top"
    }
    default {
        puts "ERROR: Unknown board: $board"
        exit 1
    }
}

# Create project
create_project riscv_${board} $proj_dir -part $part -force

# Set board part (may fail if board files not installed)
catch {set_property board_part $board_part [current_project]}

# Add RTL sources
add_files [glob -nocomplain \
    ${rtl_dir}/include/*.sv \
    ${rtl_dir}/core/*.sv \
    ${rtl_dir}/alu/*.sv \
    ${rtl_dir}/memory/*.sv \
    ${rtl_dir}/soc/*.sv \
    ${board_dir}/*.sv \
]

# Add constraints
add_files -fileset constrs_1 [glob -nocomplain ${board_dir}/*.xdc]

# Set top module
set_property top $top_module [current_fileset]

# Set SystemVerilog as default language
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]

# Set synthesis/implementation strategies
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]

puts "=== Project created: riscv_${board} ==="
puts "Part: $part"
puts "Top:  $top_module"

close_project
