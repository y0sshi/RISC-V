// =============================================================================
// rv_uart.sv - Memory-Mapped 8N1 UART Peripheral
// =============================================================================
// Implements a simple 8N1 UART with memory-mapped registers.
//
// Register map (byte addresses within this peripheral's 16-byte window):
//   0x00 DATA : TX write / RX read (8-bit)
//              - Write: loads TX shift register (ignored if TXEN=0)
//              - Read : returns RX data register, clears RXRDY
//   0x04 STAT : Status register (read-only)
//              - [0] TXRDY : TX idle, ready for next byte
//              - [1] RXRDY : received byte available
//              - [2] RXERR : framing error (stop bit ≠ 1); cleared on DATA read
//   0x08 CTRL : Control register (R/W)
//              - [0] TXEN  : TX enable
//              - [1] RXEN  : RX enable
//              - [2] TXIE  : TX interrupt enable (fires when TXRDY becomes 1)
//              - [3] RXIE  : RX interrupt enable (fires when RXRDY=1)
//   0x0C DIV  : Baud divisor [15:0] = clocks_per_bit - 1 (R/W)
//              - Default: CLK_FREQ/BAUD_RATE - 1
//
// Interrupts:
//   tx_irq : one-cycle pulse when TX completes and TXIE=1
//   rx_irq : level signal: RXRDY & RXIE
//
// TX state machine: IDLE → START → DATA(0..7) → STOP → IDLE
// RX state machine: IDLE → START(wait half-bit) → DATA(0..7) → STOP → IDLE
//   2-FF synchronizer on uart_rx input.
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module rv_uart #(
    parameter int CLK_FREQ  = 50_000_000,   // Hz
    parameter int BAUD_RATE = 115_200        // bps
) (
    input  wire         clk,
    input  wire         rst_n,

    // 32-bit memory-mapped bus (byte address within 16-byte window)
    input  wire  [3:0]  addr,
    input  wire         req,
    input  wire         we,
    input  wire  [31:0] wdata,
    output logic [31:0] rdata,

    // UART pins
    output logic        uart_tx,
    input  wire         uart_rx,

    // Interrupts
    output logic        tx_irq,
    output logic        rx_irq
);

    // =========================================================================
    // Default baud divisor
    // =========================================================================
    localparam logic [15:0] DEF_DIV = CLK_FREQ / BAUD_RATE - 1;

    // =========================================================================
    // Registers
    // =========================================================================
    logic [7:0]  tx_data_reg;   // byte to transmit
    logic [7:0]  rx_data_reg;   // received byte

    // STAT bits
    logic        txrdy;         // TX idle
    logic        rxrdy;         // RX byte available
    logic        rxerr;         // framing error

    // CTRL bits
    logic        txen;
    logic        rxen;
    logic        txie;
    logic        rxie;

    logic [15:0] div_reg;       // baud divisor

    // =========================================================================
    // TX state machine
    // =========================================================================
    typedef enum logic [1:0] {
        TX_IDLE  = 2'd0,
        TX_START = 2'd1,
        TX_DATA  = 2'd2,
        TX_STOP  = 2'd3
    } tx_state_t;

    tx_state_t   tx_state;
    logic [15:0] tx_baud_cnt;
    logic [2:0]  tx_bit_cnt;
    logic [7:0]  tx_shift;
    logic        tx_done;       // one-cycle pulse: TX just finished

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state    <= TX_IDLE;
            tx_baud_cnt <= 16'd0;
            tx_bit_cnt  <= 3'd0;
            tx_shift    <= 8'hFF;
            uart_tx     <= 1'b1;
            txrdy       <= 1'b1;
            tx_done     <= 1'b0;
        end else begin
            tx_done <= 1'b0;

            case (tx_state)
                TX_IDLE: begin
                    uart_tx <= 1'b1;
                    // Start TX when software writes DATA register (txrdy→0)
                    if (!txrdy) begin
                        tx_shift    <= tx_data_reg;
                        tx_baud_cnt <= div_reg;
                        tx_state    <= TX_START;
                        uart_tx     <= 1'b0;   // start bit
                    end
                end

                TX_START: begin
                    if (tx_baud_cnt == 16'd0) begin
                        tx_baud_cnt <= div_reg;
                        tx_bit_cnt  <= 3'd0;
                        uart_tx     <= tx_shift[0];
                        tx_shift    <= {1'b1, tx_shift[7:1]};
                        tx_state    <= TX_DATA;
                    end else begin
                        tx_baud_cnt <= tx_baud_cnt - 16'd1;
                    end
                end

                TX_DATA: begin
                    if (tx_baud_cnt == 16'd0) begin
                        tx_baud_cnt <= div_reg;
                        if (tx_bit_cnt == 3'd7) begin
                            uart_tx  <= 1'b1;  // stop bit
                            tx_state <= TX_STOP;
                        end else begin
                            tx_bit_cnt <= tx_bit_cnt + 3'd1;
                            uart_tx    <= tx_shift[0];
                            tx_shift   <= {1'b1, tx_shift[7:1]};
                        end
                    end else begin
                        tx_baud_cnt <= tx_baud_cnt - 16'd1;
                    end
                end

                TX_STOP: begin
                    if (tx_baud_cnt == 16'd0) begin
                        tx_state <= TX_IDLE;
                        txrdy    <= 1'b1;
                        tx_done  <= 1'b1;
                    end else begin
                        tx_baud_cnt <= tx_baud_cnt - 16'd1;
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    // =========================================================================
    // RX state machine
    // =========================================================================
    // 2-FF synchronizer
    logic rx_sync0, rx_sync1, rx_prev;

    typedef enum logic [1:0] {
        RX_IDLE  = 2'd0,
        RX_START = 2'd1,
        RX_DATA  = 2'd2,
        RX_STOP  = 2'd3
    } rx_state_t;

    rx_state_t   rx_state;
    logic [15:0] rx_baud_cnt;
    logic [2:0]  rx_bit_cnt;
    logic [7:0]  rx_shift;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync0    <= 1'b1;
            rx_sync1    <= 1'b1;
            rx_prev     <= 1'b1;
            rx_state    <= RX_IDLE;
            rx_baud_cnt <= 16'd0;
            rx_bit_cnt  <= 3'd0;
            rx_shift    <= 8'd0;
            rx_data_reg <= 8'd0;
            rxrdy       <= 1'b0;
            rxerr       <= 1'b0;
        end else begin
            // synchronizer pipeline
            rx_sync0 <= uart_rx;
            rx_sync1 <= rx_sync0;
            rx_prev  <= rx_sync1;

            case (rx_state)
                RX_IDLE: begin
                    // detect falling edge (start bit)
                    if (rxen && rx_prev && !rx_sync1) begin
                        // wait half bit period to sample in the middle
                        rx_baud_cnt <= div_reg >> 1;
                        rx_state    <= RX_START;
                    end
                end

                RX_START: begin
                    if (rx_baud_cnt == 16'd0) begin
                        // confirm start bit is still 0
                        if (!rx_sync1) begin
                            rx_baud_cnt <= div_reg;
                            rx_bit_cnt  <= 3'd0;
                            rx_shift    <= 8'd0;
                            rx_state    <= RX_DATA;
                        end else begin
                            rx_state <= RX_IDLE;  // glitch, abort
                        end
                    end else begin
                        rx_baud_cnt <= rx_baud_cnt - 16'd1;
                    end
                end

                RX_DATA: begin
                    if (rx_baud_cnt == 16'd0) begin
                        rx_baud_cnt <= div_reg;
                        rx_shift    <= {rx_sync1, rx_shift[7:1]};
                        if (rx_bit_cnt == 3'd7) begin
                            rx_state <= RX_STOP;
                        end else begin
                            rx_bit_cnt <= rx_bit_cnt + 3'd1;
                        end
                    end else begin
                        rx_baud_cnt <= rx_baud_cnt - 16'd1;
                    end
                end

                RX_STOP: begin
                    if (rx_baud_cnt == 16'd0) begin
                        rx_data_reg <= rx_shift;
                        rxrdy       <= 1'b1;
                        rxerr       <= !rx_sync1;   // stop bit must be 1
                        rx_state    <= RX_IDLE;
                    end else begin
                        rx_baud_cnt <= rx_baud_cnt - 16'd1;
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Bus interface (register read/write)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_data_reg <= 8'd0;
            txen        <= 1'b1;
            rxen        <= 1'b1;
            txie        <= 1'b0;
            rxie        <= 1'b0;
            div_reg     <= DEF_DIV;
        end else if (req && we) begin
            case (addr[3:2])
                2'b00: begin  // DATA write → start TX
                    if (txen && txrdy) begin
                        tx_data_reg <= wdata[7:0];
                        txrdy       <= 1'b0;
                    end
                end
                2'b01: ;  // STAT read-only
                2'b10: begin  // CTRL
                    txen <= wdata[0];
                    rxen <= wdata[1];
                    txie <= wdata[2];
                    rxie <= wdata[3];
                end
                2'b11: begin  // DIV
                    div_reg <= wdata[15:0];
                end
            endcase
        end
    end

    // DATA read: clear RXRDY + RXERR
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // rxrdy/rxerr reset handled above
        end else if (req && !we && addr[3:2] == 2'b00) begin
            rxrdy <= 1'b0;
            rxerr <= 1'b0;
        end
    end

    // =========================================================================
    // Combinational read  (avoid constant part-selects in always_comb)
    // =========================================================================
    // Pre-build each register's read value as wires (zero-extended to 32 bits)
    wire [31:0] rdata_data = 32'd0 | {24'd0, rx_data_reg};
    wire [31:0] rdata_stat = 32'd0 | {29'd0, rxerr, rxrdy, txrdy};
    wire [31:0] rdata_ctrl = 32'd0 | {28'd0, rxie, txie, rxen, txen};
    wire [31:0] rdata_div  = 32'd0 | div_reg;  // zero-extend 16→32

    // Extract register select outside always_* to avoid iverilog constant-select warning
    wire [1:0] reg_sel = {addr[3], addr[2]};

    always_comb begin
        case (reg_sel)
            2'b00: rdata = rdata_data;
            2'b01: rdata = rdata_stat;
            2'b10: rdata = rdata_ctrl;
            2'b11: rdata = rdata_div;
        endcase
    end

    // =========================================================================
    // Interrupts
    // =========================================================================
    assign tx_irq = tx_done & txie;
    assign rx_irq = rxrdy  & rxie;

endmodule

`default_nettype wire
