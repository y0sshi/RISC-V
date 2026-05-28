// =============================================================================
// tb_rv_mal.sv - Misaligned Memory Access Tests
// =============================================================================
// Exercises every hardware fix applied during riscv-tests debugging.
//
// Bugs covered:
//  [A] rv_core: mem_wb_byte_offset widened [1:0]->[2:0] — byte offset>=4 wrong shift
//  [B] rv_dmem: word_addr not 8-byte aligned for RV64 — SW at addr[2]=1 wrong BRAM word
//  [C] rv_core: store wdata replication -> direct shift — SH/SW at offset 1..7
//  [D] rv_core: crossing load combine — LH/LW/LD spanning 8-byte boundary
//  [E] rv_core: crossing store + load-back verify
//  [F] rv_core: flush_ex suppression (stall_ex=1): crossing SD then LD back-to-back
//  [G] rv_core: crossing LD + dependent ALU (load-use hazard meets mal_stall)
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_rv_mal;
    import rv_pkg::*;

    localparam int XLEN       = 64;
    localparam int CLK_PERIOD = 10;

    logic clk = 0, rst_n = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // DUT 1: rv_core with byte-addressed DMEM model
    // =========================================================================
    logic [63:0] imem_addr, dmem_addr, dmem_wdata, dmem_rdata;
    logic        imem_req,  dmem_req,  dmem_we;
    logic [31:0] imem_rdata;
    logic        imem_ready, dmem_ready;
    logic [7:0]  dmem_wstrb;
    logic [63:0] satp_out;
    logic [1:0]  priv_out;
    logic        mstatus_sum_out, mstatus_mxr_out, tlb_flush_out;

    logic [31:0] imem_bram [0:511];
    logic [7:0]  dmem_b    [0:4095];

    logic [31:0] imem_rdata_r = '0;
    logic        imem_ready_r = 0;
    assign imem_rdata = imem_rdata_r;
    assign imem_ready = imem_ready_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            imem_rdata_r <= 32'h0000_0013;
            imem_ready_r <= 1'b0;
        end else begin
            imem_ready_r <= imem_req;
            if (imem_req)
                imem_rdata_r <= imem_bram[imem_addr[$clog2(512)+1:2]];
        end
    end

    logic [63:0] dmem_rdata_r = '0;
    logic        dmem_ready_r = 0;
    assign dmem_rdata = dmem_rdata_r;
    assign dmem_ready = dmem_ready_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dmem_rdata_r <= '0;
            dmem_ready_r <= 1'b0;
        end else begin
            dmem_ready_r <= dmem_req;
            if (dmem_req && dmem_we) begin
                for (int i = 0; i < 8; i++)
                    if (dmem_wstrb[i])
                        dmem_b[(dmem_addr & ~64'h7) + i] <= dmem_wdata[i*8+:8];
            end else if (dmem_req)
                dmem_rdata_r <= {dmem_b[(dmem_addr & ~64'h7)+7],
                                 dmem_b[(dmem_addr & ~64'h7)+6],
                                 dmem_b[(dmem_addr & ~64'h7)+5],
                                 dmem_b[(dmem_addr & ~64'h7)+4],
                                 dmem_b[(dmem_addr & ~64'h7)+3],
                                 dmem_b[(dmem_addr & ~64'h7)+2],
                                 dmem_b[(dmem_addr & ~64'h7)+1],
                                 dmem_b[(dmem_addr & ~64'h7)+0]};
        end
    end

    rv_core #(.XLEN(64), .RST_ADDR(64'h0)) dut (
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
        .timer_irq       (1'b0),
        .sw_irq          (1'b0),
        .ext_irq         (1'b0)
    );

    // =========================================================================
    // DUT 2: rv_dmem (direct instantiation for Bug [B])
    // =========================================================================
    logic [63:0] d2_addr  = '0;
    logic [63:0] d2_wdata = '0;
    logic [7:0]  d2_wstrb = '0;
    logic        d2_req   = 0;
    logic        d2_we    = 0;
    logic [63:0] d2_rdata;
    logic        d2_ready;

    rv_dmem #(.XLEN(64), .DEPTH(4096)) u_dmem2 (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (d2_addr),
        .wdata (d2_wdata),
        .wstrb (d2_wstrb),
        .req   (d2_req),
        .we    (d2_we),
        .rdata (d2_rdata),
        .ready (d2_ready)
    );

    // =========================================================================
    // Test helpers
    // =========================================================================
    int pass_cnt = 0, fail_cnt = 0;

    localparam logic [31:0] NOP  = 32'h0000_0013;
    localparam logic [31:0] SPIN = 32'h0000_006F;

    function automatic logic [63:0] reg_val(input int n);
        return dut.u_regfile.regs[n];
    endfunction

    task automatic check(input string name,
                         input logic [63:0] got, exp);
        if (got === exp) begin
            $display("  PASS: %s = 0x%016h", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %s got=0x%016h exp=0x%016h", name, got, exp);
            fail_cnt++;
        end
    endtask

    // Instruction encoders
    function automatic logic [31:0] addi(input [4:0] rd, input [4:0] rs1, input [11:0] imm);
        return {imm, rs1, 3'b000, rd, 7'h13};
    endfunction
    function automatic logic [31:0] add(input [4:0] rd, input [4:0] rs1, input [4:0] rs2);
        return {7'h00, rs2, rs1, 3'b000, rd, 7'h33};
    endfunction
    function automatic logic [31:0] lui(input [4:0] rd, input [19:0] imm20);
        return {imm20, rd, 7'h37};
    endfunction
    function automatic logic [31:0] load(input [4:0] rd, input [4:0] rs1, input [2:0] f3, input [11:0] imm);
        return {imm, rs1, f3, rd, 7'h03};
    endfunction
    function automatic logic [31:0] store(input [4:0] rs2, input [4:0] rs1, input [2:0] f3, input [11:0] imm);
        return {imm[11:5], rs2, rs1, f3, imm[4:0], 7'h23};
    endfunction

    // Reset core, clear state, run N cycles
    task automatic run_test(input int ncycles);
        rst_n = 0;
        for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = '0;
        for (int i = 0; i < 4096; i++) dmem_b[i] = 8'h0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (ncycles) @(posedge clk);
    endtask

    task automatic fill_rest(input int from);
        for (int i = from; i < 512; i++) imem_bram[i] = SPIN;
    endtask

    // =========================================================================
    // VCD
    // =========================================================================
    initial begin
        $dumpfile("wave/tb_rv_mal.vcd");
        $dumpvars(0, tb_rv_mal);
    end

    // =========================================================================
    // Test sequence
    // =========================================================================
    initial begin
        for (int i = 0; i < 512;  i++) imem_bram[i] = NOP;
        for (int i = 0; i < 4096; i++) dmem_b[i]    = 8'h0;

        $display("=== tb_rv_mal: Misaligned Memory Access Tests ===\n");

        // =====================================================================
        // [A] Bug: mem_wb_byte_offset truncation for byte offset >= 4
        //     Old code used [1:0], so offset=4 was treated as 0 (wrong shift)
        //     Fix: widened to [BYTE_LANE_W-1:0] = [2:0] for RV64
        //
        //     Test: LW at base+4 (non-crossing, bytes [4..7] of 8-byte block)
        //     Without fix: shift=0 -> reads bytes [0..3] instead of [4..7]
        // =====================================================================
        $display("[A] mem_wb_byte_offset widening: LW at byte offset=4");
        begin
            // x1 = 0x100 (data base, 8-byte aligned)
            imem_bram[0] = addi(5'd1, 5'd0, 12'h100);
            imem_bram[1] = load(5'd2, 5'd1, 3'b010, 12'd4); // lw x2, 4(x1)
            imem_bram[2] = load(5'd3, 5'd1, 3'b001, 12'd5); // lh x3, 5(x1)
            imem_bram[3] = SPIN;
            fill_rest(4);

            rst_n = 0;
            for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = '0;
            for (int i = 0; i < 4096; i++) dmem_b[i] = 8'h0;
            // Place 0xDEADBEEF at bytes [0x104..0x107]
            dmem_b['h104] = 8'hEF; dmem_b['h105] = 8'hBE;
            dmem_b['h106] = 8'hAD; dmem_b['h107] = 8'hDE;
            repeat (3) @(posedge clk);
            rst_n = 1;
            repeat (80) @(posedge clk);

            // LW sign-extends 0xDEADBEEF
            check("x2 LW@off=4",  reg_val(2), 64'hFFFF_FFFF_DEAD_BEEF);
            // LH at off=5: bytes [5..6] = {0xAD, 0xBE} -> little-endian 0xADBE -> sign-extend
            check("x3 LH@off=5",  reg_val(3), 64'hFFFF_FFFF_FFFF_ADBE);
        end

        // =====================================================================
        // [B] Bug: rv_dmem word_addr not 8-byte aligned for RV64
        //     Old: word_addr = addr >> 2  (4-byte index)
        //     For addr=0x104: old gives index=0x41, correct gives 0x40
        //     Fix: word_addr = {addr[N:3], 1'b0}  (8-byte aligned, even index)
        // =====================================================================
        $display("\n[B] rv_dmem word_addr alignment (SW at addr[2]=1)");
        begin
            rst_n = 0;
            repeat (3) @(posedge clk);
            rst_n = 1;
            repeat (2) @(posedge clk);

            // SW at 0x104: upper 4 bytes of aligned 8-byte block [0x100..0x107]
            // rv_core sends wstrb=8'hF0 for SW at byte offset=4
            d2_addr  = 64'h104;
            d2_wdata = 64'hDEAD_BEEF_DEAD_BEEF; // core replicates for aligned SW
            d2_wstrb = 8'hF0;                   // bytes [4..7] enabled
            d2_req   = 1'b1;
            d2_we    = 1'b1;
            @(posedge clk);
            d2_req = 1'b0; d2_we = 1'b0;
            repeat (3) @(posedge clk);

            // LD at 0x100 should return 0xDEADBEEF in upper half
            d2_addr = 64'h100;
            d2_req  = 1'b1;
            d2_we   = 1'b0;
            @(posedge clk);
            d2_req = 1'b0;
            repeat (2) @(posedge clk);
            // bytes [4..7] = DEAD_BEEF, bytes [0..3] = 0
            check("rv_dmem LD@0x100 after SW@0x104", d2_rdata, 64'hDEAD_BEEF_0000_0000);
        end

        // =====================================================================
        // [C] Bug: store wdata replication reversed byte order for offsets > 0
        //     Old: dmem_wdata = {(XLEN/16){rs2[15:0]}} for SH -> bytes reversed
        //     Fix: dmem_wdata = rs2 << mal_shl  (direct shift by byte_offset*8)
        // =====================================================================
        $display("\n[C1] Non-crossing SH at offset=1 (store wdata shift fix)");
        begin
            imem_bram[0] = addi(5'd1, 5'd0, 12'h100);
            imem_bram[1] = addi(5'd2, 5'd0, 12'h345);
            imem_bram[2] = store(5'd2, 5'd1, 3'b001, 12'd1); // sh x2, 1(x1)
            imem_bram[3] = load(5'd3,  5'd1, 3'b001, 12'd1); // lh x3, 1(x1)
            imem_bram[4] = SPIN;
            fill_rest(5);
            run_test(80);
            check("x3 LH@off=1 after SH", reg_val(3), 64'h0000_0000_0000_0345);
        end

        $display("\n[C2] Non-crossing SW at offset=2");
        begin
            imem_bram[0] = addi(5'd1, 5'd0, 12'h100);
            imem_bram[1] = addi(5'd2, 5'd0, 12'h7AB);
            imem_bram[2] = store(5'd2, 5'd1, 3'b010, 12'd2); // sw x2, 2(x1)
            imem_bram[3] = load(5'd3,  5'd1, 3'b010, 12'd2); // lw x3, 2(x1)
            imem_bram[4] = SPIN;
            fill_rest(5);
            run_test(80);
            check("x3 LW@off=2 after SW", reg_val(3), 64'h0000_0000_0000_07AB);
        end

        $display("\n[C3] Non-crossing SW at offset=5");
        begin
            imem_bram[0] = addi(5'd1, 5'd0, 12'h100);
            imem_bram[1] = addi(5'd2, 5'd0, 12'h123);
            imem_bram[2] = store(5'd2, 5'd1, 3'b010, 12'd5); // sw x2, 5(x1)
            imem_bram[3] = load(5'd3,  5'd1, 3'b010, 12'd5); // lw x3, 5(x1)
            imem_bram[4] = SPIN;
            fill_rest(5);
            run_test(80);
            check("x3 LW@off=5 after SW", reg_val(3), 64'h0000_0000_0000_0123);
        end

        // =====================================================================
        // [D] Crossing misaligned loads (span 8-byte boundary)
        //     Tests: mal_cross detection, 2-phase stall, WB combine logic
        // =====================================================================
        $display("\n[D1] Crossing LH at offset=7 (1+1 split across boundary)");
        begin
            imem_bram[0] = addi(5'd1, 5'd0, 12'h100);
            imem_bram[1] = load(5'd2, 5'd1, 3'b001, 12'd7); // lh x2, 7(x1)
            imem_bram[2] = SPIN;
            fill_rest(3);

            rst_n = 0;
            for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = '0;
            for (int i = 0; i < 4096; i++) dmem_b[i] = 8'h0;
            dmem_b['h107] = 8'h00;  // low byte  (first block)
            dmem_b['h108] = 8'h80;  // high byte (second block)
            repeat (3) @(posedge clk);
            rst_n = 1;
            repeat (80) @(posedge clk);
            // 0x8000 sign-extended to 64-bit
            check("x2 LH@off=7 crossing", reg_val(2), 64'hFFFF_FFFF_FFFF_8000);
        end

        $display("\n[D2] Crossing LW at offset=6 (2+2 split)");
        begin
            imem_bram[0] = addi(5'd1, 5'd0, 12'h100);
            imem_bram[1] = load(5'd2, 5'd1, 3'b010, 12'd6); // lw x2, 6(x1)
            imem_bram[2] = SPIN;
            fill_rest(3);

            rst_n = 0;
            for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = '0;
            for (int i = 0; i < 4096; i++) dmem_b[i] = 8'h0;
            // 0xDEADBEEF at bytes 0x106..0x109
            dmem_b['h106] = 8'hEF; dmem_b['h107] = 8'hBE;
            dmem_b['h108] = 8'hAD; dmem_b['h109] = 8'hDE;
            repeat (3) @(posedge clk);
            rst_n = 1;
            repeat (80) @(posedge clk);
            check("x2 LW@off=6 crossing", reg_val(2), 64'hFFFF_FFFF_DEAD_BEEF);
        end

        $display("\n[D3] Crossing LD at offset=1 (1+7 split)");
        begin
            imem_bram[0] = addi(5'd1, 5'd0, 12'h100);
            imem_bram[1] = load(5'd2, 5'd1, 3'b011, 12'd1); // ld x2, 1(x1)
            imem_bram[2] = SPIN;
            fill_rest(3);

            rst_n = 0;
            for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = '0;
            for (int i = 0; i < 4096; i++) dmem_b[i] = 8'h0;
            // 0xCAFEBABEDEADBEEF at bytes 0x101..0x108 (little-endian)
            dmem_b['h101] = 8'hEF; dmem_b['h102] = 8'hBE;
            dmem_b['h103] = 8'hAD; dmem_b['h104] = 8'hDE;
            dmem_b['h105] = 8'hBE; dmem_b['h106] = 8'hBA;
            dmem_b['h107] = 8'hFE; dmem_b['h108] = 8'hCA;
            repeat (3) @(posedge clk);
            rst_n = 1;
            repeat (80) @(posedge clk);
            check("x2 LD@off=1 crossing", reg_val(2), 64'hCAFE_BABE_DEAD_BEEF);
        end

        // =====================================================================
        // [E] Crossing store then load-back
        //     Tests: mal_cross store wdata, crossing store byte split
        // =====================================================================
        $display("\n[E] Crossing SD at offset=1, then LD back");
        begin
            // x2 = 0x12345678 via lui+addi
            imem_bram[0] = addi(5'd1, 5'd0, 12'h100);
            imem_bram[1] = lui(5'd2, 20'h12345);
            imem_bram[2] = addi(5'd2, 5'd2, 12'h678);        // x2 = 0x12345678
            imem_bram[3] = store(5'd2, 5'd1, 3'b011, 12'd1); // sd x2, 1(x1)
            imem_bram[4] = load(5'd3,  5'd1, 3'b011, 12'd1); // ld x3, 1(x1)
            imem_bram[5] = SPIN;
            fill_rest(6);
            run_test(100);
            check("x3 LD after crossing SD@off=1", reg_val(3), 64'h0000_0000_1234_5678);
        end

        // =====================================================================
        // [F] Pipeline bug: crossing SD followed immediately by LD (same addr)
        //     When crossing SD is in EX/MEM (mal_stall=1) AND next LD triggers
        //     load_use_hazard simultaneously, old code: flush_ex=1 unconditionally
        //     -> LD flushed from ID/EX -> LD lost from pipeline -> x3 never loaded
        //     Fix: flush_ex = (load_use_hazard && !stall_ex) | branch | trap
        // =====================================================================
        $display("\n[F] SD+LD back-to-back crossing (flush_ex suppression fix)");
        begin
            imem_bram[0] = addi(5'd1, 5'd0, 12'h100);
            imem_bram[1] = addi(5'd2, 5'd0, 12'h5A5);
            imem_bram[2] = store(5'd2, 5'd1, 3'b011, 12'd1); // sd x2, 1(x1) -- crossing
            imem_bram[3] = load(5'd3,  5'd1, 3'b011, 12'd1); // ld x3, 1(x1) -- immediately follows
            imem_bram[4] = SPIN;
            fill_rest(5);
            run_test(120);
            // Without fix: x3 retains old value (0) because LD was flushed
            check("x3 LD after back-to-back crossing SD (pipeline fix)", reg_val(3), 64'h0000_0000_0000_05A5);
        end

        // =====================================================================
        // [G] Crossing LD + dependent ALU instruction
        //     Tests: load-use hazard detection still works with mal_stall active,
        //     forwarding path carries crossing-load result to next ALU op
        // =====================================================================
        $display("\n[G] Crossing LD + dependent ADD (load-use hazard meets mal_stall)");
        begin
            imem_bram[0] = addi(5'd1, 5'd0, 12'h100);
            imem_bram[1] = load(5'd2, 5'd1, 3'b011, 12'd3);  // ld x2, 3(x1)  crossing
            imem_bram[2] = add(5'd3, 5'd2, 5'd2);             // add x3, x2, x2  (depends on x2)
            imem_bram[3] = SPIN;
            fill_rest(4);

            rst_n = 0;
            for (int i = 0; i < 32; i++) dut.u_regfile.regs[i] = '0;
            for (int i = 0; i < 4096; i++) dmem_b[i] = 8'h0;
            // 0x0000_0000_0000_0042 at bytes 0x103..0x10A (little-endian)
            dmem_b['h103] = 8'h42;
            // bytes 0x104..0x10A = 0x00 (already cleared)
            repeat (3) @(posedge clk);
            rst_n = 1;
            repeat (100) @(posedge clk);
            check("x2 crossing LD@off=3",     reg_val(2), 64'h0000_0000_0000_0042);
            check("x3 ADD x2+x2 (dep on LD)", reg_val(3), 64'h0000_0000_0000_0084);
        end

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n=== Summary: %0d/%0d passed, %0d failed ===",
                 pass_cnt, pass_cnt + fail_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL PASS");
        else
            $display("SOME TESTS FAILED");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
