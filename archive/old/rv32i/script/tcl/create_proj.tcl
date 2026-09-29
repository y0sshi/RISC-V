# env
set WORKSPACE_DIR ".."
set PROJECT_NAME  "RISC-V"
set TOP_MODULE    "zybo_z7_top"
set JOBS          4
set CHIP          "xc7z020clg400-1"
set BOARD         "digilentinc.com:zybo-z7-20:part0:1.0"

# create project
if { [ file exists ${WORKSPACE_DIR}/vivado_proj/${PROJECT_NAME}.xpr ] == 0 } then {
	file mkdir ${WORKSPACE_DIR}/vivado_proj
		create_project ${PROJECT_NAME} ${WORKSPACE_DIR}/vivado_proj -part ${CHIP}
}
set_property board_part ${BOARD} [current_project]

# import sources (hdl, block design, xdc)
source tcl/add_files.tcl
set_property top sim_rv32i [get_filesets sim_1]
add_files -fileset constrs_1 -norecurse "${WORKSPACE_DIR}/src/xdc/target.xdc"
set_property target_constrs_file ${WORKSPACE_DIR}/src/xdc/target.xdc [current_fileset -constrset]

exit

