# =============================================================================
# bringup_jtag.tcl - Pure-JTAG bring-up of the KV260 RISC-V SoC (prep-D / P1).
# =============================================================================
# ---- Confidence note: THIS IS THE LEAST-VALIDATED SCRIPT IN THIS BOARD PORT ----
# On Zynq-7000 (Zybo/PYNQ), JTAG bring-up is a pure register-poke sequence
# (source ps7_init.tcl; ps7_init; ps7_post_config -- no code ever runs on the
# APU) -- see boards/zybo_z720/vitis/bringup_jtag.tcl. Zynq UltraScale+ (KV260)
# does NOT have an equivalent register-poke-only path: PS8 bring-up over JTAG
# requires ACTUAL CODE EXECUTION on both the PMU (pmufw.elf) and the APU
# (fsbl.elf) -- confirmed via AMD's own Kria baremetal JTAG-boot documentation
# (xilinx.github.io/kria-apps-docs, "Baremetal Flow Example", Option 1: Boot
# Using JTAG), which downloads pmufw.elf + fsbl.elf + the application ELF and
# resumes all cores together.
#
# This script mirrors that documented flow as closely as possible, but:
#   - it was written from documentation, NOT run against real KV260 hardware/
#     JTAG by this script's author (no board available at authoring time);
#   - the reference example includes two `mwr` register pokes
#     (0xffca0010, 0xff5e0200) whose exact purpose is not fully understood
#     here, so they are OMITTED rather than blindly copied -- add them back
#     if bring-up hangs and you have confirmed what they do;
#   - target name strings (`targets -set -filter {name =~ ...}`) can vary
#     across Vitis/hw_server versions -- if a `targets -set` below matches
#     nothing, run bare `targets` first to see the actual target list and
#     adjust the filter.
#   - our firmware is a bare-metal payload for the PL-resident RISC-V core,
#     NOT an APU application -- the FSBL only needs to bring up PS8 (DDR4 +
#     clocks) and then sit idle; it does not need to "hand off" to anything
#     on the APU. If the stock/default FSBL tries to search for a next boot
#     partition and hangs/faults because none exists, a minimal custom FSBL
#     (or the "bare" psu_init-only path, if one is found) may be required --
#     treat this script as a starting point for interactive debugging with
#     xsct, not a proven one-shot recipe like the Zybo/PYNQ equivalents.
#
# RUN WITH THE BOARD CONNECTED via USB-JTAG (powered on, hw_server reachable):
#   & "$env:XILINX_VITIS\bin\xsct.bat" `
#       $PWD\boards\kv260\vitis\bringup_jtag.tcl   (from the repo root)
#
# Then observe the OpenSBI banner on the J2 Pmod USB-UART at 57600 8N1
# (FPGA TX=E12 -> adapter RX, FPGA RX=D11 <- adapter TX, common GND;
#  see ../vivado/kv260_uart.xdc for the pin-sourcing caveat).
# =============================================================================

set here [file normalize [file dirname [info script]]]
set repo [file normalize "$here/../../.."]

set bit    "$repo/boards/kv260/vivado/rv_riscv_kv260/rv_riscv_kv260.runs/impl_1/bd_riscv_wrapper.bit"
set pmufw  "$here/ws/kv260_plat/export/kv260_plat/sw/boot/pmufw.elf"
set fsbl   "$here/ws/kv260_plat/export/kv260_plat/sw/boot/fsbl.elf"
# Real-HW firmware (OpenSBI hello), re-linked to 0x200000 with the 50 MHz /
# 57600 device tree (prep-E). Swap for fw_payload_linux_hw.elf to boot Linux.
#set fw    "$repo/tests/opensbi/work/fw_payload_hw.elf"
set fw     "$repo/tests/linux/work/fw_payload_linux_hw.elf"

foreach f [list $bit $pmufw $fsbl $fw] {
    if {![file exists $f]} { error "missing input: $f" }
}

puts "== connecting to the board (hw_server / local JTAG) =="
connect

puts "== configuring the PL first (so the RISC-V core is held in reset while PS8 comes up) =="
puts "   (if 'targets' output below doesn't show a PSU/FPGA-programmable target, list targets: 'targets')"
fpga -file $bit

puts "== selecting the PMU (MicroBlaze) target and downloading PMUFW =="
targets -set -nocase -filter {name =~ "*PMU*"}
dow $pmufw

puts "== selecting APU Cortex-A53 #0 and downloading the FSBL =="
targets -set -nocase -filter {name =~ "*Cortex-A53*#0"}
dow $fsbl

puts "== downloading the RISC-V firmware into PS DDR4 @ 0x200000 =="
dow $fw
puts "   readback @0x200000:"
puts [mrd 0x00200000 4]

puts "== resuming all cores (PMU runs pmufw, APU runs fsbl -> PS8/DDR4 bring-up) =="
con

puts "== DONE: watch the J2 Pmod USB-UART at 57600 8N1 =="
puts "   (OpenSBI banner -> 'PAYLOAD: hello' for the hello firmware)"

# ---- Liveness probe: the hello payload writes 0x00C0FFEE to TOHOST (= base+0x2000)
#      AFTER it has printed the banner via SBI putchar. Reading it back proves the
#      RISC-V core ran (fetched from DDR4, ran OpenSBI init + the S-mode payload,
#      and the UART register writes executed) WITHOUT needing to see the UART. ----
puts "== waiting ~2s, then reading the done-sentinel @0x00202000 =="
after 2000
puts "   sentinel @0x202000 (expect 0x00C0FFEE if the core ran the payload):"
puts [mrd 0x00202000 1]
