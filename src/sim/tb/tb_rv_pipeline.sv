// =============================================================================
// tb_rv_pipeline.sv — Minimal Pipeline Forwarding Tests
// =============================================================================
// Tests core data forwarding behavior: EX/MEM, MEM/WB, and double forwarding.
// Focus on register-to-register operations to verify pipeline dataflow.
// Note: Memory operations are tested separately in sim_core/sim_soc
//
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_pipeline;

    import rv_pkg::*;

    localparam int XLEN       = rv_pkg::XLEN;
    localparam int CLK_PERIOD = 10;

    logic clk, rst_n;

    logic [XLEN-1:0]     imem_addr, dmem_addr, dmem_wdata, dmem_rdata;
    logic                imem_req, dmem_req, dmem_we;
    logic [31:0]         imem_rdata;
    logic                imem_ready, dmem_ready;
    logic [XLEN/8-1:0]   dmem_wstrb;

    logic [XLEN-1:0]     satp_out;
    priv_level_t         priv_out;
    logic                mstatus_sum_out, mstatus_mxr_out, tlb_flush_out;

    logic timer_irq = 1'b0, sw_irq = 1'b0, ext_irq = 1'b0;

    // Behavioral IMEM/DMEM
    logic [31:0] imem_bram [0:255];
    logic [31:0] dmem_bram [0:255];

    // =========================================================================
    // DUT: rv_core
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
        .tlb_flush_out   (tlb_flush_out),
        .mmu_stall       (1'b0),
        .mem_stall       (1'b0),
        .if_fault        (1'b0),
        .mem_fault       (1'b0),
        .timer_irq       (timer_irq),
        .sw_irq          (sw_irq),
        .ext_irq         (ext_irq)
    );

    // Clock and memory models
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

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dmem_rdata <= '0;
            dmem_ready <= 1'b0;
        end else begin
            dmem_ready <= dmem_req;
            if (dmem_req && dmem_we) begin
                if (dmem_wstrb[0]) dmem_bram[dmem_addr[9:2]][ 7: 0] <= dmem_wdata[ 7: 0];
                if (dmem_wstrb[1]) dmem_bram[dmem_addr[9:2]][15: 8] <= dmem_wdata[15: 8];
                if (dmem_wstrb[2]) dmem_bram[dmem_addr[9:2]][23:16] <= dmem_wdata[23:16];
                if (dmem_wstrb[3]) dmem_bram[dmem_addr[9:2]][31:24] <= dmem_wdata[31:24];
            end
            if (dmem_req && !dmem_we)
                dmem_rdata <= dmem_bram[dmem_addr[9:2]];
        end
    end

    // Test helpers
    int pass_cnt = 0, fail_cnt = 0;

    localparam logic [31:0] NOP  = 32'h0000_0013;   // ADDI x0, x0, 0
    localparam logic [31:0] SPIN = 32'h0000_006F;   // JAL x0, 0

    function automatic logic [XLEN-1:0] reg_val(input int n);
        return dut.u_regfile.regs[n];
    endfunction

    task automatic check_x(input string name,
                            input logic [XLEN-1:0] got, exp);
        if (got === exp) begin
            $display("  PASS: %s = 0x%0h", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %s got=0x%0h exp=0x%0h", name, got, exp);
            fail_cnt++;
        end
    endtask

    // Instruction encoding helpers
    function automatic logic [31:0] imm_instr(input [6:0] opcode,
                                              input [4:0] rd,
                                              input [2:0] funct3,
                                              input [4:0] rs1,
                                              input [11:0] imm);
        return {imm, rs1, funct3, rd, opcode};
    endfunction

    function automatic logic [31:0] reg_instr(input [6:0] opcode,
                                              input [4:0] rd,
                                              input [2:0] funct3,
                                              input [4:0] rs1,
                                              input [4:0] rs2,
                                              input [6:0] funct7);
        return {funct7, rs2, rs1, funct3, rd, opcode};
    endfunction

    // JAL rd, offset  (offset is signed PC-relative byte offset, must be even)
    // Encoding: {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'h6F}
    function automatic logic [31:0] jal_instr(input [4:0] rd,
                                              input signed [20:0] offset);
        logic [20:0] imm;
        imm = offset;
        return {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'h6F};
    endfunction

    // JALR rd, rs1, imm  (jump to (rs1+imm)&~1, rd = PC+4)
    function automatic logic [31:0] jalr_instr(input [4:0] rd,
                                               input [4:0] rs1,
                                               input [11:0] imm);
        return {imm, rs1, 3'b000, rd, 7'h67};
    endfunction

    // Branch rs1, rs2, funct3, offset  (offset signed PC-relative, even)
    // Encoding: {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], 7'h63}
    function automatic logic [31:0] branch_instr(input [4:0] rs1,
                                                  input [4:0] rs2,
                                                  input [2:0] funct3,
                                                  input signed [12:0] offset);
        logic [12:0] imm;
        imm = offset;
        return {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], 7'h63};
    endfunction

    // LW/LB/LBU/LH/LHU rd, imm(rs1)
    function automatic logic [31:0] load_instr(input [4:0] rd,
                                               input [4:0] rs1,
                                               input [11:0] imm,
                                               input [2:0] funct3);
        return {imm, rs1, funct3, rd, 7'h03};
    endfunction

    // SW/SH/SB rs2, imm(rs1)  (S-type: opcode=0100011)
    function automatic logic [31:0] store_instr(input [4:0] rs2,
                                                input [4:0] rs1,
                                                input [11:0] imm,
                                                input [2:0]  funct3);
        return {imm[11:5], rs2, rs1, funct3, imm[4:0], 7'h23};
    endfunction

    // =========================================================================
    // VCD
    // =========================================================================
    initial begin
        $dumpfile("wave/tb_rv_pipeline.vcd");
        $dumpvars(0, tb_rv_pipeline);
    end

    // =========================================================================
    // Debug monitors
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n && imem_req && imem_ready) begin
            $display("[IMEM] @%0t: addr=%08h imem_addr[9:2]=%0d",
                     $time, imem_addr, imem_addr[9:2]);
        end
    end

    always @(posedge clk) begin
        if (rst_n && dut.wb_reg_write && dut.wb_rd_addr != 0) begin
            $display("[WB] @%0t: x%0d <= %016h",
                     $time, dut.wb_rd_addr, dut.wb_data);
        end
    end

    // =========================================================================
    // Test sequence
    // =========================================================================
    initial begin
        $display("=== tb_rv_pipeline: Register Forwarding Tests ===\n");

        // Initialize memory BEFORE reset
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        for (int i = 0; i < 256; i++) dmem_bram[i] = 32'h0;

        // ================================================================
        // [1] EX/MEM Forwarding
        // ADDI x1, x0, 10  → x1 = 10
        // ADD  x2, x1, x1  → x2 = 20 (forwarded from EX/MEM)
        // ================================================================
        $display("[1] EX/MEM Forwarding (result used 1 instruction later)");
        imem_bram[0] = imm_instr(7'h13, 5'd1, 3'd0, 5'd0, 12'd10);  // ADDI x1, x0, 10
        imem_bram[1] = reg_instr(7'h33, 5'd2, 3'd0, 5'd1, 5'd1, 7'd0);  // ADD x2, x1, x1
        imem_bram[2] = SPIN;

        // Now reset with program loaded
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // Clear all registers
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat (40) @(posedge clk);
        check_x("x1", reg_val(1), XLEN'(10));
        check_x("x2 (EX/MEM fwd)", reg_val(2), XLEN'(20));

        // ================================================================
        // [2] MEM/WB Forwarding
        // ADDI x1, x0, 7   → x1 = 7
        // NOP
        // ADD  x3, x1, x1  → x3 = 14 (forwarded from MEM/WB)
        // ================================================================
        $display("\n[2] MEM/WB Forwarding (result used 2 instructions later)");
        imem_bram[0] = imm_instr(7'h13, 5'd1, 3'd0, 5'd0, 12'd7);   // ADDI x1, x0, 7
        imem_bram[1] = NOP;
        imem_bram[2] = reg_instr(7'h33, 5'd3, 3'd0, 5'd1, 5'd1, 7'd0);  // ADD x3, x1, x1
        imem_bram[3] = SPIN;

        // Reset and clear registers
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat (40) @(posedge clk);
        check_x("x1", reg_val(1), XLEN'(7));
        check_x("x3 (MEM/WB fwd)", reg_val(3), XLEN'(14));

        // ================================================================
        // [3] Double Forwarding (same register forwarded to rs1 and rs2)
        // ADDI x1, x0, 3   → x1 = 3
        // ADD  x1, x1, x1  → x1 = 6  (EX/MEM fwd to both rs1 and rs2)
        // ADD  x2, x1, x1  → x2 = 12 (MEM/WB fwd to both rs1 and rs2)
        // ================================================================
        $display("\n[3] Double Forwarding (rs1=rs2)");
        imem_bram[0] = imm_instr(7'h13, 5'd1, 3'd0, 5'd0, 12'd3);   // ADDI x1, x0, 3
        imem_bram[1] = reg_instr(7'h33, 5'd1, 3'd0, 5'd1, 5'd1, 7'd0);  // ADD x1, x1, x1
        imem_bram[2] = reg_instr(7'h33, 5'd2, 3'd0, 5'd1, 5'd1, 7'd0);  // ADD x2, x1, x1
        imem_bram[3] = SPIN;

        // Reset and clear registers
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat (40) @(posedge clk);
        check_x("x1", reg_val(1), XLEN'(6));
        check_x("x2 (double fwd)", reg_val(2), XLEN'(12));

        // ================================================================
        // [4] Load-Use Hazard: LW result used immediately by next instruction
        //
        // Bug detected: without Fix-2 (EX/MEM incorrectly flushed on load-use),
        // the LOAD was discarded from EX/MEM and never reached MEM, so DMEM
        // was never accessed and x2/x3 would both be 0.
        //
        // LW x2, 0(x0)    -> x2 = dmem[0] = 0x42  (1-cycle hazard stall)
        // ADD x3, x2, x0  -> x3 = x2 = 0x42 (forwarded via MEM/WB after stall)
        // ================================================================
        $display("\n[4] Load-Use Hazard (LW result used 1 instruction later)");
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        dmem_bram[0] = 32'h0000_0042;  // preload dmem[word 0] = 0x42
        imem_bram[0] = load_instr(5'd2, 5'd0, 12'd0, 3'b010); // LW  x2, 0(x0)
        imem_bram[1] = reg_instr (7'h33, 5'd3, 3'd0, 5'd2, 5'd0, 7'd0); // ADD x3, x2, x0
        imem_bram[2] = SPIN;

        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat(40) @(posedge clk);
        check_x("x2 (LW result)", reg_val(2), XLEN'(32'h42));
        check_x("x3 (load-use fwd)", reg_val(3), XLEN'(32'h42));

        // ================================================================
        // [5] JAL rd writeback
        //
        // Bug detected: without Fix-2, JAL in EX caused flush_ex=1 which also
        // cleared EX/MEM, so JAL's return address (PC+4) was never written to rd.
        //
        // PC=0: JAL x1, +8   -> x1 = 4 (PC+4), jumps to PC=8
        // PC=4: ADDI x1,x0,0 -> MUST be flushed by JAL (should NOT execute)
        // PC=8: SPIN
        // ================================================================
        $display("\n[5] JAL rd writeback (return address written correctly)");
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        imem_bram[0] = jal_instr(5'd1, 21'sd8);    // JAL x1, +8
        imem_bram[1] = imm_instr(7'h13, 5'd1, 3'd0, 5'd0, 12'd0); // ADDI x1,x0,0 (flushed)
        imem_bram[2] = SPIN;                         // at PC=8

        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat(40) @(posedge clk);
        check_x("x1 (JAL ra = PC+4)", reg_val(1), XLEN'(4));

        // ================================================================
        // [6] Instruction before JAL still commits (EX/MEM not spuriously flushed)
        //
        // Bug detected: without Fix-2, ADDI in EX/MEM when JAL is in EX was
        // flushed, so x1 would be 0 instead of 42.
        //
        // PC=0:  ADDI x1, x0, 42  -> x1 = 42  (must commit)
        // PC=4:  JAL  x0, +8      -> jump to PC=12
        // PC=8:  ADDI x1, x0, 0   -> MUST be flushed (should NOT execute)
        // PC=12: SPIN
        // ================================================================
        $display("\n[6] Instruction before JAL commits (EX/MEM not flushed on branch)");
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        imem_bram[0] = imm_instr(7'h13, 5'd1, 3'd0, 5'd0, 12'd42); // ADDI x1,x0,42
        imem_bram[1] = jal_instr(5'd0, 21'sd8);                      // JAL x0, +8
        imem_bram[2] = imm_instr(7'h13, 5'd1, 3'd0, 5'd0, 12'd0);   // ADDI x1,x0,0 (flushed)
        imem_bram[3] = SPIN;                                           // at PC=12

        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat(40) @(posedge clk);
        check_x("x1 (ADDI before JAL)", reg_val(1), XLEN'(42));

        // ================================================================
        // [7] BEQ taken: instruction before branch commits
        //
        // Same bug class as [6] but with a conditional branch (BEQ) instead of JAL.
        //
        // PC=0:  ADDI x1, x0, 99  -> x1 = 99  (must commit)
        // PC=4:  BEQ  x0, x0, +8  -> always taken, jump to PC=12
        // PC=8:  ADDI x1, x0, 0   -> MUST be flushed (should NOT execute)
        // PC=12: SPIN
        // ================================================================
        $display("\n[7] BEQ taken: instruction before branch commits");
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        imem_bram[0] = imm_instr(7'h13, 5'd1, 3'd0, 5'd0, 12'd99);  // ADDI x1,x0,99
        imem_bram[1] = branch_instr(5'd0, 5'd0, 3'b000, 13'sd8);      // BEQ x0,x0,+8
        imem_bram[2] = imm_instr(7'h13, 5'd1, 3'd0, 5'd0, 12'd0);    // ADDI x1,x0,0 (flushed)
        imem_bram[3] = SPIN;                                            // at PC=12

        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat(40) @(posedge clk);
        check_x("x1 (ADDI before BEQ)", reg_val(1), XLEN'(99));

        // ================================================================
        // [8] JALR: register-indirect jump with rd writeback
        //
        // Exercises EX/MEM forwarding for the JALR base register (rs1=x2),
        // and correct rd writeback via EX/MEM (same bug class as [5]).
        //
        // PC=0:  ADDI x2, x0, 16  -> x2 = 16
        // PC=4:  JALR x1, x2, 0   -> jump to x2+0=16, x1 = 8 (PC+4)
        // PC=8:  NOP               (flushed)
        // PC=12: NOP               (flushed)
        // PC=16: SPIN
        // ================================================================
        $display("\n[8] JALR: register-indirect jump + rd writeback");
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        imem_bram[0] = imm_instr(7'h13, 5'd2, 3'd0, 5'd0, 12'd16);  // ADDI x2,x0,16
        imem_bram[1] = jalr_instr(5'd1, 5'd2, 12'd0);                 // JALR x1,x2,0
        imem_bram[2] = NOP;   // flushed
        imem_bram[3] = NOP;   // flushed
        imem_bram[4] = SPIN;  // at PC=16

        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat(40) @(posedge clk);
        check_x("x1 (JALR ra = PC+4)", reg_val(1), XLEN'(8));
        check_x("x2 (JALR rs1 unchanged)", reg_val(2), XLEN'(16));

        // ================================================================
        // [9] Load-Use Stall + Branch NOT Taken: fall-through must not be skipped
        //
        // Root cause: During a load-use stall (stall_if=1), the synchronous BRAM
        // receives the already-advanced pc_reg (next-next PC) instead of re-fetching
        // the same address.  The instruction arriving in imem_rdata during the stall
        // cycle is DISCARDED (if_id is stalled), and when the stall resolves the BRAM
        // delivers the WRONG instruction one position ahead.
        // Fix: drive imem_addr = fetch_pc (not pc_reg) during stall, so the BRAM
        // re-delivers mem[fetch_pc] in the first post-stall cycle.
        //
        // PC=0:  LBU x3, 0(x0)    -> x3 = 0x42  (load-use stall with BEQ)
        // PC=4:  BEQ x3, x0, +16  -> NOT taken (x3=0x42 != 0)
        // PC=8:  ADDI x4, x0, 77  -> MUST execute (silently skipped before fix)
        // PC=12: SPIN
        // ================================================================
        $display("\n[9] Load-Use + BEQ NOT Taken: fall-through must not be skipped");
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        for (int i = 0; i < 256; i++) dmem_bram[i] = 32'h0;
        dmem_bram[0] = 32'h0000_0042;
        imem_bram[0] = load_instr(5'd3, 5'd0, 12'd0, 3'b100);           // LBU x3, 0(x0)
        imem_bram[1] = branch_instr(5'd3, 5'd0, 3'b000, 13'sd16);       // BEQ x3,x0,+16 NOT taken
        imem_bram[2] = imm_instr(7'h13, 5'd4, 3'd0, 5'd0, 12'd77);     // ADDI x4,x0,77
        imem_bram[3] = SPIN;

        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat(40) @(posedge clk);
        check_x("x3 (LBU result)", reg_val(3), XLEN'(32'h42));
        check_x("x4 (fall-through ADDI)", reg_val(4), XLEN'(77));

        // ================================================================
        // [10] Load-Use Stall + BNE NOT Taken: fall-through must not be skipped
        //
        // Same BRAM-skip bug as [9] but exercising BNE (the exact scenario from
        // uart_puts in hello.elf: lbu a5,0(s0) / bne a5,s1,loop).
        // When BNE is NOT taken (a5 == s1), the instruction right after BNE was
        // silently replaced by the one two positions ahead.
        //
        // PC=0:  ADDI x9, x0, 10  -> x9 = 10 (sentinel = newline)
        // PC=4:  LBU  x3, 0(x0)   -> x3 = 10 (== x9; load-use stall with BNE)
        // PC=8:  BNE  x3, x9, +16 -> NOT taken (x3 == x9 == 10)
        // PC=12: ADDI x4, x0, 88  -> MUST execute (silently skipped before fix)
        // PC=16: SPIN
        // ================================================================
        $display("\n[10] Load-Use + BNE NOT Taken: fall-through must not be skipped");
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        for (int i = 0; i < 256; i++) dmem_bram[i] = 32'h0;
        dmem_bram[0] = 32'h0000_000A;                                    // byte 10 = '\n'
        imem_bram[0] = imm_instr(7'h13, 5'd9, 3'd0, 5'd0, 12'd10);     // ADDI x9,x0,10
        imem_bram[1] = load_instr(5'd3, 5'd0, 12'd0, 3'b100);           // LBU x3, 0(x0)
        imem_bram[2] = branch_instr(5'd3, 5'd9, 3'b001, 13'sd16);       // BNE x3,x9,+16 NOT taken
        imem_bram[3] = imm_instr(7'h13, 5'd4, 3'd0, 5'd0, 12'd88);     // ADDI x4,x0,88
        imem_bram[4] = SPIN;

        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat(40) @(posedge clk);
        check_x("x3 (LBU=10)", reg_val(3), XLEN'(10));
        check_x("x4 (fall-through ADDI)", reg_val(4), XLEN'(88));

        // ================================================================
        // [11] SW wstrb: SW to address where addr[2]=1 (addr mod 8 >= 4)
        //
        // Bug: dmem_wstrb = (4'hF) << ex_mem_alu_result[2:0]
        //   For addr[2:0]=4: wstrb = 4'hF << 4 = 4'h0 -> NO BYTES WRITTEN
        //   This silently drops every SW to addresses like stack offsets
        //   that land in the upper half of an 8-byte aligned block.
        //   Symptom: main()'s "sw ra, 28(sp)" fails -> ra is lost -> ret
        //   jumps to PC=0 (_start) -> infinite banner loop in sim_bm.
        //
        // Fix: use addr[$clog2(XLEN/8)-1:0] = addr[1:0] for RV32
        //   -> wstrb = 4'hF << 0 = 4'hF (word-aligned SW always writes all bytes)
        //
        // PC=0: ADDI x1, x0, 123  -> x1 = 123
        // PC=4: ADDI x2, x0, 4    -> x2 = 4  (addr[2:0]=4, addr[2]=1)
        // PC=8: SW x1, 0(x2)      -> store 123 to dmem[word 1] (addr=4)
        // PC=12: NOP               -> pipeline drain
        // PC=16: LW x3, 0(x2)     -> load back from addr=4
        // PC=20: SPIN
        // ================================================================
        $display("\n[11] SW wstrb: SW to addr[2]=1 must write all bytes");
        for (int i = 0; i < 256; i++) imem_bram[i] = NOP;
        for (int i = 0; i < 256; i++) dmem_bram[i] = 32'h0;
        imem_bram[0] = imm_instr(7'h13, 5'd1, 3'd0, 5'd0, 12'd123);    // ADDI x1,x0,123
        imem_bram[1] = imm_instr(7'h13, 5'd2, 3'd0, 5'd0, 12'd4);      // ADDI x2,x0,4
        imem_bram[2] = store_instr(5'd1, 5'd2, 12'd0, 3'b010);          // SW x1, 0(x2)
        imem_bram[3] = NOP;                                              // drain pipeline
        imem_bram[4] = load_instr(5'd3, 5'd2, 12'd0, 3'b010);           // LW x3, 0(x2)
        imem_bram[5] = SPIN;

        rst_n = 1'b0;
        repeat(3) @(posedge clk);
        rst_n = 1'b1;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = {XLEN{1'b0}};
        repeat(50) @(posedge clk);
        check_x("x1 (SW source)", reg_val(1), XLEN'(123));
        check_x("x3 (LW after SW addr[2]=1)", reg_val(3), XLEN'(123));

        // ================================================================
        // Results
        // ================================================================
        $display("\n=== Results: %0d passed, %0d failed ===",
                 pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        $finish;
    end

endmodule
