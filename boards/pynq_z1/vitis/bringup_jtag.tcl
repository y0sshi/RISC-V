# =============================================================================
# bringup_jtag.tcl - Pure-JTAG bring-up of the PYNQ-Z1 RISC-V SoC (prep-D / P1).
# =============================================================================
# RUN WITH THE BOARD CONNECTED via USB-JTAG (powered on, hw_server reachable).
# This is the recommended FIRST bring-up path (more controllable + observable than
# SD/BOOT.bin): it brings the PS + DDR up with ps7_init, loads the RISC-V firmware
# into PS DDR at 0x0020_0000 BEFORE configuring the PL, then configures the PL so
# the RISC-V core comes out of reset and boots from 0x200000 with the firmware
# already resident.
#
# The XSDB/debug commands (connect/targets/dow/fpga/...) ARE available in this
# Vitis 2024.2 install (only the classic IDE *project* flow is not). Run:
#   & "$env:XILINX_VITIS\bin\xsct.bat" `
#       $PWD\boards\pynq_z1\vitis\bringup_jtag.tcl   (from the repo root)
#
# Then observe the OpenSBI banner on the Pmod JB USB-UART at 57600 8N1
# (FPGA TX=W14 -> adapter RX, FPGA RX=Y14 <- adapter TX, common GND).
# =============================================================================

set here [file normalize [file dirname [info script]]]
set repo [file normalize "$here/../../.."]

set ps7_init "$here/ps7_init.tcl"
set bit      "$repo/boards/pynq_z1/vivado/rv_riscv_pynq_z1/rv_riscv_pynq_z1.runs/impl_1/bd_riscv_wrapper.bit"
# Real-HW firmware (OpenSBI hello), re-linked to 0x200000 with the 50 MHz /
# 57600 device tree (prep-E). Swap for fw_payload_linux_hw.elf to boot Linux.
#set fw       "$repo/tests/opensbi/work/fw_payload_hw.elf"
set fw       "$repo/tests/linux/work/fw_payload_linux_hw.elf"

foreach f [list $ps7_init $bit $fw] {
    if {![file exists $f]} { error "missing input: $f" }
}

puts "== connecting to the board (hw_server / local JTAG) =="
connect

# ---- Select the PS Cortex-A9 #0 (for PS init + DDR access over JTAG) ----
targets -set -nocase -filter {name =~ "*Cortex-A9*#0"}
catch { stop };  # may already be stopped from a prior session -> don't abort

# ---- PS init: DDR controller, MIO, clocks (FCLK_CLK0 = 50 MHz) ----
puts "== ps7_init (DDR / MIO / clocks) =="
source $ps7_init
ps7_init
ps7_post_config

# ---- Load the RISC-V firmware into PS DDR @ 0x200000 (BEFORE PL config) ----
puts "== downloading firmware to DDR 0x200000: $fw =="
dow $fw
puts "   readback @0x200000:"
puts [mrd 0x00200000 4]

# ---- Configure the PL -> the RISC-V core leaves reset and boots from 0x200000 ----
puts "== configuring PL with $bit =="
fpga -file $bit

puts "== DONE: RISC-V core released; watch the Pmod JB UART at 57600 8N1 =="
puts "   (OpenSBI banner -> 'PAYLOAD: hello' for the hello firmware)"

# ---- Liveness probe: the hello payload writes 0x00C0FFEE to TOHOST (= base+0x2000)
#      AFTER it has printed the banner via SBI putchar. Reading it back proves the
#      core ran (fetched from DDR, ran OpenSBI init + the S-mode payload, and the
#      UART register writes executed) WITHOUT needing to see the UART. ----
puts "== waiting ~1s, then reading the done-sentinel @0x00202000 =="
after 1000
puts "   sentinel @0x202000 (expect 0x00C0FFEE if the core ran the payload):"
puts [mrd 0x00202000 1]
