# =============================================================================
# bringup_ila_pre.tcl - stage 1 of the ILA capture: load firmware, HOLD the core
#                       in reset, configure the PL.  (Then arm the ILA, then run
#                       bringup_ila_go.tcl to release.)
# =============================================================================
# Captures the jal/ret fetch bug from the very first instruction.  The core boots
# the instant the PL is configured, so to let the ILA arm BEFORE it runs we hold
# the PL in reset via the PS reset control (SLCR FPGA_RST_CTRL bit0 = FCLK_RESET0).
#
# Flow:
#   1) xsct  bringup_ila_pre.tcl   <- this: ps7_init, dow firmware, ASSERT PL reset, config PL
#   2) Vivado Hardware Manager     <- arm the ILA (trigger on branch_taken_ex; .ltx auto-loaded)
#   3) xsct  bringup_ila_go.tcl    <- DEASSERT PL reset -> core boots -> ILA triggers
#   4) Vivado Hardware Manager     <- view waveform; also `mrd 0x00300000 1` (marker)
#
#   & "E:\Tools\Xilinx\Vitis\2024.2\bin\xsct.bat" `
#       E:\work\git\RISC-V.git\boards\zybo_z720\vitis\bringup_ila_pre.tcl
# =============================================================================

set here [file normalize [file dirname [info script]]]
set repo [file normalize "$here/../../.."]

set ps7_init "$here/ps7_init.tcl"
set bit      "$repo/boards/zybo_z720/vivado/rv_riscv_zybo/rv_riscv_zybo.runs/impl_1/bd_riscv_wrapper.bit"
set fw       "$repo/src/software/boot/minpoll_hw.elf"

foreach f [list $ps7_init $bit $fw] {
    if {![file exists $f]} { error "missing input: $f" }
}

puts "== connecting =="
connect
targets -set -nocase -filter {name =~ "*Cortex-A9*#0"}
stop

puts "== ps7_init =="
source $ps7_init
ps7_init
ps7_post_config

puts "== downloading firmware to DDR 0x200000: $fw =="
dow $fw
puts "   readback @0x200000: [mrd 0x00200000 1]"

puts "== poisoning marker 0x300000 = 0xDEADBEEF =="
mwr 0x00300000 0xDEADBEEF

# ---- HOLD the PL (core) in reset via SLCR FPGA_RST_CTRL bit0 (FCLK_RESET0) ----
puts "== asserting PL reset (SLCR FPGA_RST_CTRL=0x1) to hold the core =="
mwr 0xF8000008 0xDF0D          ;# unlock SLCR
mwr 0xF8000240 0x00000001      ;# FPGA_RST_CTRL[0]=1 -> assert FCLK_RESET0_N
puts "   FPGA_RST_CTRL = [mrd 0xF8000240 1]"

puts "== configuring PL (core stays in reset): $bit =="
fpga -file $bit

puts ""
puts ">>> PL configured, core HELD in reset."
puts ">>> NOW: in Vivado Hardware Manager connect + arm the ILA"
puts ">>>      (trigger e.g. branch_taken_ex==1), THEN run bringup_ila_go.tcl."
