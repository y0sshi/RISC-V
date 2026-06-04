// =============================================================================
// tb_rv_icache.sv - Unit testbench for rv_icache + read-only burst bridge + BFM
// =============================================================================
// Verifies the instruction cache against a byte-addressable instruction memory
// (BFM ALIGN=0):
//   - aligned fetch hit/miss + line fill,
//   - 2-byte-aligned (RVC) window spanning two words within a line,
//   - line-crossing window served uncached (bypass),
//   - FENCE.I flush forces a re-fetch of modified memory,
//   - correctness under several AXI latency profiles.
// XLEN selected by -DRV_XLEN_64 (default 32).
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_rv_icache;

`ifdef RV_XLEN_64
    localparam int XLEN = 64;
`else
    localparam int XLEN = 32;
`endif
    localparam int LINE_BYTES = 32;
    localparam int SETS       = 64;
    localparam int IDW        = 4;
    localparam logic [63:0] BASE = 64'h8000_0000;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // core side
    logic            c_req;
    logic [XLEN-1:0] c_addr;
    logic [31:0]     c_rdata;
    logic            c_ready;
    logic            flush;
    logic [31:0]     hit_cnt, miss_cnt;

    // cache <-> burst bridge
    logic            m_req;
    logic [XLEN-1:0] m_addr;
    logic [7:0]      m_len;
    logic [31:0]     m_rdata;
    logic            m_rvalid;
    logic [7:0]      m_rbeat;
    logic            m_rlast, m_done, m_busy;

    logic [7:0] ar_delay, r_delay, aw_delay, w_delay, b_delay;

    // AXI wires (32-bit instruction port)
    logic [IDW-1:0]  awid;   logic [XLEN-1:0] awaddr; logic [7:0] awlen;
    logic [2:0]      awsize; logic [1:0]      awburst; logic awvalid, awready;
    logic [31:0]     wdata;  logic [3:0]      wstrb;   logic wlast, wvalid, wready;
    logic [IDW-1:0]  bid;    logic [1:0]      bresp;   logic bvalid, bready;
    logic [IDW-1:0]  arid;   logic [XLEN-1:0] araddr;  logic [7:0] arlen;
    logic [2:0]      arsize; logic [1:0]      arburst; logic arvalid, arready;
    logic [IDW-1:0]  rid;    logic [31:0]     rdata;   logic [1:0] rresp;
    logic            rlast, rvalid, rready;

    rv_icache #(.XLEN (XLEN), .LINE_BYTES (LINE_BYTES), .SETS (SETS),
                .RST_ADDR (BASE)) u_ic (
        .clk (clk), .rst_n (rst_n), .flush (flush),
        .c_req (c_req), .c_addr (c_addr), .c_rdata (c_rdata), .c_ready (c_ready),
        .hit_cnt (hit_cnt), .miss_cnt (miss_cnt),
        .m_req (m_req), .m_addr (m_addr), .m_len (m_len),
        .m_rdata (m_rdata), .m_rvalid (m_rvalid), .m_rbeat (m_rbeat),
        .m_rlast (m_rlast), .m_done (m_done), .m_busy (m_busy)
    );

    rv_axi_burst_bridge #(.ADDR_WIDTH (XLEN), .DATA_WIDTH (32),
                          .ID_WIDTH (IDW), .READ_ONLY (1'b1)) u_br (
        .clk (clk), .rst_n (rst_n),
        .s_req (m_req), .s_we (1'b0), .s_addr (m_addr), .s_len (m_len),
        .s_wdata (32'b0), .s_wstrb (4'b0),
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

    rv_axi_slave_bfm #(.ADDR_WIDTH (XLEN), .DATA_WIDTH (32), .ID_WIDTH (IDW),
                       .DEPTH (4096), .BASE_ADDR (BASE), .ALIGN (1'b0)) u_bfm (
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
    task automatic check(input [31:0] got, input [31:0] exp, input [255:0] msg);
        begin
            if (got === exp) pass_cnt = pass_cnt + 1;
            else begin
                fail_cnt = fail_cnt + 1;
                $display("[FAIL] %0s: got=%08h exp=%08h", msg, got, exp);
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

    // poke a 32-bit word (LE) into BFM byte store at relative byte addr
    task automatic poke_word(input integer ba, input [31:0] v);
        begin
            u_bfm.mem_b[ba+0] = v[7:0];
            u_bfm.mem_b[ba+1] = v[15:8];
            u_bfm.mem_b[ba+2] = v[23:16];
            u_bfm.mem_b[ba+3] = v[31:24];
        end
    endtask

    // Fetch the 32-bit window at byte address A.  The I$ advances its internal
    // addr_q with the same enable the core uses for fetch_pc (on c_ready), so we
    // hold c_addr=A and read c_rdata on the cycle the I$ is actually serving A
    // (addr_q == A && c_ready) -- the pipelined-fetch contract.
    task automatic fetch(input [XLEN-1:0] a, output [31:0] d);
        logic done;
        begin
            done = 1'b0;
            @(negedge clk);
            c_req = 1; c_addr = a;
            while (!done) begin
                @(negedge clk); #1;
                if (c_ready && (u_ic.addr_q == a)) begin d = c_rdata; done = 1'b1; end
            end
        end
    endtask

    task automatic set_latency(input [7:0] v);
        begin ar_delay=v; r_delay=v; aw_delay=v; w_delay=v; b_delay=v; end
    endtask

    logic [31:0] d;
    integer i, m0;

    initial begin
        c_req = 0; c_addr = 0; flush = 0;
        set_latency(8'd2);
        // preload 64 words of pattern
        for (i = 0; i < 64; i = i + 1) poke_word(i*4, 32'hC0DE_0000 + i);
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        // aligned fetches: word 0 (miss fill) then word 1 (same line -> hit)
        m0 = miss_cnt;
        fetch(BASE + 0, d);  check(d, 32'hC0DE_0000, "w0 (miss fill)");
        check_i(miss_cnt - m0, 1, "one fill for line0");
        fetch(BASE + 4, d);  check(d, 32'hC0DE_0001, "w1 same line hit");

        // line 1 word 0 (miss)
        m0 = miss_cnt;
        fetch(BASE + 32'h20, d); check(d, 32'hC0DE_0008, "line1 w0 (miss)");
        check_i(miss_cnt - m0, 1, "one fill for line1");

        // 2-byte-aligned window within line 0: bytes[2..5]
        fetch(BASE + 2, d);  check(d, 32'h0001_C0DE, "RVC window byte+2");

        // line-crossing window (offset 30): served uncached (bypass)
        fetch(BASE + 30, d); check(d, 32'h0008_C0DE, "line-cross window bypass");

        // latency sweep: re-fetch all of line 0 words at various latencies (hits)
        begin : sweep
            integer lat, k;
            for (lat = 0; lat <= 7; lat = lat + (lat<1?1:(lat<3?2:4))) begin
                set_latency(lat[7:0]);
                for (k = 0; k < 8; k = k + 1) begin
                    fetch(BASE + k*4, d);
                    check(d, 32'hC0DE_0000 + k, "sweep word");
                end
            end
            set_latency(8'd2);
        end

        // FENCE.I: modify memory, flush, expect re-fetch of new value (miss)
        poke_word(0, 32'hBEEF_1234);
        fetch(BASE + 0, d);  check(d, 32'hC0DE_0000, "pre-FENCE.I stale (cached)");
        @(negedge clk); flush = 1; @(negedge clk); flush = 0;
        m0 = miss_cnt;
        fetch(BASE + 0, d);  check(d, 32'hBEEF_1234, "post-FENCE.I refetch");
        check_i(miss_cnt - m0, 1, "FENCE.I -> refill");

        $display("==================================================");
        $display("rv_icache (XLEN=%0d): %0d passed, %0d failed", XLEN, pass_cnt, fail_cnt);
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
