# Open the routed checkpoint and report the worst setup path (50MHz path analysis).
open_checkpoint [file join [file dirname [info script]] rv_riscv_zybo rv_riscv_zybo.runs impl_1 bd_riscv_wrapper_routed.dcp]
puts "==== WORST SETUP PATHS ===="
report_timing -delay_type max -max_paths 3 -nworst 3 -path_type full_clock_expanded -input_pins
puts "==== WORST PATH SUMMARY (datapath only) ===="
report_timing -delay_type max -max_paths 5 -nworst 1
