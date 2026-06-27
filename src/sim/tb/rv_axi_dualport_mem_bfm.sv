// =============================================================================
// rv_axi_dualport_mem_bfm.sv - Shared-memory dual-port AXI4 slave (sim only)
// =============================================================================
// One byte-addressable backing store exposed as TWO AXI4 slave ports over the
// SAME memory image -- the simulation analogue of the real board where the
// instruction and data masters fan into an AXI SmartConnect and reach ONE PS DDR.
// This is what OpenSBI / Linux need: code, data, and page tables all live in the
// same DRAM (fetch over the IF port, load/store + PTW over the data port).
//
//   - Instruction port (i_*): read-only, byte-exact window (ALIGN=0).
//   - Data port (d_*):        read/write, aligned (ALIGN=1).
//   Both read ports support multi-beat INCR bursts (cache line fills).
//   Runtime-programmable per-channel latency (shared knobs).
//
// Initialized from INIT_FILE via $readmemh (objcopy -O verilog, base-relative
// byte addresses -- link at BASE_ADDR and objcopy --adjust-vma=-BASE_ADDR).
// =============================================================================

`default_nettype none
`timescale 1ns / 1ps

module rv_axi_dualport_mem_bfm #(
    parameter int          ADDR_WIDTH = 64,
    parameter int          XLEN       = 64,        // data port width
    parameter int          ID_WIDTH   = 4,
    parameter int          DEPTH      = 1 << 20,   // bytes
    parameter logic [63:0] BASE_ADDR  = 64'h8000_0000,
    parameter              INIT_FILE  = ""
) (
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire  [7:0]              ar_delay,
    input  wire  [7:0]              r_delay,
    input  wire  [7:0]              aw_delay,
    input  wire  [7:0]              w_delay,
    input  wire  [7:0]              b_delay,

    // ---- Data port (read/write, XLEN, aligned) -----------------------------
    input  wire  [ID_WIDTH-1:0]     d_awid,
    input  wire  [ADDR_WIDTH-1:0]   d_awaddr,
    input  wire  [7:0]              d_awlen,
    input  wire  [2:0]              d_awsize,
    input  wire  [1:0]              d_awburst,
    input  wire                     d_awvalid,
    output logic                    d_awready,
    input  wire  [XLEN-1:0]         d_wdata,
    input  wire  [XLEN/8-1:0]       d_wstrb,
    input  wire                     d_wlast,
    input  wire                     d_wvalid,
    output logic                    d_wready,
    output logic [ID_WIDTH-1:0]     d_bid,
    output logic [1:0]              d_bresp,
    output logic                    d_bvalid,
    input  wire                     d_bready,
    input  wire  [ID_WIDTH-1:0]     d_arid,
    input  wire  [ADDR_WIDTH-1:0]   d_araddr,
    input  wire  [7:0]              d_arlen,
    input  wire  [2:0]              d_arsize,
    input  wire  [1:0]              d_arburst,
    input  wire                     d_arvalid,
    output logic                    d_arready,
    output logic [ID_WIDTH-1:0]     d_rid,
    output logic [XLEN-1:0]         d_rdata,
    output logic [1:0]              d_rresp,
    output logic                    d_rlast,
    output logic                    d_rvalid,
    input  wire                     d_rready,

    // ---- Instruction port (read-only, 32-bit, byte-exact) ------------------
    input  wire  [ID_WIDTH-1:0]     i_arid,
    input  wire  [ADDR_WIDTH-1:0]   i_araddr,
    input  wire  [7:0]              i_arlen,
    input  wire  [2:0]              i_arsize,
    input  wire  [1:0]              i_arburst,
    input  wire                     i_arvalid,
    output logic                    i_arready,
    output logic [ID_WIDTH-1:0]     i_rid,
    output logic [31:0]             i_rdata,
    output logic [1:0]              i_rresp,
    output logic                    i_rlast,
    output logic                    i_rvalid,
    input  wire                     i_rready
);

    localparam int DNB = XLEN / 8;     // data-port bytes per beat

    logic [7:0] mem_b [0:DEPTH-1];

    // =========================================================================
    // Optional per-transaction VARIABLE latency (BFM_RANDLAT): model the real
    // board, where the instruction master, the data master and the write channel
    // each see a DIFFERENT, transaction-dependent DDR/SmartConnect latency.  The
    // default fixed shared ar_delay/r_delay make BOTH read ports respond with the
    // SAME latency, so the IF fill and the data/PTW responses are PHASE-LOCKED --
    // they cannot interleave at arbitrary phases the way real concurrent masters
    // do.  Three INDEPENDENT LFSR streams (one per channel) de-phase the ports so
    // the I$-fill-vs-PTW corner the step-8 block fetch hits on hardware is
    // exercised.  Deterministic per BFM_SEED (repeatable repro).  Strict no-op
    // when undefined (lat == the fixed input delay).
    //   lat = base_delay + (lfsr % (BFM_RAND_SPREAD+1))
`ifndef BFM_RAND_SPREAD
  `define BFM_RAND_SPREAD 24
`endif
`ifndef BFM_SEED
  `define BFM_SEED 1
`endif
    logic [15:0] lfsr_ir, lfsr_dr, lfsr_dw;
    function automatic [15:0] lfsr_nxt(input [15:0] s);
        // x^16 + x^14 + x^13 + x^11 + 1 (maximal-length, never all-zero seed)
        return {s[14:0], s[15]^s[13]^s[12]^s[10]};
    endfunction
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr_ir <= 16'(`BFM_SEED) ^ 16'hBEEF;
            lfsr_dr <= 16'(`BFM_SEED) ^ 16'h1234;
            lfsr_dw <= 16'(`BFM_SEED) ^ 16'hA5A5;
        end else begin
            lfsr_ir <= lfsr_nxt(lfsr_ir);
            lfsr_dr <= lfsr_nxt(lfsr_dr);
            lfsr_dw <= lfsr_nxt(lfsr_dw);
        end
    end
    function automatic [7:0] rand_lat(input [7:0] base, input [15:0] s);
`ifdef BFM_RANDLAT
        return base + 8'(s % 16'(`BFM_RAND_SPREAD + 1));
`else
        return base;
`endif
    endfunction

    initial begin
        for (int k = 0; k < DEPTH; k++) mem_b[k] = 8'h0;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem_b);
    end

    function automatic [63:0] base_off(input [ADDR_WIDTH-1:0] a, input bit aln, input int nb);
        logic [63:0] off;
        off = {{(64-ADDR_WIDTH){1'b0}}, a} - BASE_ADDR;
        if (aln) off = off & ~64'(nb - 1);
        return off;
    endfunction

    // =========================================================================
    // Data port read FSM (burst, aligned)
    // =========================================================================
    typedef enum logic [1:0] { R_IDLE, R_ARWAIT, R_LAT, R_DATA } rstate_t;
    rstate_t              d_rstate;
    logic [7:0]           d_rcnt, d_rlen_q, d_rbeat;
    logic [ADDR_WIDTH-1:0] d_raddr_q;
    logic [ID_WIDTH-1:0]  d_rid_q;

    function automatic [XLEN-1:0] d_beat_rd(input [7:0] beat);
        logic [63:0] off; logic [XLEN-1:0] d;
        off = base_off(d_raddr_q, 1'b1, DNB) + 64'(beat) * DNB;
        for (int i = 0; i < DNB; i++) d[i*8 +: 8] = mem_b[off + i];
        return d;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_rstate<=R_IDLE; d_rcnt<='0; d_rlen_q<='0; d_rbeat<='0;
            d_raddr_q<='0; d_rid_q<='0; d_rdata<='0;
        end else case (d_rstate)
            R_IDLE:   if (ser_grant_dr) begin d_raddr_q<=d_araddr; d_rid_q<=d_arid; d_rlen_q<=d_arlen; d_rcnt<=rand_lat(ar_delay,lfsr_dr); d_rstate<=R_ARWAIT; end
            R_ARWAIT: if (d_rcnt==0) begin d_rcnt<=rand_lat(r_delay,lfsr_dr); d_rbeat<=0; d_rstate<=R_LAT; end else d_rcnt<=d_rcnt-8'd1;
            R_LAT:    if (d_rcnt==0) begin d_rdata<=d_beat_rd(8'd0); d_rstate<=R_DATA; end else d_rcnt<=d_rcnt-8'd1;
            R_DATA:   if (d_rready) begin
                          if (d_rbeat==d_rlen_q) d_rstate<=R_IDLE;
                          else begin d_rbeat<=d_rbeat+8'd1; d_rdata<=d_beat_rd(d_rbeat+8'd1); end
                      end
            default:  d_rstate<=R_IDLE;
        endcase
    end
    assign d_arready = (d_rstate==R_ARWAIT) && (d_rcnt==0);
    assign d_rvalid  = (d_rstate==R_DATA);
    assign d_rid     = d_rid_q;
    assign d_rresp   = 2'b00;
    assign d_rlast   = (d_rstate==R_DATA) && (d_rbeat==d_rlen_q);

    // =========================================================================
    // Data port write FSM (single beat, aligned)
    // =========================================================================
    typedef enum logic [2:0] { W_IDLE, W_AWWAIT, W_WWAIT, W_LAT, W_RESP } wstate_t;
    wstate_t              d_wstate;
    logic [7:0]           d_wcnt;
    logic [ADDR_WIDTH-1:0] d_waddr_q;
    logic [ID_WIDTH-1:0]  d_wid_q;
`ifdef BFM_STORE_HASH
    logic [31:0] st_cnt = 32'd0, st_hash = 32'd0;  // differential store-seq trace
`ifndef STLO
`define STLO 32'hFFFF_FFFF
`endif
`endif

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_wstate<=W_IDLE; d_wcnt<='0; d_waddr_q<='0; d_wid_q<='0;
        end else case (d_wstate)
            W_IDLE:   if (ser_grant_dw) begin d_waddr_q<=d_awaddr; d_wid_q<=d_awid; d_wcnt<=rand_lat(aw_delay,lfsr_dw); d_wstate<=W_AWWAIT; end
            W_AWWAIT: if (d_wcnt==0) begin d_wcnt<=rand_lat(w_delay,lfsr_dw); d_wstate<=W_WWAIT; end else d_wcnt<=d_wcnt-8'd1;
            W_WWAIT:  if (d_wcnt==0) begin
                          if (d_wvalid) begin
                              for (int i=0;i<DNB;i++) if (d_wstrb[i]) mem_b[base_off(d_waddr_q,1'b1,DNB)+i] <= d_wdata[i*8 +: 8];
                              d_wcnt<=rand_lat(b_delay,lfsr_dw); d_wstate<=W_LAT;
`ifdef BFM_STORE_HASH
                              // Differential store trace: cumulative hash over the
                              // (addr,strobe,data) write SEQUENCE, printed every N
                              // stores BY INDEX (timing-independent so baseline vs
                              // C-2a are comparable).  First divergent index = the
                              // corrupting store.
                              // Count/hash ONLY stores that actually CHANGE memory
                              // (filter idempotent re-issues of a held store, which
                              // diverge in the transaction stream but not in content).
                              begin
                                  automatic logic changed = 1'b0;
                                  for (int i=0;i<DNB;i++)
                                      if (d_wstrb[i] &&
                                          mem_b[base_off(d_waddr_q,1'b1,DNB)+i] != d_wdata[i*8 +: 8])
                                          changed = 1'b1;
                                  // Pointer filter: only kernel-VA-valued stores
                                  // (d[63:40]==0xffffff) -- skips timing-dependent
                                  // small values (cycle/jiffy counts) that diverge
                                  // benignly under different divide timing.
                                  if (changed && (d_wdata[63:40] == 24'hffffff)) begin
                                      st_cnt  <= st_cnt + 1;
                                      st_hash <= (st_hash ^ {d_waddr_q[31:0], d_wstrb}
                                                  ^ d_wdata[31:0] ^ d_wdata[63:32]) * 32'h01000193;
                                      if (st_cnt % 32'd20000 == 0)
                                          $display("[STHASH] n=%0d hash=%08h", st_cnt, st_hash);
                                      if (st_cnt >= `STLO && st_cnt <= `STLO + 22000)
                                          $display("[ST] n=%0d a=%08h strb=%02h d=%016h",
                                                   st_cnt, d_waddr_q[31:0], d_wstrb, d_wdata);
                                  end
                              end
`endif
                          end
                      end else d_wcnt<=d_wcnt-8'd1;
            W_LAT:    if (d_wcnt==0) d_wstate<=W_RESP; else d_wcnt<=d_wcnt-8'd1;
            W_RESP:   if (d_bready) d_wstate<=W_IDLE;
            default:  d_wstate<=W_IDLE;
        endcase
    end
    assign d_awready = (d_wstate==W_AWWAIT) && (d_wcnt==0);
    assign d_wready  = (d_wstate==W_WWAIT)  && (d_wcnt==0);
    assign d_bvalid  = (d_wstate==W_RESP);
    assign d_bid     = d_wid_q;
    assign d_bresp   = 2'b00;

    // =========================================================================
    // Instruction port read FSM (burst, byte-exact, read-only)
    // =========================================================================
    rstate_t              i_rstate;
    logic [7:0]           i_rcnt, i_rlen_q, i_rbeat;
    logic [ADDR_WIDTH-1:0] i_raddr_q;
    logic [ID_WIDTH-1:0]  i_rid_q;

    // =========================================================================
    // Optional single-DDR serialization (BFM_SERIALIZE): model the real board's
    // AXI SmartConnect -> ONE PS DDR, where the instruction master, the data
    // master and the write channel cannot all reach DRAM at once.  The default
    // (independent ports) lets I$ line fills run in PARALLEL with data/PTW
    // traffic -- which the board CANNOT do -- hiding the I$-vs-data contention
    // suspected in the netlink atomic_dec loss (memory zybo-netlink-atomic-bug).
    // When defined, at most ONE of {data-read, data-write, instruction-read} is
    // in flight at a time; a fixed priority (data-read > data-write >
    // instruction-read) breaks simultaneous requests so exactly one transaction
    // is accepted per idle cycle.  These grants gate the IDLE->accept edges of
    // the three FSMs below; everything else is unchanged (strict no-op when the
    // macro is undefined: grant == the channel's own *valid).
    wire ser_grant_dr, ser_grant_dw, ser_grant_ir;
`ifdef BFM_SERIALIZE
    wire ser_any_busy = (d_rstate != R_IDLE) || (d_wstate != W_IDLE)
                        || (i_rstate != R_IDLE);
    assign ser_grant_dr = !ser_any_busy && d_arvalid;
    assign ser_grant_dw = !ser_any_busy && !d_arvalid && d_awvalid;
    assign ser_grant_ir = !ser_any_busy && !d_arvalid && !d_awvalid && i_arvalid;
`else
    assign ser_grant_dr = d_arvalid;
    assign ser_grant_dw = d_awvalid;
    assign ser_grant_ir = i_arvalid;
`endif

    function automatic [31:0] i_beat_rd(input [7:0] beat);
        logic [63:0] off; logic [31:0] d;
        off = base_off(i_raddr_q, 1'b0, 4) + 64'(beat) * 4;
        for (int i = 0; i < 4; i++) d[i*8 +: 8] = mem_b[off + i];
        return d;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_rstate<=R_IDLE; i_rcnt<='0; i_rlen_q<='0; i_rbeat<='0;
            i_raddr_q<='0; i_rid_q<='0; i_rdata<='0;
        end else case (i_rstate)
            R_IDLE:   if (ser_grant_ir) begin i_raddr_q<=i_araddr; i_rid_q<=i_arid; i_rlen_q<=i_arlen; i_rcnt<=rand_lat(ar_delay,lfsr_ir); i_rstate<=R_ARWAIT; end
            R_ARWAIT: if (i_rcnt==0) begin i_rcnt<=rand_lat(r_delay,lfsr_ir); i_rbeat<=0; i_rstate<=R_LAT; end else i_rcnt<=i_rcnt-8'd1;
            R_LAT:    if (i_rcnt==0) begin i_rdata<=i_beat_rd(8'd0); i_rstate<=R_DATA; end else i_rcnt<=i_rcnt-8'd1;
            R_DATA:   if (i_rready) begin
                          if (i_rbeat==i_rlen_q) i_rstate<=R_IDLE;
                          else begin i_rbeat<=i_rbeat+8'd1; i_rdata<=i_beat_rd(i_rbeat+8'd1); end
                      end
            default:  i_rstate<=R_IDLE;
        endcase
    end
    assign i_arready = (i_rstate==R_ARWAIT) && (i_rcnt==0);
    assign i_rvalid  = (i_rstate==R_DATA);
    assign i_rid     = i_rid_q;
    assign i_rresp   = 2'b00;
    assign i_rlast   = (i_rstate==R_DATA) && (i_rbeat==i_rlen_q);

endmodule

`default_nettype wire
