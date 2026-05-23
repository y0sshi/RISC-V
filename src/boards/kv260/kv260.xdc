## =============================================================================
## kv260.xdc - Kria KV260 Constraints (Placeholder)
## =============================================================================
## The KV260 SOM provides clocks and resets via the PS (Processing System).
## PL-side constraints depend on the carrier board and PMOD connections.
##
## Refer to Xilinx UG1089 and KV260 schematic for actual pin assignments.
## =============================================================================

## Clock constraint (PL fabric clock from PS, typically 100 MHz)
# create_clock -period 10.000 -name pl_clk0 [get_ports pl_clk0]

## PMOD connector (depends on carrier board revision)
## Uncomment and adjust when connecting to actual hardware.
# set_property -dict { PACKAGE_PIN H12 IOSTANDARD LVCMOS33 } [get_ports { pmod[0] }]
# set_property -dict { PACKAGE_PIN E10 IOSTANDARD LVCMOS33 } [get_ports { pmod[1] }]
# set_property -dict { PACKAGE_PIN D10 IOSTANDARD LVCMOS33 } [get_ports { pmod[2] }]
# set_property -dict { PACKAGE_PIN C11 IOSTANDARD LVCMOS33 } [get_ports { pmod[3] }]
# set_property -dict { PACKAGE_PIN B10 IOSTANDARD LVCMOS33 } [get_ports { pmod[4] }]
# set_property -dict { PACKAGE_PIN E12 IOSTANDARD LVCMOS33 } [get_ports { pmod[5] }]
# set_property -dict { PACKAGE_PIN D11 IOSTANDARD LVCMOS33 } [get_ports { pmod[6] }]
# set_property -dict { PACKAGE_PIN B11 IOSTANDARD LVCMOS33 } [get_ports { pmod[7] }]
