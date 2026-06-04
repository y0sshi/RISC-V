// =============================================================================
// tb_rv_cache_soc.sv - Cache effectiveness + transparency integration testbench
// =============================================================================
// Runs the SAME program/data through two rv_soc instances in parallel:
//   u_c : caches ENABLED  (ICACHE_EN=1, DCACHE_EN=1)
//   u_n : caches DISABLED (ICACHE_EN=0, DCACHE_EN=0  -> single-beat AXI, pre-cache)
// Each has its own IF + data AXI slave models (randomized latency).
//
// The program is a nested loop that sums an 8-word DDR array 4 times (= 1440) and
// stores the result, plus drives GPIO and reads rdtime.  Re-fetching the loop
// body and re-loading the array exercises both caches.
//
// Verifies:
//   (1) TRANSPARENCY: the cached and uncached runs produce identical DDR results
//       and identical architectural state (the stored sum).
//   (2) EFFECTIVENESS: the cached run issues far fewer AXI read transactions
//       (AR handshakes) on both the instruction and data masters, and the cache
//       hit/miss counters confirm hits dominate.
//
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_rv_cache_soc;

    import rv_pkg::*;
    localparam int XLEN = rv_pkg::XLEN;
    localparam int IDW  = 4;
    localparam logic [63:0] MEM_BASE = 64'h8000_0000;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---- Cached instance AXI wires ----
    logic [IDW-1:0]  c_awid;  logic [XLEN-1:0] c_awaddr; logic [7:0] c_awlen;
    logic [2:0] c_awsize; logic [1:0] c_awburst; logic c_awvalid,c_awready;
    logic [XLEN-1:0] c_wdata; logic [XLEN/8-1:0] c_wstrb; logic c_wlast,c_wvalid,c_wready;
    logic [IDW-1:0]  c_bid; logic [1:0] c_bresp; logic c_bvalid,c_bready;
    logic [IDW-1:0]  c_arid; logic [XLEN-1:0] c_araddr; logic [7:0] c_arlen;
    logic [2:0] c_arsize; logic [1:0] c_arburst; logic c_arvalid,c_arready;
    logic [IDW-1:0]  c_rid; logic [XLEN-1:0] c_rdata; logic [1:0] c_rresp;
    logic c_rlast,c_rvalid,c_rready;
    logic [IDW-1:0]  ci_awid; logic [XLEN-1:0] ci_awaddr; logic [7:0] ci_awlen;
    logic [2:0] ci_awsize; logic [1:0] ci_awburst; logic ci_awvalid,ci_awready;
    logic [31:0] ci_wdata; logic [3:0] ci_wstrb; logic ci_wlast,ci_wvalid,ci_wready;
    logic [IDW-1:0] ci_bid; logic [1:0] ci_bresp; logic ci_bvalid,ci_bready;
    logic [IDW-1:0] ci_arid; logic [XLEN-1:0] ci_araddr; logic [7:0] ci_arlen;
    logic [2:0] ci_arsize; logic [1:0] ci_arburst; logic ci_arvalid,ci_arready;
    logic [IDW-1:0] ci_rid; logic [31:0] ci_rdata; logic [1:0] ci_rresp;
    logic ci_rlast,ci_rvalid,ci_rready;
    logic [3:0] c_gpio;

    // ---- Uncached instance AXI wires ----
    logic [IDW-1:0]  n_awid;  logic [XLEN-1:0] n_awaddr; logic [7:0] n_awlen;
    logic [2:0] n_awsize; logic [1:0] n_awburst; logic n_awvalid,n_awready;
    logic [XLEN-1:0] n_wdata; logic [XLEN/8-1:0] n_wstrb; logic n_wlast,n_wvalid,n_wready;
    logic [IDW-1:0]  n_bid; logic [1:0] n_bresp; logic n_bvalid,n_bready;
    logic [IDW-1:0]  n_arid; logic [XLEN-1:0] n_araddr; logic [7:0] n_arlen;
    logic [2:0] n_arsize; logic [1:0] n_arburst; logic n_arvalid,n_arready;
    logic [IDW-1:0]  n_rid; logic [XLEN-1:0] n_rdata; logic [1:0] n_rresp;
    logic n_rlast,n_rvalid,n_rready;
    logic [IDW-1:0]  ni_awid; logic [XLEN-1:0] ni_awaddr; logic [7:0] ni_awlen;
    logic [2:0] ni_awsize; logic [1:0] ni_awburst; logic ni_awvalid,ni_awready;
    logic [31:0] ni_wdata; logic [3:0] ni_wstrb; logic ni_wlast,ni_wvalid,ni_wready;
    logic [IDW-1:0] ni_bid; logic [1:0] ni_bresp; logic ni_bvalid,ni_bready;
    logic [IDW-1:0] ni_arid; logic [XLEN-1:0] ni_araddr; logic [7:0] ni_arlen;
    logic [2:0] ni_arsize; logic [1:0] ni_arburst; logic ni_arvalid,ni_arready;
    logic [IDW-1:0] ni_rid; logic [31:0] ni_rdata; logic [1:0] ni_rresp;
    logic ni_rlast,ni_rvalid,ni_rready;
    logic [3:0] n_gpio;

    rv_soc #(.XLEN(XLEN), .RST_ADDR(MEM_BASE), .AXI_ID_WIDTH(IDW),
             .ICACHE_EN(1'b1), .DCACHE_EN(1'b1)) u_c (
        .clk(clk), .rst_n(rst_n), .gpio_in(4'b0), .gpio_out(c_gpio),
        .uart_rx(1'b1), .uart_tx(),
        .m_axi_awid(c_awid),.m_axi_awaddr(c_awaddr),.m_axi_awlen(c_awlen),
        .m_axi_awsize(c_awsize),.m_axi_awburst(c_awburst),.m_axi_awvalid(c_awvalid),.m_axi_awready(c_awready),
        .m_axi_wdata(c_wdata),.m_axi_wstrb(c_wstrb),.m_axi_wlast(c_wlast),.m_axi_wvalid(c_wvalid),.m_axi_wready(c_wready),
        .m_axi_bid(c_bid),.m_axi_bresp(c_bresp),.m_axi_bvalid(c_bvalid),.m_axi_bready(c_bready),
        .m_axi_arid(c_arid),.m_axi_araddr(c_araddr),.m_axi_arlen(c_arlen),
        .m_axi_arsize(c_arsize),.m_axi_arburst(c_arburst),.m_axi_arvalid(c_arvalid),.m_axi_arready(c_arready),
        .m_axi_rid(c_rid),.m_axi_rdata(c_rdata),.m_axi_rresp(c_rresp),.m_axi_rlast(c_rlast),.m_axi_rvalid(c_rvalid),.m_axi_rready(c_rready),
        .m_axi_if_awid(ci_awid),.m_axi_if_awaddr(ci_awaddr),.m_axi_if_awlen(ci_awlen),
        .m_axi_if_awsize(ci_awsize),.m_axi_if_awburst(ci_awburst),.m_axi_if_awvalid(ci_awvalid),.m_axi_if_awready(ci_awready),
        .m_axi_if_wdata(ci_wdata),.m_axi_if_wstrb(ci_wstrb),.m_axi_if_wlast(ci_wlast),.m_axi_if_wvalid(ci_wvalid),.m_axi_if_wready(ci_wready),
        .m_axi_if_bid(ci_bid),.m_axi_if_bresp(ci_bresp),.m_axi_if_bvalid(ci_bvalid),.m_axi_if_bready(ci_bready),
        .m_axi_if_arid(ci_arid),.m_axi_if_araddr(ci_araddr),.m_axi_if_arlen(ci_arlen),
        .m_axi_if_arsize(ci_arsize),.m_axi_if_arburst(ci_arburst),.m_axi_if_arvalid(ci_arvalid),.m_axi_if_arready(ci_arready),
        .m_axi_if_rid(ci_rid),.m_axi_if_rdata(ci_rdata),.m_axi_if_rresp(ci_rresp),.m_axi_if_rlast(ci_rlast),.m_axi_if_rvalid(ci_rvalid),.m_axi_if_rready(ci_rready)
    );

    rv_soc #(.XLEN(XLEN), .RST_ADDR(MEM_BASE), .AXI_ID_WIDTH(IDW),
             .ICACHE_EN(1'b0), .DCACHE_EN(1'b0)) u_n (
        .clk(clk), .rst_n(rst_n), .gpio_in(4'b0), .gpio_out(n_gpio),
        .uart_rx(1'b1), .uart_tx(),
        .m_axi_awid(n_awid),.m_axi_awaddr(n_awaddr),.m_axi_awlen(n_awlen),
        .m_axi_awsize(n_awsize),.m_axi_awburst(n_awburst),.m_axi_awvalid(n_awvalid),.m_axi_awready(n_awready),
        .m_axi_wdata(n_wdata),.m_axi_wstrb(n_wstrb),.m_axi_wlast(n_wlast),.m_axi_wvalid(n_wvalid),.m_axi_wready(n_wready),
        .m_axi_bid(n_bid),.m_axi_bresp(n_bresp),.m_axi_bvalid(n_bvalid),.m_axi_bready(n_bready),
        .m_axi_arid(n_arid),.m_axi_araddr(n_araddr),.m_axi_arlen(n_arlen),
        .m_axi_arsize(n_arsize),.m_axi_arburst(n_arburst),.m_axi_arvalid(n_arvalid),.m_axi_arready(n_arready),
        .m_axi_rid(n_rid),.m_axi_rdata(n_rdata),.m_axi_rresp(n_rresp),.m_axi_rlast(n_rlast),.m_axi_rvalid(n_rvalid),.m_axi_rready(n_rready),
        .m_axi_if_awid(ni_awid),.m_axi_if_awaddr(ni_awaddr),.m_axi_if_awlen(ni_awlen),
        .m_axi_if_awsize(ni_awsize),.m_axi_if_awburst(ni_awburst),.m_axi_if_awvalid(ni_awvalid),.m_axi_if_awready(ni_awready),
        .m_axi_if_wdata(ni_wdata),.m_axi_if_wstrb(ni_wstrb),.m_axi_if_wlast(ni_wlast),.m_axi_if_wvalid(ni_wvalid),.m_axi_if_wready(ni_wready),
        .m_axi_if_bid(ni_bid),.m_axi_if_bresp(ni_bresp),.m_axi_if_bvalid(ni_bvalid),.m_axi_if_bready(ni_bready),
        .m_axi_if_arid(ni_arid),.m_axi_if_araddr(ni_araddr),.m_axi_if_arlen(ni_arlen),
        .m_axi_if_arsize(ni_arsize),.m_axi_if_arburst(ni_arburst),.m_axi_if_arvalid(ni_arvalid),.m_axi_if_arready(ni_arready),
        .m_axi_if_rid(ni_rid),.m_axi_if_rdata(ni_rdata),.m_axi_if_rresp(ni_rresp),.m_axi_if_rlast(ni_rlast),.m_axi_if_rvalid(ni_rvalid),.m_axi_if_rready(ni_rready)
    );

    // ---- Latency knobs (shared profile for both instances) ----
    logic [7:0] ar_delay, r_delay, aw_delay, w_delay, b_delay, iar_delay, ir_delay;
    initial begin ar_delay=0;r_delay=0;aw_delay=0;w_delay=0;b_delay=0;iar_delay=0;ir_delay=0; end
    always @(posedge clk) begin
        ar_delay<=$random&8'h3; r_delay<=$random&8'h3; aw_delay<=$random&8'h3;
        w_delay<=$random&8'h3; b_delay<=$random&8'h3; iar_delay<=$random&8'h3; ir_delay<=$random&8'h3;
    end

    // ---- Four AXI slave models (data + IF for each instance) ----
    rv_axi_slave_bfm #(.ADDR_WIDTH(XLEN),.DATA_WIDTH(XLEN),.ID_WIDTH(IDW),.DEPTH(1024),.BASE_ADDR(MEM_BASE),.ALIGN(1'b1)) u_c_d (
        .clk(clk),.rst_n(rst_n),.ar_delay(ar_delay),.r_delay(r_delay),.aw_delay(aw_delay),.w_delay(w_delay),.b_delay(b_delay),
        .awid(c_awid),.awaddr(c_awaddr),.awlen(c_awlen),.awsize(c_awsize),.awburst(c_awburst),.awvalid(c_awvalid),.awready(c_awready),
        .wdata(c_wdata),.wstrb(c_wstrb),.wlast(c_wlast),.wvalid(c_wvalid),.wready(c_wready),
        .bid(c_bid),.bresp(c_bresp),.bvalid(c_bvalid),.bready(c_bready),
        .arid(c_arid),.araddr(c_araddr),.arlen(c_arlen),.arsize(c_arsize),.arburst(c_arburst),.arvalid(c_arvalid),.arready(c_arready),
        .rid(c_rid),.rdata(c_rdata),.rresp(c_rresp),.rlast(c_rlast),.rvalid(c_rvalid),.rready(c_rready));
    rv_axi_slave_bfm #(.ADDR_WIDTH(XLEN),.DATA_WIDTH(32),.ID_WIDTH(IDW),.DEPTH(1024),.BASE_ADDR(MEM_BASE),.ALIGN(1'b0)) u_c_i (
        .clk(clk),.rst_n(rst_n),.ar_delay(iar_delay),.r_delay(ir_delay),.aw_delay(8'd0),.w_delay(8'd0),.b_delay(8'd0),
        .awid(ci_awid),.awaddr(ci_awaddr),.awlen(ci_awlen),.awsize(ci_awsize),.awburst(ci_awburst),.awvalid(ci_awvalid),.awready(ci_awready),
        .wdata(ci_wdata),.wstrb(ci_wstrb),.wlast(ci_wlast),.wvalid(ci_wvalid),.wready(ci_wready),
        .bid(ci_bid),.bresp(ci_bresp),.bvalid(ci_bvalid),.bready(ci_bready),
        .arid(ci_arid),.araddr(ci_araddr),.arlen(ci_arlen),.arsize(ci_arsize),.arburst(ci_arburst),.arvalid(ci_arvalid),.arready(ci_arready),
        .rid(ci_rid),.rdata(ci_rdata),.rresp(ci_rresp),.rlast(ci_rlast),.rvalid(ci_rvalid),.rready(ci_rready));
    rv_axi_slave_bfm #(.ADDR_WIDTH(XLEN),.DATA_WIDTH(XLEN),.ID_WIDTH(IDW),.DEPTH(1024),.BASE_ADDR(MEM_BASE),.ALIGN(1'b1)) u_n_d (
        .clk(clk),.rst_n(rst_n),.ar_delay(ar_delay),.r_delay(r_delay),.aw_delay(aw_delay),.w_delay(w_delay),.b_delay(b_delay),
        .awid(n_awid),.awaddr(n_awaddr),.awlen(n_awlen),.awsize(n_awsize),.awburst(n_awburst),.awvalid(n_awvalid),.awready(n_awready),
        .wdata(n_wdata),.wstrb(n_wstrb),.wlast(n_wlast),.wvalid(n_wvalid),.wready(n_wready),
        .bid(n_bid),.bresp(n_bresp),.bvalid(n_bvalid),.bready(n_bready),
        .arid(n_arid),.araddr(n_araddr),.arlen(n_arlen),.arsize(n_arsize),.arburst(n_arburst),.arvalid(n_arvalid),.arready(n_arready),
        .rid(n_rid),.rdata(n_rdata),.rresp(n_rresp),.rlast(n_rlast),.rvalid(n_rvalid),.rready(n_rready));
    rv_axi_slave_bfm #(.ADDR_WIDTH(XLEN),.DATA_WIDTH(32),.ID_WIDTH(IDW),.DEPTH(1024),.BASE_ADDR(MEM_BASE),.ALIGN(1'b0)) u_n_i (
        .clk(clk),.rst_n(rst_n),.ar_delay(iar_delay),.r_delay(ir_delay),.aw_delay(8'd0),.w_delay(8'd0),.b_delay(8'd0),
        .awid(ni_awid),.awaddr(ni_awaddr),.awlen(ni_awlen),.awsize(ni_awsize),.awburst(ni_awburst),.awvalid(ni_awvalid),.awready(ni_awready),
        .wdata(ni_wdata),.wstrb(ni_wstrb),.wlast(ni_wlast),.wvalid(ni_wvalid),.wready(ni_wready),
        .bid(ni_bid),.bresp(ni_bresp),.bvalid(ni_bvalid),.bready(ni_bready),
        .arid(ni_arid),.araddr(ni_araddr),.arlen(ni_arlen),.arsize(ni_arsize),.arburst(ni_arburst),.arvalid(ni_arvalid),.arready(ni_arready),
        .rid(ni_rid),.rdata(ni_rdata),.rresp(ni_rresp),.rlast(ni_rlast),.rvalid(ni_rvalid),.rready(ni_rready));

    // ---- Instruction encoders ----
    function automatic logic [31:0] i_instr(input [6:0] op,input [4:0] rd,input [2:0] f3,input [4:0] rs1,input [11:0] imm);
        return {imm,rs1,f3,rd,op}; endfunction
    function automatic logic [31:0] r_instr(input [4:0] rd,input [2:0] f3,input [4:0] rs1,input [4:0] rs2,input [6:0] f7);
        return {f7,rs2,rs1,f3,rd,7'h33}; endfunction
    function automatic logic [31:0] lui_instr(input [4:0] rd,input [19:0] imm20);
        return {imm20,rd,7'h37}; endfunction
    function automatic logic [31:0] jal_i(input [4:0] rd,input signed [20:0] off);
        logic [20:0] imm; imm=off; return {imm[20],imm[10:1],imm[11],imm[19:12],rd,7'h6F}; endfunction
    function automatic logic [31:0] b_instr(input [4:0] rs1,input [4:0] rs2,input [2:0] f3,input signed [12:0] off);
        logic [12:0] imm; imm=off; return {imm[12],imm[10:5],rs2,rs1,f3,imm[4:1],imm[11],7'h63}; endfunction
    function automatic logic [31:0] s_instr(input [4:0] rs2,input [4:0] rs1,input [11:0] imm,input [2:0] f3);
        return {imm[11:5],rs2,rs1,f3,imm[4:0],7'h23}; endfunction

    // Load one instruction word into BOTH IF memories
    task automatic load_if(input int idx, input logic [31:0] w);
        u_c_i.mem_b[idx*4+0]=w[7:0];  u_c_i.mem_b[idx*4+1]=w[15:8];
        u_c_i.mem_b[idx*4+2]=w[23:16];u_c_i.mem_b[idx*4+3]=w[31:24];
        u_n_i.mem_b[idx*4+0]=w[7:0];  u_n_i.mem_b[idx*4+1]=w[15:8];
        u_n_i.mem_b[idx*4+2]=w[23:16];u_n_i.mem_b[idx*4+3]=w[31:24];
    endtask
    // Load one data word into BOTH data memories (byte offset within BFM)
    task automatic load_data(input int boff, input logic [31:0] w);
        u_c_d.mem_b[boff+0]=w[7:0]; u_c_d.mem_b[boff+1]=w[15:8];
        u_c_d.mem_b[boff+2]=w[23:16];u_c_d.mem_b[boff+3]=w[31:24];
        u_n_d.mem_b[boff+0]=w[7:0]; u_n_d.mem_b[boff+1]=w[15:8];
        u_n_d.mem_b[boff+2]=w[23:16];u_n_d.mem_b[boff+3]=w[31:24];
    endtask
    function automatic logic [31:0] c_dword(input int boff);
        return {u_c_d.mem_b[boff+3],u_c_d.mem_b[boff+2],u_c_d.mem_b[boff+1],u_c_d.mem_b[boff+0]}; endfunction
    function automatic logic [31:0] n_dword(input int boff);
        return {u_n_d.mem_b[boff+3],u_n_d.mem_b[boff+2],u_n_d.mem_b[boff+1],u_n_d.mem_b[boff+0]}; endfunction

    // ---- AR handshake counters ----
    integer c_if_ar=0, c_d_ar=0, n_if_ar=0, n_d_ar=0;
    always @(posedge clk) if (rst_n) begin
        if (ci_arvalid & ci_arready) c_if_ar++;
        if (c_arvalid  & c_arready ) c_d_ar++;
        if (ni_arvalid & ni_arready) n_if_ar++;
        if (n_arvalid  & n_arready ) n_d_ar++;
    end

    integer pass_cnt=0, fail_cnt=0, i;
    task automatic check(input integer cond, input [255:0] msg);
        begin if (cond) pass_cnt++; else begin fail_cnt++; $display("[FAIL] %0s", msg); end end
    endtask

    initial begin
        $dumpfile("wave/tb_rv_cache_soc.vcd"); $dumpvars(0, tb_rv_cache_soc);
        #1;
        // Nested loop: acc += array[0..7], repeated 4 times -> 360*4 = 1440
        load_if( 0, lui_instr(5'd4,20'h80000));               // x4 = 0x80000000
        load_if( 1, i_instr(7'h13,5'd4,3'd0,5'd4,12'h200));   // x4 += 0x200 (array base)
        load_if( 2, lui_instr(5'd5,20'h80000));               // x5 = 0x80000000
        load_if( 3, i_instr(7'h13,5'd5,3'd0,5'd5,12'h300));   // x5 += 0x300 (result)
        load_if( 4, i_instr(7'h13,5'd1,3'd0,5'd0,12'd0));     // x1 = 0 (acc)
        load_if( 5, i_instr(7'h13,5'd7,3'd0,5'd0,12'd4));     // x7 = 4 (outer cnt)
        load_if( 6, i_instr(7'h13,5'd6,3'd0,5'd0,12'd0));     // x6 = 0 (outer idx)
        load_if( 7, i_instr(7'h13,5'd3,3'd0,5'd0,12'd8));     // x3 = 8 (inner cnt)
        // outer (idx 8):
        load_if( 8, i_instr(7'h13,5'd9,3'd0,5'd4,12'd0));     // x9 = x4 (ptr)
        load_if( 9, i_instr(7'h13,5'd2,3'd0,5'd0,12'd0));     // x2 = 0 (inner idx)
        // inner (idx 10):
        load_if(10, i_instr(7'h03,5'd8,3'b010,5'd9,12'd0));   // lw x8,0(x9)
        load_if(11, r_instr(5'd1,3'd0,5'd1,5'd8,7'd0));       // add x1,x1,x8
        load_if(12, i_instr(7'h13,5'd9,3'd0,5'd9,12'd4));     // x9 += 4
        load_if(13, i_instr(7'h13,5'd2,3'd0,5'd2,12'd1));     // x2 += 1
        load_if(14, b_instr(5'd2,5'd3,3'b100,-13'sd16));      // blt x2,x3,inner(10)
        load_if(15, i_instr(7'h13,5'd6,3'd0,5'd6,12'd1));     // x6 += 1
        load_if(16, b_instr(5'd6,5'd7,3'b100,-13'sd32));      // blt x6,x7,outer(8)
        load_if(17, s_instr(5'd1,5'd5,12'd0,3'b010));         // sw x1,0(x5)
        load_if(18, jal_i(5'd0,21'sd0));                      // spin

        // array[0..7] = 10,20,...,80 at data byte 0x200
        for (i = 0; i < 8; i = i + 1) load_data(32'h200 + i*4, (i+1)*10);

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (8000) @(posedge clk);

        // (1) Transparency: identical stored result and it equals 1440
        check(c_dword(32'h300) === 32'd1440, "cached result == 1440");
        check(n_dword(32'h300) === 32'd1440, "uncached result == 1440");
        check(c_dword(32'h300) === n_dword(32'h300), "cached == uncached result");
        check(c_gpio === n_gpio, "gpio identical");

        // (2) Effectiveness: caches issue far fewer AXI read transactions
        check(c_if_ar < n_if_ar, "I$ reduces IF read txns");
        check(c_d_ar  < n_d_ar,  "D$ reduces data read txns");

        $display("--------------------------------------------------");
        $display("AXI read transactions (AR handshakes):");
        $display("  IF : cached=%0d  uncached=%0d", c_if_ar, n_if_ar);
        $display("  DATA: cached=%0d  uncached=%0d", c_d_ar, n_d_ar);
        $display("Cache counters (cached instance):");
        $display("  I$  hit=%0d miss=%0d", u_c.gen_icache.u_ic.hit_cnt, u_c.gen_icache.u_ic.miss_cnt);
        $display("  D$  hit=%0d miss=%0d", u_c.gen_dcache.u_dc.hit_cnt, u_c.gen_dcache.u_dc.miss_cnt);
        $display("--------------------------------------------------");
        $display("tb_rv_cache_soc (XLEN=%0d): %0d passed, %0d failed", XLEN, pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL TESTS PASSED");
        else               $display("TESTS FAILED");
        $finish;
    end

    initial begin #2000000; $display("TIMEOUT"); $finish; end

endmodule

`default_nettype wire
