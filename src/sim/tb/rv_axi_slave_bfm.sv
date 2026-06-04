// =============================================================================
// rv_axi_slave_bfm.sv - AXI4 slave memory behavioral model (simulation only)
// =============================================================================
// A byte-addressable memory exposed as a single AXI4 slave, with RUNTIME
// programmable latency and handshake backpressure so a testbench can stress a
// master (rv_axi_bridge) under 0 / 1 / N / variable latency.
//
// Supported subset (matches rv_axi_bridge):
//   - Single beat (AxLEN ignored beyond beat 0; WLAST/RLAST = 1).
//   - Independent read and write FSMs (concurrent read/write allowed).
//   - Byte-enable writes via WSTRB.
//
// Latency / backpressure knobs (inputs, sampled when a channel becomes active):
//   ar_delay : cycles ARVALID is held before ARREADY is asserted.
//   r_delay  : cycles after AR accept before RVALID is asserted (read latency).
//   aw_delay : cycles AWVALID is held before AWREADY is asserted.
//   w_delay  : cycles WVALID is held before WREADY is asserted.
//   b_delay  : cycles after W accept before BVALID is asserted (write latency).
//
// Addressing: byte_off = (addr - BASE_ADDR), optionally aligned to DATA_WIDTH/8
// when ALIGN=1 (data port).  ALIGN=0 returns the DATA_WIDTH window starting at
// the exact byte address (instruction port, mirrors rv_unified_mem port A).
// =============================================================================

`default_nettype none

module rv_axi_slave_bfm #(
    parameter int           ADDR_WIDTH = 32,
    parameter int           DATA_WIDTH = 32,
    parameter int           ID_WIDTH   = 4,
    parameter int           DEPTH      = 65536,        // 32-bit words -> *4 bytes
    parameter logic [63:0]  BASE_ADDR  = 64'h8000_0000,
    parameter               INIT_FILE  = "",
    parameter bit           ALIGN      = 1'b1          // 1=data port, 0=instr port
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // Latency / backpressure knobs
    input  wire  [7:0]              ar_delay,
    input  wire  [7:0]              r_delay,
    input  wire  [7:0]              aw_delay,
    input  wire  [7:0]              w_delay,
    input  wire  [7:0]              b_delay,

    // AXI4 slave: write address
    input  wire  [ID_WIDTH-1:0]     awid,
    input  wire  [ADDR_WIDTH-1:0]   awaddr,
    input  wire  [7:0]              awlen,
    input  wire  [2:0]              awsize,
    input  wire  [1:0]              awburst,
    input  wire                     awvalid,
    output logic                    awready,

    // AXI4 slave: write data
    input  wire  [DATA_WIDTH-1:0]   wdata,
    input  wire  [DATA_WIDTH/8-1:0] wstrb,
    input  wire                     wlast,
    input  wire                     wvalid,
    output logic                    wready,

    // AXI4 slave: write response
    output logic [ID_WIDTH-1:0]     bid,
    output logic [1:0]              bresp,
    output logic                    bvalid,
    input  wire                     bready,

    // AXI4 slave: read address
    input  wire  [ID_WIDTH-1:0]     arid,
    input  wire  [ADDR_WIDTH-1:0]   araddr,
    input  wire  [7:0]              arlen,
    input  wire  [2:0]              arsize,
    input  wire  [1:0]              arburst,
    input  wire                     arvalid,
    output logic                    arready,

    // AXI4 slave: read data
    output logic [ID_WIDTH-1:0]     rid,
    output logic [DATA_WIDTH-1:0]   rdata,
    output logic [1:0]              rresp,
    output logic                    rlast,
    output logic                    rvalid,
    input  wire                     rready
);

    localparam int MEM_BYTES  = DEPTH * 4;
    localparam int NB         = DATA_WIDTH / 8;   // bytes per beat

    logic [7:0] mem_b [0:MEM_BYTES-1];

    initial begin
        for (int i = 0; i < MEM_BYTES; i++) mem_b[i] = 8'h0;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem_b);
    end

    // Byte offset helper (aligned for data port, exact for instruction port)
    function automatic [63:0] byte_off(input [ADDR_WIDTH-1:0] a);
        logic [63:0] off;
        off = {{(64-ADDR_WIDTH){1'b0}}, a} - BASE_ADDR;
        if (ALIGN)
            off = off & ~64'(NB - 1);
        return off;
    endfunction

    // =========================================================================
    // Read FSM (supports multi-beat INCR bursts: arlen+1 beats)
    // =========================================================================
    typedef enum logic [1:0] { R_IDLE, R_ARWAIT, R_LAT, R_DATA } rstate_t;
    rstate_t             rstate;
    logic [7:0]          rcnt;
    logic [ADDR_WIDTH-1:0] raddr_q;
    logic [ID_WIDTH-1:0] rid_q;
    logic [7:0]          rlen_q;   // latched ARLEN (beats - 1)
    logic [7:0]          rbeat;    // current beat index

    // Combinational backing-store read for a given beat of the current burst.
    function automatic [DATA_WIDTH-1:0] beat_rd(input [7:0] beat);
        logic [63:0] off;
        logic [DATA_WIDTH-1:0] d;
        off = byte_off(raddr_q) + 64'(beat) * NB;
        for (int i = 0; i < NB; i++)
            d[i*8 +: 8] = mem_b[off + i];
        return d;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate  <= R_IDLE;
            rcnt    <= '0;
            raddr_q <= '0;
            rid_q   <= '0;
            rlen_q  <= '0;
            rbeat   <= '0;
            rdata   <= '0;
        end else begin
            case (rstate)
                R_IDLE: begin
                    if (arvalid) begin
                        raddr_q <= araddr;
                        rid_q   <= arid;
                        rlen_q  <= arlen;
                        rcnt    <= ar_delay;
                        rstate  <= R_ARWAIT;
                    end
                end
                R_ARWAIT: begin
                    // hold ARVALID for ar_delay cycles, then accept
                    if (rcnt == 0) begin
                        rcnt   <= r_delay;
                        rbeat  <= '0;
                        rstate <= R_LAT;
                    end else begin
                        rcnt <= rcnt - 8'd1;
                    end
                end
                R_LAT: begin
                    if (rcnt == 0) begin
                        // latch first beat
                        rdata  <= beat_rd(8'd0);
                        rstate <= R_DATA;
                    end else begin
                        rcnt <= rcnt - 8'd1;
                    end
                end
                R_DATA: begin
                    // stream beats back-to-back after the initial read latency
                    if (rready) begin
                        if (rbeat == rlen_q) begin
                            rstate <= R_IDLE;
                        end else begin
                            rbeat <= rbeat + 8'd1;
                            rdata <= beat_rd(rbeat + 8'd1);
                        end
                    end
                end
                default: rstate <= R_IDLE;
            endcase
        end
    end

    assign arready = (rstate == R_ARWAIT) && (rcnt == 0);
    assign rvalid  = (rstate == R_DATA);
    assign rid     = rid_q;
    assign rresp   = 2'b00;   // OKAY
    assign rlast   = (rstate == R_DATA) && (rbeat == rlen_q);

    // =========================================================================
    // Write FSM
    // =========================================================================
    typedef enum logic [2:0] { W_IDLE, W_AWWAIT, W_WWAIT, W_LAT, W_RESP } wstate_t;
    wstate_t             wstate;
    logic [7:0]          wcnt;
    logic [ADDR_WIDTH-1:0] waddr_q;
    logic [ID_WIDTH-1:0] wid_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wstate  <= W_IDLE;
            wcnt    <= '0;
            waddr_q <= '0;
            wid_q   <= '0;
        end else begin
            case (wstate)
                W_IDLE: begin
                    if (awvalid) begin
                        waddr_q <= awaddr;
                        wid_q   <= awid;
                        wcnt    <= aw_delay;
                        wstate  <= W_AWWAIT;
                    end
                end
                W_AWWAIT: begin
                    if (wcnt == 0) begin
                        wcnt   <= w_delay;
                        wstate <= W_WWAIT;
                    end else begin
                        wcnt <= wcnt - 8'd1;
                    end
                end
                W_WWAIT: begin
                    // hold WVALID for w_delay cycles, then accept + commit write
                    if (wcnt == 0) begin
                        if (wvalid) begin
                            for (int i = 0; i < NB; i++)
                                if (wstrb[i])
                                    mem_b[byte_off(waddr_q) + i] <= wdata[i*8 +: 8];
                            wcnt   <= b_delay;
                            wstate <= W_LAT;
                        end
                    end else begin
                        wcnt <= wcnt - 8'd1;
                    end
                end
                W_LAT: begin
                    if (wcnt == 0) wstate <= W_RESP;
                    else           wcnt   <= wcnt - 8'd1;
                end
                W_RESP: begin
                    if (bready) wstate <= W_IDLE;
                end
                default: wstate <= W_IDLE;
            endcase
        end
    end

    assign awready = (wstate == W_AWWAIT) && (wcnt == 0);
    assign wready  = (wstate == W_WWAIT)  && (wcnt == 0);
    assign bvalid  = (wstate == W_RESP);
    assign bid     = wid_q;
    assign bresp   = 2'b00;   // OKAY

endmodule

`default_nettype wire
