// rv_soc.sv
// =============================================================================
// rv_soc.sv - RISC-V System on Chip Top Module
// =============================================================================
// Two build modes:
//   - Default (production) : rv_imem + rv_dmem + peripherals (Harvard)
//   - ACT_MODE (compliance) : rv_unified_mem only, no peripherals
// =============================================================================
`default_nettype none

module rv_soc
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN,
`ifdef AXI_MODE
    // AXI_MODE: data + PTW exposed as an AXI4 master (to external/PS DDR).
    // Instruction fetch uses an internal always-ready memory loaded from INIT_FILE
    // (instructions-in-DDR over AXI awaits the IF redirect-latch fix; see docs/axi_ddr.md).
    parameter int IMEM_DEPTH = 16384,                 // internal IF memory (32-bit words)
    parameter logic [63:0] RST_ADDR = 64'h8000_0000,
    parameter INIT_FILE = "",
    parameter int AXI_ID_WIDTH = 4,
`elsif ACT_MODE
    parameter int UMEM_DEPTH = 524288, // 2 MB (arch-test jal tests place tohost/sig ~1.2 MB)
    parameter logic [63:0] RST_ADDR = 64'h8000_0000, // ACT entry point
    parameter INIT_FILE = "",
`else
    parameter int IMEM_DEPTH = 4069,
    parameter int DMEM_DEPTH = 4096,
    parameter logic [63:0] RST_ADDR = 64'h0,
    parameter IMEM_FILE = "",
    parameter DMEM_FILE = "",
`endif
    parameter int CLK_FREQ = 125_000_000,
    parameter int BAUD_RATE = 115_200
)(
    input wire clk,
    input wire rst_n,

    input wire [3:0] gpio_in,
    output logic [3:0] gpio_out,

    input wire uart_rx,
    output logic uart_tx
`ifdef AXI_MODE
    ,
    // ---- AXI4 master: data + PTW path to external memory (PS DDR) ----------
    output logic [AXI_ID_WIDTH-1:0] m_axi_awid,
    output logic [XLEN-1:0]         m_axi_awaddr,
    output logic [7:0]              m_axi_awlen,
    output logic [2:0]              m_axi_awsize,
    output logic [1:0]              m_axi_awburst,
    output logic                    m_axi_awvalid,
    input  wire                     m_axi_awready,
    output logic [XLEN-1:0]         m_axi_wdata,
    output logic [XLEN/8-1:0]       m_axi_wstrb,
    output logic                    m_axi_wlast,
    output logic                    m_axi_wvalid,
    input  wire                     m_axi_wready,
    input  wire  [AXI_ID_WIDTH-1:0] m_axi_bid,
    input  wire  [1:0]              m_axi_bresp,
    input  wire                     m_axi_bvalid,
    output logic                    m_axi_bready,
    output logic [AXI_ID_WIDTH-1:0] m_axi_arid,
    output logic [XLEN-1:0]         m_axi_araddr,
    output logic [7:0]              m_axi_arlen,
    output logic [2:0]              m_axi_arsize,
    output logic [1:0]              m_axi_arburst,
    output logic                    m_axi_arvalid,
    input  wire                     m_axi_arready,
    input  wire  [AXI_ID_WIDTH-1:0] m_axi_rid,
    input  wire  [XLEN-1:0]         m_axi_rdata,
    input  wire  [1:0]              m_axi_rresp,
    input  wire                     m_axi_rlast,
    input  wire                     m_axi_rvalid,
    output logic                    m_axi_rready,

    // ---- AXI4 master: instruction fetch (read-only, 32-bit) ----------------
    // Full AXI master interface; the write channels are tied idle (READ_ONLY).
    output logic [AXI_ID_WIDTH-1:0] m_axi_if_awid,
    output logic [XLEN-1:0]         m_axi_if_awaddr,
    output logic [7:0]              m_axi_if_awlen,
    output logic [2:0]              m_axi_if_awsize,
    output logic [1:0]              m_axi_if_awburst,
    output logic                    m_axi_if_awvalid,
    input  wire                     m_axi_if_awready,
    output logic [31:0]             m_axi_if_wdata,
    output logic [3:0]              m_axi_if_wstrb,
    output logic                    m_axi_if_wlast,
    output logic                    m_axi_if_wvalid,
    input  wire                     m_axi_if_wready,
    input  wire  [AXI_ID_WIDTH-1:0] m_axi_if_bid,
    input  wire  [1:0]              m_axi_if_bresp,
    input  wire                     m_axi_if_bvalid,
    output logic                    m_axi_if_bready,
    output logic [AXI_ID_WIDTH-1:0] m_axi_if_arid,
    output logic [XLEN-1:0]         m_axi_if_araddr,
    output logic [7:0]              m_axi_if_arlen,
    output logic [2:0]              m_axi_if_arsize,
    output logic [1:0]              m_axi_if_arburst,
    output logic                    m_axi_if_arvalid,
    input  wire                     m_axi_if_arready,
    input  wire  [AXI_ID_WIDTH-1:0] m_axi_if_rid,
    input  wire  [31:0]             m_axi_if_rdata,
    input  wire  [1:0]              m_axi_if_rresp,
    input  wire                     m_axi_if_rlast,
    input  wire                     m_axi_if_rvalid,
    output logic                    m_axi_if_rready
`endif
);

    // =========================================================================
    // Common: Core <-> MMU buses
    // =========================================================================
    logic [XLEN-1:0] core_imem_va;
    logic core_imem_req;
    logic [XLEN-1:0] core_dmem_va;
    logic [XLEN-1:0] core_dmem_wdata;
    logic [XLEN/8-1:0] core_dmem_wstrb;
    logic core_dmem_req;
    logic core_dmem_we;

    logic [XLEN-1:0] mmu_imem_pa;
    logic mmu_imem_req;
    logic [XLEN-1:0] mmu_dmem_pa;
    logic mmu_dmem_req;
    logic mmu_dmem_we;

    logic [XLEN-1:0] ptw_paddr;
    logic ptw_req;
    logic [XLEN-1:0] ptw_rdata;
    logic ptw_ready;

    logic [31:0] imem_rdata;
    logic imem_ready;
    logic [XLEN-1:0] dmem_rdata;
    logic dmem_ready;

    logic [XLEN-1:0] satp_out;
    priv_level_t priv_out;
    logic mstatus_sum_out;
    logic mstatus_mxr_out;
    logic tlb_flush_out;
    logic mmu_stall;
    logic mem_stall;
    logic if_fault_mmu;
    logic mem_fault_mmu;
    logic mstatus_mprv_out;
    logic [1:0] mstatus_mpp_out_sig;

    logic timer_irq_sig;
    logic [1:0] plic_ext_irq;
    logic gpio_irq;

    // Data-port wait into the core (variable-latency memory).  Zero for the
    // BRAM/unified-mem paths; driven by the AXI bridge in AXI_MODE.
    logic core_dmem_wait;

    // =========================================================================
    // CPU Core (common to both modes)
    // =========================================================================
    rv_core #(
        .XLEN (XLEN),
        .RST_ADDR (RST_ADDR)
    ) u_core (
        .clk (clk),
        .rst_n (rst_n),
        .imem_addr (core_imem_va),
        .imem_req (core_imem_req),
        .imem_rdata (imem_rdata),
        .imem_ready (imem_ready),
        .dmem_addr (core_dmem_va),
        .dmem_wdata (core_dmem_wdata),
        .dmem_wstrb (core_dmem_wstrb),
        .dmem_req (core_dmem_req),
        .dmem_we (core_dmem_we),
        .dmem_rdata (dmem_rdata),
        .dmem_ready (dmem_ready),
        .satp_out (satp_out),
        .priv_out (priv_out),
        .mstatus_sum_out  (mstatus_sum_out),
        .mstatus_mxr_out  (mstatus_mxr_out),
        .mstatus_mprv_out (mstatus_mprv_out),
        .mstatus_mpp_out  (mstatus_mpp_out_sig),
        .tlb_flush_out (tlb_flush_out),
        .mmu_stall (mmu_stall),
        .mem_stall (mem_stall),
        .dmem_wait (core_dmem_wait),
        .if_fault  (if_fault_mmu),
        .mem_fault (mem_fault_mmu),
`ifdef AXI_MODE
        .timer_irq (1'b0),
        .sw_irq (1'b0),
        .ext_irq (1'b0)
`elsif ACT_MODE
        .timer_irq (1'b0),
        .sw_irq (1'b0),
        .ext_irq (1'b0)
`else
        .timer_irq (timer_irq_sig),
        .sw_irq (1'b0),
        .ext_irq (plic_ext_irq[0])
`endif
    );

    // =========================================================================
    // MMU (common to both modes)
    // =========================================================================
    rv_mmu #(
        .XLEN (XLEN),
        .TLB_ENTRIES (16)
    ) u_mmu (
        .clk (clk),
        .rst_n (rst_n),
        .satp (satp_out),
        .priv_level (priv_out),
        .mstatus_sum  (mstatus_sum_out),
        .mstatus_mxr  (mstatus_mxr_out),
        .mstatus_mprv (mstatus_mprv_out),
        .mstatus_mpp  (mstatus_mpp_out_sig),
        .tlb_flush (tlb_flush_out),
        .if_va (core_imem_va),
        .if_req (core_imem_req),
        .if_pa (mmu_imem_pa),
        .if_req_out (mmu_imem_req),
        .if_fault (if_fault_mmu),
        .mem_va (core_dmem_va),
        .mem_req (core_dmem_req),
        .mem_we (core_dmem_we),
        .mem_pa (mmu_dmem_pa),
        .mem_req_out (mmu_dmem_req),
        .mem_we_out (mmu_dmem_we),
        .mem_fault (mem_fault_mmu),
        .mmu_stall (mmu_stall),
        .mem_stall (mem_stall),
        .ptw_paddr (ptw_paddr),
        .ptw_req (ptw_req),
        .ptw_rdata (ptw_rdata),
        .ptw_ready (ptw_ready)
    );

`ifdef AXI_MODE
    // =========================================================================
    // AXI_MODE: instruction fetch AND data + PTW each through an AXI4 master
    // (external/PS DDR).  Two masters (IF read-only 32-bit, data read/write
    // XLEN); on hardware both fan into an AXI SmartConnect -> S_AXI_HP -> DDR.
    // =========================================================================
    // --- Instruction fetch AXI master (read-only, 32-bit) ---
    logic if_axi_busy, if_axi_wait;
    rv_axi_bridge #(
        .ADDR_WIDTH (XLEN),
        .DATA_WIDTH (32),
        .ID_WIDTH   (AXI_ID_WIDTH),
        .READ_ONLY  (1'b1)
    ) u_axi_if (
        .clk (clk), .rst_n (rst_n),
        .s_req (mmu_imem_req), .s_we (1'b0), .s_addr (mmu_imem_pa),
        .s_wdata (32'b0), .s_wstrb (4'b0),
        .s_rdata (imem_rdata), .s_ready (imem_ready),
        .s_busy (if_axi_busy), .s_wait (if_axi_wait),
        .m_axi_awid (m_axi_if_awid), .m_axi_awaddr (m_axi_if_awaddr),
        .m_axi_awlen (m_axi_if_awlen), .m_axi_awsize (m_axi_if_awsize),
        .m_axi_awburst (m_axi_if_awburst), .m_axi_awvalid (m_axi_if_awvalid),
        .m_axi_awready (m_axi_if_awready),
        .m_axi_wdata (m_axi_if_wdata), .m_axi_wstrb (m_axi_if_wstrb),
        .m_axi_wlast (m_axi_if_wlast), .m_axi_wvalid (m_axi_if_wvalid),
        .m_axi_wready (m_axi_if_wready),
        .m_axi_bid (m_axi_if_bid), .m_axi_bresp (m_axi_if_bresp),
        .m_axi_bvalid (m_axi_if_bvalid), .m_axi_bready (m_axi_if_bready),
        .m_axi_arid (m_axi_if_arid), .m_axi_araddr (m_axi_if_araddr),
        .m_axi_arlen (m_axi_if_arlen), .m_axi_arsize (m_axi_if_arsize),
        .m_axi_arburst (m_axi_if_arburst), .m_axi_arvalid (m_axi_if_arvalid),
        .m_axi_arready (m_axi_if_arready),
        .m_axi_rid (m_axi_if_rid), .m_axi_rdata (m_axi_if_rdata),
        .m_axi_rresp (m_axi_if_rresp), .m_axi_rlast (m_axi_if_rlast),
        .m_axi_rvalid (m_axi_if_rvalid), .m_axi_rready (m_axi_if_rready)
    );

    // --- Data + PTW arbitration into one simple bus (PTW has priority) ---
    logic [XLEN-1:0]    axi_d_addr;
    logic [XLEN-1:0]    axi_d_wdata;
    logic [XLEN/8-1:0]  axi_d_wstrb;
    logic               axi_d_req;
    logic               axi_d_we;

    always_comb begin
        if (ptw_req) begin
            axi_d_addr  = ptw_paddr;
            axi_d_wdata = '0;
            axi_d_wstrb = '0;
            axi_d_req   = 1'b1;
            axi_d_we    = 1'b0;
        end else begin
            axi_d_addr  = mmu_dmem_pa;
            axi_d_wdata = core_dmem_wdata;
            axi_d_wstrb = core_dmem_wstrb;
            axi_d_req   = mmu_dmem_req;
            axi_d_we    = mmu_dmem_we;
        end
    end

    logic [XLEN-1:0] axi_s_rdata;
    logic            axi_s_ready;
    logic            axi_s_busy;
    logic            axi_s_wait;

    rv_axi_bridge #(
        .ADDR_WIDTH (XLEN),
        .DATA_WIDTH (XLEN),
        .ID_WIDTH   (AXI_ID_WIDTH),
        .READ_ONLY  (1'b0)
    ) u_axi_data (
        .clk (clk), .rst_n (rst_n),
        .s_req (axi_d_req), .s_we (axi_d_we), .s_addr (axi_d_addr),
        .s_wdata (axi_d_wdata), .s_wstrb (axi_d_wstrb),
        .s_rdata (axi_s_rdata), .s_ready (axi_s_ready),
        .s_busy (axi_s_busy), .s_wait (axi_s_wait),
        .m_axi_awid (m_axi_awid), .m_axi_awaddr (m_axi_awaddr),
        .m_axi_awlen (m_axi_awlen), .m_axi_awsize (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst), .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),
        .m_axi_wdata (m_axi_wdata), .m_axi_wstrb (m_axi_wstrb),
        .m_axi_wlast (m_axi_wlast), .m_axi_wvalid (m_axi_wvalid),
        .m_axi_wready (m_axi_wready),
        .m_axi_bid (m_axi_bid), .m_axi_bresp (m_axi_bresp),
        .m_axi_bvalid (m_axi_bvalid), .m_axi_bready (m_axi_bready),
        .m_axi_arid (m_axi_arid), .m_axi_araddr (m_axi_araddr),
        .m_axi_arlen (m_axi_arlen), .m_axi_arsize (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst), .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),
        .m_axi_rid (m_axi_rid), .m_axi_rdata (m_axi_rdata),
        .m_axi_rresp (m_axi_rresp), .m_axi_rlast (m_axi_rlast),
        .m_axi_rvalid (m_axi_rvalid), .m_axi_rready (m_axi_rready)
    );

    // Return paths.  dmem_wait holds the data access; PTW uses ptw_ready (the
    // MMU's PTW FSM handles its own multi-cycle wait), so dmem_wait is only the
    // data path (suppressed while a PTW transaction occupies the bridge -- the
    // pending data access is held by mem_stall in that window).
    assign core_dmem_wait = ptw_req ? 1'b0 : axi_s_wait;
    assign dmem_rdata     = axi_s_rdata;
    assign dmem_ready     = ptw_req ? 1'b0 : axi_s_ready;
    assign ptw_rdata      = axi_s_rdata;
    assign ptw_ready      = ptw_req ? axi_s_ready : 1'b0;

    // No peripherals in AXI_MODE
    assign gpio_out = 4'h0;
    assign uart_tx  = 1'b1;

`elsif ACT_MODE
    // =========================================================================
    // ACT_MODE: Unified memory at 0x80000000, no peripherals
    // =========================================================================
    // PTW arbitration: PTW has priority over data port
    logic [XLEN-1:0] umem_d_addr;
    logic [XLEN-1:0] umem_d_wdata;
    logic [XLEN/8-1:0] umem_d_wstrb;
    logic umem_d_req;
    logic umem_d_we;

    always_comb begin
        if (ptw_req) begin
            umem_d_addr = ptw_paddr;
            umem_d_wdata = '0;
            umem_d_wstrb = '0;
            umem_d_req = 1'b1;
            umem_d_we = 1'b0;
        end else begin
            umem_d_addr = mmu_dmem_pa;
            umem_d_wdata = core_dmem_wdata;
            umem_d_wstrb = core_dmem_wstrb;
            umem_d_req = mmu_dmem_req;
            umem_d_we = mmu_dmem_we;
        end
    end

    logic [XLEN-1:0] umem_d_rdata;
    logic umem_d_ready;

    rv_unified_mem #(
        .XLEN      (XLEN),
        .DEPTH     (UMEM_DEPTH),
        .BASE_ADDR (64'h8000_0000),
        .INIT_FILE (INIT_FILE)
    ) u_umem (
        .clk     (clk),
        .rst_n   (rst_n),
        .i_addr  (mmu_imem_pa),
        .i_req   (mmu_imem_req),
        .i_rdata (imem_rdata),
        .i_ready (imem_ready),
        .d_addr  (umem_d_addr),
        .d_wdata (umem_d_wdata),
        .d_wstrb (umem_d_wstrb),
        .d_req   (umem_d_req),
        .d_we    (umem_d_we),
        .d_rdata (umem_d_rdata),
        .d_ready (umem_d_ready)
    );

    // PTW return path
    assign ptw_rdata = umem_d_rdata;
    assign ptw_ready = ptw_req ? umem_d_ready : 1'b0;

    // Data return path (no peripherals in ACT mode)
    assign dmem_rdata = umem_d_rdata;
    assign dmem_ready = ptw_req ? 1'b0 : umem_d_ready;

    // Tie off unused outputs
    assign gpio_out = 4'h0;
    assign uart_tx = 1'b1;
    assign core_dmem_wait = 1'b0;   // unified mem is zero-latency

`else
    // =========================================================================
    // Production mode: Existing IMEM + DMEM + Peripherals (unchanged)
    // =========================================================================
    assign core_dmem_wait = 1'b0;   // BRAM path is zero-latency
    rv_imem #(
        .XLEN (XLEN),
        .DEPTH (IMEM_DEPTH),
        .INIT_FILE (IMEM_FILE)
    ) u_imem (
        .clk (clk),
        .rst_n (rst_n),
        .addr (mmu_imem_pa),
        .req (mmu_imem_req),
        .rdata (imem_rdata),
        .ready (imem_ready)
    );

    // --- (以下、既存の DMEM + 周辺機器ロジックそのまま温存) ---
    logic [XLEN-1:0] dmem_addr_arb;
    logic [XLEN-1:0] dmem_wdata_arb;
    logic [XLEN/8-1:0] dmem_wstrb_arb;
    logic dmem_req_arb;
    logic dmem_we_arb;

    logic is_timer_access;
    logic is_uart_access;
    logic is_plic_access;
    logic is_dmem_access;
    logic is_gpio_access;

    logic [31:0] timer_rdata;
    logic [31:0] uart_rdata;
    logic [31:0] plic_rdata;
    logic [31:0] gpio_rdata;
    logic [XLEN-1:0] dmem_rdata_mem;
    logic dmem_ready_mem;

    always_comb begin
        is_timer_access = (mmu_dmem_pa[31:16] == 16'hC000);
        is_uart_access  = (mmu_dmem_pa[31:16] == 16'hC001);
        is_gpio_access  = (mmu_dmem_pa[31:16] == 16'hC002);
        is_plic_access  = (mmu_dmem_pa[31:16] == 16'hC010);
        is_dmem_access  = ~is_timer_access & ~is_uart_access
                        & ~is_gpio_access  & ~is_plic_access;
    end

    always_comb begin
        if (ptw_req) begin
            dmem_addr_arb  = ptw_paddr;
            dmem_wdata_arb = '0;
            dmem_wstrb_arb = '0;
            dmem_req_arb   = 1'b1;
            dmem_we_arb    = 1'b0;
        end else begin
            dmem_addr_arb  = mmu_dmem_pa;
            dmem_wdata_arb = core_dmem_wdata;
            dmem_wstrb_arb = core_dmem_wstrb;
            dmem_req_arb   = mmu_dmem_req & is_dmem_access;
            dmem_we_arb    = mmu_dmem_we & is_dmem_access;
        end
    end

    assign ptw_rdata = dmem_rdata_mem;
    assign ptw_ready = ptw_req ? dmem_ready_mem : 1'b0;

    logic [XLEN-1:0] periph_rdata_reg;
    logic prev_periph_read;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            periph_rdata_reg <= '0;
            prev_periph_read <= 1'b0;
        end else begin
            if (is_timer_access)
                periph_rdata_reg <= {{(XLEN-32){1'b0}}, timer_rdata};
            else if (is_uart_access)
                periph_rdata_reg <= {{(XLEN-32){1'b0}}, uart_rdata};
            else if (is_gpio_access)
                periph_rdata_reg <= {{(XLEN-32){1'b0}}, gpio_rdata};
            else if (is_plic_access)
                periph_rdata_reg <= {{(XLEN-32){1'b0}}, plic_rdata};

            prev_periph_read <= mmu_dmem_req & ~mmu_dmem_we
                             & (is_timer_access | is_uart_access
                             | is_gpio_access  | is_plic_access);
        end
    end

    always_comb begin
        if (prev_periph_read) begin
            dmem_rdata = periph_rdata_reg;
            dmem_ready = 1'b1;
        end else begin
            dmem_rdata = dmem_rdata_mem;
            dmem_ready = dmem_ready_mem;
        end
    end

    rv_dmem #(
        .XLEN (XLEN),
        .DEPTH (DMEM_DEPTH),
        .INIT_FILE (DMEM_FILE)
    ) u_dmem (
        .clk (clk),
        .rst_n (rst_n),
        .addr (dmem_addr_arb),
        .wdata (dmem_wdata_arb),
        .wstrb (dmem_wstrb_arb),
        .req (dmem_req_arb),
        .we (dmem_we_arb),
        .rdata (dmem_rdata_mem),
        .ready (dmem_ready_mem)
    );

    rv_timer u_timer (
        .clk (clk),
        .rst_n (rst_n),
        .addr (mmu_dmem_pa[3:0]),
        .req (mmu_dmem_req & is_timer_access),
        .we (mmu_dmem_we & is_timer_access),
        .wdata (core_dmem_wdata[31:0]),
        .rdata (timer_rdata),
        .timer_irq (timer_irq_sig)
    );

    logic uart_tx_sig;
    logic uart_tx_irq;
    logic uart_rx_irq;

    rv_uart #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_uart (
        .clk (clk),
        .rst_n (rst_n),
        .addr (mmu_dmem_pa[3:0]),
        .req (mmu_dmem_req & is_uart_access),
        .we (mmu_dmem_we & is_uart_access),
        .wdata (core_dmem_wdata[31:0]),
        .rdata (uart_rdata),
        .uart_tx (uart_tx_sig),
        .uart_rx (uart_rx),
        .tx_irq (uart_tx_irq),
        .rx_irq (uart_rx_irq)
    );

    rv_plic #(
        .NSRC (8),
        .NCTX (2),
        .PRIO_BITS (3)
    ) u_plic (
        .clk (clk),
        .rst_n (rst_n),
        .addr (mmu_dmem_pa[11:0]),
        .req (mmu_dmem_req & is_plic_access),
        .we (mmu_dmem_we & is_plic_access),
        .wdata (core_dmem_wdata[31:0]),
        .rdata (plic_rdata),
        .src_irq ({5'b0, gpio_irq, uart_tx_irq, uart_rx_irq}),
        .ext_irq (plic_ext_irq)
    );

    rv_gpio #(.WIDTH(4)) u_gpio (
        .clk (clk),
        .rst_n (rst_n),
        .addr (mmu_dmem_pa[3:0]),
        .req (mmu_dmem_req & is_gpio_access),
        .we (mmu_dmem_we & is_gpio_access),
        .wdata (core_dmem_wdata[31:0]),
        .rdata (gpio_rdata),
        .gpio_in (gpio_in),
        .gpio_out (gpio_out),
        .irq (gpio_irq)
    );

    assign uart_tx = uart_tx_sig;
`endif // ACT_MODE
endmodule

`default_nettype wire
