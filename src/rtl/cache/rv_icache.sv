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
/// served as a 1-cycle HIT from BOTH adjacent lines when each is cached: a second
/// registered read port (@c line_q2, set @c idx+1) supplies the high half while
/// @c line_q supplies the low half.  A cold straddle (either line not yet cached)
/// fills the missing line(s) through the normal @c S_FILL/@c S_FILL2 path (up to
/// two sequential line fills) and then hits -- there is NO uncached bypass.  This
/// keeps every memory access an aligned line burst and removes the multi-cycle
/// uncached fetch that otherwise turned a redirect whose target is a straddle
/// address into a fetch/redirect squash race.
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

    // ---- Line data: synchronous-read block RAM (two R ports + one W port) ----
    // The two read ports (line_q at set idx, line_q2 at set idx+1) let a straddle
    // window be assembled from two adjacent lines; Xilinx replicates the BRAM.
    (* ram_style = "block" *)
    logic [LINEW-1:0]   line  [0:SETS-1];

    // ---- Registered fetch address (1-cycle, BRAM-equivalent) ----------------
    logic [XLEN-1:0] addr_q;
    logic            req_q;
    // fill_unserved: 1 = a line fill for the held addr_q has COMPLETED but addr_q
    // has not been served yet (c_ready never fired for it).  This happens when the
    // MMU withdraws c_req (an IF-TLB miss / PTW for the NEXT, FTQ-pre-generated
    // address) WHILE this line is being filled: req_q drops, so the post-fill
    // S_LOOKUP cannot serve.  It must NOT let the resume-prime advance addr_q to
    // the next address (that would SKIP this completed-but-unserved fetch), so it
    // gates the resume-prime term below.  Cleared the moment addr_q is served.
    logic            fill_unserved;

    wire [OFFW-1:0]  boff = addr_q[OFFW-1:0];
    wire [IDXW-1:0]  idx  = addr_q[OFFW +: IDXW];
    wire [TAGW-1:0]  tg   = addr_q[OFFW+IDXW +: TAGW];
    wire             hit  = valid[idx] & (tagm[idx] == tg);
    // 4-byte window that crosses the line end (only even offset that does so)
    wire             straddle = (boff == OFFW'(LINE_BYTES-2));
    wire [XLEN-1:0]  line_base = {addr_q[XLEN-1:OFFW], {OFFW{1'b0}}};

    // ---- Straddle (line-crossing window) 2-line hit -------------------------
    // A line-crossing fetch window's low 16 bits live in the TOP of line[idx] and
    // its high 16 bits in the BOTTOM of the NEXT line (idx+1; tag +1 when the set
    // index wraps).  When BOTH adjacent lines are cached the window is served as a
    // 1-cycle HIT from the two registered line reads, exactly like an aligned hit.
    // A cold straddle (either line not yet cached) is resolved by filling the
    // missing line(s) through the SAME proven S_FILL/S_FILL2 path a normal miss
    // uses (up to two sequential line fills), after which the held address re-
    // looks-up and hits.  There is NO uncached/multi-cycle-bypass path: this
    // removes the "multi-cycle uncached redirect-target fetch" that turned a
    // redirect whose target is a straddle address into a fetch/redirect squash
    // race (OpenSBI/Linux livelock), and makes every memory access an aligned
    // line burst (no unaligned ARADDR on real S_AXI_HP).
    wire [IDXW-1:0]  idx_p1  = idx + IDXW'(1);
    wire [TAGW-1:0]  tg_next = (idx == IDXW'(SETS-1)) ? (tg + TAGW'(1)) : tg;
    wire             hit2    = valid[idx_p1] & (tagm[idx_p1] == tg_next);
    wire             straddle_hit = straddle & hit & hit2;

    // ---- FSM ----------------------------------------------------------------
    typedef enum logic [1:0] { S_LOOKUP, S_FILL, S_FILL2 } state_t;
    state_t state;

    logic [IDXW-1:0] fill_idx;
    logic [TAGW-1:0] fill_tag;
    logic [XLEN-1:0] fill_base;

    // ---- Fetch-address register enable --------------------------------------
    // addr_q advances when this fetch completes (c_ready) or when a request is
    // (re)presented after an idle gap (resume priming).
    //
    // 50 MHz step 8 (FTQ/block fetch): the old EXTRA-2 term
    // (state==S_FILL && m_done && c_req) re-armed addr_q from the core's LIVE
    // c_addr at fill completion.  That required the core to re-present the MISSED
    // address for the whole fill (imem_addr = ~imem_ready ? fetch_pc : seq_pc),
    // which is exactly the combinational ~imem_ready dependence that put the I$
    // fetch loop (addr_q -> hit -> imem_ready -> core fetch addr -> MMU -> addr_q)
    // on the binding 50 MHz path.  Removing the term makes the I$ HOLD its own
    // addr_q (= the missed physical address, latched when the miss was accepted)
    // across the fill, so S_FILL2 re-reads line[idx(addr_q)] and S_LOOKUP re-looks
    // up the SAME missed address -> hit.  The core no longer needs to re-present
    // the missed address: imem_addr becomes a pure register (the block fetch
    // pres/bfpc engine), breaking the loop.  The MRET/SRET mid-fill re-translation
    // case the EXTRA-2 term used to cover is now handled by the registered redirect
    // re-presenting the target after the privilege/SATP change settles (the fill of
    // the stale-translation line completes but its line is re-looked-up under the
    // new PA after the redirect: tag mismatch -> proper refill).  Validated by full
    // Linux NET=y boot (the same MRET-return path that used to need EXTRA-2).
    wire addr_q_en = c_ready
                   || (state == S_LOOKUP && c_req && !req_q && !fill_unserved);

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

    // Second registered read port (set idx+1) for the straddle window.  Reads in
    // lockstep with line_q (same rd_en), one set ahead, so at the serve cycle
    // line_q2 == line[idx+1].  1W2R -> Xilinx replicates the (small) line BRAM.
    logic [LINEW-1:0] line_q2;
    wire  [IDXW-1:0]  rd_set2 = rd_set + IDXW'(1);
    always_ff @(posedge clk) begin
        if (rd_en) line_q2 <= line[rd_set2];
    end

    // Combinational 32-bit window extract from the registered line read
    wire [31:0] window = line_q[boff*8 +: 32];
    // Straddle window: low 16b = top of this line, high 16b = bottom of next line
    // (addr_q[1:0]==2'b10 for any straddle).
    wire [31:0] window_straddle = {line_q2[15:0], line_q[LINEW-1 -: 16]};

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
    // Only S_LOOKUP serves a fetch: an aligned/in-line hit OR a 2-line straddle
    // hit (both adjacent lines cached).  c_rdata is don't-care while c_ready=0.
    always_comb begin
        c_ready = (state == S_LOOKUP) & req_q & ((~straddle & hit) | straddle_hit);
        c_rdata = straddle ? window_straddle : window;
    end

    // Memory side: only aligned line-fill bursts (no uncached/unaligned reads).
    always_comb begin
        m_req  = (state == S_FILL);
        m_addr = fill_base;
        m_len  = 8'(WORDS-1);
    end

    // ---- Sequential (FSM / tag / valid / addr / counters) -------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_LOOKUP;
            addr_q   <= RST_ADDR[XLEN-1:0];
            req_q    <= 1'b0;
            hit_cnt  <= '0;
            miss_cnt <= '0;
            fill_idx <= '0; fill_tag <= '0; fill_base <= '0;
            valid <= '0;
            fill_unserved <= 1'b0;
        end else begin
            // Track a completed-but-unserved fill so the resume-prime cannot skip
            // it (see addr_q_en / fill_unserved comments).  Set when a fill
            // finishes (S_FILL m_done), cleared the cycle addr_q is served.
            if (c_ready)                       fill_unserved <= 1'b0;
            else if (state == S_FILL && m_done) fill_unserved <= 1'b1;
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
            // during a fill (state!=S_LOOKUP), so the redirect protection
            // above is preserved.
            //
            // (The old EXTRA-2 m_done re-arm term was removed in 50 MHz step 8;
            // see the addr_q_en comment above.  addr_q now HOLDS its own missed
            // address across the fill, so the core's block-fetch engine no longer
            // re-presents the missed address and imem_addr can be a pure register.
            // The MRET/SRET mid-fill re-translation case is covered by the
            // registered redirect re-presenting the target after the privilege
            // change settles: the stale-translation line fill completes but is
            // re-looked-up under the new PA -> tag mismatch -> proper refill.)
            if (addr_q_en)
                addr_q <= c_addr;
            req_q    <= c_req;

            // FENCE.I invalidate (cheap: clear all valid bits).
            if (flush)
                valid <= '0;

            unique case (state)
                S_LOOKUP: begin
                    if (req_q) begin
                        if (straddle) begin
                            if (hit && hit2) begin
                                // line-crossing window served this cycle from both
                                // cached lines (combinationally); stay in S_LOOKUP.
                                hit_cnt <= hit_cnt + 32'd1;
                            end else if (!hit) begin
                                // cold straddle: fill THIS line first (then re-eval).
                                fill_idx  <= idx;
                                fill_tag  <= tg;
                                fill_base <= line_base;
                                miss_cnt  <= miss_cnt + 32'd1;
                                state     <= S_FILL;
                            end else begin
                                // this line cached, NEXT line missing: fill it; the
                                // re-lookup then sees hit && hit2 and serves.
                                fill_idx  <= idx_p1;
                                fill_tag  <= tg_next;
                                fill_base <= line_base + XLEN'(LINE_BYTES);
                                miss_cnt  <= miss_cnt + 32'd1;
                                state     <= S_FILL;
                            end
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

                default: state <= S_LOOKUP;
            endcase
        end
    end

endmodule

`default_nettype wire
