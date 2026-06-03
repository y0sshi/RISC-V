// =============================================================================
// rv_soc_bram.sv - SoC with on-chip BRAM (Harvard) + peripherals
// =============================================================================
// Self-contained SoC: rv_cpu + instruction BRAM (rv_imem) + data BRAM (rv_dmem)
// + peripheral subsystem (rv_periph: CLINT/UART/PLIC/GPIO).  Targets small /
// PS-less FPGA bring-up where the whole program + data fit on-chip.  For the
// DDR-backed (AXI) configuration see rv_soc.sv.
// =============================================================================
`default_nettype none

module rv_soc_bram
    import rv_pkg::*;
#(
    parameter int          XLEN       = rv_pkg::XLEN,
    parameter int          IMEM_DEPTH = 4096,
    parameter int          DMEM_DEPTH = 4096,
    parameter logic [63:0] RST_ADDR   = 64'h0,
    parameter              IMEM_FILE  = "",
    parameter              DMEM_FILE  = "",
    parameter int          CLK_FREQ   = 125_000_000,
    parameter int          BAUD_RATE  = 115_200
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire  [3:0] gpio_in,
    output logic [3:0] gpio_out,
    input  wire        uart_rx,
    output logic       uart_tx
);

    // ---- CPU complex + physical-address memory interface --------------------
    logic [XLEN-1:0]   mmu_imem_pa;  logic mmu_imem_req;
    logic [XLEN-1:0]   mmu_dmem_pa;  logic mmu_dmem_req, mmu_dmem_we;
    logic [XLEN-1:0]   core_dmem_wdata;  logic [XLEN/8-1:0] core_dmem_wstrb;
    logic [XLEN-1:0]   core_dmem_va;
    logic [XLEN-1:0]   ptw_paddr;    logic ptw_req;
    logic [XLEN-1:0]   ptw_rdata;    logic ptw_ready;
    logic [31:0]       imem_rdata;   logic imem_ready;
    logic [XLEN-1:0]   dmem_rdata;   logic dmem_ready;
    logic              timer_irq_sig; logic [1:0] plic_ext_irq;

    // tb monitoring aliases
    logic core_dmem_req, core_dmem_we;
    assign core_dmem_req = mmu_dmem_req;
    assign core_dmem_we  = mmu_dmem_we;

    rv_cpu #(.XLEN (XLEN), .RST_ADDR (RST_ADDR)) u_cpu (
        .clk (clk), .rst_n (rst_n),
        .imem_addr (mmu_imem_pa), .imem_req (mmu_imem_req),
        .imem_rdata (imem_rdata), .imem_ready (imem_ready),
        .dmem_addr (mmu_dmem_pa), .dmem_wdata (core_dmem_wdata),
        .dmem_wstrb (core_dmem_wstrb), .dmem_req (mmu_dmem_req), .dmem_we (mmu_dmem_we),
        .dmem_rdata (dmem_rdata), .dmem_ready (dmem_ready),
        .dmem_wait (1'b0),            // BRAM is zero-latency
        .dmem_va (core_dmem_va),
        .ptw_paddr (ptw_paddr), .ptw_req (ptw_req),
        .ptw_rdata (ptw_rdata), .ptw_ready (ptw_ready),
        .timer_irq (timer_irq_sig), .sw_irq (1'b0), .ext_irq (plic_ext_irq[0])
    );

    // ---- Instruction BRAM ---------------------------------------------------
    rv_imem #(.XLEN (XLEN), .DEPTH (IMEM_DEPTH), .INIT_FILE (IMEM_FILE)) u_imem (
        .clk (clk), .rst_n (rst_n),
        .addr (mmu_imem_pa), .req (mmu_imem_req),
        .rdata (imem_rdata), .ready (imem_ready)
    );

    // ---- Peripheral subsystem -----------------------------------------------
    logic            periph_is_periph;
    logic [XLEN-1:0] periph_rdata;
    logic            periph_rdata_valid;
    logic            uart_tx_sig;

    rv_periph #(.XLEN (XLEN), .CLK_FREQ (CLK_FREQ), .BAUD_RATE (BAUD_RATE)) u_periph (
        .clk (clk), .rst_n (rst_n),
        .addr (mmu_dmem_pa), .wdata (core_dmem_wdata),
        .req (mmu_dmem_req), .we (mmu_dmem_we),
        .is_periph (periph_is_periph), .rdata (periph_rdata), .rdata_valid (periph_rdata_valid),
        .timer_irq (timer_irq_sig), .ext_irq (plic_ext_irq),
        .gpio_in (gpio_in), .gpio_out (gpio_out),
        .uart_rx (uart_rx), .uart_tx (uart_tx_sig)
    );
    assign uart_tx = uart_tx_sig;

    // ---- Data BRAM (non-peripheral) + PTW (PTW priority) --------------------
    logic [XLEN-1:0]   dmem_addr_arb, dmem_wdata_arb;
    logic [XLEN/8-1:0] dmem_wstrb_arb;
    logic              dmem_req_arb, dmem_we_arb;
    logic [XLEN-1:0]   dmem_rdata_mem;
    logic              dmem_ready_mem;

    always_comb begin
        if (ptw_req) begin
            dmem_addr_arb  = ptw_paddr;  dmem_wdata_arb = '0; dmem_wstrb_arb = '0;
            dmem_req_arb   = 1'b1;       dmem_we_arb    = 1'b0;
        end else begin
            dmem_addr_arb  = mmu_dmem_pa;  dmem_wdata_arb = core_dmem_wdata;
            dmem_wstrb_arb = core_dmem_wstrb;
            dmem_req_arb   = mmu_dmem_req & ~periph_is_periph;
            dmem_we_arb    = mmu_dmem_we  & ~periph_is_periph;
        end
    end

    assign ptw_rdata = dmem_rdata_mem;
    assign ptw_ready = ptw_req ? dmem_ready_mem : 1'b0;

    always_comb begin
        if (periph_rdata_valid) begin dmem_rdata = periph_rdata;   dmem_ready = 1'b1; end
        else                    begin dmem_rdata = dmem_rdata_mem; dmem_ready = dmem_ready_mem; end
    end

    rv_dmem #(.XLEN (XLEN), .DEPTH (DMEM_DEPTH), .INIT_FILE (DMEM_FILE)) u_dmem (
        .clk (clk), .rst_n (rst_n),
        .addr (dmem_addr_arb), .wdata (dmem_wdata_arb), .wstrb (dmem_wstrb_arb),
        .req (dmem_req_arb), .we (dmem_we_arb),
        .rdata (dmem_rdata_mem), .ready (dmem_ready_mem)
    );

endmodule

`default_nettype wire
