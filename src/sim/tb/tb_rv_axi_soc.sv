// =============================================================================
// tb_rv_axi_soc.sv - rv_soc (AXI/DDR) integration (instructions AND data in DDR)
// =============================================================================
// Drives rv_soc (AXI/DDR) built with BOTH masters exercised:
//   - instruction fetch  -> m_axi_if_* (read-only, 32-bit) -> IF DDR model
//   - data + PTW          -> m_axi_*    (read/write, XLEN)   -> data DDR model
// Both AXI slaves run at randomized latency.  (On hardware the two masters fan
// into an AXI SmartConnect -> a single S_AXI_HP -> one DDR; in sim two BFMs
// suffice for this self-contained program whose code and data regions do not
// overlap.)
//
// Program (loaded into the IF DDR model): sum 1..10 (=55) via a loop (branches +
// backward jump fetched over AXI), then store the result to 0x8000_0100, which
// goes out the DATA master.  The testbench verifies the data-DDR word.
//
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_rv_axi_soc;

    import rv_pkg::*;

    localparam int XLEN = rv_pkg::XLEN;
    localparam int IDW  = 4;
    localparam logic [63:0] MEM_BASE = 64'h8000_0000;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---- DATA AXI master <-> slave ----
    logic [IDW-1:0]  awid;   logic [XLEN-1:0] awaddr; logic [7:0] awlen;
    logic [2:0]      awsize; logic [1:0]    awburst; logic awvalid, awready;
    logic [XLEN-1:0] wdata;  logic [XLEN/8-1:0] wstrb; logic wlast, wvalid, wready;
    logic [IDW-1:0]  bid;    logic [1:0]    bresp;   logic bvalid, bready;
    logic [IDW-1:0]  arid;   logic [XLEN-1:0] araddr;  logic [7:0] arlen;
    logic [2:0]      arsize; logic [1:0]    arburst; logic arvalid, arready;
    logic [IDW-1:0]  rid;    logic [XLEN-1:0] rdata;   logic [1:0] rresp;
    logic            rlast, rvalid, rready;

    // ---- IF AXI master <-> slave (32-bit) ----
    logic [IDW-1:0]  i_awid;  logic [XLEN-1:0] i_awaddr; logic [7:0] i_awlen;
    logic [2:0]      i_awsize;logic [1:0] i_awburst; logic i_awvalid,i_awready;
    logic [31:0]     i_wdata; logic [3:0] i_wstrb; logic i_wlast,i_wvalid,i_wready;
    logic [IDW-1:0]  i_bid;   logic [1:0] i_bresp; logic i_bvalid,i_bready;
    logic [IDW-1:0]  i_arid;  logic [XLEN-1:0] i_araddr; logic [7:0] i_arlen;
    logic [2:0]      i_arsize;logic [1:0] i_arburst; logic i_arvalid,i_arready;
    logic [IDW-1:0]  i_rid;   logic [31:0] i_rdata; logic [1:0] i_rresp;
    logic            i_rlast, i_rvalid, i_rready;

    logic [3:0] gpio_out_w;

    rv_soc #(
        .XLEN (XLEN), .RST_ADDR (MEM_BASE), .AXI_ID_WIDTH (IDW)
    ) u_soc (
        .clk (clk), .rst_n (rst_n),
        .gpio_in (4'b0), .gpio_out (gpio_out_w), .uart_rx (1'b1), .uart_tx (),
        // data master
        .m_axi_awid (awid), .m_axi_awaddr (awaddr), .m_axi_awlen (awlen),
        .m_axi_awsize (awsize), .m_axi_awburst (awburst),
        .m_axi_awvalid (awvalid), .m_axi_awready (awready),
        .m_axi_wdata (wdata), .m_axi_wstrb (wstrb), .m_axi_wlast (wlast),
        .m_axi_wvalid (wvalid), .m_axi_wready (wready),
        .m_axi_bid (bid), .m_axi_bresp (bresp), .m_axi_bvalid (bvalid), .m_axi_bready (bready),
        .m_axi_arid (arid), .m_axi_araddr (araddr), .m_axi_arlen (arlen),
        .m_axi_arsize (arsize), .m_axi_arburst (arburst),
        .m_axi_arvalid (arvalid), .m_axi_arready (arready),
        .m_axi_rid (rid), .m_axi_rdata (rdata), .m_axi_rresp (rresp),
        .m_axi_rlast (rlast), .m_axi_rvalid (rvalid), .m_axi_rready (rready),
        // instruction master
        .m_axi_if_awid (i_awid), .m_axi_if_awaddr (i_awaddr), .m_axi_if_awlen (i_awlen),
        .m_axi_if_awsize (i_awsize), .m_axi_if_awburst (i_awburst),
        .m_axi_if_awvalid (i_awvalid), .m_axi_if_awready (i_awready),
        .m_axi_if_wdata (i_wdata), .m_axi_if_wstrb (i_wstrb), .m_axi_if_wlast (i_wlast),
        .m_axi_if_wvalid (i_wvalid), .m_axi_if_wready (i_wready),
        .m_axi_if_bid (i_bid), .m_axi_if_bresp (i_bresp), .m_axi_if_bvalid (i_bvalid),
        .m_axi_if_bready (i_bready),
        .m_axi_if_arid (i_arid), .m_axi_if_araddr (i_araddr), .m_axi_if_arlen (i_arlen),
        .m_axi_if_arsize (i_arsize), .m_axi_if_arburst (i_arburst),
        .m_axi_if_arvalid (i_arvalid), .m_axi_if_arready (i_arready),
        .m_axi_if_rid (i_rid), .m_axi_if_rdata (i_rdata), .m_axi_if_rresp (i_rresp),
        .m_axi_if_rlast (i_rlast), .m_axi_if_rvalid (i_rvalid), .m_axi_if_rready (i_rready)
    );

    logic [7:0] ar_delay, r_delay, aw_delay, w_delay, b_delay;
    logic [7:0] i_ar_delay, i_r_delay;

    // data DDR model
    rv_axi_slave_bfm #(.ADDR_WIDTH (XLEN), .DATA_WIDTH (XLEN), .ID_WIDTH (IDW),
                       .DEPTH (1024), .BASE_ADDR (MEM_BASE), .ALIGN (1'b1)) u_bfm (
        .clk (clk), .rst_n (rst_n),
        .ar_delay (ar_delay), .r_delay (r_delay),
        .aw_delay (aw_delay), .w_delay (w_delay), .b_delay (b_delay),
        .awid (awid), .awaddr (awaddr), .awlen (awlen), .awsize (awsize),
        .awburst (awburst), .awvalid (awvalid), .awready (awready),
        .wdata (wdata), .wstrb (wstrb), .wlast (wlast), .wvalid (wvalid), .wready (wready),
        .bid (bid), .bresp (bresp), .bvalid (bvalid), .bready (bready),
        .arid (arid), .araddr (araddr), .arlen (arlen), .arsize (arsize),
        .arburst (arburst), .arvalid (arvalid), .arready (arready),
        .rid (rid), .rdata (rdata), .rresp (rresp), .rlast (rlast),
        .rvalid (rvalid), .rready (rready)
    );

    // IF DDR model (32-bit, exact byte offset)
    rv_axi_slave_bfm #(.ADDR_WIDTH (XLEN), .DATA_WIDTH (32), .ID_WIDTH (IDW),
                       .DEPTH (1024), .BASE_ADDR (MEM_BASE), .ALIGN (1'b0)) u_ifbfm (
        .clk (clk), .rst_n (rst_n),
        .ar_delay (i_ar_delay), .r_delay (i_r_delay),
        .aw_delay (8'd0), .w_delay (8'd0), .b_delay (8'd0),
        .awid (i_awid), .awaddr (i_awaddr), .awlen (i_awlen), .awsize (i_awsize),
        .awburst (i_awburst), .awvalid (i_awvalid), .awready (i_awready),
        .wdata (i_wdata), .wstrb (i_wstrb), .wlast (i_wlast),
        .wvalid (i_wvalid), .wready (i_wready),
        .bid (i_bid), .bresp (i_bresp), .bvalid (i_bvalid), .bready (i_bready),
        .arid (i_arid), .araddr (i_araddr), .arlen (i_arlen), .arsize (i_arsize),
        .arburst (i_arburst), .arvalid (i_arvalid), .arready (i_arready),
        .rid (i_rid), .rdata (i_rdata), .rresp (i_rresp), .rlast (i_rlast),
        .rvalid (i_rvalid), .rready (i_rready)
    );

    initial begin
        ar_delay=0; r_delay=0; aw_delay=0; w_delay=0; b_delay=0; i_ar_delay=0; i_r_delay=0;
    end
    always @(posedge clk) begin
        ar_delay <= $random & 8'h3; r_delay <= $random & 8'h3;
        aw_delay <= $random & 8'h3; w_delay <= $random & 8'h3; b_delay <= $random & 8'h3;
        i_ar_delay <= $random & 8'h3; i_r_delay <= $random & 8'h3;
    end

    // Instruction encoders
    function automatic logic [31:0] i_instr(input [6:0] op, input [4:0] rd,
                input [2:0] f3, input [4:0] rs1, input [11:0] imm);
        return {imm, rs1, f3, rd, op}; endfunction
    function automatic logic [31:0] r_instr(input [4:0] rd, input [2:0] f3,
                input [4:0] rs1, input [4:0] rs2, input [6:0] f7);
        return {f7, rs2, rs1, f3, rd, 7'h33}; endfunction
    function automatic logic [31:0] lui_instr(input [4:0] rd, input [19:0] imm20);
        return {imm20, rd, 7'h37}; endfunction
    function automatic logic [31:0] jal_i(input [4:0] rd, input signed [20:0] off);
        logic [20:0] imm; imm = off; return {imm[20],imm[10:1],imm[11],imm[19:12],rd,7'h6F}; endfunction
    function automatic logic [31:0] b_instr(input [4:0] rs1, input [4:0] rs2,
                input [2:0] f3, input signed [12:0] off);
        logic [12:0] imm; imm = off; return {imm[12],imm[10:5],rs2,rs1,f3,imm[4:1],imm[11],7'h63}; endfunction
    function automatic logic [31:0] s_instr(input [4:0] rs2, input [4:0] rs1,
                input [11:0] imm, input [2:0] f3);
        return {imm[11:5], rs2, rs1, f3, imm[4:0], 7'h23}; endfunction

    // instruction into IF DDR model (byte LE, base 0x8000_0000)
    task automatic imem_set(input int idx, input logic [31:0] w);
        u_ifbfm.mem_b[idx*4+0]=w[7:0];  u_ifbfm.mem_b[idx*4+1]=w[15:8];
        u_ifbfm.mem_b[idx*4+2]=w[23:16]; u_ifbfm.mem_b[idx*4+3]=w[31:24];
    endtask
    function automatic logic [31:0] bfm_word(input int byte_off);
        return {u_bfm.mem_b[byte_off+3], u_bfm.mem_b[byte_off+2],
                u_bfm.mem_b[byte_off+1], u_bfm.mem_b[byte_off+0]};
    endfunction

    integer pass_cnt = 0, fail_cnt = 0;

    initial begin
        $dumpfile("wave/tb_rv_axi_soc.vcd"); $dumpvars(0, tb_rv_axi_soc);
        #1;
        // sum 1..10 -> 55, store to 0x8000_0100
        imem_set( 0, i_instr(7'h13, 5'd1, 3'd0, 5'd0, 12'd0));
        imem_set( 1, i_instr(7'h13, 5'd2, 3'd0, 5'd0, 12'd1));
        imem_set( 2, i_instr(7'h13, 5'd3, 3'd0, 5'd0, 12'd11));
        imem_set( 3, b_instr(5'd2, 5'd3, 3'b101, 13'sd16));      // bge x2,x3,+16 -> idx7
        imem_set( 4, r_instr(5'd1, 3'd0, 5'd1, 5'd2, 7'd0));     // add x1,x1,x2
        imem_set( 5, i_instr(7'h13, 5'd2, 3'd0, 5'd2, 12'd1));   // addi x2,x2,1
        imem_set( 6, jal_i(5'd0, -21'sd12));                     // jal x0,-12 -> idx3
        imem_set( 7, lui_instr(5'd4, 20'h80000));                // lui x4,0x80000
        imem_set( 8, i_instr(7'h13, 5'd4, 3'd0, 5'd4, 12'h100)); // addi x4,x4,0x100
        imem_set( 9, s_instr(5'd1, 5'd4, 12'd0, 3'b010));        // sw x1,0(x4)  -> DDR
        // Peripheral access over AXI-mode SoC: drive GPIO (0xC002_0000).
        imem_set(10, lui_instr(5'd9, 20'hC0020));                // x9 = 0xC0020000 (GPIO)
        imem_set(11, i_instr(7'h13, 5'd10, 3'd0, 5'd0, 12'hF));  // x10 = 0xF (DIR mask)
        imem_set(12, s_instr(5'd10, 5'd9, 12'd8, 3'b010));       // sw x10,8(x9)  DIR=0xF (periph)
        imem_set(13, i_instr(7'h13, 5'd11, 3'd0, 5'd0, 12'd5));  // x11 = 5 (OUT value)
        imem_set(14, s_instr(5'd11, 5'd9, 12'd0, 3'b010));       // sw x11,0(x9)  OUT=5 (periph)
        imem_set(15, jal_i(5'd0, 21'sd0));                       // spin

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (5000) @(posedge clk);

        if (bfm_word(32'h100) === 32'd55) begin
            $display("  PASS: DDR[0x8000_0100] = %0d (sum 1..10 over AXI)", bfm_word(32'h100));
            pass_cnt++;
        end else begin
            $display("  FAIL: DDR[0x8000_0100] = 0x%08h (exp 55)", bfm_word(32'h100));
            fail_cnt++;
        end

        if (gpio_out_w === 4'h5) begin
            $display("  PASS: GPIO out = 0x%0h (peripheral write over AXI-mode SoC)", gpio_out_w);
            pass_cnt++;
        end else begin
            $display("  FAIL: GPIO out = 0x%0h (exp 5)", gpio_out_w);
            fail_cnt++;
        end

        $display("\n=== tb_rv_axi_soc: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL TESTS PASSED");
        else               $display("TESTS FAILED");
        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish; end

endmodule

`default_nettype wire
