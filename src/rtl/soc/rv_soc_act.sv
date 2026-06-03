// =============================================================================
// rv_soc_act.sv - SoC for Architecture Compliance Tests (ACT)
// =============================================================================
// rv_cpu + a single unified instruction/data memory (rv_unified_mem), no
// peripherals.  Used by the riscv-tests / riscof flow (tb_rv_act).  Keeps the
// monitoring signal names (core_dmem_*, dmem_rdata) and the u_umem instance the
// compliance testbenches reference hierarchically.
// =============================================================================
`default_nettype none

module rv_soc_act
    import rv_pkg::*;
#(
    parameter int          XLEN      = rv_pkg::XLEN,
    parameter int          UMEM_DEPTH = 524288,           // 2 MB (arch-test tohost/sig ~1.2 MB)
    parameter logic [63:0] RST_ADDR   = 64'h8000_0000,
    parameter              INIT_FILE  = ""
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

    // tb monitoring aliases (tohost detection in tb_rv_act / tb_rv_act_debug)
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
        .dmem_wait (1'b0),            // unified mem is zero-latency
        .dmem_va (core_dmem_va),
        .ptw_paddr (ptw_paddr), .ptw_req (ptw_req),
        .ptw_rdata (ptw_rdata), .ptw_ready (ptw_ready),
        .timer_irq (1'b0), .sw_irq (1'b0), .ext_irq (1'b0)
    );

    // ---- Unified memory (PTW has priority over the data port) ---------------
    logic [XLEN-1:0]   umem_d_addr, umem_d_wdata;
    logic [XLEN/8-1:0] umem_d_wstrb;
    logic              umem_d_req, umem_d_we;
    always_comb begin
        if (ptw_req) begin
            umem_d_addr = ptw_paddr; umem_d_wdata = '0; umem_d_wstrb = '0;
            umem_d_req  = 1'b1;      umem_d_we    = 1'b0;
        end else begin
            umem_d_addr = mmu_dmem_pa; umem_d_wdata = core_dmem_wdata;
            umem_d_wstrb = core_dmem_wstrb;
            umem_d_req  = mmu_dmem_req; umem_d_we = mmu_dmem_we;
        end
    end

    logic [XLEN-1:0] umem_d_rdata;
    logic            umem_d_ready;

    rv_unified_mem #(
        .XLEN (XLEN), .DEPTH (UMEM_DEPTH), .BASE_ADDR (64'h8000_0000), .INIT_FILE (INIT_FILE)
    ) u_umem (
        .clk (clk), .rst_n (rst_n),
        .i_addr (mmu_imem_pa), .i_req (mmu_imem_req),
        .i_rdata (imem_rdata), .i_ready (imem_ready),
        .d_addr (umem_d_addr), .d_wdata (umem_d_wdata), .d_wstrb (umem_d_wstrb),
        .d_req (umem_d_req), .d_we (umem_d_we),
        .d_rdata (umem_d_rdata), .d_ready (umem_d_ready)
    );

    assign ptw_rdata  = umem_d_rdata;
    assign ptw_ready  = ptw_req ? umem_d_ready : 1'b0;
    assign dmem_rdata = umem_d_rdata;
    assign dmem_ready = ptw_req ? 1'b0 : umem_d_ready;

    // No peripherals in ACT mode
    assign gpio_out = 4'h0;
    assign uart_tx  = 1'b1;

endmodule

`default_nettype wire
