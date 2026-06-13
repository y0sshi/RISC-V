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
/// Design (BRAM-backed data array):
///   - **Direct-mapped**, parameterized SETS x LINE_BYTES.
///   - The DATA array is a true **synchronous-read block RAM** (one read port +
///     one byte-write port) so it maps to Xilinx RAMB36/RAMB18 instead of LUTRAM
///     / fabric flip-flops.  Tag/valid stay in fabric (small, combinational
///     lookup).
///   - **Load HIT**: tag/valid are checked combinationally in the access cycle;
///     @c c_wait stays low and the BRAM read register presents the word the NEXT
///     cycle (BRAM-identical 1-cycle latency).
///   - **Load MISS**: @c c_wait is held while a whole line is fetched in one AXI
///     burst, then a one-cycle RE-LOOKUP reads the requested word out of the BRAM
///     (the write port cannot be read on the same cycle it is written, so the
///     read is deferred one cycle past the fill -- a single extra MISS cycle; the
///     hit path is unaffected).
///   - **Write-through, write-no-allocate**: every store is forwarded to memory
///     (single-beat AXI write) and, IF the line is currently cached, the cached
///     word is updated in place via the BRAM byte-write port (keeps cache ==
///     memory).  A store that misses does NOT allocate.  Memory therefore always
///     holds the latest value, so the cache is always coherent with it (single
///     hart).
///
/// The cache is transparent to AMO / LR-SC and misaligned 2-phase accesses: the
/// core decomposes those into ordinary word loads/stores at this interface, each
/// of which honors the @c c_wait / @c c_rdata contract.
///
/// Contract (matches the AXI bridge the core was validated against):
///   - @c c_wait rises combinationally the cycle a miss/store is presented and
///     drops on the completion cycle; the core freezes the access in MEM while
///     @c c_wait is high (drives this onto @c dmem_wait).
///   - @c c_rdata is the REGISTERED BRAM read output, held until the next load
///     completes, so the WB stage (which samples one cycle after the access) and
///     the misaligned phase-0 capture both see stable data.
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
    localparam int DEPTH = SETS * WORDS;              // BRAM depth (one word/entry)
    localparam int AW    = IDXW + WIDXW;              // BRAM address width

    // ---- Tag / valid (fabric, combinational lookup) -------------------------
    logic [SETS-1:0]    valid;
    logic [TAGW-1:0]    tagm  [0:SETS-1];

    // ---- Data array: synchronous-read block RAM (one R port + one W port) ----
    (* ram_style = "block" *)
    logic [XLEN-1:0]    data  [0:DEPTH-1];

    // ---- Address decode (current request) -----------------------------------
    // The set index is the LSBs of the translated physical data address
    // (mmu_dmem_pa).  In RV64 it drove ~880 loads (valid[idx]/tagm[idx] 64:1
    // muxes + the BRAM word address), which Vivado synthesis flagged as the
    // single highest-fanout net on the worst timing path.  max_fanout lets the
    // tool replicate the index buffer so each copy drives a bounded subset --
    // a pure physical hint, functionally a no-op (ignored by iverilog/Verilator).
    (* max_fanout = 64 *)
    wire [IDXW-1:0]  idx  = c_addr[OFFW +: IDXW];
    wire [TAGW-1:0]  tg   = c_addr[OFFW+IDXW +: TAGW];
    wire [WIDXW-1:0] wsel = c_addr[BYTEW +: WIDXW];
    wire             hit  = c_req & valid[idx] & (tagm[idx] == tg);
    wire [XLEN-1:0]  line_base = {c_addr[XLEN-1:OFFW], {OFFW{1'b0}}};

    // ---- FSM ----------------------------------------------------------------
    typedef enum logic [1:0] { S_LOOKUP, S_FILL, S_RELOOKUP, S_WRITE } state_t;
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

    // ---- c_wait (combinational) ---------------------------------------------
    // A load HIT keeps c_wait low (1-cycle BRAM read).  A store or load MISS
    // raises it until the access (and, for a load miss, the post-fill re-lookup)
    // completes.
    always_comb begin
        unique case (state)
            S_LOOKUP:   c_wait = c_req & (c_we | ~hit);  // store, or load miss
            S_FILL:     c_wait = 1'b1;                   // held; re-lookup ends it
            S_RELOOKUP: c_wait = 1'b0;                   // requested word read this cycle
            S_WRITE:    c_wait = ~m_done;                // drop on the write response
            default:    c_wait = 1'b0;
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

    // ---- BRAM read port (registered output = c_rdata) -----------------------
    // Read on a load HIT (in the access cycle) or on the post-fill RE-LOOKUP.
    // The address is the live request word for a hit, or the filled word for the
    // re-lookup.  rdata_q is the BRAM output register; held when not enabled, so
    // it satisfies the "data stable until the next load completes" contract.
    logic            rd_en;
    logic [AW-1:0]   rd_addr;
    logic [XLEN-1:0] rdata_q;

    always_comb begin
        if (state == S_RELOOKUP) begin
            rd_en   = 1'b1;
            rd_addr = {fill_idx, fill_wsel};
        end else begin
            rd_en   = (state == S_LOOKUP) & c_req & ~c_we & hit;
            rd_addr = {idx, wsel};
        end
    end

    always_ff @(posedge clk) begin
        if (rd_en) rdata_q <= data[rd_addr];
    end
    assign c_rdata = rdata_q;

    // ---- BRAM write port (line fill beats + write-through hit updates) -------
    // Mutually exclusive in time: fill beats arrive only in S_FILL; a store
    // update commits only on the S_WRITE completion cycle.
    logic              wr_en;
    logic [AW-1:0]     wr_addr;
    logic [XLEN-1:0]   wr_data;
    logic [XLEN/8-1:0] wr_be;

    always_comb begin
        wr_en   = 1'b0;
        wr_addr = {fill_idx, fill_wsel};
        wr_data = m_rdata;
        wr_be   = '1;
        if (state == S_FILL && m_rvalid) begin
            wr_en   = 1'b1;
            wr_addr = {fill_idx, m_rbeat[WIDXW-1:0]};
            wr_data = m_rdata;
            wr_be   = '1;                         // full word per beat
        end else if (state == S_WRITE && m_done && st_hit) begin
            wr_en   = 1'b1;
            wr_addr = {st_idx, st_wsel};
            wr_data = st_wdata;
            wr_be   = st_wstrb;                   // byte-enabled store update
        end
    end

    integer b;
    always_ff @(posedge clk) begin
        if (wr_en) begin
            for (b = 0; b < XLEN/8; b = b + 1)
                if (wr_be[b])
                    data[wr_addr][b*8 +: 8] <= wr_data[b*8 +: 8];
        end
    end

    // ---- FSM / tag / valid / counters (fabric) ------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_LOOKUP;
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
                            hit_cnt <= hit_cnt + 32'd1;  // word read by BRAM port
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
                    // Beats stream into the BRAM write port (above).  On the
                    // completion cycle the line is valid; defer the load result to
                    // a one-cycle re-lookup (the just-written word cannot be read
                    // out of the same BRAM on the cycle it is written).
                    if (m_done) begin
                        valid[fill_idx] <= 1'b1;
                        tagm[fill_idx]  <= fill_tag;
                        state           <= S_RELOOKUP;
                    end
                end

                S_RELOOKUP: begin
                    // BRAM read of {fill_idx,fill_wsel} is issued this cycle; the
                    // word lands in rdata_q next cycle.  c_wait is already low.
                    state <= S_LOOKUP;
                end

                S_WRITE: begin
                    if (m_done) begin
                        // Cached word is updated by the BRAM write port (above).
                        state <= S_LOOKUP;
                    end
                end

                default: state <= S_LOOKUP;
            endcase
        end
    end

endmodule

`default_nettype wire
