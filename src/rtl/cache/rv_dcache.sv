// =============================================================================
/// @file rv_dcache.sv
/// @brief Direct-mapped, write-through, write-no-allocate data cache.
///
/// Sits between the CPU complex's PHYSICAL-address data port and the burst AXI
/// master (in @ref rv_soc), amortizing DDR latency for the DDR data region.
/// Peripheral (MMIO) and page-table-walk accesses are kept UNCACHED and bypass
/// this module (handled in @ref rv_soc) -- only cacheable DDR loads/stores reach
/// the cache.
///
/// Design (first, provably-correct version):
///   - **Direct-mapped**, parameterized SETS x LINE_BYTES.
///   - **Combinational tag/data lookup** (LUTRAM-style arrays) so a HIT is
///     resolved in the access cycle: a load HIT presents data the next cycle
///     (BRAM-identical 1-cycle latency, @c c_wait stays low); a MISS asserts
///     @c c_wait while a whole line is fetched in one AXI burst, then the held
///     access re-looks-up and hits.
///   - **Write-through, write-no-allocate**: every store is forwarded to memory
///     (single-beat AXI write) and, IF the line is currently cached, the cached
///     word is updated in place (keeps cache == memory).  A store that misses
///     does NOT allocate.  Memory therefore always holds the latest value, so the
///     cache is always coherent with it (single hart).
///
/// The cache is transparent to AMO / LR-SC and misaligned 2-phase accesses: the
/// core decomposes those into ordinary word loads/stores at this interface, each
/// of which honors the @c c_wait / @c c_rdata contract.
///
/// Contract (matches the AXI bridge the core was validated against):
///   - @c c_wait rises combinationally the cycle a miss/store is presented and
///     drops on the completion cycle; the core freezes the access in MEM while
///     @c c_wait is high (drives this onto @c dmem_wait).
///   - @c c_rdata is REGISTERED and held until the next load completes, so the WB
///     stage (which samples one cycle after the access) and the misaligned
///     phase-0 capture both see stable data.
///
/// @param XLEN       Data path width (32 or 64).
/// @param LINE_BYTES Cache line size in bytes (power of two, >= 2*(XLEN/8)).
/// @param SETS       Number of direct-mapped sets (power of two).
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_dcache #(
    parameter int XLEN       = 32,
    parameter int LINE_BYTES = 32,
    parameter int SETS       = 64
) (
    input  wire                clk,
    input  wire                rst_n,

    // ---- Core (physical-address) data port; cacheable accesses only ---------
    input  wire                c_req,
    input  wire                c_we,
    input  wire  [XLEN-1:0]    c_addr,
    input  wire  [XLEN-1:0]    c_wdata,
    input  wire  [XLEN/8-1:0]  c_wstrb,
    output logic [XLEN-1:0]    c_rdata,
    output logic               c_wait,

    // ---- Statistics (for verification of caching effectiveness) -------------
    output logic [31:0]        hit_cnt,
    output logic [31:0]        miss_cnt,

    // ---- Memory side: to the burst AXI master (arbitrated with PTW upstream) -
    output logic               m_req,
    output logic               m_we,
    output logic [XLEN-1:0]    m_addr,
    output logic [7:0]         m_len,
    output logic [XLEN-1:0]    m_wdata,
    output logic [XLEN/8-1:0]  m_wstrb,
    input  wire  [XLEN-1:0]    m_rdata,
    input  wire                m_rvalid,
    input  wire  [7:0]         m_rbeat,
    input  wire                m_rlast,
    input  wire                m_done,
    input  wire                m_busy
);

    // ---- Geometry -----------------------------------------------------------
    localparam int BYTEW = $clog2(XLEN/8);            // byte-within-word bits
    localparam int OFFW  = $clog2(LINE_BYTES);        // byte-within-line bits
    localparam int WORDS = LINE_BYTES / (XLEN/8);     // words per line
    localparam int WIDXW = $clog2(WORDS);             // word-within-line bits
    localparam int IDXW  = $clog2(SETS);              // set index bits
    localparam int TAGW  = XLEN - OFFW - IDXW;        // tag bits

    // ---- Storage (combinational read) ---------------------------------------
    logic [SETS-1:0]    valid;
    logic [TAGW-1:0]    tagm  [0:SETS-1];
    logic [XLEN-1:0]    data  [0:SETS-1][0:WORDS-1];

    // ---- Address decode (current request) -----------------------------------
    wire [IDXW-1:0]  idx  = c_addr[OFFW +: IDXW];
    wire [TAGW-1:0]  tg   = c_addr[OFFW+IDXW +: TAGW];
    wire [WIDXW-1:0] wsel = c_addr[BYTEW +: WIDXW];
    wire             hit  = c_req & valid[idx] & (tagm[idx] == tg);
    wire [XLEN-1:0]  line_base = {c_addr[XLEN-1:OFFW], {OFFW{1'b0}}};

    // ---- FSM ----------------------------------------------------------------
    typedef enum logic [1:0] { S_LOOKUP, S_FILL, S_WRITE } state_t;
    state_t state;

    // Latched miss/store context
    logic [IDXW-1:0]   fill_idx;
    logic [TAGW-1:0]   fill_tag;
    logic [XLEN-1:0]   fill_base;
    logic [WIDXW-1:0]  fill_wsel;     // requested word within the line being filled
    logic              st_hit;
    logic [IDXW-1:0]   st_idx;
    logic [WIDXW-1:0]  st_wsel;
    logic [XLEN-1:0]   st_addr;
    logic [XLEN-1:0]   st_wdata;
    logic [XLEN/8-1:0] st_wstrb;

    logic [XLEN-1:0]   rdata_q;
    assign c_rdata = rdata_q;

    // ---- c_wait (combinational) ---------------------------------------------
    always_comb begin
        unique case (state)
            S_LOOKUP: c_wait = c_req & (c_we | ~hit);  // store, or load miss
            S_FILL:   c_wait = ~m_done;                // drop on the line-fill completion
            S_WRITE:  c_wait = ~m_done;                // drop on the write response
            default:  c_wait = 1'b0;
        endcase
    end

    // ---- Memory-side request drivers ----------------------------------------
    always_comb begin
        m_req   = 1'b0;
        m_we    = 1'b0;
        m_addr  = fill_base;
        m_len   = 8'(WORDS-1);
        m_wdata = st_wdata;
        m_wstrb = st_wstrb;
        unique case (state)
            S_FILL: begin
                m_req = 1'b1; m_we = 1'b0; m_addr = fill_base; m_len = 8'(WORDS-1);
            end
            S_WRITE: begin
                m_req = 1'b1; m_we = 1'b1; m_addr = st_addr; m_len = 8'd0;
                m_wdata = st_wdata; m_wstrb = st_wstrb;
            end
            default: ;
        endcase
    end

    // ---- Sequential ---------------------------------------------------------
    integer w, b;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_LOOKUP;
            rdata_q  <= '0;
            hit_cnt  <= '0;
            miss_cnt <= '0;
            fill_idx <= '0; fill_tag <= '0; fill_base <= '0; fill_wsel <= '0;
            st_hit   <= 1'b0; st_idx <= '0; st_wsel <= '0;
            st_addr  <= '0; st_wdata <= '0; st_wstrb <= '0;
            valid <= '0;
        end else begin
            unique case (state)
                S_LOOKUP: begin
                    if (c_req && !c_we) begin
                        // Load
                        if (hit) begin
                            rdata_q <= data[idx][wsel];
                            hit_cnt <= hit_cnt + 32'd1;
                        end else begin
                            // Miss: start a line fill
                            fill_idx  <= idx;
                            fill_tag  <= tg;
                            fill_base <= line_base;
                            fill_wsel <= wsel;
                            miss_cnt  <= miss_cnt + 32'd1;
                            state     <= S_FILL;
                        end
                    end else if (c_req && c_we) begin
                        // Store (write-through): latch context, issue write
                        st_hit   <= hit;
                        st_idx   <= idx;
                        st_wsel  <= wsel;
                        st_addr  <= c_addr;
                        st_wdata <= c_wdata;
                        st_wstrb <= c_wstrb;
                        if (hit) hit_cnt  <= hit_cnt  + 32'd1;
                        else     miss_cnt <= miss_cnt + 32'd1;
                        state    <= S_WRITE;
                    end
                end

                S_FILL: begin
                    if (m_rvalid) begin
                        data[fill_idx][m_rbeat[WIDXW-1:0]] <= m_rdata;
                        // Capture the requested word as its beat streams by, so the
                        // load result is ready when the fill completes (no re-lookup).
                        if (m_rbeat[WIDXW-1:0] == fill_wsel)
                            rdata_q <= m_rdata;
                    end
                    if (m_done) begin
                        valid[fill_idx] <= 1'b1;
                        tagm[fill_idx]  <= fill_tag;
                        state           <= S_LOOKUP;
                    end
                end

                S_WRITE: begin
                    if (m_done) begin
                        // Update cached word on a write-through hit
                        if (st_hit) begin
                            for (b = 0; b < XLEN/8; b = b + 1)
                                if (st_wstrb[b])
                                    data[st_idx][st_wsel][b*8 +: 8] <= st_wdata[b*8 +: 8];
                        end
                        state <= S_LOOKUP;
                    end
                end

                default: state <= S_LOOKUP;
            endcase
        end
    end

endmodule

`default_nettype wire
