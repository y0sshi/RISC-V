# =============================================================================
# kv260_uart.xdc - Physical pin constraints for the RISC-V UART console on KV260
# =============================================================================
# The SoC UART (NS16550-compatible 8N1) is routed to 2 pins of the KV260
# Vision AI Starter Kit carrier card's J2 "Digilent Pmod 2x6" expansion header.
#
# ---- Pin sourcing / confidence note (read before wiring hardware) ----
# The KV260 carrier's board_files (Xilinx-shipped, board.xml/part0_pins.xml
# under the Vivado install) do not model J2 as a generic "Pmod" board
# interface -- they model it as TWO optional presets that share the SAME
# physical header: an "i2s_in" 3-signal group and an "i2s_out" 3-signal group
# (for an optional Digilent Pmod I2S2 audio module). If no I2S module is
# plugged in, these pins are ordinary free 3.3V LVCMOS I/O at J2.
#
# The 2 pins below (som240_1_b21 / som240_1_b22, part of the "i2s_in" group)
# were cross-checked against TWO independent sources and agree exactly:
#   - Xilinx's own kv260_som board_files part0_pins.xml (authoritative package
#     pin locations): som240_1_b21 -> E12, som240_1_b22 -> D11.
#   - A community-published KV260 Pmod pin table (gist by tonosaman) listing
#     the same E12/D11 package pins at J2 positions 8/9 with net names
#     HDA16_CC / HDA17.
# This is NOT independently verified against the full AMD carrier-card
# schematic (UG1089) by this script's author -- double-check against your own
# board revision / the schematic before physically wiring, same as any other
# hand-sourced pin assignment.
#
# Wiring (J2 Pmod, "i2s_in" position):
#   J2 pin 8 (E12) = uart_tx  (FPGA output) -> connect to adapter RX
#   J2 pin 9 (D11) = uart_rx  (FPGA input)  <- connect to adapter TX
#   Use a common ground between the board and the USB-UART adapter (J2 has a
#   GND pin in the standard Digilent 2x6 Pmod pinout).
#
# NOTE: the PS clock/reset, DDR4 and FIXED_IO are PS-dedicated pins configured
# by the KV260 (kv260_som) board preset (apply_board_preset) on the PS8; they
# are auto-constrained and need no entries here.
# =============================================================================

set_property -dict {PACKAGE_PIN E12 IOSTANDARD LVCMOS33} [get_ports uart_tx]
set_property -dict {PACKAGE_PIN D11 IOSTANDARD LVCMOS33} [get_ports uart_rx]
