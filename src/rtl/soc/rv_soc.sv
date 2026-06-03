// =============================================================================
// rv_soc.sv - RISC-V SoC (default / real hardware): DDR over AXI4 + peripherals
// =============================================================================
// rv_cpu + two AXI4 masters to external memory (instruction fetch read-only
// 32-bit; data + page-table-walk read/write XLEN) + on-chip peripheral
// subsystem (rv_periph: CLINT/UART/PLIC/GPIO).  On a Zynq board both masters
// fan into an AXI SmartConnect -> S_AXI_HP -> PS DDR (see boards/*/vivado).
// Peripheral region (0xC0xx_xxxx) is served locally; everything else (DDR) goes
// out the data AXI master.
//
// Other build configurations:
//   rv_soc_bram.sv - on-chip BRAM (Harvard) + peripherals (PS-less bring-up)
//   rv_soc_act.sv  - unified memory, no peripherals (compliance/ACT)
// =============================================================================
`default_nettype none

module rv_soc
    import rv_pkg::*;
#(
    parameter int          XLEN         = rv_pkg::XLEN,
    parameter logic [63:0] RST_ADDR     = 64'h8000_0000,
    parameter int          AXI_ID_WIDTH = 4,
    parameter int          CLK_FREQ     = 125_000_000,
    parameter int          BAUD_RATE    = 115_200
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire  [3:0] gpio_in,
    output logic [3:0] gpio_out,
    input  wire        uart_rx,
    output logic       uart_tx,

    // ---- AXI4 master: data + PTW (read/write, XLEN) -> PS DDR ---------------
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

    // ---- AXI4 master: instruction fetch (read-only, 32-bit) -> PS DDR -------
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
    logic              core_dmem_wait;
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
        .dmem_wait (core_dmem_wait),
        .dmem_va (core_dmem_va),
        .ptw_paddr (ptw_paddr), .ptw_req (ptw_req),
        .ptw_rdata (ptw_rdata), .ptw_ready (ptw_ready),
        .timer_irq (timer_irq_sig), .sw_irq (1'b0), .ext_irq (plic_ext_irq[0])
    );

    // ---- Instruction fetch AXI master (read-only, 32-bit) -------------------
    logic if_axi_busy, if_axi_wait;
    rv_axi_bridge #(.ADDR_WIDTH (XLEN), .DATA_WIDTH (32),
                    .ID_WIDTH (AXI_ID_WIDTH), .READ_ONLY (1'b1)) u_axi_if (
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

    // ---- Peripheral subsystem (served locally) ------------------------------
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

    // ---- Data + PTW arbitration to the DDR AXI master (PTW priority;
    //      peripheral accesses are served locally and excluded) ---------------
    logic [XLEN-1:0]   axi_d_addr, axi_d_wdata;
    logic [XLEN/8-1:0] axi_d_wstrb;
    logic              axi_d_req, axi_d_we;
    always_comb begin
        if (ptw_req) begin
            axi_d_addr = ptw_paddr; axi_d_wdata = '0; axi_d_wstrb = '0;
            axi_d_req  = 1'b1;      axi_d_we    = 1'b0;
        end else begin
            axi_d_addr = mmu_dmem_pa; axi_d_wdata = core_dmem_wdata; axi_d_wstrb = core_dmem_wstrb;
            axi_d_req  = mmu_dmem_req & ~periph_is_periph;
            axi_d_we   = mmu_dmem_we  & ~periph_is_periph;
        end
    end

    logic [XLEN-1:0] axi_s_rdata; logic axi_s_ready, axi_s_busy, axi_s_wait;
    rv_axi_bridge #(.ADDR_WIDTH (XLEN), .DATA_WIDTH (XLEN),
                    .ID_WIDTH (AXI_ID_WIDTH), .READ_ONLY (1'b0)) u_axi_data (
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

    // ---- Return paths -------------------------------------------------------
    // PTW + DDR data go through the AXI master.  A peripheral access keeps the
    // AXI bridge idle (axi_d_req=0 -> axi_s_wait=0) so the core does not stall
    // and the peripheral 1-cycle registered read is selected next cycle.
    assign core_dmem_wait = ptw_req ? 1'b0 : axi_s_wait;
    assign ptw_rdata      = axi_s_rdata;
    assign ptw_ready      = ptw_req ? axi_s_ready : 1'b0;

    always_comb begin
        if (periph_rdata_valid) begin
            dmem_rdata = periph_rdata;
            dmem_ready = 1'b1;
        end else begin
            dmem_rdata = axi_s_rdata;
            dmem_ready = ptw_req ? 1'b0 : axi_s_ready;
        end
    end

endmodule

`default_nettype wire
