#!/bin/sh

VIVADO=/tools/Xilinx/Vivado/2020.2/bin/vivado
TCL=${1}

${VIVADO} -mode tcl -source ${TCL}
rm -rf .Xil .srcs vivado.* *.{jou,log}
