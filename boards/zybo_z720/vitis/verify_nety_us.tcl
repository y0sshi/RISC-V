# =============================================================================
# verify_nety_us.tcl - CONFIG_NET=y boot with a LONG wait + userspace handoff
#                      check via __log_buf (25 MHz core needs ~400 s+ to reach
#                      userspace; the param_sysfs_builtin_init soft-lockup dump
#                      is non-fatal slowness, not a hang).
# =============================================================================
# Confirms, JTAG-only, that the boot reached userspace handoff by finding the
# kernel printk "Run /init as init process" (emitted right before exec'ing init)
# in __log_buf, plus nl_table_users==0 (netlink atomic_dec fix held).
#   & "$env:XILINX_VITIS\bin\xsct.bat" $PWD\boards\zybo_z720\vitis\verify_nety_us.tcl
# =============================================================================

set here [file normalize [file dirname [info script]]]
set repo [file normalize "$here/../../.."]
set ps7_init "$here/ps7_init.tcl"
set bit  "$repo/boards/zybo_z720/vivado/rv_riscv_zybo/rv_riscv_zybo.runs/impl_1/bd_riscv_wrapper.bit"
set fw   "$repo/tests/linux/work/fw_payload_linux_hw.elf"

set PA_NL_USERS 0x0191d9f8
set PA_JIFFIES  0x01917cd8
set PA_LOGBUF   0x0192d110
set WAIT_MS     500000     ;# ~8.3 min: 25 MHz core needs ~400 s+ to userspace
set LOG_WORDS   16384      ;# 64 KiB of __log_buf (catches late 'Run /init')

foreach f [list $ps7_init $bit $fw] {
    if {![file exists $f]} { error "missing input: $f" }
}

connect
targets -set -nocase -filter {name =~ "*Cortex-A9*#0"}
catch { stop }
source $ps7_init
catch { ps7_init }
catch { ps7_post_config }
dow $fw
fpga -file $bit
puts "== booting; waiting [expr {$WAIT_MS/1000}] s for userspace =="
after $WAIT_MS

set u [mrd -value $PA_NL_USERS 1]
set j [mrd -value $PA_JIFFIES 2]
puts "nl_table_users=$u  jiffies=$j"

# Scan __log_buf for the userspace-handoff / late-init markers.
set words [mrd -value $PA_LOGBUF $LOG_WORDS]
set line ""
set hit_run 0
set hit_free 0
foreach w $words {
    for {set b 0} {$b < 4} {incr b} {
        set c [expr {($w >> ($b*8)) & 0xff}]
        if {$c == 10 || $c == 13} {
            if {[string length $line] > 2} {
                if {[string match -nocase "*Run /init*" $line]}        { set hit_run 1;  puts "LOG: $line" }
                if {[string match -nocase "*Freeing unused*" $line]}    { set hit_free 1; puts "LOG: $line" }
                if {[string match -nocase "*netlink*" $line]}           { puts "LOG: $line" }
                if {[string match -nocase "*Kernel panic*" $line]}      { puts "LOG: $line" }
            }
            set line ""
        } elseif {$c >= 32 && $c < 127} {
            append line [format %c $c]
        }
    }
}

puts ""
puts ">>> nl_table_users = $u  (==0 -> netlink atomic fix held)"
puts ">>> Run-/init-as-init seen in log: $hit_run   Freeing-unused seen: $hit_free"
puts ">>> (both 1 + nl==0  ->  reached userspace handoff with the fix)"
