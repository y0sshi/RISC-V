# =============================================================================
# export_xsa.tcl - Export a fixed hardware platform (.xsa) from the ALREADY-BUILT
#                  Zybo Z7-20 project, reusing impl_1 (no re-implementation).
# =============================================================================
# The .xsa bundles the PS7 init (ps7_init.tcl/.c -- DDR/MIO/clock bring-up) and
# the implemented bitstream, and is the hand-off Vitis consumes to generate the
# FSBL and BOOT.bin (prep-C) and the JTAG bring-up scripts (prep-D).
#
# Run from PowerShell with an ABSOLUTE -source path (Bash/MSYS path translation
# crashes Vivado synth/child processes; a relative path makes Vivado's cwd != repo
# root and "couldn't read file"):
#   & "E:\Tools\Xilinx\Vivado\2024.2\bin\vivado.bat" -mode batch `
#       -source E:\work\git\RISC-V.git\boards\zybo_z720\vivado\export_xsa.tcl `
#       *> E:\work\git\RISC-V.git\boards\zybo_z720\vivado\export_xsa.log 2>&1
#
# Requires a completed impl_1 with a written bitstream (build_zybo.tcl -tclargs bit).
# Output: boards/zybo_z720/vivado/rv_riscv_zybo/rv_riscv_zybo.xsa (gitignored).
# =============================================================================

set script_dir [file normalize [file dirname [info script]]]
set proj_name  "rv_riscv_zybo"
set proj_dir   "$script_dir/$proj_name"
set xpr        "$proj_dir/$proj_name.xpr"
set xsa        "$proj_dir/$proj_name.xsa"

if {![file exists $xpr]} {
    error "project not found: $xpr  (build it first: build_zybo.tcl -tclargs bit)"
}

open_project $xpr

# Pull the routed design + bitstream from impl_1 into memory so write_hw_platform
# can emit the fixed platform with ps7_init and the embedded .bit.
open_run impl_1

write_hw_platform -fixed -include_bit -force $xsa
puts "INFO: wrote hardware platform: $xsa"
validate_hw_platform $xsa
puts "INFO: export_xsa DONE"
