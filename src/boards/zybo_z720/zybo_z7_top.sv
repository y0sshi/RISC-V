// =============================================================================
// zybo_z7_top.sv - Top Module for Digilent Zybo Z7-20
// =============================================================================
// Board: Digilent Zybo Z7-20 (Zynq-7020, 125 MHz system clock)
//
// Pin assignment:
//   sysclk       125 MHz oscillator (K17)
//   btn[0]       Active-HIGH reset -> converted to active-LOW rst_n
//   sw[3:0]      Slide switches    -> rv_soc gpio_in
//   led[3:0]     LEDs              <- rv_soc gpio_out
//   led5_r       Red   - asserted while in reset
//   led5_g       Green - asserted while running (reset released)
//   led5_b       Blue  - unused (0)
//   led6_r/g/b   Unused (0)
//   je[0]        Pmod JE pin-1 -> uart_tx  (connect to external device RX)
//   je[1]        Pmod JE pin-2 <- uart_rx  (connect to external device TX)
//   je[7:2]      Pmod JE remaining pins - tri-stated (unused)
//
// Note: HDMI TX, Pmod JA/JB/JC/JD are NOT connected to rv_soc and are
//       omitted from this port list.  The corresponding XDC constraints
//       are commented out in zybo-z7.xdc.
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module zybo_z7_top (
    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    input  wire        sysclk,     // 125 MHz (K17)

    // -------------------------------------------------------------------------
    // User I/O
    // -------------------------------------------------------------------------
    input  wire [3:0]  btn,        // btn[0] = active-HIGH reset
    input  wire [3:0]  sw,         // Slide switches -> gpio_in[3:0]
    output logic [3:0] led,        // LEDs <- gpio_out[3:0]

    // Status RGB LEDs
    output logic       led5_r,     // Reset indicator (red)
    output logic       led5_g,     // Running indicator (green)
    output logic       led5_b,     // Unused
    output logic       led6_r,     // Unused
    output logic       led6_g,     // Unused
    output logic       led6_b,     // Unused

    // -------------------------------------------------------------------------
    // Pmod JE - UART  (LVCMOS33, 3.3 V)
    //   je[0] = uart_tx  (output to remote RX)
    //   je[1] = uart_rx  (input  from remote TX)
    //   je[7:2] = NC     (tri-stated)
    // -------------------------------------------------------------------------
    inout  wire [7:0]  je
);

    // =========================================================================
    // Clock & Reset
    // =========================================================================
    wire clk   = sysclk;          // 125 MHz - use directly (add MMCM if needed)
    wire rst_n = ~btn[0];         // btn[0] active-HIGH -> invert to active-LOW

    // =========================================================================
    // UART pin steering on Pmod JE
    // =========================================================================
    logic uart_tx_sig;
    wire  uart_rx_sig;

    assign je[0]   = uart_tx_sig; // UART TX driven out
    assign uart_rx_sig = je[1];   // UART RX read in
    assign je[7:2] = 6'bz;       // Unused pins: tri-state

    // =========================================================================
    // SoC instance
    // =========================================================================
    logic [3:0] gpio_out;

    rv_soc #(
        .IMEM_DEPTH (8192),        // 8K x 32-bit = 32 KB instruction memory
        .DMEM_DEPTH (4096),        // 4K x 32-bit = 16 KB data memory
        .IMEM_FILE  (""),          // Load via Vivado memory initialisation
        .DMEM_FILE  ("")
    ) u_soc (
        .clk      (clk),
        .rst_n    (rst_n),
        .gpio_in  (sw),
        .gpio_out (gpio_out),
        .uart_rx  (uart_rx_sig),
        .uart_tx  (uart_tx_sig)
    );

    // =========================================================================
    // Output assignments
    // =========================================================================
    assign led = gpio_out;

    // Status LEDs: red while reset is asserted, green while running
    assign led5_r = ~rst_n;       // red   = btn[0] pressed (in reset)
    assign led5_g =  rst_n;       // green = running normally
    assign led5_b = 1'b0;

    assign led6_r = 1'b0;
    assign led6_g = 1'b0;
    assign led6_b = 1'b0;

endmodule

`default_nettype wire
