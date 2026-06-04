// =============================================================================
// tb_rv_axi_burst.sv - Unit testbench for rv_axi_burst_bridge + rv_axi_slave_bfm
// =============================================================================
// Verifies multi-beat INCR read bursts (cache line fill) and single-beat writes
// through rv_axi_burst_bridge into the burst-capable rv_axi_slave_bfm, under
// several latency profiles.  This is the line-fill primitive the I$/D$ rely on.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_rv_axi_burst;

    localparam int AW  = 32;
    localparam int DW  = 32;
    localparam int IDW = 4;
    localparam logic [63:0] BASE = 64'h8000_0000;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // -------- Simple (cache) bus --------------------------------------------
    logic            s_req;
    logic            s_we;
    logic [AW-1:0]   s_addr;
    logic [7:0]      s_len;
    logic [DW-1:0]   s_wdata;
    logic [DW/8-1:0] s_wstrb;
    logic [DW-1:0]   s_rdata;
    logic            s_rvalid;
    logic [7:0]      s_rbeat;
    logic            s_rlast;
    logic            s_done;
    logic            s_busy;

    logic [7:0] ar_delay, r_delay, aw_delay, w_delay, b_delay;

    // -------- AXI wires ------------------------------------------------------
    logic [IDW-1:0]  awid;   logic [AW-1:0] awaddr; logic [7:0] awlen;
    logic [2:0]      awsize; logic [1:0]    awburst; logic awvalid, awready;
    logic [DW-1:0]   wdata;  logic [DW/8-1:0] wstrb; logic wlast, wvalid, wready;
    logic [IDW-1:0]  bid;    logic [1:0]    bresp;   logic bvalid, bready;
    logic [IDW-1:0]  arid;   logic [AW-1:0] araddr;  logic [7:0] arlen;
    logic [2:0]      arsize; logic [1:0]    arburst; logic arvalid, arready;
    logic [IDW-1:0]  rid;    logic [DW-1:0] rdata;   logic [1:0] rresp;
    logic            rlast, rvalid, rready;

    rv_axi_burst_bridge #(
        .ADDR_WIDTH (AW), .DATA_WIDTH (DW), .ID_WIDTH (IDW), .READ_ONLY (1'b0)
    ) u_bridge (
        .clk (clk), .rst_n (rst_n),
        .s_req (s_req), .s_we (s_we), .s_addr (s_addr), .s_len (s_len),
        .s_wdata (s_wdata), .s_wstrb (s_wstrb),
        .s_rdata (s_rdata), .s_rvalid (s_rvalid), .s_rbeat (s_rbeat),
        .s_rlast (s_rlast), .s_done (s_done), .s_busy (s_busy),
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

    rv_axi_slave_bfm #(
        .ADDR_WIDTH (AW), .DATA_WIDTH (DW), .ID_WIDTH (IDW),
        .DEPTH (4096), .BASE_ADDR (BASE), .ALIGN (1'b1)
    ) u_bfm (
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

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task automatic check(input [DW-1:0] got, input [DW-1:0] exp, input [255:0] msg);
        begin
            if (got === exp) pass_cnt = pass_cnt + 1;
            else begin
                fail_cnt = fail_cnt + 1;
                $display("[FAIL] %0s: got=%08x exp=%08x", msg, got, exp);
            end
        end
    endtask

    task automatic do_write(input [AW-1:0] a, input [DW-1:0] d);
        begin
            @(negedge clk);
            s_req = 1; s_we = 1; s_addr = a; s_len = 0; s_wdata = d; s_wstrb = 4'hF;
            while (!s_done) @(negedge clk);
            s_req = 0; s_we = 0;
            @(negedge clk);
        end
    endtask

    // Read a burst of (len+1) beats and capture into cap[]
    logic [DW-1:0] cap [0:255];
    task automatic do_burst(input [AW-1:0] a, input [7:0] len);
        logic done_f;
        begin
            @(negedge clk);
            s_req = 1; s_we = 0; s_addr = a; s_len = len;
            done_f = 1'b0;
            while (!done_f) begin
                @(negedge clk);
                if (s_rvalid) cap[s_rbeat] = s_rdata;
                if (s_done)   done_f = 1'b1;
            end
            s_req = 0;
            @(negedge clk);
        end
    endtask

    task automatic set_latency(input [7:0] v);
        begin
            ar_delay = v; r_delay = v; aw_delay = v; w_delay = v; b_delay = v;
        end
    endtask

    integer lat, i;

    initial begin
        s_req = 0; s_we = 0; s_addr = 0; s_len = 0; s_wdata = 0; s_wstrb = 0;
        set_latency(8'd0);
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        // Preload 16 sequential words at BASE via single writes
        for (i = 0; i < 16; i = i + 1)
            do_write(BASE + i*4, 32'hA000_0000 + i);

        // Sweep latency profiles and burst lengths
        for (lat = 0; lat <= 7; lat = lat + (lat < 1 ? 1 : (lat < 3 ? 2 : 4))) begin
            set_latency(lat[7:0]);

            // 8-beat line fill from BASE
            do_burst(BASE, 8'd7);
            for (i = 0; i < 8; i = i + 1)
                check(cap[i], 32'hA000_0000 + i, "line8");

            // 4-beat line fill from BASE+0x20 (word 8)
            do_burst(BASE + 32'h20, 8'd3);
            for (i = 0; i < 4; i = i + 1)
                check(cap[i], 32'hA000_0000 + 8 + i, "line4");

            // single-beat read (len=0)
            do_burst(BASE + 32'h0C, 8'd0);
            check(cap[0], 32'hA000_0003, "single");
        end

        $display("==================================================");
        $display("rv_axi_burst_bridge: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL TESTS PASSED");
        else               $display("TESTS FAILED");
        $display("==================================================");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
