// =============================================================================
// rv_uart.sv - NS16550-compatible 8N1 UART (memory-mapped, reg-shift=2)
// =============================================================================
// Register-compatible with the industry-standard 16550 so the stock OpenSBI
// `uart8250` driver and the Linux `8250`/`ns16550` driver work unmodified.
// Registers are spaced 4 bytes apart (reg-shift=2, reg-io-width=4); index =
// addr[4:2].  Device tree: compatible = "ns16550a", reg-shift = <2>,
// reg-io-width = <4>, clock-frequency = <CLK_FREQ>.
//
//   idx off  name (DLAB=0)        name (DLAB=1)
//   --- ---- -------------------- ------------
//    0  0x00 RBR(r)/THR(w)        DLL (divisor low)
//    1  0x04 IER                  DLM (divisor high)
//    2  0x08 IIR(r)/FCR(w)
//    3  0x0C LCR  (bit7 = DLAB)
//    4  0x10 MCR
//    5  0x14 LSR  (r): DR[0] FE[3] THRE[5] TEMT[6]
//    6  0x18 MSR  (r)
//    7  0x1C SCR
//
// Baud: bit period = 16 * divisor_latch clocks (true 16x oversampling, so a
// driver writing DLL/DLM = clock-frequency/(16*baud) yields the right baud rate).
// Default divisor = max(1, CLK_FREQ/(16*BAUD_RATE)).
//
// FIFOs are not implemented (FCR is accepted/ignored; IIR reports no FIFO unless
// the driver sets FCR.FIFO, in which case the FIFO-enabled bits are echoed so the
// driver's probe succeeds).  Single-byte THR/RBR; THRE/TEMT both reflect TX idle.
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module rv_uart #(
    parameter int CLK_FREQ  = 50_000_000,
    parameter int BAUD_RATE = 115_200
) (
    input  wire         clk,
    input  wire         rst_n,

    // 32-bit memory-mapped bus (byte address within the UART window)
    input  wire  [4:0]  addr,
    input  wire         req,
    input  wire         we,
    input  wire  [31:0] wdata,
    output logic [31:0] rdata,

    // UART pins
    output logic        uart_tx,
    input  wire         uart_rx,

    // Interrupts (level): rx_irq = combined 16550 interrupt line; tx_irq unused
    output logic        tx_irq,
    output logic        rx_irq
);

    localparam logic [15:0] DEF_DIV =
        (CLK_FREQ / (16 * BAUD_RATE)) == 0 ? 16'd1 : CLK_FREQ / (16 * BAUD_RATE);

    // ---- Register file ------------------------------------------------------
    logic [7:0]  ier;          // interrupt enable
    logic [7:0]  lcr;          // line control (bit7 = DLAB)
    logic [7:0]  mcr;          // modem control
    logic [7:0]  scr;          // scratch
    logic [7:0]  fcr;          // FIFO control (stored; no real FIFO)
    logic [15:0] divisor;      // {DLM,DLL}
    wire         dlab = lcr[7];

    // Effective bit period in clocks (16x oversampling)
    wire [19:0]  bit_clocks = {divisor == 16'd0 ? 16'd1 : divisor, 4'd0}; // *16
    wire [19:0]  half_bit   = {1'b0, bit_clocks[19:1]};

    // ---- Status -------------------------------------------------------------
    logic        dr;           // RX data ready
    logic        fe;           // framing error
    logic [7:0]  rx_data_reg;
    logic        txrdy;        // TX idle (THRE/TEMT)

    wire  [7:0]  lsr = {1'b0, txrdy /*TEMT*/, txrdy /*THRE*/, 1'b0,
                        fe /*FE*/, 1'b0, 1'b0, dr /*DR*/};
    wire  [7:0]  msr = 8'hB0;  // DCD|DSR|CTS asserted (no real modem)

    // IIR: priority-encoded pending interrupt (bit0=1 -> none)
    wire rx_pending = ier[0] & dr;       // received data available
    wire tx_pending = ier[1] & txrdy;    // THR empty
    wire [7:0] iir = rx_pending ? 8'h04 :
                     tx_pending ? 8'h02 : 8'h01 | (fcr[0] ? 8'hC0 : 8'h00);

    assign rx_irq = rx_pending | tx_pending;   // single combined interrupt line
    assign tx_irq = 1'b0;

    // =========================================================================
    // TX state machine (8N1)
    // =========================================================================
    typedef enum logic [1:0] { TX_IDLE, TX_START, TX_DATA, TX_STOP } tx_state_t;
    tx_state_t   tx_state;
    logic [19:0] tx_cnt;
    logic [2:0]  tx_bit;
    logic [7:0]  tx_shift;
    logic [7:0]  thr;
    logic        tx_kick;       // pulse: THR written, start TX

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state <= TX_IDLE; tx_cnt <= '0; tx_bit <= '0;
            tx_shift <= 8'hFF; uart_tx <= 1'b1; txrdy <= 1'b1;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    uart_tx <= 1'b1;
                    if (tx_kick) begin
                        tx_shift <= thr; tx_cnt <= bit_clocks - 20'd1;
                        uart_tx <= 1'b0;              // start bit
                        txrdy <= 1'b0; tx_state <= TX_START;
                    end
                end
                TX_START: if (tx_cnt == 0) begin
                              tx_cnt <= bit_clocks - 20'd1; tx_bit <= 3'd0;
                              uart_tx <= tx_shift[0]; tx_shift <= {1'b1, tx_shift[7:1]};
                              tx_state <= TX_DATA;
                          end else tx_cnt <= tx_cnt - 20'd1;
                TX_DATA:  if (tx_cnt == 0) begin
                              tx_cnt <= bit_clocks - 20'd1;
                              if (tx_bit == 3'd7) begin
                                  uart_tx <= 1'b1; tx_state <= TX_STOP;
                              end else begin
                                  tx_bit <= tx_bit + 3'd1;
                                  uart_tx <= tx_shift[0]; tx_shift <= {1'b1, tx_shift[7:1]};
                              end
                          end else tx_cnt <= tx_cnt - 20'd1;
                TX_STOP:  if (tx_cnt == 0) begin
                              tx_state <= TX_IDLE; txrdy <= 1'b1;
                          end else tx_cnt <= tx_cnt - 20'd1;
                default:  tx_state <= TX_IDLE;
            endcase
        end
    end

    // =========================================================================
    // RX state machine (8N1, 16x oversample: sample at mid-bit)
    // =========================================================================
    logic rx_s0, rx_s1, rx_prev;
    typedef enum logic [1:0] { RX_IDLE, RX_START, RX_DATA, RX_STOP } rx_state_t;
    rx_state_t   rx_state;
    logic [19:0] rx_cnt;
    logic [2:0]  rx_bit;
    logic [7:0]  rx_shift;
    logic        rx_done;       // pulse: byte received this cycle
    logic        rx_stop_bit;   // stop-bit value sampled at the stop instant

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s0 <= 1'b1; rx_s1 <= 1'b1; rx_prev <= 1'b1;
            rx_state <= RX_IDLE; rx_cnt <= '0; rx_bit <= '0; rx_shift <= '0;
            rx_done <= 1'b0; rx_stop_bit <= 1'b1;
        end else begin
            rx_s0 <= uart_rx; rx_s1 <= rx_s0; rx_prev <= rx_s1;
            rx_done <= 1'b0;
            case (rx_state)
                RX_IDLE:  if (rx_prev && !rx_s1) begin
                              rx_cnt <= half_bit; rx_state <= RX_START;
                          end
                RX_START: if (rx_cnt == 0) begin
                              if (!rx_s1) begin
                                  rx_cnt <= bit_clocks - 20'd1; rx_bit <= 3'd0;
                                  rx_shift <= 8'd0; rx_state <= RX_DATA;
                              end else rx_state <= RX_IDLE;   // glitch
                          end else rx_cnt <= rx_cnt - 20'd1;
                RX_DATA:  if (rx_cnt == 0) begin
                              rx_cnt <= bit_clocks - 20'd1;
                              rx_shift <= {rx_s1, rx_shift[7:1]};
                              if (rx_bit == 3'd7) rx_state <= RX_STOP;
                              else                rx_bit <= rx_bit + 3'd1;
                          end else rx_cnt <= rx_cnt - 20'd1;
                RX_STOP:  if (rx_cnt == 0) begin
                              rx_done <= 1'b1; rx_stop_bit <= rx_s1;  // sample stop now
                              rx_state <= RX_IDLE;
                          end else rx_cnt <= rx_cnt - 20'd1;
                default:  rx_state <= RX_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Register read/write
    // =========================================================================
    wire [2:0] ridx = addr[4:2];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ier <= 8'd0; lcr <= 8'd0; mcr <= 8'd0; scr <= 8'd0; fcr <= 8'd0;
            divisor <= DEF_DIV;
            thr <= 8'd0; tx_kick <= 1'b0;
            dr <= 1'b0; fe <= 1'b0; rx_data_reg <= 8'd0;
        end else begin
            tx_kick <= 1'b0;

            // RX byte capture
            if (rx_done) begin
                rx_data_reg <= rx_shift;
                fe          <= !rx_stop_bit;   // stop bit must be 1 (sampled at stop)
                dr          <= 1'b1;
            end

            if (req && we) begin
                case (ridx)
                    3'd0: if (dlab) divisor[7:0]  <= wdata[7:0];
                          else begin thr <= wdata[7:0]; if (txrdy) tx_kick <= 1'b1; end
                    3'd1: if (dlab) divisor[15:8] <= wdata[7:0];
                          else ier <= wdata[7:0];
                    3'd2: fcr <= wdata[7:0];          // FIFO control (no real FIFO)
                    3'd3: lcr <= wdata[7:0];
                    3'd4: mcr <= wdata[7:0];
                    3'd7: scr <= wdata[7:0];
                    default: ;                         // LSR/MSR read-only
                endcase
            end else if (req && !we) begin
                // read side effects
                if (ridx == 3'd0 && !dlab) dr <= 1'b0;   // reading RBR clears DR
                if (ridx == 3'd5)          fe <= 1'b0;   // reading LSR clears FE
            end
        end
    end

    // Combinational read mux
    always_comb begin
        unique case (ridx)
            3'd0: rdata = dlab ? {24'd0, divisor[7:0]}  : {24'd0, rx_data_reg};
            3'd1: rdata = dlab ? {24'd0, divisor[15:8]} : {24'd0, ier};
            3'd2: rdata = {24'd0, iir};
            3'd3: rdata = {24'd0, lcr};
            3'd4: rdata = {24'd0, mcr};
            3'd5: rdata = {24'd0, lsr};
            3'd6: rdata = {24'd0, msr};
            3'd7: rdata = {24'd0, scr};
            default: rdata = 32'd0;
        endcase
    end

endmodule

`default_nettype wire
