// =============================================================================
// tb_rv_axi_ifetch.sv - rv_core INSTRUCTION port over AXI4 (variable latency)
// =============================================================================
// Routes the core's instruction fetch through rv_axi_bridge (READ_ONLY) +
// rv_axi_slave_bfm at programmable latency, keeping the data port on a 1-cycle
// behavioral memory.  Exercises branch / jump / JALR / loop programs to expose
// (and then validate the fix for) the IF-over-AXI redirect-loss + duplication
// hazards.
//
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_rv_axi_ifetch;

    import rv_pkg::*;

    localparam int XLEN = rv_pkg::XLEN;
    localparam int IDW  = 4;
    localparam int CLKP = 10;

    logic clk = 0, rst_n = 0;
    always #(CLKP/2) clk = ~clk;

    // Core <-> memory
    logic [XLEN-1:0] imem_addr, dmem_addr, dmem_wdata, dmem_rdata;
    logic            imem_req, dmem_req, dmem_we;
    logic [31:0]     imem_rdata;
    logic            imem_ready, dmem_ready;
    logic [XLEN/8-1:0] dmem_wstrb;

    logic [XLEN-1:0] satp_out; priv_level_t priv_out;
    logic mstatus_sum_out, mstatus_mxr_out, tlb_flush_out, mstatus_mprv_out;
    logic [1:0] mstatus_mpp_out;

    // IF AXI wires
    logic            if_busy, if_wait;
    logic [IDW-1:0]  i_awid;  logic [XLEN-1:0] i_awaddr; logic [7:0] i_awlen;
    logic [2:0]      i_awsize;logic [1:0] i_awburst; logic i_awvalid,i_awready;
    logic [31:0]     i_wdata; logic [3:0] i_wstrb; logic i_wlast,i_wvalid,i_wready;
    logic [IDW-1:0]  i_bid;   logic [1:0] i_bresp; logic i_bvalid,i_bready;
    logic [IDW-1:0]  i_arid;  logic [XLEN-1:0] i_araddr; logic [7:0] i_arlen;
    logic [2:0]      i_arsize;logic [1:0] i_arburst; logic i_arvalid,i_arready;
    logic [IDW-1:0]  i_rid;   logic [31:0] i_rdata; logic [1:0] i_rresp;
    logic            i_rlast, i_rvalid, i_rready;

    rv_core #(.XLEN(XLEN), .RST_ADDR(64'h0)) dut (
        .clk (clk), .rst_n (rst_n),
        .imem_addr (imem_addr), .imem_req (imem_req),
        .imem_rdata (imem_rdata), .imem_ready (imem_ready),
        .dmem_addr (dmem_addr), .dmem_wdata (dmem_wdata), .dmem_wstrb (dmem_wstrb),
        .dmem_req (dmem_req), .dmem_we (dmem_we),
        .dmem_rdata (dmem_rdata), .dmem_ready (dmem_ready),
        .satp_out (satp_out), .priv_out (priv_out),
        .mstatus_sum_out (mstatus_sum_out), .mstatus_mxr_out (mstatus_mxr_out),
        .mstatus_mprv_out (mstatus_mprv_out), .mstatus_mpp_out (mstatus_mpp_out),
        .tlb_flush_out (tlb_flush_out),
        .mmu_stall (1'b0), .mem_stall (1'b0), .dmem_wait (1'b0),
        .if_fault (1'b0), .mem_fault (1'b0),
        .timer_irq (1'b0), .sw_irq (1'b0), .ext_irq (1'b0)
    );

    // ---- IF: simple bus -> AXI bridge (READ_ONLY) -> slave BFM ----
    rv_axi_bridge #(.ADDR_WIDTH (XLEN), .DATA_WIDTH (32), .ID_WIDTH (IDW),
                    .READ_ONLY (1'b1)) u_ifbr (
        .clk (clk), .rst_n (rst_n),
        .s_req (imem_req), .s_we (1'b0), .s_addr (imem_addr),
        .s_wdata (32'b0), .s_wstrb (4'b0),
        .s_rdata (imem_rdata), .s_ready (imem_ready),
        .s_busy (if_busy), .s_wait (if_wait),
        .m_axi_awid (i_awid), .m_axi_awaddr (i_awaddr), .m_axi_awlen (i_awlen),
        .m_axi_awsize (i_awsize), .m_axi_awburst (i_awburst),
        .m_axi_awvalid (i_awvalid), .m_axi_awready (i_awready),
        .m_axi_wdata (i_wdata), .m_axi_wstrb (i_wstrb), .m_axi_wlast (i_wlast),
        .m_axi_wvalid (i_wvalid), .m_axi_wready (i_wready),
        .m_axi_bid (i_bid), .m_axi_bresp (i_bresp), .m_axi_bvalid (i_bvalid),
        .m_axi_bready (i_bready),
        .m_axi_arid (i_arid), .m_axi_araddr (i_araddr), .m_axi_arlen (i_arlen),
        .m_axi_arsize (i_arsize), .m_axi_arburst (i_arburst),
        .m_axi_arvalid (i_arvalid), .m_axi_arready (i_arready),
        .m_axi_rid (i_rid), .m_axi_rdata (i_rdata), .m_axi_rresp (i_rresp),
        .m_axi_rlast (i_rlast), .m_axi_rvalid (i_rvalid), .m_axi_rready (i_rready)
    );

    logic [7:0] ar_d, r_d;
    rv_axi_slave_bfm #(.ADDR_WIDTH (XLEN), .DATA_WIDTH (32), .ID_WIDTH (IDW),
                       .DEPTH (1024), .BASE_ADDR (64'h0), .ALIGN (1'b0)) u_ifbfm (
        .clk (clk), .rst_n (rst_n),
        .ar_delay (ar_d), .r_delay (r_d),
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

    // ---- Data: 1-cycle behavioral memory ----
    logic [31:0] dmem_bram [0:255];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin dmem_rdata <= '0; dmem_ready <= 1'b0; end
        else begin
            dmem_ready <= dmem_req;
            if (dmem_req && dmem_we) begin
                if (dmem_wstrb[0]) dmem_bram[dmem_addr[9:2]][ 7: 0] <= dmem_wdata[ 7: 0];
                if (dmem_wstrb[1]) dmem_bram[dmem_addr[9:2]][15: 8] <= dmem_wdata[15: 8];
                if (dmem_wstrb[2]) dmem_bram[dmem_addr[9:2]][23:16] <= dmem_wdata[23:16];
                if (dmem_wstrb[3]) dmem_bram[dmem_addr[9:2]][31:24] <= dmem_wdata[31:24];
            end
            if (dmem_req && !dmem_we) dmem_rdata <= XLEN'(dmem_bram[dmem_addr[9:2]]);
        end
    end

    // ---- Helpers ----
    int pass_cnt = 0, fail_cnt = 0;
    localparam logic [31:0] NOP  = 32'h0000_0013;
    localparam logic [31:0] SPIN = 32'h0000_006F;

    function automatic logic [XLEN-1:0] reg_val(input int n);
        return dut.u_regfile.regs[n];
    endfunction
    task automatic check_x(input string nm, input logic [XLEN-1:0] got, exp);
        if (got === exp) begin $display("  PASS: %s = 0x%0h", nm, got); pass_cnt++; end
        else begin $display("  FAIL: %s got=0x%0h exp=0x%0h", nm, got, exp); fail_cnt++; end
    endtask

    function automatic logic [31:0] imm_i(input [6:0] op,input [4:0] rd,input [2:0] f3,input [4:0] rs1,input [11:0] imm);
        return {imm, rs1, f3, rd, op}; endfunction
    function automatic logic [31:0] reg_i(input [4:0] rd,input [2:0] f3,input [4:0] rs1,input [4:0] rs2,input [6:0] f7);
        return {f7, rs2, rs1, f3, rd, 7'h33}; endfunction
    function automatic logic [31:0] jal_i(input [4:0] rd,input signed [20:0] off);
        logic [20:0] m; m=off; return {m[20],m[10:1],m[11],m[19:12],rd,7'h6F}; endfunction
    function automatic logic [31:0] jalr_i(input [4:0] rd,input [4:0] rs1,input [11:0] imm);
        return {imm, rs1, 3'b000, rd, 7'h67}; endfunction
    function automatic logic [31:0] b_i(input [4:0] rs1,input [4:0] rs2,input [2:0] f3,input signed [12:0] off);
        logic [12:0] m; m=off; return {m[12],m[10:5],rs2,rs1,f3,m[4:1],m[11],7'h63}; endfunction
    function automatic logic [31:0] ld_i(input [4:0] rd,input [4:0] rs1,input [11:0] imm,input [2:0] f3);
        return {imm, rs1, f3, rd, 7'h03}; endfunction

    // Write instruction word into IF BFM (byte LE, base 0)
    task automatic iset(input int idx, input logic [31:0] w);
        u_ifbfm.mem_b[idx*4+0]=w[7:0]; u_ifbfm.mem_b[idx*4+1]=w[15:8];
        u_ifbfm.mem_b[idx*4+2]=w[23:16]; u_ifbfm.mem_b[idx*4+3]=w[31:24];
    endtask
    task automatic iclear;
        for (int i=0;i<1024*4;i++) u_ifbfm.mem_b[i]=8'h0;
        for (int i=0;i<256;i++) dmem_bram[i]=32'h0;
    endtask

    task automatic do_reset;
        rst_n=0; repeat(3) @(posedge clk); rst_n=1;
        for (int i=0;i<32;i++) dut.u_regfile.regs[i]={XLEN{1'b0}};
    endtask

    initial begin
        $dumpfile("wave/tb_rv_axi_ifetch.vcd"); $dumpvars(0, tb_rv_axi_ifetch);
    end

    // DEBUG: retire monitor (rd in {1,2,3})
    logic dbg = 0;
    always @(posedge clk) begin
        if (dbg && rst_n && dut.wb_reg_write &&
            (dut.wb_rd_addr==5'd1 || dut.wb_rd_addr==5'd2 || dut.wb_rd_addr==5'd3))
            $display("    [WB %0t] x%0d <= %0d (pc4=%0h)", $time, dut.wb_rd_addr,
                     dut.wb_data, dut.mem_wb_pc4);
    end

    // Run all programs at a given IF read latency
    task automatic run_suite(input [7:0] lat);
        begin
            ar_d = 8'd0; r_d = lat;
            $display("\n--- IF AXI latency r_delay=%0d ---", lat);

            // [A] sequential ALU (baseline, no branch)
            iclear();
            iset(0, imm_i(7'h13,5'd1,3'd0,5'd0,12'd10));   // addi x1,x0,10
            iset(1, reg_i(5'd2,3'd0,5'd1,5'd1,7'd0));      // add x2,x1,x1
            iset(2, imm_i(7'h13,5'd5,3'd0,5'd2,12'd1));    // addi x5,x2,1
            iset(3, SPIN);
            do_reset(); repeat(250) @(posedge clk);
            check_x("A x2=20", reg_val(2), XLEN'(20));
            check_x("A x5=21", reg_val(5), XLEN'(21));

            // [B] JAL forward + rd writeback
            iclear();
            iset(0, jal_i(5'd1, 21'sd8));                   // jal x1,+8 -> idx2
            iset(1, imm_i(7'h13,5'd1,3'd0,5'd0,12'd0));     // flushed
            iset(2, imm_i(7'h13,5'd6,3'd0,5'd0,12'd99));    // addi x6,x0,99
            iset(3, SPIN);
            do_reset(); repeat(250) @(posedge clk);
            check_x("B x1=4 (JAL ra)", reg_val(1), XLEN'(4));
            check_x("B x6=99 (target ran)", reg_val(6), XLEN'(99));

            // [C] BEQ taken
            iclear();
            iset(0, imm_i(7'h13,5'd1,3'd0,5'd0,12'd99));    // addi x1,x0,99 (must commit)
            iset(1, b_i(5'd0,5'd0,3'b000,13'sd8));          // beq x0,x0,+8 -> idx3
            iset(2, imm_i(7'h13,5'd1,3'd0,5'd0,12'd0));     // flushed
            iset(3, imm_i(7'h13,5'd7,3'd0,5'd0,12'd55));    // addi x7,x0,55
            iset(4, SPIN);
            do_reset(); repeat(250) @(posedge clk);
            check_x("C x1=99 (pre-branch commit)", reg_val(1), XLEN'(99));
            check_x("C x7=55 (branch target)", reg_val(7), XLEN'(55));

            // [D] JALR
            iclear();
            iset(0, imm_i(7'h13,5'd2,3'd0,5'd0,12'd16));    // addi x2,x0,16
            iset(1, jalr_i(5'd1,5'd2,12'd0));               // jalr x1,x2,0 -> idx4
            iset(2, NOP); iset(3, NOP);
            iset(4, imm_i(7'h13,5'd8,3'd0,5'd0,12'd77));    // addi x8,x0,77
            iset(5, SPIN);
            do_reset(); repeat(250) @(posedge clk);
            check_x("D x1=8 (JALR ra)", reg_val(1), XLEN'(8));
            check_x("D x8=77 (target)", reg_val(8), XLEN'(77));

            // [E] backward loop: sum 1..10 = 55
            iclear();
            iset(0, imm_i(7'h13,5'd1,3'd0,5'd0,12'd0));     // sum=0
            iset(1, imm_i(7'h13,5'd2,3'd0,5'd0,12'd1));     // i=1
            iset(2, imm_i(7'h13,5'd3,3'd0,5'd0,12'd11));    // limit=11
            iset(3, b_i(5'd2,5'd3,3'b101,13'sd16));         // bge x2,x3,+16 -> idx7
            iset(4, reg_i(5'd1,3'd0,5'd1,5'd2,7'd0));       // add x1,x1,x2
            iset(5, imm_i(7'h13,5'd2,3'd0,5'd2,12'd1));     // addi x2,x2,1
            iset(6, jal_i(5'd0, -21'sd12));                 // jal x0,-12 -> idx3
            iset(7, SPIN);
            do_reset(); repeat(900) @(posedge clk);
            check_x("E x1=55 (loop sum)", reg_val(1), XLEN'(55));

            // [F] load-use + BEQ not taken (fall-through), data behavioral
            iclear();
            dmem_bram[0] = 32'h0000_0042;
            iset(0, ld_i(5'd3,5'd0,12'd0,3'b100));          // lbu x3,0(x0)=0x42
            iset(1, b_i(5'd3,5'd0,3'b000,13'sd16));         // beq x3,x0,+16 NOT taken
            iset(2, imm_i(7'h13,5'd4,3'd0,5'd0,12'd77));    // addi x4,x0,77 (must run)
            iset(3, SPIN);
            do_reset(); repeat(900) @(posedge clk);
            check_x("F x3=0x42 (LBU)", reg_val(3), XLEN'(32'h42));
            check_x("F x4=77 (fall-through)", reg_val(4), XLEN'(77));
        end
    endtask

    initial begin
        $display("=== tb_rv_axi_ifetch: instruction fetch over AXI ===");
        ar_d=0; r_d=0;
        run_suite(8'd1);
        run_suite(8'd3);
        $display("\n=== Results: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt==0) $display("ALL TESTS PASSED"); else $display("TESTS FAILED");
        $finish;
    end

    initial begin #2000000; $display("TIMEOUT"); $finish; end

endmodule

`default_nettype wire
