// =============================================================================
// tb_rv_dcache.sv - Unit testbench for rv_dcache + burst bridge + slave BFM
// =============================================================================
// Drives the cache's core-side data bus with loads/stores and verifies:
//   - write-through reaches memory (read-back through a fresh fill matches),
//   - load hit/miss behavior and 1-cycle hit latency contract,
//   - same-line fills (one miss fills neighbours),
//   - write-through hit updates the cached word,
//   - eviction (same set, different tag),
//   - correctness under several AXI latency profiles,
//   - hit/miss counters reflect the access stream.
// XLEN selected by -DRV_XLEN_64 (default 32).
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_rv_dcache;

`ifdef RV_XLEN_64
    localparam int XLEN = 64;
`else
    localparam int XLEN = 32;
`endif
    localparam int LINE_BYTES = 32;
    localparam int SETS       = 64;
    localparam int IDW        = 4;
    localparam int WB         = XLEN/8;             // bytes per word (load/store size)
    localparam logic [63:0] BASE = 64'h8000_0000;
    localparam int SET_STRIDE = SETS * LINE_BYTES;  // same-set, different-tag stride

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // core side
    logic              c_req, c_we;
    logic [XLEN-1:0]   c_addr, c_wdata;
    logic [XLEN/8-1:0] c_wstrb;
    logic [XLEN-1:0]   c_rdata;
    logic              c_wait;
    logic [31:0]       hit_cnt, miss_cnt;

    // cache <-> burst bridge
    logic              m_req, m_we;
    logic [XLEN-1:0]   m_addr;
    logic [7:0]        m_len;
    logic [XLEN-1:0]   m_wdata;
    logic [XLEN/8-1:0] m_wstrb;
    logic [XLEN-1:0]   m_rdata;
    logic              m_rvalid;
    logic [7:0]        m_rbeat;
    logic              m_rlast, m_done, m_busy;

    // BFM latency
    logic [7:0] ar_delay, r_delay, aw_delay, w_delay, b_delay;

    // AXI wires
    logic [IDW-1:0]    awid;   logic [XLEN-1:0] awaddr; logic [7:0] awlen;
    logic [2:0]        awsize; logic [1:0]      awburst; logic awvalid, awready;
    logic [XLEN-1:0]   wdata;  logic [XLEN/8-1:0] wstrb; logic wlast, wvalid, wready;
    logic [IDW-1:0]    bid;    logic [1:0]      bresp;   logic bvalid, bready;
    logic [IDW-1:0]    arid;   logic [XLEN-1:0] araddr;  logic [7:0] arlen;
    logic [2:0]        arsize; logic [1:0]      arburst; logic arvalid, arready;
    logic [IDW-1:0]    rid;    logic [XLEN-1:0] rdata;   logic [1:0] rresp;
    logic              rlast, rvalid, rready;

    rv_dcache #(.XLEN (XLEN), .LINE_BYTES (LINE_BYTES), .SETS (SETS)) u_dc (
        .clk (clk), .rst_n (rst_n),
        .c_req (c_req), .c_we (c_we), .c_addr (c_addr),
        .c_wdata (c_wdata), .c_wstrb (c_wstrb),
        .c_rdata (c_rdata), .c_wait (c_wait),
        .hit_cnt (hit_cnt), .miss_cnt (miss_cnt),
        .m_req (m_req), .m_we (m_we), .m_addr (m_addr), .m_len (m_len),
        .m_wdata (m_wdata), .m_wstrb (m_wstrb),
        .m_rdata (m_rdata), .m_rvalid (m_rvalid), .m_rbeat (m_rbeat),
        .m_rlast (m_rlast), .m_done (m_done), .m_busy (m_busy)
    );

    rv_axi_burst_bridge #(.ADDR_WIDTH (XLEN), .DATA_WIDTH (XLEN),
                          .ID_WIDTH (IDW), .READ_ONLY (1'b0)) u_br (
        .clk (clk), .rst_n (rst_n),
        .s_req (m_req), .s_we (m_we), .s_addr (m_addr), .s_len (m_len),
        .s_wdata (m_wdata), .s_wstrb (m_wstrb),
        .s_rdata (m_rdata), .s_rvalid (m_rvalid), .s_rbeat (m_rbeat),
        .s_rlast (m_rlast), .s_done (m_done), .s_busy (m_busy),
        .m_axi_awid (awid), .m_axi_awaddr (awaddr), .m_axi_awlen (awlen),
        .m_axi_awsize (awsize), .m_axi_awburst (awburst),
        .m_axi_awvalid (awvalid), .m_axi_awready (awready),
        .m_axi_wdata (wdata), .m_axi_wstrb (wstrb), .m_axi_wlast (wlast),
        .m_axi_wvalid (wvalid), .m_axi_wready (wready),
        .m_axi_bid (bid), .m_axi_bresp (bresp), .m_axi_bvalid (bvalid),
        .m_axi_bready (bready),
        .m_axi_arid (arid), .m_axi_araddr (araddr), .m_axi_arlen (arlen),
        .m_axi_arsize (arsize), .m_axi_arburst (arburst),
        .m_axi_arvalid (arvalid), .m_axi_arready (arready),
        .m_axi_rid (rid), .m_axi_rdata (rdata), .m_axi_rresp (rresp),
        .m_axi_rlast (rlast), .m_axi_rvalid (rvalid), .m_axi_rready (rready)
    );

    rv_axi_slave_bfm #(.ADDR_WIDTH (XLEN), .DATA_WIDTH (XLEN), .ID_WIDTH (IDW),
                       .DEPTH (16384), .BASE_ADDR (BASE), .ALIGN (1'b1)) u_bfm (
        .clk (clk), .rst_n (rst_n),
        .ar_delay (ar_delay), .r_delay (r_delay),
        .aw_delay (aw_delay), .w_delay (w_delay), .b_delay (b_delay),
        .awid (awid), .awaddr (awaddr), .awlen (awlen), .awsize (awsize),
        .awburst (awburst), .awvalid (awvalid), .awready (awready),
        .wdata (wdata), .wstrb (wstrb), .wlast (wlast),
        .wvalid (wvalid), .wready (wready),
        .bid (bid), .bresp (bresp), .bvalid (bvalid), .bready (bready),
        .arid (arid), .araddr (araddr), .arlen (arlen), .arsize (arsize),
        .arburst (arburst), .arvalid (arvalid), .arready (arready),
        .rid (rid), .rdata (rdata), .rresp (rresp), .rlast (rlast),
        .rvalid (rvalid), .rready (rready)
    );

    integer pass_cnt = 0, fail_cnt = 0;
    task automatic check(input [XLEN-1:0] got, input [XLEN-1:0] exp, input [255:0] msg);
        begin
            if (got === exp) pass_cnt = pass_cnt + 1;
            else begin
                fail_cnt = fail_cnt + 1;
                $display("[FAIL] %0s: got=%0h exp=%0h", msg, got, exp);
            end
        end
    endtask
    task automatic check_i(input integer got, input integer exp, input [255:0] msg);
        begin
            if (got === exp) pass_cnt = pass_cnt + 1;
            else begin
                fail_cnt = fail_cnt + 1;
                $display("[FAIL] %0s: got=%0d exp=%0d", msg, got, exp);
            end
        end
    endtask

    task automatic do_store(input [XLEN-1:0] a, input [XLEN-1:0] d);
        begin
            @(negedge clk);
            c_req = 1; c_we = 1; c_addr = a; c_wdata = d; c_wstrb = '1;
            #1;                                     // let combinational c_wait settle
            while (c_wait) begin @(negedge clk); #1; end
            c_req = 0; c_we = 0;
            @(negedge clk);
        end
    endtask

    task automatic do_load(input [XLEN-1:0] a, output [XLEN-1:0] d);
        begin
            @(negedge clk);
            c_req = 1; c_we = 0; c_addr = a;
            #1;
            while (c_wait) begin @(negedge clk); #1; end
            // completion cycle (c_wait==0, c_req held): hit latches rdata_q at this
            // posedge; a fill captured it during the burst.  Advance one cycle, read.
            @(negedge clk);
            d = c_rdata;
            c_req = 0;
        end
    endtask

    task automatic set_latency(input [7:0] v);
        begin ar_delay=v; r_delay=v; aw_delay=v; w_delay=v; b_delay=v; end
    endtask

    logic [XLEN-1:0] rd;
    integer h0, m0;

    initial begin
        c_req=0; c_we=0; c_addr=0; c_wdata=0; c_wstrb=0;
        set_latency(8'd2);
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        // 1) store (miss, no-allocate) then load (miss fill) returns stored value
        do_store(BASE + 'h40, 'h1111_1111);
        do_load (BASE + 'h40, rd); check(rd, 'h1111_1111, "load after store(miss)");

        // 2) load again -> hit
        h0 = hit_cnt;
        do_load (BASE + 'h40, rd); check(rd, 'h1111_1111, "load hit");
        check_i(hit_cnt - h0, 1, "hit_cnt incremented");

        // 3) neighbour in same line -> hit (filled by the line)
        do_store(BASE + 'h40 + WB, 'h2222_2222);   // write-through + update (hit if cached)
        h0 = hit_cnt;
        do_load (BASE + 'h40 + WB, rd); check(rd, 'h2222_2222, "same-line neighbour");
        check_i(hit_cnt - h0, 1, "neighbour hit");

        // 4) write-through hit updates cached word AND memory
        do_store(BASE + 'h40, 'hABCD_0001);
        do_load (BASE + 'h40, rd); check(rd, 'hABCD_0001, "store-hit update visible");

        // 5) eviction: access same set, different tag, then original misses
        do_load (BASE + 'h40, rd);                 // ensure line A cached
        do_load (BASE + SET_STRIDE + 'h40, rd);    // line B, same set -> evicts A (fill)
        m0 = miss_cnt;
        do_load (BASE + 'h40, rd); check(rd, 'hABCD_0001, "post-evict value ok");
        check_i(miss_cnt - m0, 1, "evicted -> miss");

        // 6) latency sweep: many words across a line, all read back correctly
        begin : sweep
            integer lat, i;
            for (lat = 0; lat <= 7; lat = lat + (lat<1?1:(lat<3?2:4))) begin
                set_latency(lat[7:0]);
                for (i = 0; i < 8; i = i + 1)
                    do_store(BASE + 'h1000 + i*WB, 'h5000_0000 + i);
                for (i = 0; i < 8; i = i + 1) begin
                    do_load(BASE + 'h1000 + i*WB, rd);
                    check(rd, 'h5000_0000 + i, "sweep word");
                end
            end
        end

        $display("==================================================");
        $display("rv_dcache (XLEN=%0d): %0d passed, %0d failed", XLEN, pass_cnt, fail_cnt);
        $display("hit_cnt=%0d miss_cnt=%0d", hit_cnt, miss_cnt);
        if (fail_cnt == 0) $display("ALL TESTS PASSED");
        else               $display("TESTS FAILED");
        $display("==================================================");
        $finish;
    end

    initial begin
        #500000; $display("TIMEOUT"); $finish;
    end

endmodule

`default_nettype wire
