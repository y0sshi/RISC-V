# =============================================================================
# check_liveness.tcl - read-only check of the liveness_hw.elf probe
# (src/software/boot/liveness_hw.S), WITHOUT touching boot mode / resetting
# anything. Safe to run against an already-running system (e.g. right after
# `xmutil loadapp` released the RISC-V core via the fpgautil/xmutil path).
#
# Run with the board connected via USB-JTAG:
#   & "$env:XILINX_VITIS\bin\xsct.bat" $PWD\boards\kv260\vitis\check_liveness.tcl
# =============================================================================

connect
targets -set -nocase -filter {name =~ "*PSU*"}

puts "t=0: [mrd 0x00300000 2]"
after 1000
puts "t=1: [mrd 0x00300000 2]"
puts "(expect 0x300000=0x600d600d and 0x300004 DIFFERENT between t=0 and t=1)"
