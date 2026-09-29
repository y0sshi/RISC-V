# =============================================================================
# bringup_jtag.tcl - Pure-JTAG bring-up of the KV260 RISC-V SoC (prep-D / P1).
# =============================================================================
# ---- STATUS (2026-07-04): the full PMUFW -> FSBL -> DDR4 -> firmware-dow ->
#      PL-config chain has run on REAL KV260 hardware with NO Tcl/xsct
#      errors at any step, and the DDR4 readback @0x200000 showed
#      sane-looking RISC-V machine code (not garbage), confirming JTAG can
#      correctly write into live DDR4. BUT: with PL config LAST (after
#      firmware was loaded), the UART showed NOTHING at all -- no banner,
#      no garbage, silence -- and the done-sentinel @0x202000 read back as
#      the ELF's own static content (not a runtime-written value),
#      indicating the RISC-V core likely never actually started running.
#      Current hypothesis (untested as of this note): our plain
#      Vitis-generated FSBL doesn't know a bitstream was loaded via JTAG
#      outside its own boot-image flow, and may only release the PS-PL
#      reset (pl_resetn0) as part of housekeeping tied to detecting an
#      already-configured PL -- which requires the PL to be configured
#      BEFORE the FSBL runs, not after. This revision configures the PL
#      twice: once EARLY (right after boot_jtag, before PMUFW/FSBL, so FSBL
#      can see it) and once again LATE (after DDR4+firmware are ready, to
#      force a clean reset-release regardless of what the early one did).
#      If this is STILL silent, the problem is likely NOT ordering at all
#      -- see the header note below for what to check next (UART pin
#      wiring, AXI address mapping, rv_soc_wrap RST_ADDR vs actual DDR4
#      base). Keep extending this history as new things are learned. ----
# ---- Confidence note: THIS IS THE LEAST-VALIDATED SCRIPT IN THIS BOARD PORT ----
# On Zynq-7000 (Zybo/PYNQ), JTAG bring-up is a pure register-poke sequence
# (source ps7_init.tcl; ps7_init; ps7_post_config -- no code ever runs on the
# APU) -- see boards/zybo_z720/vitis/bringup_jtag.tcl. Zynq UltraScale+ (KV260)
# does NOT have an equivalent register-poke-only path: PS8 bring-up over JTAG
# requires ACTUAL CODE EXECUTION on both the PMU (pmufw.elf) and the APU
# (fsbl.elf) -- confirmed via AMD's own Kria baremetal JTAG-boot documentation.
#
# This has been revised several times against real KV260 hardware output
# (2026-07-04); each fix below was confirmed necessary by an actual error on
# real silicon, not just theorized:
#
#   1. An unqualified `fpga -file $bit` right after `connect` (no target
#      selected) fails "No supported FPGA device found" -- fixed by
#      explicitly selecting a target before calling fpga.
#   2. `dow $pmufw` while "PMU" is selected fails "Code 16 ... Invalid
#      context" -- the PMU MicroBlaze is not debugger-visible (silicon
#      v3.0+) until a security-gate register is unlocked (`mwr 0xffca0038
#      0x1ff` with PSU selected), AND that unlock needs `after 500` before
#      it takes effect (both confirmed via AMD's official "PMU Firmware"
#      wiki page). After the unlock, a NEW child target "MicroBlaze PMU"
#      appears (distinct from the parent "PMU" bus node) -- filtering on
#      bare "*PMU*" then matches both and errors "more than one targets
#      found"; must filter specifically for "*MicroBlaze PMU*".
#   3. **THE BIG ONE**: `targets` at the very start already showed
#      Cortex-A53 #1 and #3 as "(Running)" -- i.e. the board had ALREADY
#      booted through its normal chain before we even connected via JTAG.
#      This is because **the KV260 Vision AI Starter Kit carrier card has
#      NO boot-mode switch at all -- it is factory hardware-locked to
#      QSPI32** (confirmed via AMD/Kria documentation), unlike Zybo/PYNQ
#      which have a physical jumper for JTAG-only boot. Every power-on
#      unconditionally boots QSPI -> FSBL -> ATF/U-Boot -> SD -> Linux,
#      regardless of switch settings (there are none). Attempting our own
#      FSBL/PMUFW dance on top of an already-running multi-core Linux
#      caused `stop` to fail with "Cannot halt processor core, timeout"
#      (likely cross-core/GIC/PSCI interference from the live OS).
#      FIX (from AMD's own "Baremetal Flow Example" reference `boot_jtag`
#      proc): before anything else, force a JTAG-mode boot-mode override
#      and a FULL SYSTEM reset so the boot ROM itself waits for JTAG
#      instead of proceeding to QSPI again -- see the `boot_jtag` step
#      below. This is what the two `mwr` pokes omitted in an earlier
#      revision of this script actually do (their purpose is now
#      confirmed, not guessed).
#
# One deliberate deviation from AMD's reference sequence: their example
# configures the PL (`fpga -file`) immediately after the boot_jtag reset,
# before PMUFW/FSBL -- fine for their BRAM-based demo app, but our RISC-V
# core lives in the PL and starts fetching from DDR4 @0x200000 the moment
# its reset releases, so the PL is configured LAST here (after DDR4 is
# confirmed up and firmware is loaded), same principle as Zybo/PYNQ's "load
# DDR before releasing the core" ordering -- NOT yet hardware-confirmed
# whether pl_resetn0 actually gates on this the way assumed; if the RISC-V
# core still isn't running firmware correctly, try moving the `fpga -file`
# line to right after `boot_jtag`+`after 2000` instead (matching AMD's
# reference order exactly) and see if that changes anything.
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
# pmufw.elf lands under sw/qemu/, not sw/boot/ alongside fsbl.elf (empirically
# confirmed 2026-07-04; not a QEMU-only artifact despite the directory name).
set pmufw  "$here/ws/kv260_plat/export/kv260_plat/sw/qemu/pmufw.elf"
set fsbl   "$here/ws/kv260_plat/export/kv260_plat/sw/boot/fsbl.elf"
# ---- DEBUG PIVOT (2026-07-04): two full bring-up attempts with the real
# OpenSBI/Linux firmware produced silence on the UART and an unwritten
# sentinel, with no xsct/Tcl errors anywhere -- meaning it's not yet known
# whether the RISC-V core is fetching/executing ANYTHING from DDR4 at all.
# Switched to `liveness_hw.elf` (src/software/boot/liveness_hw.S) instead:
# a few-instruction probe that only needs core fetch (m_axi_if) + one AXI
# store (m_axi) to succeed -- no UART/CSR/MMU/OpenSBI in the way. It writes
# a fixed magic value once, then a free-running incrementing counter,
# to 0x00300000 / 0x00300004. Once this is confirmed working (see the
# readback loop at the bottom of this script), swap back to the real
# firmware below.
set fw     "$repo/src/software/boot/liveness_hw.elf"
# Real-HW firmware (OpenSBI hello), re-linked to 0x200000 with the 50 MHz /
# 57600 device tree (prep-E). Swap for fw_payload_linux_hw.elf to boot Linux.
#set fw    "$repo/tests/opensbi/work/fw_payload_hw.elf"
#set fw     "$repo/tests/linux/work/fw_payload_linux_hw.elf"

foreach f [list $bit $pmufw $fsbl $fw] {
    if {![file exists $f]} { error "missing input: $f" }
}

proc boot_jtag {} {
    # Force JTAG boot mode + a full system reset. KV260 has NO boot-mode
    # switch (factory-locked to QSPI32), so this software override is the
    # ONLY way to stop it auto-booting QSPI->U-Boot->Linux on every
    # power-on/reset. Sequence + register addresses are AMD's own Kria
    # "Baremetal Flow Example" reference (Option 1: Boot Using JTAG),
    # not a guess.
    targets -set -nocase -filter {name =~ "*PSU*"}
    mwr 0xffca0010 0x0      ;# multiboot register -> 0 (boot image index 0)
    mwr 0xff5e0200 0x0100   ;# CRL_APB boot-mode override -> JTAG
    rst -system
}

puts "== connecting to the board (hw_server / local JTAG) =="
connect

puts "== full JTAG target list (before the forced JTAG-mode reset; for reference) =="
puts [targets]

puts "== forcing JTAG boot mode + full system reset (KV260 has no boot-mode switch) =="
boot_jtag
after 2000

puts "== JTAG target list after the reset (should show fresh/halted cores, not '(Running)') =="
puts [targets]

puts "== selecting the FPGA-programmable (PL config) target and configuring the PL =="
# MOVED HERE (matching AMD's reference order exactly) after the first
# attempt (PL config LAST, after DDR4+firmware) produced a clean run with
# no errors but silence on the UART -- suspected cause: our plain
# Vitis-generated FSBL doesn't know a bitstream was loaded via JTOG outside
# its own boot-image flow, so it may skip the PS-PL reset-release
# housekeeping it would normally do after loading a bitstream from
# BOOT.BIN itself. Configuring the PL BEFORE FSBL runs gives FSBL a chance
# to detect the already-configured PL and perform that housekeeping as
# part of its normal boot sequence. (Not hardware-confirmed which ordering
# is actually correct -- if THIS ordering is also silent, the RISC-V core
# start-up is not simply an ordering issue; see the header note.)
# 'fpga -file ...' operates on whatever debug target is currently selected,
# NOT automatically on the PL -- must explicitly select the PL-config target
# (showed up simply as "PL" in the real target list, not named after the
# chip part).
targets -set -nocase -filter {name =~ "*PL*" || name =~ "*xck26*" || name =~ "*XCVC*"}
fpga -file $bit
targets -set -nocase -filter {name =~ "*PSU*"}

puts "== unlocking PMU debug visibility (security gate, PSU-selected) =="
targets -set -nocase -filter {name =~ "*PSU*"}
mwr 0xFFCA0038 0x1FF
# The register write needs a moment to take effect before the PMU debug
# context becomes valid (AMD's own PMU Firmware wiki page).
after 500

puts "== selecting the PMU (MicroBlaze) target, downloading + starting PMUFW =="
# A NEW child target "MicroBlaze PMU" appears under the plain "PMU" bus node
# only after the security-gate unlock -- filter specifically for it (a bare
# "*PMU*" matches both and errors "more than one targets found").
targets -set -nocase -filter {name =~ "*MicroBlaze PMU*"}
dow $pmufw
con
after 500

puts "== selecting APU Cortex-A53 #0, downloading + starting the FSBL =="
targets -set -nocase -filter {name =~ "*Cortex-A53*#0"}
rst -processor -clear-registers
dow $fsbl
con

puts "== waiting for the FSBL to bring up DDR4 (10s, per AMD's reference wait) =="
after 10000
stop

puts "== downloading the RISC-V firmware into PS DDR4 @ 0x200000 (DDR4 should be live now) =="
dow $fw
puts "   readback @0x200000:"
puts [mrd 0x00200000 4]

puts "== re-configuring the PL now that firmware is loaded (forces a clean re-release) =="
# Belt-and-suspenders: the PL was already configured once, early, so the
# FSBL above had a chance to see it (in case its normal boot sequence only
# releases the PS-PL reset when it detects a configured PL). But if
# pl_resetn0 instead released immediately back when we first called
# `fpga -file` -- i.e. BEFORE DDR4 was up and BEFORE firmware was loaded --
# the RISC-V core would have started running garbage from an
# uninitialized/empty DDR4 long before this point, and it will NOT
# magically restart just because DDR4 now has valid firmware in it (only a
# fresh reset does that). Reconfiguring the PL again HERE, now that DDR4 is
# live and firmware is loaded, forces exactly that fresh reset release
# regardless of which hypothesis about the first `fpga -file` was correct.
targets -set -nocase -filter {name =~ "*PL*" || name =~ "*xck26*" || name =~ "*XCVC*"}
fpga -file $bit
targets -set -nocase -filter {name =~ "*PSU*"}

puts "== DONE =="

# ---- liveness_hw.elf probe (see src/software/boot/liveness_hw.S): writes
#      MAGIC=0x600D600D to 0x300000 once, then free-runs a counter at
#      0x300004. This needs ONLY core fetch (m_axi_if) + one AXI store
#      (m_axi) to succeed -- no UART/CSR/MMU/OpenSBI involved. Read the
#      counter twice, 1s apart: if it's the SAME both times, the core is
#      not running (or not reaching DDR4); if it CHANGES, the fetch/store
#      path over the PS8 HP port is proven good and any further boot
#      failure (with the real firmware) is OpenSBI/UART-specific, not
#      fundamental. ----
puts "== reading the liveness probe (0x300000 magic / 0x300004 counter), twice 1s apart =="
after 500
puts "   t=0: [mrd 0x00300000 2]"
after 1000
puts "   t=1: [mrd 0x00300000 2]"
puts "   (expect 0x300000=0x600d600d and 0x300004 DIFFERENT between t=0 and t=1)"
