// =============================================================================
// kv260_top.sv - Top Module for Kria KV260
// =============================================================================
// Board-specific top module for the Xilinx Kria KV260 Vision AI Starter Kit.
// The KV260 uses a Zynq UltraScale+ (K26 SOM) with PS-PL interface.
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module kv260_top (
    // System clock (from PS or PL clock)
    input  wire        pl_clk0,

    // Reset (directly active from PS)
    input  wire        pl_resetn0,

    // PMOD interface (directly accessible on KV260 carrier)
    inout  wire [7:0]  pmod

    // TODO: Add AXI interface for PS-PL communication
    // TODO: Add fan control, I2C, etc. as needed
);

    // =========================================================================
    // Clock and Reset
    // =========================================================================
    wire clk   = pl_clk0;
    wire rst_n = pl_resetn0;

    // =========================================================================
    // SoC Instance
    // =========================================================================
    logic [3:0] gpio_out;

    rv_soc #(
        .IMEM_DEPTH (4096),
        .DMEM_DEPTH (4096),
        .IMEM_FILE  (""),
        .DMEM_FILE  ("")
    ) u_soc (
        .clk      (clk),
        .rst_n    (rst_n),
        .gpio_in  (pmod[3:0]),
        .gpio_out (gpio_out),
        .uart_rx  (pmod[4]),
        .uart_tx  (pmod[5])
    );

    // Connect GPIO outputs to PMOD pins
    assign pmod[3:0] = gpio_out;
    // pmod[5] driven by uart_tx
    // pmod[4] is uart_rx input
    assign pmod[7:6] = 2'bz;  // Unused, tri-state

endmodule

`default_nettype wire
