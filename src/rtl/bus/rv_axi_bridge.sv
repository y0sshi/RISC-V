// =============================================================================
/// @file rv_axi_bridge.sv
/// @brief Simple-bus to AXI4 master bridge (single-beat, single outstanding)
///
/// Converts the core's synchronous BRAM-style simple memory bus into AXI4
/// master transactions.  Designed to sit AFTER the MMU (physical-address side),
/// replacing rv_imem / rv_dmem / rv_unified_mem with a path to external DDR
/// (Zynq PS via S_AXI_HP).
///
/// Protocol (simple-bus side):
///   - The consumer presents @c s_req with @c s_addr (and, for writes,
///     @c s_we / @c s_wdata / @c s_wstrb) and holds them stable while the
///     transaction is in flight (the core's stall logic guarantees this).
///   - @c s_ready is a 1-cycle completion PULSE: for reads it marks the cycle
///     @c s_rdata is valid; for writes it marks write-response acceptance.
///   - @c s_busy is high while a transaction is in flight and drops on the
///     completion cycle.  A consumer that needs a hold signal (the data port)
///     uses @c s_wait = s_busy & ~s_ready; the IF port only needs @c s_ready.
///   - @c s_rdata is REGISTERED and held after completion until the next
///     transaction starts, so a consumer that samples it one cycle late
///     (the core's WB stage) still sees valid data.
///
/// AXI4 (master side):
///   - Single beat only (AWLEN = ARLEN = 0, WLAST = 1, burst = INCR).
///   - One outstanding transaction at a time (no pipelining) for simplicity and
///     to keep ordering trivial.  Caches can be added later for throughput.
///   - AWSIZE / ARSIZE = log2(DATA_WIDTH/8).
///
/// @param ADDR_WIDTH Address bus width (= XLEN of the core: 32 or 64).
/// @param DATA_WIDTH Data bus width (32 for the IF port, XLEN for the data port).
/// @param ID_WIDTH   AXI ID width.
/// @param READ_ONLY  1 = instruction port (no write channels); 0 = read/write.
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_axi_bridge #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter int ID_WIDTH   = 4,
    parameter bit READ_ONLY  = 1'b0
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // -------- Simple bus (consumer side) -----------------------------------
    input  wire                     s_req,
    input  wire                     s_we,
    input  wire  [ADDR_WIDTH-1:0]   s_addr,
    input  wire  [DATA_WIDTH-1:0]   s_wdata,
    input  wire  [DATA_WIDTH/8-1:0] s_wstrb,
    output logic [DATA_WIDTH-1:0]   s_rdata,
    output logic                    s_ready,   // 1-cycle completion pulse
    output logic                    s_busy,    // transaction in flight
    output logic                    s_wait,    // s_busy & ~s_ready (hold signal)

    // -------- AXI4 master: write address channel ---------------------------
    output logic [ID_WIDTH-1:0]     m_axi_awid,
    output logic [ADDR_WIDTH-1:0]   m_axi_awaddr,
    output logic [7:0]              m_axi_awlen,
    output logic [2:0]              m_axi_awsize,
    output logic [1:0]              m_axi_awburst,
    output logic                    m_axi_awvalid,
    input  wire                     m_axi_awready,

    // -------- AXI4 master: write data channel ------------------------------
    output logic [DATA_WIDTH-1:0]   m_axi_wdata,
    output logic [DATA_WIDTH/8-1:0] m_axi_wstrb,
    output logic                    m_axi_wlast,
    output logic                    m_axi_wvalid,
    input  wire                     m_axi_wready,

    // -------- AXI4 master: write response channel --------------------------
    input  wire  [ID_WIDTH-1:0]     m_axi_bid,
    input  wire  [1:0]              m_axi_bresp,
    input  wire                     m_axi_bvalid,
    output logic                    m_axi_bready,

    // -------- AXI4 master: read address channel ----------------------------
    output logic [ID_WIDTH-1:0]     m_axi_arid,
    output logic [ADDR_WIDTH-1:0]   m_axi_araddr,
    output logic [7:0]              m_axi_arlen,
    output logic [2:0]              m_axi_arsize,
    output logic [1:0]              m_axi_arburst,
    output logic                    m_axi_arvalid,
    input  wire                     m_axi_arready,

    // -------- AXI4 master: read data channel -------------------------------
    input  wire  [ID_WIDTH-1:0]     m_axi_rid,
    input  wire  [DATA_WIDTH-1:0]   m_axi_rdata,
    input  wire  [1:0]              m_axi_rresp,
    input  wire                     m_axi_rlast,
    input  wire                     m_axi_rvalid,
    output logic                    m_axi_rready
);

    // log2(DATA_WIDTH/8): AxSIZE encoding
    localparam int SIZE_LOG2 = (DATA_WIDTH == 64) ? 3 :
                               (DATA_WIDTH == 32) ? 2 :
                               (DATA_WIDTH == 16) ? 1 : 0;

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_IDLE = 3'd0,
        ST_AR   = 3'd1,   // drive ARVALID
        ST_R    = 3'd2,   // wait RVALID
        ST_AW   = 3'd3,   // drive AWVALID
        ST_W    = 3'd4,   // drive WVALID
        ST_B    = 3'd5    // wait BVALID
    } state_t;

    state_t state;

    // Latched request payload
    logic [ADDR_WIDTH-1:0]   addr_q;
    logic [DATA_WIDTH-1:0]   wdata_q;
    logic [DATA_WIDTH/8-1:0] wstrb_q;
    logic [DATA_WIDTH-1:0]   rdata_q;

    // Completion pulse (combinational): the cycle the transaction finishes.
    wire read_done  = (state == ST_R) && m_axi_rvalid && m_axi_rready;
    wire write_done = (state == ST_B) && m_axi_bvalid && m_axi_bready;

    always_comb begin
        s_ready = read_done | write_done;
        s_busy  = (state != ST_IDLE);
        // s_wait must rise the SAME cycle a request appears (state is still IDLE
        // then), otherwise a consumer that gates its advance on s_wait (the data
        // port's dmem_wait) would advance before the transaction even started.
        // It drops on the completion cycle (s_ready) so the consumer advances and
        // the held s_rdata is sampled the following cycle.
        s_wait  = (s_req | s_busy) & ~s_ready;
        // On the completion cycle present the AXI read data COMBINATIONALLY so a
        // consumer that samples in the same cycle as s_ready (the instruction
        // port: captures imem_rdata when imem_ready=1) gets valid data.  After
        // completion the registered rdata_q holds it for a consumer that samples
        // one cycle later (the data port: WB reads dmem_rdata after the access).
        s_rdata = read_done ? m_axi_rdata : rdata_q;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= ST_IDLE;
            addr_q  <= '0;
            wdata_q <= '0;
            wstrb_q <= '0;
            rdata_q <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (s_req) begin
                        addr_q  <= s_addr;
                        wdata_q <= s_wdata;
                        wstrb_q <= s_wstrb;
                        if (!READ_ONLY && s_we) state <= ST_AW;
                        else                    state <= ST_AR;
                    end
                end

                // ---- Read ----
                ST_AR: if (m_axi_arready) state <= ST_R;
                ST_R:  if (m_axi_rvalid) begin
                           rdata_q <= m_axi_rdata;  // hold until next transaction
                           state   <= ST_IDLE;
                       end

                // ---- Write ----
                ST_AW: if (m_axi_awready) state <= ST_W;
                ST_W:  if (m_axi_wready)  state <= ST_B;
                ST_B:  if (m_axi_bvalid)  state <= ST_IDLE;

                default: state <= ST_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // AXI channel drivers
    // -------------------------------------------------------------------------
    // Read address
    assign m_axi_arid    = '0;
    assign m_axi_araddr  = addr_q;
    assign m_axi_arlen   = 8'd0;                 // single beat
    assign m_axi_arsize  = 3'(SIZE_LOG2);
    assign m_axi_arburst = 2'b01;                // INCR
    assign m_axi_arvalid = (state == ST_AR);
    assign m_axi_rready  = (state == ST_R);

    // Write address / data / response (tied off when READ_ONLY)
    assign m_axi_awid    = '0;
    assign m_axi_awaddr  = addr_q;
    assign m_axi_awlen   = 8'd0;
    assign m_axi_awsize  = 3'(SIZE_LOG2);
    assign m_axi_awburst = 2'b01;
    assign m_axi_awvalid = (!READ_ONLY) && (state == ST_AW);
    assign m_axi_wdata   = wdata_q;
    assign m_axi_wstrb   = wstrb_q;
    assign m_axi_wlast   = 1'b1;                 // single beat
    assign m_axi_wvalid  = (!READ_ONLY) && (state == ST_W);
    assign m_axi_bready  = (!READ_ONLY) && (state == ST_B);

endmodule

`default_nettype wire
