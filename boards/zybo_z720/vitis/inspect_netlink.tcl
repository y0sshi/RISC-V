# =============================================================================
# inspect_netlink.tcl - Phase-1 (no re-synth/ILA) diagnosis of the real-HW
#                       CONFIG_NET=y inet_init / netlink_table_grab hang.
# =============================================================================
# The RISC-V SoC runs its firmware from PS DDR (S_AXI_HP).  That SAME DDR is
# directly readable from the PS Cortex-A9 over JTAG (`mrd`), so while the RISC-V
# core is hung in netlink_table_grab we can read kernel state out of DDR WITHOUT
# any ILA / re-synthesis.
#
# Decisive question this answers:
#   nl_table_users (atomic_t) is what netlink_table_grab() spins on
#   (`while (atomic_read(&nl_table_users) != 0) schedule();`).  If it is stuck
#   NON-ZERO  -> a lost/garbled atomic_dec (counter corruption: AMO/LR-SC wrote
#                a wrong value or a store was lost).
#   If it is ZERO but the grab still hangs -> the wake-up was lost (the wake path
#                cmpxchg/scheduler atomic failed), not the counter.
#   jiffies_64 advancing across polls confirms the timer tick is still alive
#   (i.e. a true wait, not a dead core).
#
# Flow (run AFTER booting Linux with bringup_jtag.tcl, while it is hung):
#   & "$env:XILINX_VITIS\bin\xsct.bat" `
#       $PWD\boards\zybo_z720\vitis\inspect_netlink.tcl   (from the repo root)
#
# Re-runnable cheaply (no dow/fpga); just polls DDR.  Physical addresses are for
# the HW build: kernel loaded at PA 0x400000 (OpenSBI FW_BASE 0x200000 + payload
# offset 0x200000), kernel link base VA 0xffffffff80000000.
#   PA(sym) = (VA(sym) - 0xffffffff80000000) + 0x400000
# Regenerate with:  riscv64-linux-gnu-nm vmlinux | grep -E 'nl_table_users|jiffies_64|__log_buf'
# =============================================================================

set PA_NL_USERS  0x0191d9f8   ;# nl_table_users  (VA ffffffff8151d9f8) - atomic_t
set PA_NL_TABLE  0x0191da00   ;# nl_table[]      (VA ffffffff8151da00)
set PA_JIFFIES   0x01917cd8   ;# jiffies_64      (VA ffffffff81517cd8) - 64-bit
set PA_LOGBUF    0x0192d110   ;# __log_buf       (VA ffffffff8152d110)

set NPOLL   45                ;# number of polls
set DELAYMS 12000             ;# ms between polls (~9 min total window)

puts "== connecting (A9 is used only as a DDR read aperture; PL keeps running) =="
connect
targets -set -nocase -filter {name =~ "*Cortex-A9*#0"}
catch { stop }

puts "== sanity readback (kernel image area; expect non-zero kernel data) =="
puts "   nl_table_users @ $PA_NL_USERS = [mrd $PA_NL_USERS 1]"
puts "   nl_table[]     @ $PA_NL_TABLE = [mrd $PA_NL_TABLE 4]"

puts ""
puts "== polling nl_table_users + jiffies_64 every [expr {$DELAYMS/1000}] s, $NPOLL times =="
puts "   (watch the Pmod JC UART for the hung_task netlink_table_grab stack)"
puts "poll   jiffies_64(lo hi)        nl_table_users   nl_table_users_window(d9f0..)"
for {set i 0} {$i < $NPOLL} {incr i} {
    set j   [mrd -value $PA_JIFFIES 2]
    set u   [mrd -value $PA_NL_USERS 1]
    set win [mrd -value [expr {$PA_NL_USERS - 0x8}] 4]
    puts [format "%4d   %s        %s     %s" $i $j $u $win]
    after $DELAYMS
}

puts ""
puts "== final snapshot =="
puts "   jiffies_64     = [mrd $PA_JIFFIES 2]"
puts "   nl_table_users = [mrd $PA_NL_USERS 1]"
puts "   nl_table[]     = [mrd $PA_NL_TABLE 8]"
puts ""
puts ">>> INTERPRET:"
puts ">>>   nl_table_users stuck NON-ZERO  -> atomic_dec lost/garbled (counter corruption)"
puts ">>>   nl_table_users == 0 (but hung)  -> wake-up lost (scheduler/waitqueue atomic)"
puts ">>>   jiffies_64 NOT advancing        -> core fully dead (not a netlink wait)"
