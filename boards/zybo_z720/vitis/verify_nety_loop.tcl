# =============================================================================
# verify_nety_loop.tcl - Repeat the CONFIG_NET=y boot + netlink-health check N
#                        times in one xsct session (the netlink AMO write-loss
#                        bug is INTERMITTENT, so require several consecutive
#                        PASSes).  See verify_nety.tcl for the single-shot.
# =============================================================================
#   & "$env:XILINX_VITIS\bin\xsct.bat" $PWD\boards\zybo_z720\vitis\verify_nety_loop.tcl
# =============================================================================

set here [file normalize [file dirname [info script]]]
set repo [file normalize "$here/../../.."]
set ps7_init "$here/ps7_init.tcl"
set bit  "$repo/boards/zybo_z720/vivado/rv_riscv_zybo/rv_riscv_zybo.runs/impl_1/bd_riscv_wrapper.bit"
set fw   "$repo/tests/linux/work/fw_payload_linux_hw.elf"

set PA_NL_USERS 0x0191d9f8
set PA_JIFFIES  0x01917cd8
set NITERS      4          ;# additional boots (run 1 was verify_nety.tcl)
set WAIT_MS     360000     ;# ~6 min: past inet_init/netlink to userspace/idle

foreach f [list $ps7_init $bit $fw] {
    if {![file exists $f]} { error "missing input: $f" }
}

connect
targets -set -nocase -filter {name =~ "*Cortex-A9*#0"}
source $ps7_init

set npass 0
for {set it 1} {$it <= $NITERS} {incr it} {
    puts "\n========== BOOT $it / $NITERS =========="
    catch { stop }
    catch { ps7_init }
    catch { ps7_post_config }
    dow $fw
    fpga -file $bit
    puts "   booting; waiting [expr {$WAIT_MS/1000}] s ..."
    after $WAIT_MS
    set u  [mrd -value $PA_NL_USERS 1]
    set j  [mrd -value $PA_JIFFIES 2]
    if {$u == 0} {
        incr npass
        puts ">>> BOOT $it: PASS  nl_table_users=$u  jiffies=$j"
    } else {
        puts ">>> BOOT $it: FAIL (netlink atomic_dec lost)  nl_table_users=$u  jiffies=$j"
    }
}

puts "\n========== SUMMARY =========="
puts ">>> $npass / $NITERS boots passed (nl_table_users settled to 0)"
puts ">>> (plus verify_nety.tcl run 1 = PASS).  Need all consecutive for the fix gate."
