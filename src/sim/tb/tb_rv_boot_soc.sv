// =============================================================================
// tb_rv_boot_soc.sv - OpenSBI-style boot harness over a SHARED DDR image
// =============================================================================
// Boots a firmware image (the mini-SBI stand-in, or a real OpenSBI fw_payload)
// on rv_soc with I/D caches enabled, where instructions, data and page tables
// all live in ONE shared DDR (rv_axi_dualport_mem_bfm) -- the sim analogue of
// the board's single PS DDR reached via an AXI SmartConnect.
//
// The firmware is loaded by the BFM via $readmemh from BOOT_HEX (objcopy -O
// verilog with --adjust-vma=-BASE so addresses are base-relative).  The UART TX
// line is deserialized (8N1) and echoed to the console; completion is detected
// by the firmware storing a sentinel word to TOHOST.
//
//   make sim_boot                       (default firmware: src/software/boot)
//   make sim_boot BOOT_HEX=path/to.hex  (e.g. a real OpenSBI fw_payload hex)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

`ifndef BOOT_HEX
  `define BOOT_HEX "../software/boot/sbi_boot.hex"
`endif

module tb_rv_boot_soc;

    import rv_pkg::*;
    localparam int XLEN = rv_pkg::XLEN;
    localparam int IDW  = 4;
    localparam logic [63:0] MEM_BASE = 64'h8000_0000;

    // NS16550 16x oversampling: bit period = 16 * divisor.  Pick CLK so the
    // default divisor = CLK/(16*BAUD) = 1 -> 16 clocks/bit (small, fast sim).
    localparam int CLKF   = 1_843_200;              // = 16 * 115200
    localparam int BAUD   = 115_200;
    localparam int BITCLK = CLKF / BAUD;            // clocks per bit (= 16)

    localparam int TOHOST_OFF = 32'h2000;           // TOHOST - MEM_BASE
    localparam logic [31:0] DONE_MAGIC = 32'h00C0_FFEE;
    localparam logic [31:0] FAIL_MAGIC = 32'h0BAD_BAD0;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---- data master <-> BFM data port ----
    logic [IDW-1:0]  awid;  logic [XLEN-1:0] awaddr; logic [7:0] awlen;
    logic [2:0] awsize; logic [1:0] awburst; logic awvalid,awready;
    logic [XLEN-1:0] wdata; logic [XLEN/8-1:0] wstrb; logic wlast,wvalid,wready;
    logic [IDW-1:0] bid; logic [1:0] bresp; logic bvalid,bready;
    logic [IDW-1:0] arid; logic [XLEN-1:0] araddr; logic [7:0] arlen;
    logic [2:0] arsize; logic [1:0] arburst; logic arvalid,arready;
    logic [IDW-1:0] rid; logic [XLEN-1:0] rdata; logic [1:0] rresp;
    logic rlast,rvalid,rready;
    // ---- IF master <-> BFM instruction port ----
    logic [IDW-1:0] i_awid; logic [XLEN-1:0] i_awaddr; logic [7:0] i_awlen;
    logic [2:0] i_awsize; logic [1:0] i_awburst; logic i_awvalid,i_awready;
    logic [31:0] i_wdata; logic [3:0] i_wstrb; logic i_wlast,i_wvalid,i_wready;
    logic [IDW-1:0] i_bid; logic [1:0] i_bresp; logic i_bvalid,i_bready;
    logic [IDW-1:0] i_arid; logic [XLEN-1:0] i_araddr; logic [7:0] i_arlen;
    logic [2:0] i_arsize; logic [1:0] i_arburst; logic i_arvalid,i_arready;
    logic [IDW-1:0] i_rid; logic [31:0] i_rdata; logic [1:0] i_rresp;
    logic i_rlast,i_rvalid,i_rready;

    logic uart_tx;
    logic [3:0] gpio_out_w;

    rv_soc #(.XLEN(XLEN), .RST_ADDR(MEM_BASE), .AXI_ID_WIDTH(IDW),
             .CLK_FREQ(CLKF), .BAUD_RATE(BAUD),
             .ICACHE_EN(1'b1), .DCACHE_EN(1'b1)) u_soc (
        .clk(clk), .rst_n(rst_n), .gpio_in(4'b0), .gpio_out(gpio_out_w),
        .uart_rx(1'b1), .uart_tx(uart_tx),
        .m_axi_awid(awid),.m_axi_awaddr(awaddr),.m_axi_awlen(awlen),.m_axi_awsize(awsize),
        .m_axi_awburst(awburst),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wlast(wlast),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bid(bid),.m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
        .m_axi_arid(arid),.m_axi_araddr(araddr),.m_axi_arlen(arlen),.m_axi_arsize(arsize),
        .m_axi_arburst(arburst),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rid(rid),.m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready),
        .m_axi_if_awid(i_awid),.m_axi_if_awaddr(i_awaddr),.m_axi_if_awlen(i_awlen),.m_axi_if_awsize(i_awsize),
        .m_axi_if_awburst(i_awburst),.m_axi_if_awvalid(i_awvalid),.m_axi_if_awready(i_awready),
        .m_axi_if_wdata(i_wdata),.m_axi_if_wstrb(i_wstrb),.m_axi_if_wlast(i_wlast),.m_axi_if_wvalid(i_wvalid),.m_axi_if_wready(i_wready),
        .m_axi_if_bid(i_bid),.m_axi_if_bresp(i_bresp),.m_axi_if_bvalid(i_bvalid),.m_axi_if_bready(i_bready),
        .m_axi_if_arid(i_arid),.m_axi_if_araddr(i_araddr),.m_axi_if_arlen(i_arlen),.m_axi_if_arsize(i_arsize),
        .m_axi_if_arburst(i_arburst),.m_axi_if_arvalid(i_arvalid),.m_axi_if_arready(i_arready),
        .m_axi_if_rid(i_rid),.m_axi_if_rdata(i_rdata),.m_axi_if_rresp(i_rresp),.m_axi_if_rlast(i_rlast),.m_axi_if_rvalid(i_rvalid),.m_axi_if_rready(i_rready)
    );

    // Modest, fixed AXI latency (a few cycles) to mimic DDR.
    logic [7:0] ard=8'd3, rd_=8'd3, awd=8'd2, wd=8'd2, bd=8'd2;

    rv_axi_dualport_mem_bfm #(.ADDR_WIDTH(XLEN), .XLEN(XLEN), .ID_WIDTH(IDW),
                              .DEPTH(1<<20), .BASE_ADDR(MEM_BASE),
                              .INIT_FILE(`BOOT_HEX)) u_bfm (
        .clk(clk), .rst_n(rst_n),
        .ar_delay(ard), .r_delay(rd_), .aw_delay(awd), .w_delay(wd), .b_delay(bd),
        .d_awid(awid),.d_awaddr(awaddr),.d_awlen(awlen),.d_awsize(awsize),.d_awburst(awburst),
        .d_awvalid(awvalid),.d_awready(awready),
        .d_wdata(wdata),.d_wstrb(wstrb),.d_wlast(wlast),.d_wvalid(wvalid),.d_wready(wready),
        .d_bid(bid),.d_bresp(bresp),.d_bvalid(bvalid),.d_bready(bready),
        .d_arid(arid),.d_araddr(araddr),.d_arlen(arlen),.d_arsize(arsize),.d_arburst(arburst),
        .d_arvalid(arvalid),.d_arready(arready),
        .d_rid(rid),.d_rdata(rdata),.d_rresp(rresp),.d_rlast(rlast),.d_rvalid(rvalid),.d_rready(rready),
        .i_arid(i_arid),.i_araddr(i_araddr),.i_arlen(i_arlen),.i_arsize(i_arsize),.i_arburst(i_arburst),
        .i_arvalid(i_arvalid),.i_arready(i_arready),
        .i_rid(i_rid),.i_rdata(i_rdata),.i_rresp(i_rresp),.i_rlast(i_rlast),.i_rvalid(i_rvalid),.i_rready(i_rready)
    );

    // ---- 8N1 UART receiver: deserialize uart_tx, echo to console ----
    integer nchars = 0;
    logic [7:0] ch; integer bi;
    initial begin
        forever begin
            @(negedge uart_tx);                          // start bit
            repeat (BITCLK + BITCLK/2) @(posedge clk);   // -> middle of bit0
            ch = 8'd0;
            for (bi = 0; bi < 8; bi = bi + 1) begin
                ch[bi] = uart_tx;
                repeat (BITCLK) @(posedge clk);
            end
            $write("%c", ch);
            nchars = nchars + 1;
        end
    end

    function automatic logic [31:0] sentinel();
        return {u_bfm.mem_b[TOHOST_OFF+3], u_bfm.mem_b[TOHOST_OFF+2],
                u_bfm.mem_b[TOHOST_OFF+1], u_bfm.mem_b[TOHOST_OFF+0]};
    endfunction

    // diagnostics
    integer if_ar = 0, d_ar = 0;
    always @(posedge clk) if (rst_n) begin
        if (i_arvalid & i_arready) if_ar = if_ar + 1;
        if (arvalid   & arready  ) d_ar  = d_ar  + 1;
    end

    integer cyc = 0;
    initial begin
        $dumpfile("wave/tb_rv_boot_soc.vcd"); $dumpvars(0, tb_rv_boot_soc);
        repeat (4) @(posedge clk);
        rst_n = 1;
        $display("\n----- boot console (firmware: %s) -----", `BOOT_HEX);
        // run until the firmware signals done, or timeout
        for (cyc = 0; cyc < 2_000_000; cyc = cyc + 1) begin
            @(posedge clk);
            if (sentinel() === DONE_MAGIC || sentinel() === FAIL_MAGIC) cyc = 2_000_000;
        end
        #1;
        $display("\n----- end of console (%0d UART chars; IF line-fills=%0d, data reads=%0d) -----",
                 nchars, if_ar, d_ar);
        if (sentinel() === DONE_MAGIC) begin
            $display("tb_rv_boot_soc: PASS (firmware reached SBI done; sentinel=0x%08h)", sentinel());
            $display("ALL TESTS PASSED");
        end else if (sentinel() === FAIL_MAGIC) begin
            $display("tb_rv_boot_soc: FAIL (firmware trapped unexpectedly; sentinel=0x%08h)", sentinel());
            $display("TESTS FAILED");
        end else begin
            $display("tb_rv_boot_soc: FAIL (timeout; no completion sentinel; %0d chars seen)", nchars);
            $display("TESTS FAILED");
        end
        $finish;
    end

endmodule

`default_nettype wire
