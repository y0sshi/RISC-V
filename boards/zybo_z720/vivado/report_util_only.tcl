# Quick follow-up: open the already-routed impl_1 (produced by build_zybo.tcl)
# and write a fresh utilization report.  Does not modify or re-run anything.
set script_dir [file normalize [file dirname [info script]]]
set proj_name  "rv_riscv_zybo"
set proj_dir   "$script_dir/$proj_name"
set proj_xpr   "$proj_dir/$proj_name.xpr"

open_project $proj_xpr
open_run impl_1

report_utilization -file "$script_dir/../../../boards/reports/build_zybo_util.rpt"
report_utilization -hierarchical -file "$script_dir/../../../boards/reports/build_zybo_util_hier.rpt"

puts "UTIL_REPORT_DONE"
