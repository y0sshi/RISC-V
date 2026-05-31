// =============================================================================
// tb_rv_axi_core.sv - rv_core data port over AXI4 (variable latency)
// =============================================================================
// Runs the proven tb_rv_pipeline test program but routes the core's DATA memory
// port through rv_axi_bridge -> rv_axi_slave_bfm with RANDOMIZED per-cycle
// latency.  The instruction port stays on a 1-cycle always-ready behavioral
// memory (so the unrelated IF-stall path is not exercised here).
//
// Purpose: prove the new `dmem_wait` contract -- loads/stores produce identical
// architectural results under variable data-memory latency as on the zero-
// latency BRAM path.  When dmem_wait is asserted the whole pipeline freezes
// (stall_if/id/ex), the load/store stays in MEM until the AXI transaction
// completes, then advances and samples the bridge's held s_rdata in WB.
//
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_axi_core;

    import rv_pkg::*;

    localparam int XLEN       = rv_pkg::XLEN;
    localparam int CLK_PERIOD = 10;
    localparam int IDW        = 4;

    logic clk, rst_n;

    logic [XLEN-1:0]     imem_addr, dmem_addr, dmem_wdata;
    logic [XLEN-1:0]     dmem_rdata;        // <- bridge s_rdata
    logic                imem_req, dmem_req, dmem_we;
    logic [31:0]         imem_rdata;
    logic                imem_ready, dmem_ready;
    logic [XLEN/8-1:0]   dmem_wstrb;
    logic                dmem_wait;          // <- bridge s_wait

    logic [XLEN-1:0]     satp_out;
    priv_level_t         priv_out;
    logic                mstatus_sum_out, mstatus_mxr_out, tlb_flush_out;
    logic                mstatus_mprv_out;
    logic [1:0]          mstatus_mpp_out;

    logic timer_irq = 1'b0, sw_irq = 1'b0, ext_irq = 1'b0;

    // Behavioral always-ready IMEM
    logic [31:0] imem_bram [0:255];

    // =========================================================================
    // DUT: rv_core (data port on AXI, instruction port behavioral)
    // =========================================================================
    rv_core #(.XLEN(XLEN), .RST_ADDR(64'h0)) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .imem_addr       (imem_addr),
        .imem_req        (imem_req),
        .imem_rdata      (imem_rdata),
        .imem_ready      (imem_ready),
        .dmem_addr       (dmem_addr),
        .dmem_wdata      (dmem_wdata),
        .dmem_wstrb      (dmem_wstrb),
        .dmem_req        (dmem_req),
        .dmem_we         (dmem_we),
        .dmem_rdata      (dmem_rdata),
        .dmem_ready      (dmem_ready),
        .satp_out        (satp_out),
        .priv_out        (priv_out),
        .mstatus_sum_out (mstatus_sum_out),
        .mstatus_mxr_out (mstatus_mxr_out),
        .mstatus_mprv_out(mstatus_mprv_out),
        .mstatus_mpp_out (mstatus_mpp_out),
        .tlb_flush_out   (tlb_flush_out),
        .mmu_stall       (1'b0),
        .mem_stall       (1'b0),
        .dmem_wait       (dmem_wait),
        .if_fault        (1'b0),
        .mem_fault       (1'b0),
        .timer_irq       (timer_irq),
        .sw_irq          (sw_irq),
        .ext_irq         (ext_irq)
    );

    // =========================================================================
    // Data port: simple bus -> AXI bridge -> AXI slave memory BFM
    // =========================================================================
    logic            s_busy;

    // AXI master <-> slave wires
    logic [IDW-1:0]  awid;   logic [XLEN-1:0] awaddr; logic [7:0] awlen;
    logic [2:0]      awsize; logic [1:0]    awburst; logic awvalid, awready;
    logic [XLEN-1:0] wdata;  logic [XLEN/8-1:0] wstrb; logic wlast, wvalid, wready;
    logic [IDW-1:0]  bid;    logic [1:0]    bresp;   logic bvalid, bready;
    logic [IDW-1:0]  arid;   logic [XLEN-1:0] araddr;  logic [7:0] arlen;
    logic [2:0]      arsize; logic [1:0]    arburst; logic arvalid, arready;
    logic [IDW-1:0]  rid;    logic [XLEN-1:0] rdata;   logic [1:0] rresp;
    logic            rlast, rvalid, rready;

    rv_axi_bridge #(
        .ADDR_WIDTH (XLEN),
        .DATA_WIDTH (XLEN),
        .ID_WIDTH   (IDW),
        .READ_ONLY  (1'b0)
    ) u_bridge (
        .clk (clk), .rst_n (rst_n),
        .s_req (dmem_req), .s_we (dmem_we), .s_addr (dmem_addr),
        .s_wdata (dmem_wdata), .s_wstrb (dmem_wstrb),
        .s_rdata (dmem_rdata), .s_ready (dmem_ready), .s_busy (s_busy), .s_wait (dmem_wait),
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

    // Latency / backpressure knobs (randomized each cycle)
    logic [7:0] ar_delay, r_delay, aw_delay, w_delay, b_delay;

    rv_axi_slave_bfm #(
        .ADDR_WIDTH (XLEN),
        .DATA_WIDTH (XLEN),
        .ID_WIDTH   (IDW),
        .DEPTH      (256),
        .BASE_ADDR  (64'h0),
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

    // Randomize latency every cycle (0..3) to stress variable-latency behavior.
    initial begin
        ar_delay = 0; r_delay = 0; aw_delay = 0; w_delay = 0; b_delay = 0;
    end
    always @(posedge clk) begin
        ar_delay <= $random & 8'h3;
        r_delay  <= $random & 8'h3;
        aw_delay <= $random & 8'h3;
        w_delay  <= $random & 8'h3;
        b_delay  <= $random & 8'h3;
    end

    // Clock + behavioral IMEM (1-cycle, always ready)
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            imem_rdata <= 32'h0000_0013;
            imem_ready <= 1'b0;
        end else begin
            imem_ready <= imem_req;
            if (imem_req)
                imem_rdata <= imem_bram[imem_addr[$clog2(256)+1:2]];
        end
    end

    // Test helpers
    int pass_cnt = 0, fail_cnt = 0;

    localparam logic [31:0] NOP  = 32'h0000_0013;   // ADDI x0, x0, 0
    localparam logic [31:0] SPIN = 32'h0000_006F;   // JAL x0, 0

    function automatic logic [XLEN-1:0] reg_val(input int n);
        return dut.u_regfile.regs[n];
    endfunction

    task automatic check_x(input string name, input logic [XLEN-1:0] got, exp);
        if (got === exp) begin
            $display("  PASS: %s = 0x%0h", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %s got=0x%0h exp=0x%0h", name, got, exp);
            fail_cnt++;
        end
    endtask

    // BFM backing-store helpers (byte array u_bfm.mem_b, base 0)
    task automatic bfm_clear;
        for (int i = 0; i < 256*4; i++) u_bfm.mem_b[i] = 8'h0;
    endtask
    task automatic bfm_set_word(input int idx, input logic [31:0] val);
        u_bfm.mem_b[idx*4+0] = val[7:0];
        u_bfm.mem_b[idx*4+1] = val[15:8];
        u_bfm.mem_b[idx*4+2] = val[23:16];
        u_bfm.mem_b[idx*4+3] = val[31:24];
    endtask

    // Instruction encoding helpers
    function automatic logic [31:0] imm_instr(input [6:0] opcode, input [4:0] rd,
                input [2:0] funct3, input [4:0] rs1, input [11:0] imm);
        return {imm, rs1, funct3, rd, opcode};
    endfunction
    function automatic logic [31:0] reg_instr(input [6:0] opcode, input [4:0] rd,
                input [2:0] funct3, input [4:0] rs1, input [4:0] rs2, input [6:0] funct7);
        return {funct7, rs2, rs1, funct3, rd, opcode};
    endfunction
    function automatic logic [31:0] jal_instr(input [4:0] rd, input signed [20:0] offset);
        logic [20:0] imm; imm = offset;
        return {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'h6F};
    endfunction
    function automatic logic [31:0] jalr_instr(input [4:0] rd, input [4:0] rs1, input [11:0] imm);
        return {imm, rs1, 3'b000, rd, 7'h67};
    endfunction
    function automatic logic [31:0] branch_instr(input [4:0] rs1, input [4:0] rs2,
                input [2:0] funct3, input signed [12:0] offset);
        logic [12:0] imm; imm = offset;
        return {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], 7'h63};
    endfunction
    function automatic logic [31:0] load_instr(input [4:0] rd, input [4:0] rs1,
                input [11:0] imm, input [2:0] funct3);
        return {imm, rs1, funct3, rd, 7'h03};
    endfunction
    function automatic logic [31:0] store_instr(input [4:0] rs2, input [4:0] rs1,
                input [11:0] imm, input [2:0] funct3);
        return {imm[11:5], rs2, rs1, funct3, imm[4:0], 7'h23};
    endfunction

    initial begin
        $dumpfile("wave/tb_rv_axi_core.vcd");
        $dumpvars(0, tb_rv_axi_core);
    end

    // =========================================================================
    // Test sequence (same programs as tb_rv_pipeline; data via AXI)
    // =========================================================================
    initial begin
        $display("=== tb_rv_axi_core: data port over AXI (variable latency) ===\n");

        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        bfm_clear();

        // [1] EX/MEM forwarding
        imem_bram[0] = imm_instr(7'h13, 5'd1, 3'd0, 5'd0, 12'd10);
        imem_bram[1] = reg_instr(7'h33, 5'd2, 3'd0, 5'd1, 5'd1, 7'd0);
        imem_bram[2] = SPIN;
        rst_n = 1'b0; repeat (3) @(posedge clk); rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat (60) @(posedge clk);
        check_x("x1", reg_val(1), XLEN'(10));
        check_x("x2 (EX/MEM fwd)", reg_val(2), XLEN'(20));

        // [4] Load-use hazard over AXI
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        bfm_clear(); bfm_set_word(0, 32'h0000_0042);
        imem_bram[0] = load_instr(5'd2, 5'd0, 12'd0, 3'b010);
        imem_bram[1] = reg_instr (7'h33, 5'd3, 3'd0, 5'd2, 5'd0, 7'd0);
        imem_bram[2] = SPIN;
        rst_n = 1'b0; repeat(3) @(posedge clk); rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat(80) @(posedge clk);
        check_x("x2 (LW result, AXI lat)", reg_val(2), XLEN'(32'h42));
        check_x("x3 (load-use fwd)",       reg_val(3), XLEN'(32'h42));

        // [9] Load-use + BEQ NOT taken (fall-through), over AXI
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        bfm_clear(); bfm_set_word(0, 32'h0000_0042);
        imem_bram[0] = load_instr(5'd3, 5'd0, 12'd0, 3'b100);          // LBU x3,0(x0)
        imem_bram[1] = branch_instr(5'd3, 5'd0, 3'b000, 13'sd16);      // BEQ x3,x0,+16 not taken
        imem_bram[2] = imm_instr(7'h13, 5'd4, 3'd0, 5'd0, 12'd77);     // ADDI x4,x0,77
        imem_bram[3] = SPIN;
        rst_n = 1'b0; repeat(3) @(posedge clk); rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat(80) @(posedge clk);
        check_x("x3 (LBU result)",         reg_val(3), XLEN'(32'h42));
        check_x("x4 (fall-through ADDI)",  reg_val(4), XLEN'(77));

        // [11] SW then LW to addr[2]=1 over AXI (full round-trip through DDR model)
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        bfm_clear();
        imem_bram[0] = imm_instr(7'h13, 5'd1, 3'd0, 5'd0, 12'd123);    // ADDI x1,x0,123
        imem_bram[1] = imm_instr(7'h13, 5'd2, 3'd0, 5'd0, 12'd4);      // ADDI x2,x0,4
        imem_bram[2] = store_instr(5'd1, 5'd2, 12'd0, 3'b010);         // SW x1,0(x2)
        imem_bram[3] = NOP;
        imem_bram[4] = load_instr(5'd3, 5'd2, 12'd0, 3'b010);          // LW x3,0(x2)
        imem_bram[5] = SPIN;
        rst_n = 1'b0; repeat(3) @(posedge clk); rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat(120) @(posedge clk);
        check_x("x1 (SW source)",                reg_val(1), XLEN'(123));
        check_x("x3 (LW after SW, AXI rt)",      reg_val(3), XLEN'(123));

        // [12] Back-to-back loads (no NOP between) over AXI: stress consecutive
        //      data transactions with variable latency.
        // x1=dmem[0]=0x11, x2=dmem[1]=0x22, x3=dmem[2]=0x33
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        bfm_clear();
        bfm_set_word(0, 32'h11); bfm_set_word(1, 32'h22); bfm_set_word(2, 32'h33);
        imem_bram[0] = load_instr(5'd1, 5'd0, 12'd0, 3'b010);          // LW x1,0(x0)
        imem_bram[1] = load_instr(5'd2, 5'd0, 12'd4, 3'b010);          // LW x2,4(x0)
        imem_bram[2] = load_instr(5'd3, 5'd0, 12'd8, 3'b010);          // LW x3,8(x0)
        imem_bram[3] = SPIN;
        rst_n = 1'b0; repeat(3) @(posedge clk); rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat(120) @(posedge clk);
        check_x("x1 (b2b LW0)", reg_val(1), XLEN'(32'h11));
        check_x("x2 (b2b LW1)", reg_val(2), XLEN'(32'h22));
        check_x("x3 (b2b LW2)", reg_val(3), XLEN'(32'h33));

        // [13] Misaligned CROSSING load over AXI (2-phase mal FSM).
        //   mem[0..3]=AABBCCDD (LE), mem[4..7]=11223344 (LE).
        //   LW @ addr 2 reads bytes 2,3,4,5 = BB AA 44 33 -> 0x3344AABB.
        // This exercises the variable-latency mal_first_data capture: phase 0
        // reads word@0, phase 1 reads word@4, WB combines.
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        bfm_clear();
        bfm_set_word(0, 32'hAABB_CCDD); bfm_set_word(1, 32'h1122_3344);
        imem_bram[0] = imm_instr(7'h13, 5'd2, 3'd0, 5'd0, 12'd2);     // addi x2,x0,2
        imem_bram[1] = load_instr(5'd5, 5'd2, 12'd0, 3'b010);         // lw x5,0(x2) crossing
        imem_bram[2] = SPIN;
        rst_n = 1'b0; repeat(3) @(posedge clk); rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat(120) @(posedge clk);
        check_x("x5 (crossing LW@2)", reg_val(5), XLEN'(32'h3344AABB));

        // [14] Misaligned CROSSING store over AXI, then read back.
        //   SW x6=0xDEADBEEF @ addr 6 (bytes 6,7,8,9 -> crosses word1/word2).
        //   LW @ addr 6 reads it back.
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        bfm_clear();
        imem_bram[0] = imm_instr(7'h13, 5'd2, 3'd0, 5'd0, 12'd6);     // addi x2,x0,6 (addr)
        // build x6 = 0xDEADBEEF via lui 0xDEADC + addi -0x111 (imm 0xEEF)
        imem_bram[1] = {20'hDEADC, 5'd6, 7'h37};                      // lui x6,0xDEADC
        imem_bram[2] = imm_instr(7'h13, 5'd6, 3'd0, 5'd6, 12'hEEF);   // addi x6,x6,-0x111 -> 0xDEADBEEF
        imem_bram[3] = store_instr(5'd6, 5'd2, 12'd0, 3'b010);        // sw x6,0(x2) crossing
        imem_bram[4] = NOP;
        imem_bram[5] = load_instr(5'd7, 5'd2, 12'd0, 3'b010);         // lw x7,0(x2) crossing
        imem_bram[6] = SPIN;
        rst_n = 1'b0; repeat(3) @(posedge clk); rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat(160) @(posedge clk);
        check_x("x6 (store value)",        reg_val(6), XLEN'(32'hDEADBEEF));
        check_x("x7 (crossing SW->LW@6)",  reg_val(7), XLEN'(32'hDEADBEEF));

        $display("\n=== Results: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL TESTS PASSED");
        else               $display("TESTS FAILED");
        $finish;
    end

    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
