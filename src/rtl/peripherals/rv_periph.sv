// =============================================================================
/// @file rv_periph.sv
/// @brief Memory-mapped peripheral subsystem (CLINT timer, UART, PLIC, GPIO).
///
/// Shared by every SoC wrapper that carries peripherals (rv_soc = AXI/DDR,
/// rv_soc_bram = Harvard).  Presents a simple synchronous slave on the core's
/// physical data bus.  Address decode (peripheral region 0xC0xx) and the
/// 1-cycle registered read path live here so the wrappers only have to:
///   - route a data access here when @c is_periph, and to memory otherwise,
///   - select @c rdata when @c rdata_valid (a peripheral read result this cycle).
///
/// Memory map (matches the SoC docs):
///   CLINT 0xC000_xxxx, UART 0xC001_xxxx, GPIO 0xC002_xxxx, PLIC 0xC010_xxxx.
///
/// @param XLEN      Data path width.
/// @param CLK_FREQ  Core clock (for UART baud divisor).
/// @param BAUD_RATE UART baud rate.
// =============================================================================

`default_nettype none

module rv_periph
    import rv_pkg::*;
#(
    parameter int XLEN      = rv_pkg::XLEN,
    parameter int CLK_FREQ  = 125_000_000,
    parameter int BAUD_RATE = 115_200
) (
    input  wire              clk,
    input  wire              rst_n,

    // ---- Simple-bus slave (physical data address from the MMU) --------------
    input  wire  [XLEN-1:0]  addr,    // = mmu_dmem_pa
    input  wire  [XLEN-1:0]  wdata,   // = core_dmem_wdata
    input  wire              req,     // = mmu_dmem_req
    input  wire              we,      // = mmu_dmem_we
    output logic             is_periph,   // combinational: addr targets a peripheral
    output logic [XLEN-1:0]  rdata,       // registered read data (valid when rdata_valid)
    output logic             rdata_valid, // a peripheral READ result is on rdata this cycle

    // ---- Interrupts ----------------------------------------------------------
    output logic             timer_irq,
    output logic [1:0]       ext_irq,     // PLIC contexts
    output logic [63:0]      mtime,       // CLINT mtime (for the core's 'time' CSR)

    // ---- I/O -----------------------------------------------------------------
    input  wire  [3:0]       gpio_in,
    output logic [3:0]       gpio_out,
    input  wire              uart_rx,
    output logic             uart_tx
);

    // ---- Address decode ------------------------------------------------------
    logic is_timer_access, is_uart_access, is_gpio_access, is_plic_access;
    always_comb begin
        is_timer_access = (addr[31:16] == 16'hC000);
        is_uart_access  = (addr[31:16] == 16'hC001);
        is_gpio_access  = (addr[31:16] == 16'hC002);
        is_plic_access  = (addr[31:16] == 16'hC010);
        is_periph       = is_timer_access | is_uart_access
                        | is_gpio_access  | is_plic_access;
    end

    logic [31:0] timer_rdata, uart_rdata, plic_rdata, gpio_rdata;
    logic        uart_tx_irq, uart_rx_irq, gpio_irq;

    // ---- 1-cycle registered read path (BRAM-like latency) -------------------
    logic [XLEN-1:0] periph_rdata_reg;
    logic            prev_periph_read;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            periph_rdata_reg <= '0;
            prev_periph_read <= 1'b0;
        end else begin
            if (is_timer_access)      periph_rdata_reg <= {{(XLEN-32){1'b0}}, timer_rdata};
            else if (is_uart_access)  periph_rdata_reg <= {{(XLEN-32){1'b0}}, uart_rdata};
            else if (is_gpio_access)  periph_rdata_reg <= {{(XLEN-32){1'b0}}, gpio_rdata};
            else if (is_plic_access)  periph_rdata_reg <= {{(XLEN-32){1'b0}}, plic_rdata};
            prev_periph_read <= req & ~we & is_periph;
        end
    end
    assign rdata       = periph_rdata_reg;
    assign rdata_valid = prev_periph_read;

    // ---- Peripherals ---------------------------------------------------------
    rv_timer u_timer (
        .clk (clk), .rst_n (rst_n),
        .addr (addr[3:0]),
        .req  (req & is_timer_access),
        .we   (we  & is_timer_access),
        .wdata (wdata[31:0]),
        .rdata (timer_rdata),
        .timer_irq (timer_irq),
        .mtime_o (mtime)
    );

    rv_uart #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_uart (
        .clk (clk), .rst_n (rst_n),
        .addr (addr[3:0]),
        .req  (req & is_uart_access),
        .we   (we  & is_uart_access),
        .wdata (wdata[31:0]),
        .rdata (uart_rdata),
        .uart_tx (uart_tx),
        .uart_rx (uart_rx),
        .tx_irq (uart_tx_irq),
        .rx_irq (uart_rx_irq)
    );

    rv_plic #(
        .NSRC (8), .NCTX (2), .PRIO_BITS (3)
    ) u_plic (
        .clk (clk), .rst_n (rst_n),
        .addr (addr[11:0]),
        .req  (req & is_plic_access),
        .we   (we  & is_plic_access),
        .wdata (wdata[31:0]),
        .rdata (plic_rdata),
        .src_irq ({5'b0, gpio_irq, uart_tx_irq, uart_rx_irq}),
        .ext_irq (ext_irq)
    );

    rv_gpio #(.WIDTH(4)) u_gpio (
        .clk (clk), .rst_n (rst_n),
        .addr (addr[3:0]),
        .req  (req & is_gpio_access),
        .we   (we  & is_gpio_access),
        .wdata (wdata[31:0]),
        .rdata (gpio_rdata),
        .gpio_in (gpio_in),
        .gpio_out (gpio_out),
        .irq (gpio_irq)
    );

endmodule

`default_nettype wire
