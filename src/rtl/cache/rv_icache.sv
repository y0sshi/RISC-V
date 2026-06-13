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
/// Storage: the line data array is a true **synchronous-read block RAM** so it
/// maps to Xilinx RAMB36/RAMB18 rather than LUTRAM / fabric flip-flops.  The
/// registered read output (@c line_q) is clocked with the SAME enable the fetch
/// address register (@c addr_q) uses, so @c line_q tracks @c addr_q in lockstep:
/// in the serve cycle @c line_q == line[set(addr_q)], identical to the previous
/// combinational read.  Tag/valid stay in fabric (small, combinational lookup).
/// After a line fill the requested word cannot be read out of the BRAM on the
/// same cycle its last beat is written, so a one-cycle SETTLE state (@c S_FILL2)
/// re-reads the freshly filled line before the held address re-looks-up; this
/// adds a single MISS cycle and leaves the hit path untouched.
///
/// Variable-length (RVC) fetch: @c fetch_pc may be 2-byte aligned, so the 32-bit
/// window can span two 32-bit words.  Within a line the window is extracted with
/// a byte-granular part-select of the registered line read.  The single offset
/// whose window would cross the LINE boundary (@c byte_off == LINE_BYTES-2) is
/// served UNCACHED via a direct single-beat read (rare; preserves the
/// byte-addressable fetch the AXI path already supported, without a two-line
/// buffer).
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
    localparam int WIDXW = $clog2(WORDS);             // word-within-line bits
    localparam int IDXW  = $clog2(SETS);              // set index bits
    localparam int TAGW  = XLEN - OFFW - IDXW;        // tag bits
    localparam int LINEW = LINE_BYTES * 8;            // packed line width

    // ---- Tag / valid (fabric, combinational lookup) -------------------------
    logic [SETS-1:0]    valid;
    logic [TAGW-1:0]    tagm  [0:SETS-1];

    // ---- Line data: synchronous-read block RAM (one R port + one W port) -----
    (* ram_style = "block" *)
    logic [LINEW-1:0]   line  [0:SETS-1];

    // ---- Registered fetch address (1-cycle, BRAM-equivalent) ----------------
    logic [XLEN-1:0] addr_q;
    logic            req_q;
    // Raw previous-cycle c_addr (registered unconditionally).  Used only to
    // detect a mid-flight translation change (addr_q vs the address the core
    // presented LAST cycle) without a combinational c_ready->c_addr loop.
    logic [XLEN-1:0] c_addr_q;

    wire [OFFW-1:0]  boff = addr_q[OFFW-1:0];
    wire [IDXW-1:0]  idx  = addr_q[OFFW +: IDXW];
    wire [TAGW-1:0]  tg   = addr_q[OFFW+IDXW +: TAGW];
    wire             hit  = valid[idx] & (tagm[idx] == tg);
    // 4-byte window that crosses the line end (only even offset that does so)
    wire             straddle = (boff == OFFW'(LINE_BYTES-2));
    wire [XLEN-1:0]  line_base = {addr_q[XLEN-1:OFFW], {OFFW{1'b0}}};

    // ---- FSM ----------------------------------------------------------------
    typedef enum logic [1:0] { S_LOOKUP, S_FILL, S_FILL2, S_BYPASS } state_t;
    state_t state;

    logic [IDXW-1:0] fill_idx;
    logic [TAGW-1:0] fill_tag;
    logic [XLEN-1:0] fill_base;

    // ---- Fetch-address register enable --------------------------------------
    // addr_q advances when this fetch completes (c_ready), when a request is
    // (re)presented after an idle gap (resume priming), or when a fill/bypass
    // completes with a request still presented (mid-flight translation re-arm).
    wire addr_q_en = c_ready
                   || (state == S_LOOKUP && c_req && !req_q)
                   || ((state == S_FILL || state == S_BYPASS) && m_done && c_req);

    // ---- BRAM read port (registered output = line_q) ------------------------
    // Hit path: clocked with addr_q_en reading set(c_addr) -- the line being
    // latched into addr_q -- so line_q tracks addr_q in lockstep.  Settle path
    // (S_FILL2): re-read set(addr_q) after a fill, when the written line is
    // readable and addr_q already holds the (re-armed) fill address.
    logic [IDXW-1:0]  rd_set;
    logic             rd_en;
    logic [LINEW-1:0] line_q;

    always_comb begin
        if (state == S_FILL2) begin
            rd_en  = 1'b1;
            rd_set = idx;                       // = addr_q set
        end else begin
            rd_en  = addr_q_en;
            rd_set = c_addr[OFFW +: IDXW];      // set being latched into addr_q
        end
    end

    always_ff @(posedge clk) begin
        if (rd_en) line_q <= line[rd_set];
    end

    // Combinational 32-bit window extract from the registered line read
    wire [31:0] window = line_q[boff*8 +: 32];

    // ---- BRAM write port (line fill beats) ----------------------------------
    integer w;
    always_ff @(posedge clk) begin
        if (state == S_FILL && m_rvalid) begin
            for (w = 0; w < WORDS; w = w + 1)
                if (m_rbeat[WIDXW-1:0] == w[WIDXW-1:0])
                    line[fill_idx][w*32 +: 32] <= m_rdata;
        end
    end

    // ---- Outputs (combinational) --------------------------------------------
    always_comb begin
        unique case (state)
            S_LOOKUP: begin
                c_ready = req_q & ~straddle & hit;
                c_rdata = window;
            end
            S_BYPASS: begin
                // Serve only if the request still targets the address this
                // bypass was launched for.  The MMU may retranslate the SAME
                // fetch_pc to a different physical address mid-flight (e.g. an
                // MRET privilege change or an SFENCE.VMA retranslation), in
                // which case this data belongs to a stale translation and must
                // be dropped; the re-armed lookup below then serves the live
                // address.  Compares against the REGISTERED previous-cycle
                // request (req_q/c_addr_q) -- the contract is "data for the
                // address presented last cycle", and using the live c_addr
                // would create a combinational c_ready -> stall -> c_addr loop.
                // No-op while c_addr is held stable (all bare runs).
                c_ready = m_done & req_q & (addr_q == c_addr_q);
                c_rdata = m_rdata;         // byte-exact window from memory
            end
            default: begin                 // S_FILL / S_FILL2
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

    // ---- Sequential (FSM / tag / valid / addr / counters) -------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_LOOKUP;
            addr_q   <= RST_ADDR[XLEN-1:0];
            c_addr_q <= RST_ADDR[XLEN-1:0];
            req_q    <= 1'b0;
            hit_cnt  <= '0;
            miss_cnt <= '0;
            fill_idx <= '0; fill_tag <= '0; fill_base <= '0;
            valid <= '0;
        end else begin
            // Track the fetch address with the SAME enable the core uses for
            // fetch_pc (advance only when this fetch completes, c_ready).  This
            // keeps addr_q == fetch_pc even when imem_addr transiently changes
            // (a branch/trap redirect) while the I$ holds c_ready=0 during a miss
            // fill -- otherwise addr_q would latch the redirect target and the I$
            // would return its window mis-tagged as the held fetch_pc.
            //
            // EXTRA: also capture on the first cycle a request is (re)presented
            // after an idle gap (state==S_LOOKUP && c_req && !req_q).  Under a VM
            // kernel the MMU withdraws c_req for the duration of a TLB-miss page
            // walk; when it resumes at a new address the c_ready-only enable would
            // leave addr_q one fetch behind, so the next lookup would serve the
            // stale pre-gap line.  This term primes addr_q for that resume.  It is
            // a structural no-op whenever c_req is held continuously (req_q==1
            // every cycle: bare/M-mode, all unit tests, OpenSBI), and never fires
            // during a fill/bypass (state!=S_LOOKUP), so the redirect protection
            // above is preserved.
            //
            // EXTRA-2: re-arm addr_q from the live c_addr when a FILL or BYPASS
            // completes (m_done) with a request still presented.  The physical
            // address of the SAME held fetch_pc can change underneath a multi-
            // cycle fill: an MRET/SRET privilege switch translates the first
            // post-redirect fetch with the stale privilege for one cycle (bare
            // physical), the I$ commits to filling that wrong-translation line,
            // and the correct translation appears on c_addr while the fill is
            // in flight.  Without the re-arm the post-fill re-lookup would serve
            // the stale addr_q line as if it were the live request (this is how
            // a Linux MRET return fetched OpenSBI firmware bytes and panicked).
            // With it, the re-lookup uses the live address: tag mismatch ->
            // proper refill.  When c_addr is held stable across the fill (every
            // bare/M-mode run; any VM fetch without an in-flight translation
            // change) c_addr == addr_q here, so this writes the same value back
            // -- a structural no-op.
            if (addr_q_en)
                addr_q <= c_addr;
            req_q    <= c_req;
            c_addr_q <= c_addr;

            // FENCE.I invalidate (cheap: clear all valid bits).
            if (flush)
                valid <= '0;

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
                    // Beats stream into the BRAM write port (above).
                    if (m_done) begin
                        // FENCE.I during a fill must not validate a stale line.
                        valid[fill_idx] <= ~flush;
                        tagm[fill_idx]  <= fill_tag;
                        state           <= S_FILL2;   // settle: re-read filled line
                    end
                end

                S_FILL2: begin
                    // BRAM read of the freshly filled line is issued this cycle
                    // (rd_en/rd_set above); line_q is valid next cycle, when the
                    // held address re-looks-up in S_LOOKUP and hits.
                    state <= S_LOOKUP;
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
