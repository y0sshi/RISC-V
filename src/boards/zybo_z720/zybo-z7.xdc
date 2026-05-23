## =============================================================================
## zybo-z7.xdc - Constraints for Digilent Zybo Z7-20
## =============================================================================
## Compatible with Zybo Z7-10 and Zybo Z7-20.
## Updated for rv_soc integration (new RISC-V core).
##
## Active ports in zybo_z7_top:
##   sysclk, btn[3:0], sw[3:0], led[3:0],
##   led5_r/g/b, led6_r/g/b, je[7:0]
##
## Unused / removed from top-level port list:
##   hdmi_tx_*, jb[7:0], jc[7:0], jd[7:0]  → constraints commented out below
## =============================================================================


## -----------------------------------------------------------------------------
## Clock signal (125 MHz)
## -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk }]


## -----------------------------------------------------------------------------
## Switches
## -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN G15 IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]
set_property -dict { PACKAGE_PIN P15 IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]
set_property -dict { PACKAGE_PIN W13 IOSTANDARD LVCMOS33 } [get_ports { sw[2] }]
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports { sw[3] }]


## -----------------------------------------------------------------------------
## Buttons  (btn[0] = active-HIGH reset)
## -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]
set_property -dict { PACKAGE_PIN K19 IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]
set_property -dict { PACKAGE_PIN Y16 IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]


## -----------------------------------------------------------------------------
## LEDs  (gpio_out[3:0])
## -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]


## -----------------------------------------------------------------------------
## RGB LED 5 (Zybo Z7-20 only) – status indicators
## -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN Y11 IOSTANDARD LVCMOS33 } [get_ports led5_r]
set_property -dict { PACKAGE_PIN T5  IOSTANDARD LVCMOS33 } [get_ports led5_g]
set_property -dict { PACKAGE_PIN Y12 IOSTANDARD LVCMOS33 } [get_ports led5_b]

## RGB LED 6 – unused (driven 0 in RTL)
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports led6_r]
set_property -dict { PACKAGE_PIN F17 IOSTANDARD LVCMOS33 } [get_ports led6_g]
set_property -dict { PACKAGE_PIN M17 IOSTANDARD LVCMOS33 } [get_ports led6_b]


## -----------------------------------------------------------------------------
## Pmod JE – UART
##   je[0] (V12)  = uart_tx  → connect to external device RX
##   je[1] (W16)  = uart_rx  ← connect to external device TX
##   je[2..7]     = NC (tri-stated in RTL)
## -----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports { je[0] }]
set_property -dict { PACKAGE_PIN W16 IOSTANDARD LVCMOS33 } [get_ports { je[1] }]
set_property -dict { PACKAGE_PIN J15 IOSTANDARD LVCMOS33 } [get_ports { je[2] }]
set_property -dict { PACKAGE_PIN H15 IOSTANDARD LVCMOS33 } [get_ports { je[3] }]
set_property -dict { PACKAGE_PIN V13 IOSTANDARD LVCMOS33 } [get_ports { je[4] }]
set_property -dict { PACKAGE_PIN U17 IOSTANDARD LVCMOS33 } [get_ports { je[5] }]
set_property -dict { PACKAGE_PIN T17 IOSTANDARD LVCMOS33 } [get_ports { je[6] }]
set_property -dict { PACKAGE_PIN Y17 IOSTANDARD LVCMOS33 } [get_ports { je[7] }]


## =============================================================================
## Unused / Not connected to rv_soc – commented out
## =============================================================================

## HDMI TX (not used by rv_soc – removed from port list)
#set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVCMOS33 } [get_ports { hdmi_tx_hpd }]
#set_property -dict { PACKAGE_PIN G17 IOSTANDARD LVCMOS33 } [get_ports { hdmi_tx_scl }]
#set_property -dict { PACKAGE_PIN G18 IOSTANDARD LVCMOS33 } [get_ports { hdmi_tx_sda }]
#set_property -dict { PACKAGE_PIN H17 IOSTANDARD TMDS_33  } [get_ports hdmi_tx_clk_n]
#set_property -dict { PACKAGE_PIN H16 IOSTANDARD TMDS_33  } [get_ports hdmi_tx_clk_p]
#set_property -dict { PACKAGE_PIN D20 IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_n[0] }]
#set_property -dict { PACKAGE_PIN D19 IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_p[0] }]
#set_property -dict { PACKAGE_PIN B20 IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_n[1] }]
#set_property -dict { PACKAGE_PIN C20 IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_p[1] }]
#set_property -dict { PACKAGE_PIN A20 IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_n[2] }]
#set_property -dict { PACKAGE_PIN B19 IOSTANDARD TMDS_33  } [get_ports { hdmi_tx_p[2] }]

## Pmod JA (XADC) – not used
#set_property -dict { PACKAGE_PIN N15 IOSTANDARD LVCMOS33 } [get_ports { ja[0] }]
#set_property -dict { PACKAGE_PIN L14 IOSTANDARD LVCMOS33 } [get_ports { ja[1] }]
#set_property -dict { PACKAGE_PIN K16 IOSTANDARD LVCMOS33 } [get_ports { ja[2] }]
#set_property -dict { PACKAGE_PIN K14 IOSTANDARD LVCMOS33 } [get_ports { ja[3] }]
#set_property -dict { PACKAGE_PIN N16 IOSTANDARD LVCMOS33 } [get_ports { ja[4] }]
#set_property -dict { PACKAGE_PIN L15 IOSTANDARD LVCMOS33 } [get_ports { ja[5] }]
#set_property -dict { PACKAGE_PIN J16 IOSTANDARD LVCMOS33 } [get_ports { ja[6] }]
#set_property -dict { PACKAGE_PIN J14 IOSTANDARD LVCMOS33 } [get_ports { ja[7] }]

## Pmod JB (Zybo Z7-20 only) – not used
#set_property -dict { PACKAGE_PIN V8  IOSTANDARD LVCMOS33 } [get_ports { jb[0] }]
#set_property -dict { PACKAGE_PIN W8  IOSTANDARD LVCMOS33 } [get_ports { jb[1] }]
#set_property -dict { PACKAGE_PIN U7  IOSTANDARD LVCMOS33 } [get_ports { jb[2] }]
#set_property -dict { PACKAGE_PIN V7  IOSTANDARD LVCMOS33 } [get_ports { jb[3] }]
#set_property -dict { PACKAGE_PIN Y7  IOSTANDARD LVCMOS33 } [get_ports { jb[4] }]
#set_property -dict { PACKAGE_PIN Y6  IOSTANDARD LVCMOS33 } [get_ports { jb[5] }]
#set_property -dict { PACKAGE_PIN V6  IOSTANDARD LVCMOS33 } [get_ports { jb[6] }]
#set_property -dict { PACKAGE_PIN W6  IOSTANDARD LVCMOS33 } [get_ports { jb[7] }]

## Pmod JC – not used
#set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports { jc[0] }]
#set_property -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS33 } [get_ports { jc[1] }]
#set_property -dict { PACKAGE_PIN T11 IOSTANDARD LVCMOS33 } [get_ports { jc[2] }]
#set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports { jc[3] }]
#set_property -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports { jc[4] }]
#set_property -dict { PACKAGE_PIN Y14 IOSTANDARD LVCMOS33 } [get_ports { jc[5] }]
#set_property -dict { PACKAGE_PIN T12 IOSTANDARD LVCMOS33 } [get_ports { jc[6] }]
#set_property -dict { PACKAGE_PIN U12 IOSTANDARD LVCMOS33 } [get_ports { jc[7] }]

## Pmod JD – not used
#set_property -dict { PACKAGE_PIN T14 IOSTANDARD LVCMOS33 } [get_ports { jd[0] }]
#set_property -dict { PACKAGE_PIN T15 IOSTANDARD LVCMOS33 } [get_ports { jd[1] }]
#set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports { jd[2] }]
#set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports { jd[3] }]
#set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports { jd[4] }]
#set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports { jd[5] }]
#set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports { jd[6] }]
#set_property -dict { PACKAGE_PIN V18 IOSTANDARD LVCMOS33 } [get_ports { jd[7] }]

## Audio Codec – not used
#set_property -dict { PACKAGE_PIN R19 IOSTANDARD LVCMOS33 } [get_ports { ac_bclk }]
#set_property -dict { PACKAGE_PIN R17 IOSTANDARD LVCMOS33 } [get_ports { ac_mclk }]
#set_property -dict { PACKAGE_PIN P18 IOSTANDARD LVCMOS33 } [get_ports { ac_muten }]
#set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports { ac_pbdat }]
#set_property -dict { PACKAGE_PIN T19 IOSTANDARD LVCMOS33 } [get_ports { ac_pblrc }]
#set_property -dict { PACKAGE_PIN R16 IOSTANDARD LVCMOS33 } [get_ports { ac_recdat }]
#set_property -dict { PACKAGE_PIN Y18 IOSTANDARD LVCMOS33 } [get_ports { ac_reclrc }]
#set_property -dict { PACKAGE_PIN N18 IOSTANDARD LVCMOS33 } [get_ports { ac_scl }]
#set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports { ac_sda }]

## HDMI RX – not used
#set_property -dict { PACKAGE_PIN W19 IOSTANDARD LVCMOS33  } [get_ports { hdmi_rx_hpd }]
#set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33  } [get_ports { hdmi_rx_scl }]
#set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33  } [get_ports { hdmi_rx_sda }]
#set_property -dict { PACKAGE_PIN U19 IOSTANDARD TMDS_33   } [get_ports { hdmi_rx_clk_n }]
#set_property -dict { PACKAGE_PIN U18 IOSTANDARD TMDS_33   } [get_ports { hdmi_rx_clk_p }]
#set_property -dict { PACKAGE_PIN W20 IOSTANDARD TMDS_33   } [get_ports { hdmi_rx_n[0] }]
#set_property -dict { PACKAGE_PIN V20 IOSTANDARD TMDS_33   } [get_ports { hdmi_rx_p[0] }]
#set_property -dict { PACKAGE_PIN U20 IOSTANDARD TMDS_33   } [get_ports { hdmi_rx_n[1] }]
#set_property -dict { PACKAGE_PIN T20 IOSTANDARD TMDS_33   } [get_ports { hdmi_rx_p[1] }]
#set_property -dict { PACKAGE_PIN P20 IOSTANDARD TMDS_33   } [get_ports { hdmi_rx_n[2] }]
#set_property -dict { PACKAGE_PIN N20 IOSTANDARD TMDS_33   } [get_ports { hdmi_rx_p[2] }]
