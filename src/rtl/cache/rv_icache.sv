// =============================================================================
/// @file rv_icache.sv
/// @brief Direct-mapped, read-only instruction cache (1-cycle hit, line fill).
///
/// Sits between the CPU complex's PHYSICAL-address instruction-fetch port and the
/// read-only burst AXI master (in @ref rv_soc), amortizing DDR latency for code.
///
/// Contract (BRAM-equivalent on a hit):
///   - The fetch port presents @c c_addr each cycle and expects the 32-bit
///     instruction window for the address presented in the PREVIOUS cycle, with
///     @c c_ready high (exactly the synchronous-read BRAM timing the core was
///     built for).  Internally the address is registered (@c addr_q) so the
///     lookup result corresponds to @c fetch_pc, just like @ref rv_imem.
///   - A HIT drives @c c_ready=1 with the window combinationally.  A MISS drives
///     @c c_ready=0 while a whole line is fetched in one AXI burst (the core
///     freezes IF on @c ~imem_ready), after which the held address re-looks-up
///     and hits.
///
/// Variable-length (RVC) fetch: @c fetch_pc may be 2-byte aligned, so the 32-bit
/// window can span two 32-bit words.  Within a line the window is extracted with
/// a byte-granular part-select of the packed line.  The single offset whose
/// window would cross the LINE boundary (@c byte_off == LINE_BYTES-2) is served
/// UNCACHED via a direct single-beat read (rare; preserves the byte-addressable
/// fetch the AXI path already supported, without a two-line buffer).
///
/// @c flush (FENCE.I) invalidates the whole cache so self-modified / newly loaded
/// code is re-fetched from memory.
///
/// @param XLEN       Address width (32 or 64).
/// @param LINE_BYTES Cache line size in bytes (power of two, >= 8).
/// @param SETS       Number of direct-mapped sets (power of two).
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_icache #(
    parameter int          XLEN       = 32,
    parameter int          LINE_BYTES = 32,
    parameter int          SETS       = 64,
    parameter logic [63:0] RST_ADDR   = 64'h0  // initial fetch address (= core reset PC)
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                flush,        // FENCE.I: invalidate all lines

    // ---- Core (physical-address) instruction port ---------------------------
    input  wire                c_req,
    input  wire  [XLEN-1:0]    c_addr,
    output logic [31:0]        c_rdata,
    output logic               c_ready,

    // ---- Statistics ---------------------------------------------------------
    output logic [31:0]        hit_cnt,
    output logic [31:0]        miss_cnt,

    // ---- Memory side: read-only burst AXI master ----------------------------
    output logic               m_req,
    output logic [XLEN-1:0]    m_addr,
    output logic [7:0]         m_len,
    input  wire  [31:0]        m_rdata,
    input  wire                m_rvalid,
    input  wire  [7:0]         m_rbeat,
    input  wire                m_rlast,
    input  wire                m_done,
    input  wire                m_busy
);

    // ---- Geometry -----------------------------------------------------------
    localparam int OFFW  = $clog2(LINE_BYTES);        // byte-within-line bits
    localparam int WORDS = LINE_BYTES / 4;            // 32-bit words per line
    localparam int IDXW  = $clog2(SETS);              // set index bits
    localparam int TAGW  = XLEN - OFFW - IDXW;        // tag bits
    localparam int LINEW = LINE_BYTES * 8;            // packed line width

    // ---- Storage ------------------------------------------------------------
    logic               valid [0:SETS-1];
    logic [TAGW-1:0]    tagm  [0:SETS-1];
    logic [LINEW-1:0]   line  [0:SETS-1];

    // ---- Registered fetch address (1-cycle, BRAM-equivalent) ----------------
    logic [XLEN-1:0] addr_q;
    logic            req_q;

    wire [OFFW-1:0]  boff = addr_q[OFFW-1:0];
    wire [IDXW-1:0]  idx  = addr_q[OFFW +: IDXW];
    wire [TAGW-1:0]  tg   = addr_q[OFFW+IDXW +: TAGW];
    wire             hit  = valid[idx] & (tagm[idx] == tg);
    // 4-byte window that crosses the line end (only even offset that does so)
    wire             straddle = (boff == OFFW'(LINE_BYTES-2));
    wire [XLEN-1:0]  line_base = {addr_q[XLEN-1:OFFW], {OFFW{1'b0}}};

    // Combinational 32-bit window extract from the packed line (within a line)
    wire [31:0]      window = line[idx][boff*8 +: 32];

    // ---- FSM ----------------------------------------------------------------
    typedef enum logic [1:0] { S_LOOKUP, S_FILL, S_BYPASS } state_t;
    state_t state;

    logic [IDXW-1:0] fill_idx;
    logic [TAGW-1:0] fill_tag;
    logic [XLEN-1:0] fill_base;

    // ---- Outputs (combinational) --------------------------------------------
    always_comb begin
        unique case (state)
            S_LOOKUP: begin
                c_ready = req_q & ~straddle & hit;
                c_rdata = window;
            end
            S_BYPASS: begin
                c_ready = m_done;          // single-beat completion
                c_rdata = m_rdata;         // byte-exact window from memory
            end
            default: begin                 // S_FILL
                c_ready = 1'b0;
                c_rdata = window;
            end
        endcase
    end

    always_comb begin
        m_req  = 1'b0;
        m_addr = fill_base;
        m_len  = 8'(WORDS-1);
        unique case (state)
            S_FILL:   begin m_req = 1'b1; m_addr = fill_base; m_len = 8'(WORDS-1); end
            S_BYPASS: begin m_req = 1'b1; m_addr = addr_q;    m_len = 8'd0;        end
            default: ;
        endcase
    end

    // ---- Sequential ---------------------------------------------------------
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_LOOKUP;
            addr_q   <= RST_ADDR[XLEN-1:0];
            req_q    <= 1'b0;
            hit_cnt  <= '0;
            miss_cnt <= '0;
            fill_idx <= '0; fill_tag <= '0; fill_base <= '0;
            for (i = 0; i < SETS; i = i + 1) valid[i] <= 1'b0;
        end else begin
            // Track the fetch address with the SAME enable the core uses for
            // fetch_pc (advance only when this fetch completes, c_ready).  This
            // keeps addr_q == fetch_pc even when imem_addr transiently changes
            // (a branch/trap redirect) while the I$ holds c_ready=0 during a miss
            // fill -- otherwise addr_q would latch the redirect target and the I$
            // would return its window mis-tagged as the held fetch_pc.
            if (c_ready) addr_q <= c_addr;
            req_q  <= c_req;

            // FENCE.I invalidate (cheap: clear all valid bits).
            if (flush)
                for (i = 0; i < SETS; i = i + 1) valid[i] <= 1'b0;

            unique case (state)
                S_LOOKUP: begin
                    if (req_q) begin
                        if (straddle) begin
                            state <= S_BYPASS;   // line-crossing window: uncached
                        end else if (hit) begin
                            hit_cnt <= hit_cnt + 32'd1;
                        end else begin
                            fill_idx  <= idx;
                            fill_tag  <= tg;
                            fill_base <= line_base;
                            miss_cnt  <= miss_cnt + 32'd1;
                            state     <= S_FILL;
                        end
                    end
                end

                S_FILL: begin
                    if (m_rvalid)
                        line[fill_idx][m_rbeat[$clog2(WORDS)-1:0]*32 +: 32] <= m_rdata;
                    if (m_done) begin
                        // FENCE.I during a fill must not validate a stale line.
                        valid[fill_idx] <= ~flush;
                        tagm[fill_idx]  <= fill_tag;
                        state           <= S_LOOKUP;
                    end
                end

                S_BYPASS: begin
                    if (m_done) state <= S_LOOKUP;
                end

                default: state <= S_LOOKUP;
            endcase
        end
    end

endmodule

`default_nettype wire
