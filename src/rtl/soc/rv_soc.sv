// =============================================================================
// rv_soc.sv - RISC-V SoC (default / real hardware): DDR over AXI4 + peripherals
// =============================================================================
// rv_cpu + I/D caches + two AXI4 masters to external memory (instruction fetch
// read-only 32-bit; data + page-table-walk read/write XLEN) + on-chip peripheral
// subsystem (rv_periph: CLINT/UART/PLIC/GPIO).  On a Zynq board both masters fan
// into an AXI SmartConnect -> S_AXI_HP -> PS DDR (see boards/*/vivado).
//
// Caches (see src/rtl/cache, docs/cache.md):
//   - rv_icache: read-only, direct-mapped, line fill over a burst AXI read.
//                Flushed by FENCE.I (cpu_fence_i).
//   - rv_dcache: write-through, write-no-allocate, direct-mapped; line fill on a
//                load miss, single-beat write-through on a store.
//   Peripheral (0xC0xx) accesses are UNCACHED (served by rv_periph) and PTW reads
//   BYPASS the D-cache (single-beat AXI read, arbitrated onto the data master).
//   Set ICACHE_EN / DCACHE_EN = 0 to bypass a cache (direct single-beat AXI) for
//   debugging; behaviour is then identical to the pre-cache SoC.
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
    parameter int          BAUD_RATE    = 115_200,
    parameter int          MTIME_DIV    = 1,           // CLINT mtime prescaler
    // ---- Cache configuration ----
    parameter bit          ICACHE_EN    = 1'b1,
    parameter int          ICACHE_LINE  = 32,
    parameter int          ICACHE_SETS  = 64,
    parameter bit          DCACHE_EN    = 1'b1,
    parameter int          DCACHE_LINE  = 32,
    parameter int          DCACHE_SETS  = 64
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
    logic              cpu_fence_i;
    logic              timer_irq_sig; logic sw_irq_sig; logic [1:0] plic_ext_irq;
    logic [63:0]       periph_mtime;

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
        .fence_i_out (cpu_fence_i),
        .ptw_paddr (ptw_paddr), .ptw_req (ptw_req),
        .ptw_rdata (ptw_rdata), .ptw_ready (ptw_ready),
        // External interrupt: OR both PLIC contexts (0 = M/MEIP, 1 = S/SEIP per
        // the DT interrupts-extended <&intc 11 &intc 9>).  Only one context owns
        // a given source, so the OR is unambiguous; rv_csr routes the shared line
        // to SEIP or MEIP by mideleg[9] (delegated -> S).  Linux services external
        // IRQs (e.g. the 8250 TX-empty IRQ that drains a userspace tty write) via
        // the S context.  (The PLIC itself must use the standard SiFive register
        // map for the Linux driver to ever enable an S-context source -- see
        // rv_plic.sv.)  Bare/mini-SBI leave both contexts at 0 (no-op).
        .timer_irq (timer_irq_sig), .sw_irq (sw_irq_sig),
        .ext_irq (plic_ext_irq[0] | plic_ext_irq[1]),
        .time_val  (periph_mtime)
    );

    // =========================================================================
    // Instruction fetch path: I-cache -> read-only burst AXI master
    // =========================================================================
    generate
    if (ICACHE_EN) begin : gen_icache
        logic            ic_m_req;
        logic [XLEN-1:0] ic_m_addr;
        logic [7:0]      ic_m_len;
        logic [31:0]     ic_m_rdata;
        logic            ic_m_rvalid, ic_m_rlast, ic_m_done, ic_m_busy;
        logic [7:0]      ic_m_rbeat;

        rv_icache #(.XLEN (XLEN), .LINE_BYTES (ICACHE_LINE), .SETS (ICACHE_SETS),
                    .RST_ADDR (RST_ADDR)) u_ic (
            .clk (clk), .rst_n (rst_n), .flush (cpu_fence_i),
            .c_req (mmu_imem_req), .c_addr (mmu_imem_pa),
            .c_rdata (imem_rdata), .c_ready (imem_ready),
            .hit_cnt (), .miss_cnt (),
            .m_req (ic_m_req), .m_addr (ic_m_addr), .m_len (ic_m_len),
            .m_rdata (ic_m_rdata), .m_rvalid (ic_m_rvalid), .m_rbeat (ic_m_rbeat),
            .m_rlast (ic_m_rlast), .m_done (ic_m_done), .m_busy (ic_m_busy)
        );

        rv_axi_burst_bridge #(.ADDR_WIDTH (XLEN), .DATA_WIDTH (32),
                              .ID_WIDTH (AXI_ID_WIDTH), .READ_ONLY (1'b1)) u_axi_if (
            .clk (clk), .rst_n (rst_n),
            .s_req (ic_m_req), .s_we (1'b0), .s_addr (ic_m_addr), .s_len (ic_m_len),
            .s_wdata (32'b0), .s_wstrb (4'b0),
            .s_rdata (ic_m_rdata), .s_rvalid (ic_m_rvalid), .s_rbeat (ic_m_rbeat),
            .s_rlast (ic_m_rlast), .s_done (ic_m_done), .s_busy (ic_m_busy),
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
    end else begin : gen_no_icache
        // Bypass: direct single-beat read (identical to the pre-cache SoC).
        logic if_busy, if_wait;
        rv_axi_bridge #(.ADDR_WIDTH (XLEN), .DATA_WIDTH (32),
                        .ID_WIDTH (AXI_ID_WIDTH), .READ_ONLY (1'b1)) u_axi_if (
            .clk (clk), .rst_n (rst_n),
            .s_req (mmu_imem_req), .s_we (1'b0), .s_addr (mmu_imem_pa),
            .s_wdata (32'b0), .s_wstrb (4'b0),
            .s_rdata (imem_rdata), .s_ready (imem_ready),
            .s_busy (if_busy), .s_wait (if_wait),
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
    end
    endgenerate

    // ---- Peripheral subsystem (served locally; uncached) --------------------
    logic            periph_is_periph;
    logic [XLEN-1:0] periph_rdata;
    logic            periph_rdata_valid;
    logic            uart_tx_sig;

    rv_periph #(.XLEN (XLEN), .CLK_FREQ (CLK_FREQ), .BAUD_RATE (BAUD_RATE), .MTIME_DIV (MTIME_DIV)) u_periph (
        .clk (clk), .rst_n (rst_n),
        .addr (mmu_dmem_pa), .wdata (core_dmem_wdata), .wstrb (core_dmem_wstrb),
        .req (mmu_dmem_req), .we (mmu_dmem_we),
        .is_periph (periph_is_periph), .rdata (periph_rdata), .rdata_valid (periph_rdata_valid),
        .timer_irq (timer_irq_sig), .sw_irq (sw_irq_sig), .ext_irq (plic_ext_irq), .mtime (periph_mtime),
        .gpio_in (gpio_in), .gpio_out (gpio_out),
        .uart_rx (uart_rx), .uart_tx (uart_tx_sig)
    );
    assign uart_tx = uart_tx_sig;

    // =========================================================================
    // Data path: D-cache (DDR) | peripheral (uncached) | PTW (bypass).
    // The D-cache memory side and the PTW share one read/write burst AXI master,
    // arbitrated with PTW priority (they never overlap: a held data access freezes
    // the pipeline, so no new translation/PTW can start while the D$ services it).
    // =========================================================================
    logic              dc_c_wait;
    logic [XLEN-1:0]   dc_c_rdata;
    // D-cache memory side
    logic              dc_m_req, dc_m_we;
    logic [XLEN-1:0]   dc_m_addr, dc_m_wdata;
    logic [7:0]        dc_m_len;
    logic [XLEN/8-1:0] dc_m_wstrb;
    // Shared data burst-bridge consumer side
    logic              br_req, br_we;
    logic [XLEN-1:0]   br_addr, br_wdata;
    logic [7:0]        br_len;
    logic [XLEN/8-1:0] br_wstrb;
    logic [XLEN-1:0]   br_rdata;
    logic              br_rvalid, br_rlast, br_done, br_busy;
    logic [7:0]        br_rbeat;

    // ---- Atomic arbiter for the shared data bridge (PTW priority) -----------
    // (declared before the D-cache generate so the gated completion signals can
    // feed the D-cache instance.)  The burst bridge serves ONE master per
    // transaction; the owner is latched at transaction start and held until
    // completion, so a PTW request asserted mid-transaction cannot steal the
    // in-flight D-cache transaction's completion (br_done) / stale rdata_hold.
    // That theft made a store's multi-cycle write-through B-response look like a
    // PTW read return (stale data -> bogus PTE -> spurious page fault -> Linux
    // panic "Attempted to kill the idle task!").
    logic owner_ptw_q;
    wire  bridge_idle = ~br_busy;
    wire  owner_ptw   = bridge_idle ? ptw_req : owner_ptw_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)           owner_ptw_q <= 1'b0;
        else if (bridge_idle) owner_ptw_q <= ptw_req;   // latch owner at (idle) grant
    end
    // Bridge completion / read-beat signals routed to the granted master only.
    wire dc_br_done   = br_done   & ~owner_ptw;
    wire dc_br_rvalid = br_rvalid & ~owner_ptw;
    wire dc_br_rlast  = br_rlast  & ~owner_ptw;

    // Cacheable data request: not a peripheral access
    wire dc_c_req = mmu_dmem_req & ~periph_is_periph;

    generate
    if (DCACHE_EN) begin : gen_dcache
        rv_dcache #(.XLEN (XLEN), .LINE_BYTES (DCACHE_LINE), .SETS (DCACHE_SETS)) u_dc (
            .clk (clk), .rst_n (rst_n),
            .c_req (dc_c_req), .c_we (mmu_dmem_we), .c_addr (mmu_dmem_pa),
            .c_wdata (core_dmem_wdata), .c_wstrb (core_dmem_wstrb),
            .c_rdata (dc_c_rdata), .c_wait (dc_c_wait),
            .hit_cnt (), .miss_cnt (),
            .m_req (dc_m_req), .m_we (dc_m_we), .m_addr (dc_m_addr), .m_len (dc_m_len),
            .m_wdata (dc_m_wdata), .m_wstrb (dc_m_wstrb),
            .m_rdata (br_rdata), .m_rvalid (dc_br_rvalid), .m_rbeat (br_rbeat),
            .m_rlast (dc_br_rlast), .m_done (dc_br_done), .m_busy (br_busy)
        );
    end else begin : gen_no_dcache
        // Bypass: every cacheable access is a single-beat AXI transaction.
        assign dc_c_rdata = br_rdata;
        assign dc_c_wait  = (dc_c_req | dc_m_req) & ~dc_br_done;  // mirror original s_wait
        assign dc_m_req   = dc_c_req;
        assign dc_m_we    = mmu_dmem_we;
        assign dc_m_addr  = mmu_dmem_pa;
        assign dc_m_len   = 8'd0;
        assign dc_m_wdata = core_dmem_wdata;
        assign dc_m_wstrb = core_dmem_wstrb;
    end
    endgenerate

    // ---- Shared data bridge request mux (owner from the arbiter above) ------
    always_comb begin
        if (owner_ptw) begin
            br_req = ptw_req; br_we = 1'b0; br_addr = ptw_paddr; br_len = 8'd0;
            br_wdata = '0; br_wstrb = '0;
        end else begin
            br_req = dc_m_req; br_we = dc_m_we; br_addr = dc_m_addr; br_len = dc_m_len;
            br_wdata = dc_m_wdata; br_wstrb = dc_m_wstrb;
        end
    end

    rv_axi_burst_bridge #(.ADDR_WIDTH (XLEN), .DATA_WIDTH (XLEN),
                          .ID_WIDTH (AXI_ID_WIDTH), .READ_ONLY (1'b0)) u_axi_data (
        .clk (clk), .rst_n (rst_n),
        .s_req (br_req), .s_we (br_we), .s_addr (br_addr), .s_len (br_len),
        .s_wdata (br_wdata), .s_wstrb (br_wstrb),
        .s_rdata (br_rdata), .s_rvalid (br_rvalid), .s_rbeat (br_rbeat),
        .s_rlast (br_rlast), .s_done (br_done), .s_busy (br_busy),
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
    // PTW reads come straight off the burst bridge (combinational on the beat,
    // which the PTW FSM samples on ptw_ready).  Peripheral accesses keep the data
    // master idle so the core does not stall and the 1-cycle registered peripheral
    // read is selected next cycle.
    assign core_dmem_wait = ptw_req ? 1'b0 : dc_c_wait;
    assign ptw_rdata      = br_rdata;
    assign ptw_ready      = owner_ptw & br_done;   // only the PTW's own completion

    always_comb begin
        if (periph_rdata_valid) begin
            dmem_rdata = periph_rdata;
            dmem_ready = 1'b1;
        end else begin
            dmem_rdata = dc_c_rdata;
            dmem_ready = ptw_req ? 1'b0 : ~dc_c_wait;
        end
    end

endmodule

`default_nettype wire
