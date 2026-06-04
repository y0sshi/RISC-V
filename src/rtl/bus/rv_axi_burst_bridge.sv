// =============================================================================
/// @file rv_axi_burst_bridge.sv
/// @brief Simple-bus to AXI4 master bridge with BURST reads (cache line fill).
///
/// Extends the single-beat @ref rv_axi_bridge with multi-beat INCR read bursts so
/// a cache can fill a whole line in one AXI transaction (the key to amortizing
/// DDR latency).  Writes remain single-beat (write-through caches issue one word
/// at a time).  One outstanding transaction at a time.
///
/// Consumer (cache) side -- a request is either:
///   - a READ BURST  (@c s_we=0): @c s_len+1 beats starting at @c s_addr
///     (the cache presents @c s_addr line-aligned, @c s_len = LINE_BEATS-1; a
///     plain single read sets @c s_len=0).  Each returned beat is streamed out on
///     @c s_rvalid / @c s_rdata with index @c s_rbeat and @c s_rlast on the last.
///   - a single WRITE (@c s_we=1): one beat (@c s_wdata / @c s_wstrb) at @c s_addr.
/// @c s_done pulses for one cycle when the whole transaction finishes (read: the
/// last beat accept; write: the B response).  @c s_busy is high while in flight.
///
/// The consumer holds @c s_req and the payload stable from assert until @c s_done
/// (the cache stall logic guarantees this).  @c s_req should drop after @c s_done.
///
/// AXI4 master side: ARLEN = @c s_len, ARBURST = INCR, ARSIZE = log2(DATA_WIDTH/8);
/// writes use AWLEN=0 / WLAST=1.
///
/// @param ADDR_WIDTH Address bus width (= XLEN: 32 or 64).
/// @param DATA_WIDTH Data bus width (32 for the IF/I$ port, XLEN for the D$ port).
/// @param ID_WIDTH   AXI ID width.
/// @param READ_ONLY  1 = instruction port (no write channels); 0 = read/write.
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_axi_burst_bridge #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter int ID_WIDTH   = 4,
    parameter bit READ_ONLY  = 1'b0
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // -------- Simple bus (consumer / cache side) ---------------------------
    input  wire                     s_req,
    input  wire                     s_we,      // 1 = single write, 0 = read burst
    input  wire  [ADDR_WIDTH-1:0]   s_addr,
    input  wire  [7:0]              s_len,     // read burst length - 1 (ARLEN)
    input  wire  [DATA_WIDTH-1:0]   s_wdata,
    input  wire  [DATA_WIDTH/8-1:0] s_wstrb,
    output logic [DATA_WIDTH-1:0]   s_rdata,   // current read beat data
    output logic                    s_rvalid,  // read beat valid (1-cycle pulse)
    output logic [7:0]              s_rbeat,   // read beat index (0..s_len)
    output logic                    s_rlast,   // last read beat
    output logic                    s_done,    // transaction complete (1-cycle)
    output logic                    s_busy,    // transaction in flight

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

    typedef enum logic [2:0] {
        ST_IDLE = 3'd0,
        ST_AR   = 3'd1,   // drive ARVALID
        ST_R    = 3'd2,   // stream read beats
        ST_AW   = 3'd3,   // drive AWVALID
        ST_W    = 3'd4,   // drive WVALID
        ST_B    = 3'd5    // wait BVALID
    } state_t;

    state_t state;

    // Latched request payload
    logic [ADDR_WIDTH-1:0]   addr_q;
    logic [7:0]              len_q;     // ARLEN for the read burst
    logic [DATA_WIDTH-1:0]   wdata_q;
    logic [DATA_WIDTH/8-1:0] wstrb_q;
    logic [7:0]              beat_q;    // current read beat index

    wire read_beat  = (state == ST_R) && m_axi_rvalid && m_axi_rready;
    wire read_last  = read_beat && m_axi_rlast;
    wire write_done = (state == ST_B) && m_axi_bvalid && m_axi_bready;

    always_comb begin
        s_rvalid = read_beat;
        s_rbeat  = beat_q;
        s_rlast  = read_beat && m_axi_rlast;
        s_rdata  = m_axi_rdata;
        s_done   = read_last | write_done;
        s_busy   = (state != ST_IDLE);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= ST_IDLE;
            addr_q  <= '0;
            len_q   <= '0;
            wdata_q <= '0;
            wstrb_q <= '0;
            beat_q  <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (s_req) begin
                        addr_q  <= s_addr;
                        len_q   <= s_len;
                        wdata_q <= s_wdata;
                        wstrb_q <= s_wstrb;
                        beat_q  <= '0;
                        if (!READ_ONLY && s_we) state <= ST_AW;
                        else                    state <= ST_AR;
                    end
                end

                // ---- Read burst ----
                ST_AR: if (m_axi_arready) state <= ST_R;
                ST_R:  if (read_beat) begin
                           if (m_axi_rlast) state  <= ST_IDLE;
                           else             beat_q <= beat_q + 8'd1;
                       end

                // ---- Single write ----
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
    assign m_axi_arid    = '0;
    assign m_axi_araddr  = addr_q;
    assign m_axi_arlen   = len_q;                // burst length - 1
    assign m_axi_arsize  = 3'(SIZE_LOG2);
    assign m_axi_arburst = 2'b01;                // INCR
    assign m_axi_arvalid = (state == ST_AR);
    assign m_axi_rready  = (state == ST_R);

    assign m_axi_awid    = '0;
    assign m_axi_awaddr  = addr_q;
    assign m_axi_awlen   = 8'd0;                 // single beat write
    assign m_axi_awsize  = 3'(SIZE_LOG2);
    assign m_axi_awburst = 2'b01;
    assign m_axi_awvalid = (!READ_ONLY) && (state == ST_AW);
    assign m_axi_wdata   = wdata_q;
    assign m_axi_wstrb   = wstrb_q;
    assign m_axi_wlast   = 1'b1;
    assign m_axi_wvalid  = (!READ_ONLY) && (state == ST_W);
    assign m_axi_bready  = (!READ_ONLY) && (state == ST_B);

endmodule

`default_nettype wire
