# =============================================================================
# program.tcl - Program FPGA via JTAG
# =============================================================================
# Usage:
#   vivado -mode batch -source program.tcl -tclargs <board>
# =============================================================================

if {$argc < 1} {
    puts "ERROR: Specify board: zybo_z720 or kv260"
    exit 1
}
set board [lindex $argv 0]

set proj_dir "../../build/vivado_${board}"

# Find bitstream file
set bit_files [glob -nocomplain ${proj_dir}/riscv_${board}.runs/impl_1/*.bit]
if {[llength $bit_files] == 0} {
    puts "ERROR: No bitstream found. Run build.tcl first."
    exit 1
}
set bit_file [lindex $bit_files 0]

puts "=== Programming FPGA with: $bit_file ==="

# Open hardware manager
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

# Get device
set hw_device [get_hw_devices]
current_hw_device $hw_device
set_property PROGRAM.FILE $bit_file [current_hw_device]

# Program
program_hw_devices [current_hw_device]

puts "=== Programming Complete ==="

close_hw_target
disconnect_hw_server
close_hw_manager
