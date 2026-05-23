// =============================================================================
// rv_gpio.sv - Memory-Mapped General Purpose I/O
// =============================================================================
// Simple GPIO peripheral with configurable width (default 4-bit for Zybo Z7-20).
//
// Register map (byte addresses within 16-byte window, 4-byte aligned):
//   0x00  OUT  (R/W)  Output data register.
//                     Write: set output pin values for bits where DIR=1.
//                     Read:  returns current OUT register value.
//   0x04  IN   (RO)   Input data register.
//                     Read:  returns synchronised gpio_in pin values.
//                     Write: ignored.
//   0x08  DIR  (R/W)  Direction control register (default 0 = all input).
//                     Bit[n] = 1 : pin n drives gpio_out[n].
//                     Bit[n] = 0 : pin n is input only (gpio_out[n] = 0).
//   0x0C  IRQ_EN (R/W) Change-detect interrupt enable.
//                     Bit[n] = 1 : assert irq when gpio_in[n] changes.
//
// Interrupt behaviour:
//   irq is a level signal: asserted when (any enabled bit changed AND not yet
//   acknowledged).  Software clears by writing 1 to the changed bits in IRQ_CLR
//   (alias of IRQ_EN address on write with we=1; cleared bits are the ack).
//
//   Simpler model used here:
//     irq = OR of (irq_en & pending_change[n]).
//     Write to IRQ_EN register clears pending bits for positions written as 1.
//
// Bus interface: 32-bit word accesses; addr[3:2] selects the register.
// All reads are combinational (ready = 1 on same cycle as req).
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module rv_gpio #(
    parameter int WIDTH = 4     // number of GPIO pins
) (
    input  wire              clk,
    input  wire              rst_n,

    // 32-bit memory-mapped bus (byte address within 16-byte window)
    input  wire  [3:0]       addr,
    input  wire              req,
    input  wire              we,
    input  wire  [31:0]      wdata,
    output logic [31:0]      rdata,

    // GPIO pins (physical)
    input  wire  [WIDTH-1:0] gpio_in,   // input  pins (e.g. switches)
    output logic [WIDTH-1:0] gpio_out,  // output pins (e.g. LEDs)

    // Change-detect interrupt (level, active high)
    output logic             irq
);

    // =========================================================================
    // Register address decode (addr[3:2] selects register)
    // =========================================================================
    logic [1:0] reg_sel;
    assign reg_sel = {addr[3], addr[2]};

    localparam logic [1:0] REG_OUT    = 2'b00;
    localparam logic [1:0] REG_IN     = 2'b01;
    localparam logic [1:0] REG_DIR    = 2'b10;
    localparam logic [1:0] REG_IRQ_EN = 2'b11;

    // =========================================================================
    // Register storage
    // =========================================================================
    logic [WIDTH-1:0] out_r;     // output data
    logic [WIDTH-1:0] dir_r;     // direction (1=output)
    logic [WIDTH-1:0] irq_en_r;  // interrupt enable per bit

    // =========================================================================
    // Input synchroniser (2-FF metastability protection)
    // =========================================================================
    logic [WIDTH-1:0] gpio_in_s1;   // sync stage 1
    logic [WIDTH-1:0] gpio_in_s2;   // sync stage 2 (stable)
    logic [WIDTH-1:0] gpio_in_prev; // previous stable value (for edge detect)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gpio_in_s1   <= '0;
            gpio_in_s2   <= '0;
            gpio_in_prev <= '0;
        end else begin
            gpio_in_s1   <= gpio_in;
            gpio_in_s2   <= gpio_in_s1;
            gpio_in_prev <= gpio_in_s2;
        end
    end

    // =========================================================================
    // Change-detect interrupt: pending bit set when any enabled bit changes
    // =========================================================================
    logic [WIDTH-1:0] changed;        // XOR of current vs previous (edge detect)
    logic [WIDTH-1:0] irq_pending_r;  // sticky pending bits

    assign changed = gpio_in_s2 ^ gpio_in_prev;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_pending_r <= '0;
        end else begin
            // Set on change (only for enabled bits)
            irq_pending_r <= irq_pending_r | (changed & irq_en_r);

            // Clear: write 1 to IRQ_EN register acts as ACK for those bits
            if (req && we && reg_sel == REG_IRQ_EN) begin
                irq_pending_r <= (irq_pending_r | (changed & irq_en_r))
                                  & ~wdata[WIDTH-1:0];
            end
        end
    end

    assign irq = |irq_pending_r;

    // =========================================================================
    // Output pin drive: enabled by DIR
    // gpio_out[n] = out_r[n] when dir_r[n]=1, else 0
    // =========================================================================
    always_comb begin
        for (int n = 0; n < WIDTH; n++) begin
            gpio_out[n] = dir_r[n] ? out_r[n] : 1'b0;
        end
    end

    // =========================================================================
    // Register write
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_r    <= '0;
            dir_r    <= '0;
            irq_en_r <= '0;
        end else if (req && we) begin
            case (reg_sel)
                REG_OUT:    out_r    <= wdata[WIDTH-1:0];
                REG_DIR:    dir_r    <= wdata[WIDTH-1:0];
                REG_IRQ_EN: irq_en_r <= wdata[WIDTH-1:0];
                default: ;   // REG_IN is read-only
            endcase
        end
    end

    // =========================================================================
    // Combinational read
    // =========================================================================
    always_comb begin
        rdata = 32'h0;
        if (req && !we) begin
            case (reg_sel)
                REG_OUT:    rdata = {{(32-WIDTH){1'b0}}, out_r};
                REG_IN:     rdata = {{(32-WIDTH){1'b0}}, gpio_in_s2};
                REG_DIR:    rdata = {{(32-WIDTH){1'b0}}, dir_r};
                REG_IRQ_EN: rdata = {{(32-WIDTH){1'b0}}, irq_en_r};
                default:    rdata = 32'h0;
            endcase
        end
    end

endmodule

`default_nettype wire
