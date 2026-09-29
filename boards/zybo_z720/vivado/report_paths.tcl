# report_paths.tcl - Open the routed impl_1 and dump the N worst setup paths
# (unique endpoints) so the near-worst timing cluster can be inspected without a
# rebuild.  Run from PowerShell, absolute -source path, from the repo root:
#   & "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch `
#       -source $PWD\boards\zybo_z720\vivado\report_paths.tcl `
#       *> $PWD\boards\reports\report_paths.log 2>&1
set script_dir [file normalize [file dirname [info script]]]
set proj_name  "rv_riscv_zybo"
set xpr        "$script_dir/$proj_name/$proj_name.xpr"
open_project $xpr
open_run impl_1
report_timing -setup -max_paths 40 -nworst 1 -unique_pins -path_type summary \
    -file "$script_dir/../../../boards/reports/report_paths_summary.rpt"
report_timing -setup -max_paths 40 -nworst 1 -unique_pins \
    -file "$script_dir/../../../boards/reports/report_paths_full.rpt"
puts "INFO: report_paths DONE"
