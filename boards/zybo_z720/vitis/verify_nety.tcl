# =============================================================================
# verify_nety.tcl - One-shot boot + netlink-health check for the CONFIG_NET=y
#                   AMO write-loss fix (rv_soc.sv:364; memory zybo-netlink-atomic-bug).
# =============================================================================
# Boots Linux over pure JTAG (ps7_init -> dow fw -> fpga config), waits for the
# kernel to pass the inet_init / netlink_table_grab site, then reads kernel state
# straight out of PS DDR over JTAG (the RISC-V firmware runs from that DDR):
#   - nl_table_users (atomic_t): MUST settle to 0 (a lost atomic_dec leaves it
#     stuck non-zero -> netlink_table_grab spins forever = the bug).
#   - jiffies_64: must advance (core alive / true wait, not dead).
#   - __log_buf: dumped as ASCII so we can see the kernel reached late init /
#     userspace ("Run /init", "Freeing unused kernel memory", ...) vs a
#     hung_task netlink_table_grab stack.
#
# The bug is INTERMITTENT (~1 in 2 boots pre-fix), so run this 3-5 times and
# require ALL runs to show nl_table_users == 0.
#
# Run (from the repo root, board powered + USB-JTAG attached):
#   & "$env:XILINX_VITIS\bin\xsct.bat" $PWD\boards\zybo_z720\vitis\verify_nety.tcl
#
# PAs are for the HW NET=y build (kernel PA = VA - 0xffffffff80000000 + 0x400000).
# Regenerate if the kernel layout changes:
#   riscv64-unknown-elf-nm tests/linux/work/linux-6.12/vmlinux \
#     | grep -E ' nl_table_users$| jiffies_64$| __log_buf$'
# =============================================================================

set here [file normalize [file dirname [info script]]]
set repo [file normalize "$here/../../.."]
set ps7_init "$here/ps7_init.tcl"
set bit  "$repo/boards/zybo_z720/vivado/rv_riscv_zybo/rv_riscv_zybo.runs/impl_1/bd_riscv_wrapper.bit"
set fw   "$repo/tests/linux/work/fw_payload_linux_hw.elf"

set PA_NL_USERS 0x0191d9f8
set PA_JIFFIES  0x01917cd8
set PA_LOGBUF   0x0192d110
set BOOT_WAIT_MS 420000   ;# ~7 min: time for OpenSBI + kernel to reach userspace

foreach f [list $ps7_init $bit $fw] {
    if {![file exists $f]} { error "missing input: $f" }
}

puts "== connect + ps7_init + load fw + configure PL =="
connect
targets -set -nocase -filter {name =~ "*Cortex-A9*#0"}
catch { stop }
source $ps7_init
ps7_init
ps7_post_config
dow $fw
puts "   readback @0x200000: [mrd 0x00200000 2]"
fpga -file $bit
puts "== PL configured; RISC-V booting.  Waiting [expr {$BOOT_WAIT_MS/1000}] s =="
after $BOOT_WAIT_MS

puts ""
puts "== netlink health (3 polls over ~30 s) =="
puts "poll  jiffies_64(lo hi)     nl_table_users"
for {set i 0} {$i < 3} {incr i} {
    set j [mrd -value $PA_JIFFIES 2]
    set u [mrd -value $PA_NL_USERS 1]
    puts [format "%3d   %s     %s" $i $j $u]
    after 10000
}

puts ""
puts "== __log_buf (ASCII, ~6 KiB) -- look for 'Run /init' / 'Freeing unused' (PASS)"
puts "   or a hung_task 'netlink_table_grab' stack (HANG) =="
set words [mrd -value $PA_LOGBUF 1536]
set line ""
foreach w $words {
    for {set b 0} {$b < 4} {incr b} {
        set c [expr {($w >> ($b*8)) & 0xff}]
        if {$c == 10 || $c == 13} {
            if {[string length $line] > 0} { puts $line; set line "" }
        } elseif {$c >= 32 && $c < 127} {
            append line [format %c $c]
        } else {
            append line "."
        }
    }
}
if {[string length $line] > 0} { puts $line }

puts ""
set uf [mrd -value $PA_NL_USERS 1]
puts ">>> VERDICT: nl_table_users (final) = $uf"
puts ">>>   == 0  -> netlink passed (fix OK for this boot)"
puts ">>>   != 0  -> atomic_dec lost AGAIN (bug still present)"
