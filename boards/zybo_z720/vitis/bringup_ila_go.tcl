# =============================================================================
# bringup_ila_go.tcl - stage 3 of the ILA capture: RELEASE the core from reset.
# =============================================================================
# Run AFTER bringup_ila_pre.tcl AND after the ILA is armed in the Vivado Hardware
# Manager.  Deasserts the PL reset so the core boots from 0x200000; the armed ILA
# then captures the first instructions (the jal + the failing ret).
#
#   & "E:\Tools\Xilinx\Vitis\2024.2\bin\xsct.bat" `
#       E:\work\git\RISC-V.git\boards\zybo_z720\vitis\bringup_ila_go.tcl
#
# After it boots, read the marker to see whether ret round-tripped:
#   0x300000 advancing (>0) -> ret worked    |    0xDEADBEEF -> ret died at boot
# =============================================================================

puts "== connecting =="
connect
targets -set -nocase -filter {name =~ "*Cortex-A9*#0"}

puts "== releasing PL reset (SLCR FPGA_RST_CTRL=0x0) -> core boots =="
mwr 0xF8000008 0xDF0D          ;# unlock SLCR
mwr 0xF8000240 0x00000000      ;# FPGA_RST_CTRL[0]=0 -> deassert FCLK_RESET0_N
puts "   FPGA_RST_CTRL = [mrd 0xF8000240 1]"

after 500
puts "== marker 0x300000 (advancing = ret OK; 0xDEADBEEF = ret died): [mrd 0x00300000 1] =="
after 1000
puts "== marker again: [mrd 0x00300000 1] =="
