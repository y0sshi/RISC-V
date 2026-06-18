# =============================================================================
# zybo_uart.xdc - Physical pin constraints for the RISC-V UART console on Zybo Z7-20
# =============================================================================
# The SoC UART (NS16550-compatible 8N1) is routed to Pmod connector JC so the real
# OpenSBI / Linux console can be observed on a 3.3 V USB-UART adapter (e.g. an FTDI
# cable or a Digilent Pmod USBUART).  Package pins are from the Digilent
# Zybo-Z7-Master.xdc (Pmod JC).  IOSTANDARD is LVCMOS33 (Pmod banks are 3.3 V).
#
# Wiring (Pmod JC, top row):
#   JC pin 1 (V15) = uart_tx  (FPGA output) -> connect to adapter RX
#   JC pin 2 (W15) = uart_rx  (FPGA input)  <- connect to adapter TX
#   JC pin 5/11    = GND                     -> adapter GND
# Use a common ground between the board and the USB-UART adapter.
#
# NOTE: the PS clock/reset, DDR and MIO are PS-dedicated pins configured by the
# Zybo board preset (apply_board_preset) on the PS7 FIXED_IO/DDR external ports;
# they are auto-constrained and need no entries here.
# =============================================================================

set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports uart_tx]
set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS33} [get_ports uart_rx]

