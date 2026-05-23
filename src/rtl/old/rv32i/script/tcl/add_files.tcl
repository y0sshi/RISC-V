# HDL-Source
add_files "
../src/hdl/zybo_z7_top.sv
../src/hdl/rv32i.sv
../src/hdl/Makefile
../src/hdl/dmem.sv
"

# SIM-Source
add_files -fileset sim_1 -norecurse "
../src/hdl/sim_rv32i.sv
"

# XDC
add_files -fileset constrs_1 -norecurse "
../src/xdc/zybo-z7.xdc
../src/xdc/timing.xdc 
"

