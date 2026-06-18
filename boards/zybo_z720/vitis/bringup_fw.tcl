# =============================================================================
# bringup_fw.tcl - generic loader: dow an arbitrary firmware ELF + boot + read marker.
# =============================================================================
# Iterate test firmwares on the SAME bitstream (no Vivado rebuild needed).
# From the repo root in PowerShell (Xilinx tool via $env:XILINX_VITIS or PATH):
#   & "$env:XILINX_VITIS\bin\xsct.bat" `
#       $PWD\boards\zybo_z720\vitis\bringup_fw.tcl `
#       $PWD\src\software\boot\jalmin_u_hw.elf
#
# Marker @0x300000: advancing = ret round-trips; 0xDEADBEEF = ret died at boot.
# Open TeraTerm 57600 8N1 if the firmware uses the UART.
# =============================================================================

if {$argc < 1} { error "usage: xsct bringup_fw.tcl <firmware.elf>" }
set fw [lindex $argv 0]

set here [file normalize [file dirname [info script]]]
set repo [file normalize "$here/../../.."]
set ps7_init "$here/ps7_init.tcl"
set bit      "$repo/boards/zybo_z720/vivado/rv_riscv_zybo/rv_riscv_zybo.runs/impl_1/bd_riscv_wrapper.bit"

foreach f [list $ps7_init $bit $fw] {
    if {![file exists $f]} { error "missing input: $f" }
}

puts "== connecting =="
connect
targets -set -nocase -filter {name =~ "*Cortex-A9*#0"}
catch { stop };  # may already be stopped from a prior session -> don't abort

puts "== ps7_init =="
source $ps7_init
ps7_init
ps7_post_config

puts "== downloading firmware: $fw =="
dow $fw
puts "   readback @0x200000: [mrd 0x00200000 1]"
puts "== poisoning marker 0x300000 = 0xDEADBEEF =="
mwr 0x00300000 0xDEADBEEF

puts "== configuring PL -> core boots =="
fpga -file $bit

after 500
puts "== marker 0x300000 (advancing = ret OK; 0xDEADBEEF = ret died): [mrd 0x00300000 1] =="
after 1000
puts "== marker again: [mrd 0x00300000 1] =="
