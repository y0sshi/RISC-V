# =============================================================================
# pynq_z2_uart.xdc - Physical pin constraints for the RISC-V UART console on PYNQ-Z2
# =============================================================================
# The SoC UART (NS16550-compatible 8N1) is routed to Pmod connector JB (PYNQ-Z2
# has only Pmod JA/JB, no Pmod JC like Zybo) so the real OpenSBI / Linux console
# can be observed on a 3.3 V USB-UART adapter (e.g. an FTDI cable or a Digilent
# Pmod USBUART). Package pins are from the vendored part0_pins.xml (see
# ../board_files/README.md) -- identical locations to PYNQ-Z1 (same physical
# Pmod JB wiring on both boards). IOSTANDARD is LVCMOS33 (Pmod banks are 3.3 V).
#
# Wiring (Pmod JB, top row):
#   JB pin 1 (W14) = uart_tx  (FPGA output) -> connect to adapter RX
#   JB pin 2 (Y14) = uart_rx  (FPGA input)  <- connect to adapter TX
#   JB pin 5/11 (GND)          -> adapter GND
# Use a common ground between the board and the USB-UART adapter.
#
# NOTE: the PS clock/reset, DDR and MIO are PS-dedicated pins configured by the
# PYNQ-Z2 board preset (apply_board_preset) on the PS7 FIXED_IO/DDR external
# ports; they are auto-constrained and need no entries here.
# =============================================================================

set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports uart_tx]
set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} [get_ports uart_rx]
