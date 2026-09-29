// =============================================================================
// tb_rv_axi_bridge.sv - Unit testbench for rv_axi_bridge + rv_axi_slave_bfm
// =============================================================================
// Drives the simple memory bus through rv_axi_bridge into rv_axi_slave_bfm and
// verifies write-then-read correctness under several latency / backpressure
// profiles (0, 1, N, and per-transaction-varying).  This validates that the
// bridge's protocol conversion is correct independent of memory latency -- the
// key property needed before wiring it into the variable-latency DDR path.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_rv_axi_bridge;

    localparam int AW = 32;
    localparam int DW = 32;
    localparam int IDW = 4;
    localparam logic [63:0] BASE = 64'h8000_0000;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // -------- Simple bus (driven by tasks) ----------------------------------
    logic            s_req;
    logic            s_we;
    logic [AW-1:0]   s_addr;
    logic [DW-1:0]   s_wdata;
    logic [DW/8-1:0] s_wstrb;
    logic [DW-1:0]   s_rdata;
    logic            s_ready;
    logic            s_busy;
    logic            s_wait;

    // -------- BFM latency knobs ---------------------------------------------
    logic [7:0] ar_delay, r_delay, aw_delay, w_delay, b_delay;

    // -------- AXI wires (bridge master <-> BFM slave) -----------------------
    logic [IDW-1:0]  awid;   logic [AW-1:0] awaddr; logic [7:0] awlen;
    logic [2:0]      awsize; logic [1:0]    awburst; logic awvalid, awready;
    logic [DW-1:0]   wdata;  logic [DW/8-1:0] wstrb; logic wlast, wvalid, wready;
    logic [IDW-1:0]  bid;    logic [1:0]    bresp;   logic bvalid, bready;
    logic [IDW-1:0]  arid;   logic [AW-1:0] araddr;  logic [7:0] arlen;
    logic [2:0]      arsize; logic [1:0]    arburst; logic arvalid, arready;
    logic [IDW-1:0]  rid;    logic [DW-1:0] rdata;   logic [1:0] rresp;
    logic            rlast, rvalid, rready;

    rv_axi_bridge #(
        .ADDR_WIDTH (AW),
        .DATA_WIDTH (DW),
        .ID_WIDTH   (IDW),
        .READ_ONLY  (1'b0)
    ) u_bridge (
        .clk (clk), .rst_n (rst_n),
        .s_req (s_req), .s_we (s_we), .s_addr (s_addr),
        .s_wdata (s_wdata), .s_wstrb (s_wstrb),
        .s_rdata (s_rdata), .s_ready (s_ready), .s_busy (s_busy), .s_wait (s_wait),
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
        .ADDR_WIDTH (AW),
        .DATA_WIDTH (DW),
        .ID_WIDTH   (IDW),
        .DEPTH      (4096),
        .BASE_ADDR  (BASE),
        .ALIGN      (1'b1)
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

    // -------- Scoreboard -----------------------------------------------------
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task automatic check(input [DW-1:0] got, input [DW-1:0] exp, input [255:0] msg);
        begin
            if (got === exp) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("[FAIL] %0s: got=%08x exp=%08x", msg, got, exp);
            end
        end
    endtask

    // -------- Bus driver tasks ----------------------------------------------
    task automatic do_write(input [AW-1:0] a, input [DW-1:0] d, input [DW/8-1:0] be);
        begin
            @(negedge clk);
            s_req = 1; s_we = 1; s_addr = a; s_wdata = d; s_wstrb = be;
            while (!s_ready) @(negedge clk);
            s_req = 0; s_we = 0;
            @(negedge clk);
        end
    endtask

    task automatic do_read(input [AW-1:0] a, output [DW-1:0] d);
        begin
            @(negedge clk);
            s_req = 1; s_we = 0; s_addr = a;
            while (!s_ready) @(negedge clk);
            // completion pulse seen; data is registered and valid next cycle
            s_req = 0;
            @(negedge clk);
            d = s_rdata;
        end
    endtask

    task automatic set_latency(input [7:0] v);
        begin
            ar_delay = v; r_delay = v; aw_delay = v; w_delay = v; b_delay = v;
        end
    endtask

    // -------- Test sequence --------------------------------------------------
    logic [DW-1:0] rd;
    integer        lat;

    initial begin
        s_req = 0; s_we = 0; s_addr = 0; s_wdata = 0; s_wstrb = 0;
        set_latency(8'd0);
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        // ---- Sweep latency profiles: 0, 1, 3, 7 ----
        for (lat = 0; lat <= 7; lat = lat + (lat < 1 ? 1 : (lat < 3 ? 2 : 4))) begin
            set_latency(lat[7:0]);

            // Full-word write/read across several addresses
            do_write(BASE + 32'h0000, 32'hDEAD_BEEF, 4'hF);
            do_write(BASE + 32'h0004, 32'h0123_4567, 4'hF);
            do_write(BASE + 32'h0010, 32'hCAFE_F00D, 4'hF);
            do_read (BASE + 32'h0000, rd); check(rd, 32'hDEAD_BEEF, "word0");
            do_read (BASE + 32'h0004, rd); check(rd, 32'h0123_4567, "word1");
            do_read (BASE + 32'h0010, rd); check(rd, 32'hCAFE_F00D, "word4");

            // Byte-enable write (only update byte lane 2)
            do_write(BASE + 32'h0000, 32'h00AA_0000, 4'b0100);
            do_read (BASE + 32'h0000, rd); check(rd, 32'hDEAA_BEEF, "bytewr");
        end

        // ---- Per-transaction varying latency ----
        ar_delay = 8'd0; r_delay = 8'd5; aw_delay = 8'd2; w_delay = 8'd1; b_delay = 8'd3;
        do_write(BASE + 32'h0020, 32'h1111_2222, 4'hF);
        ar_delay = 8'd4; r_delay = 8'd0; aw_delay = 8'd0; w_delay = 8'd3; b_delay = 8'd0;
        do_read (BASE + 32'h0020, rd); check(rd, 32'h1111_2222, "varlat");

        // ---- Summary ----
        $display("==================================================");
        $display("rv_axi_bridge: %0d passed, %0d failed", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL TESTS PASSED");
        else               $display("TESTS FAILED");
        $display("==================================================");
        $finish;
    end

    // Safety timeout
    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
