// =============================================================================
// tb_rv_amo.sv — Unit testbench for RV32A / RV64A AMO compute unit (rv_amo)
// =============================================================================
// Tests the combinational rv_amo module for all AMO operations.
// LR / SC pipeline integration is verified via tb_rv_core.
//
// Tests:
//   [1]  AMO_LR   — result = old_data (no write)
//   [2]  AMO_SC   — result = rs2_data  (conditional write handled in rv_core)
//   [3]  AMO_SWAP — result = rs2_data
//   [4]  AMO_ADD  — result = old + rs2
//   [5]  AMO_XOR  — result = old ^ rs2
//   [6]  AMO_AND  — result = old & rs2
//   [7]  AMO_OR   — result = old | rs2
//   [8]  AMO_MIN  — signed min(old, rs2)
//   [9]  AMO_MAX  — signed max(old, rs2)
//  [10]  AMO_MINU — unsigned min(old, rs2)
//  [11]  AMO_MAXU — unsigned max(old, rs2)
//  [12]  W-type overflow / corner cases
//  [13]  D-type operations (XLEN=64 only)
//
// Compile default (XLEN=32): make sim_amo
// Compile with XLEN=64:       make sim_amo64
//
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_amo;

    import rv_pkg::*;

    localparam int XLEN = rv_pkg::XLEN;

    // =========================================================================
    // DUT
    // =========================================================================
    logic [XLEN-1:0] old_data;
    logic [XLEN-1:0] rs2_data;
    amo_op_t          op;
    logic [2:0]       funct3;
    logic [XLEN-1:0] new_data;

    // funct3: 3'b010 = W (32-bit), 3'b011 = D (XLEN-bit)
    localparam logic [2:0] F3_W = 3'b010;
    localparam logic [2:0] F3_D = 3'b011;

    rv_amo #(.XLEN(XLEN)) dut (
        .old_data (old_data),
        .rs2_data (rs2_data),
        .op       (op),
        .funct3   (funct3),
        .new_data (new_data)
    );

    // =========================================================================
    // Helpers
    // =========================================================================
    int pass_cnt, fail_cnt;

    task check(input string name,
               input logic [XLEN-1:0] got, exp);
        if (got === exp) begin
            $display("  PASS: %-52s = 0x%0h", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %-52s  got=0x%0h  exp=0x%0h", name, got, exp);
            fail_cnt++;
        end
    endtask

    // Drive 64-bit literals, auto-truncated to XLEN for RV32.
    task test(
        input string    name,
        input amo_op_t  aop,
        input [2:0]     f3,
        input [63:0]    old, rs2, exp
    );
        old_data = xlen_t'(old);
        rs2_data = xlen_t'(rs2);
        op       = aop;
        funct3   = f3;
        #1;
        check(name, new_data, xlen_t'(exp));
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    initial begin
        $dumpfile("wave/tb_rv_amo.vcd");
        $dumpvars(0, tb_rv_amo);
        pass_cnt = 0;
        fail_cnt = 0;

        $display("=== A-Extension AMO Compute Unit Test (XLEN=%0d) ===", XLEN);

        // ------------------------------------------------------------------
        // [1] AMO_LR: new_data = old_data (no write; rv_core suppresses write)
        // ------------------------------------------------------------------
        $display("\n[1] AMO_LR (new_data = old_data)");
        test("LR old=0xDEAD_BEEF",
             AMO_LR, F3_W,
             64'hDEAD_BEEF, 64'h0,
             64'hFFFF_FFFF_DEAD_BEEF);   // sign-extended for W mode

        // ------------------------------------------------------------------
        // [2] AMO_SC: new_data = rs2_data (rv_core applies reservation check)
        // ------------------------------------------------------------------
        $display("\n[2] AMO_SC (new_data = rs2_data)");
        test("SC old=5 rs2=99",
             AMO_SC, F3_W,
             64'd5, 64'd99,
             64'd99);

        // ------------------------------------------------------------------
        // [3] AMOSWAP
        // ------------------------------------------------------------------
        $display("\n[3] AMOSWAP");
        test("SWAP old=0xAA rs2=0xBB",
             AMO_SWAP, F3_W,
             64'hAA, 64'hBB, 64'hBB);
        test("SWAP old=0 rs2=MAX",
             AMO_SWAP, F3_W,
             64'h0,
             XLEN == 64 ? 64'hFFFF_FFFF_FFFF_FFFF : 64'hFFFF_FFFF,
             XLEN == 64 ? 64'hFFFF_FFFF_FFFF_FFFF : 64'hFFFF_FFFF);

        // ------------------------------------------------------------------
        // [4] AMOADD
        // ------------------------------------------------------------------
        $display("\n[4] AMOADD");
        test("ADD 10 + 3 = 13",      AMO_ADD, F3_W, 64'd10,  64'd3,  64'd13);
        test("ADD 0 + 0 = 0",        AMO_ADD, F3_W, 64'd0,   64'd0,  64'd0);
        // Overflow wraps (32-bit): 0xFFFF_FFFF + 1 = 0x0 (sign-ext stays 0)
        test("ADD MAX_W + 1 = 0 (wrap)",
             AMO_ADD, F3_W,
             64'hFFFF_FFFF, 64'd1, 64'd0);

        // ------------------------------------------------------------------
        // [5] AMOXOR
        // ------------------------------------------------------------------
        $display("\n[5] AMOXOR");
        test("XOR 0xF0 ^ 0x0F = 0xFF", AMO_XOR, F3_W, 64'hF0, 64'h0F, 64'hFF);
        test("XOR x ^ x = 0",
             AMO_XOR, F3_W, 64'hABCD_EF01, 64'hABCD_EF01, 64'd0);

        // ------------------------------------------------------------------
        // [6] AMOAND
        // ------------------------------------------------------------------
        $display("\n[6] AMOAND");
        test("AND 0xFF & 0x0F = 0x0F", AMO_AND, F3_W, 64'hFF, 64'h0F, 64'h0F);
        test("AND x & 0 = 0",          AMO_AND, F3_W, 64'hFFFF_FFFF, 64'h0, 64'd0);

        // ------------------------------------------------------------------
        // [7] AMOOR
        // ------------------------------------------------------------------
        $display("\n[7] AMOOR");
        test("OR 0xF0 | 0x0F = 0xFF",  AMO_OR, F3_W, 64'hF0, 64'h0F, 64'hFF);
        test("OR  0 | MAX = MAX",
             AMO_OR, F3_W, 64'h0, 64'hFFFF_FFFF,
             64'hFFFF_FFFF_FFFF_FFFF);   // sign-extended (-1)

        // ------------------------------------------------------------------
        // [8] AMOMIN (signed)
        // ------------------------------------------------------------------
        $display("\n[8] AMOMIN (signed)");
        test("MIN  3,  7 → 3",           AMO_MIN, F3_W, 64'd3,  64'd7,  64'd3);
        test("MIN  7,  3 → 3",           AMO_MIN, F3_W, 64'd7,  64'd3,  64'd3);
        // -1 < 0 → -1
        test("MIN -1,  0 → -1",          AMO_MIN, F3_W,
             64'hFFFF_FFFF_FFFF_FFFF, 64'd0,
             64'hFFFF_FFFF_FFFF_FFFF);
        // INT32_MIN < -1 → INT32_MIN
        test("MIN INT32_MIN, -1 → INT32_MIN", AMO_MIN, F3_W,
             64'hFFFF_FFFF_8000_0000, 64'hFFFF_FFFF_FFFF_FFFF,
             64'hFFFF_FFFF_8000_0000);

        // ------------------------------------------------------------------
        // [9] AMOMAX (signed)
        // ------------------------------------------------------------------
        $display("\n[9] AMOMAX (signed)");
        test("MAX  3,  7 → 7",           AMO_MAX, F3_W, 64'd3,  64'd7,  64'd7);
        test("MAX  7,  3 → 7",           AMO_MAX, F3_W, 64'd7,  64'd3,  64'd7);
        test("MAX -1,  0 → 0",           AMO_MAX, F3_W,
             64'hFFFF_FFFF_FFFF_FFFF, 64'd0, 64'd0);
        test("MAX INT32_MAX, -1 → INT32_MAX", AMO_MAX, F3_W,
             64'h0000_0000_7FFF_FFFF, 64'hFFFF_FFFF_FFFF_FFFF,
             64'h0000_0000_7FFF_FFFF);

        // ------------------------------------------------------------------
        // [10] AMOMINU (unsigned)
        // ------------------------------------------------------------------
        $display("\n[10] AMOMINU (unsigned)");
        test("MINU  3,  7 → 3",          AMO_MINU, F3_W, 64'd3, 64'd7, 64'd3);
        // 0xFFFF_FFFF vs 0: unsigned → 0 is smaller
        test("MINU MAX_W, 0 → 0",        AMO_MINU, F3_W, 64'hFFFF_FFFF, 64'd0, 64'd0);
        test("MINU 0, MAX_W → 0",        AMO_MINU, F3_W, 64'd0, 64'hFFFF_FFFF, 64'd0);

        // ------------------------------------------------------------------
        // [11] AMOMAXU (unsigned)
        // ------------------------------------------------------------------
        $display("\n[11] AMOMAXU (unsigned)");
        test("MAXU  3,  7 → 7",          AMO_MAXU, F3_W, 64'd3, 64'd7, 64'd7);
        test("MAXU MAX_W, 0 → MAX_W",    AMO_MAXU, F3_W,
             64'hFFFF_FFFF, 64'd0,
             64'hFFFF_FFFF_FFFF_FFFF);   // sign-extended
        test("MAXU 0, MAX_W → MAX_W",    AMO_MAXU, F3_W,
             64'd0, 64'hFFFF_FFFF,
             64'hFFFF_FFFF_FFFF_FFFF);

        // ------------------------------------------------------------------
        // [12] W-type sign extension corner cases
        // ------------------------------------------------------------------
        $display("\n[12] W-type sign extension");
        // 0x7FFF_FFFF + 1 = 0x8000_0000 → sign-ext = 0xFFFF_FFFF_8000_0000
        test("ADD 0x7FFF_FFFF + 1 → sign-ext negative",
             AMO_ADD, F3_W,
             64'h7FFF_FFFF, 64'd1,
             64'hFFFF_FFFF_8000_0000);
        // SWAP of 0x8000_0000: sign-ext result
        test("SWAP rs2=0x8000_0000 → sign-ext negative",
             AMO_SWAP, F3_W,
             64'd0, 64'h8000_0000,
             64'hFFFF_FFFF_8000_0000);

        // ------------------------------------------------------------------
        // [13] D-type (64-bit) operations — XLEN=64 only
        // ------------------------------------------------------------------
        if (XLEN == 64) begin
            $display("\n[13] D-type (XLEN=64)");
            test("ADD.D 0xFFFF_FFFF_FFFF_FFFF + 1 = 0 (wrap)",
                 AMO_ADD, F3_D,
                 64'hFFFF_FFFF_FFFF_FFFF, 64'd1, 64'd0);
            test("AND.D 0xF0F0...F0F0 & 0x0F0F...0F0F = 0",
                 AMO_AND, F3_D,
                 64'hF0F0_F0F0_F0F0_F0F0,
                 64'h0F0F_0F0F_0F0F_0F0F,
                 64'd0);
            test("OR.D  0xF0F0...F0F0 | 0x0F0F...0F0F = ~0",
                 AMO_OR, F3_D,
                 64'hF0F0_F0F0_F0F0_F0F0,
                 64'h0F0F_0F0F_0F0F_0F0F,
                 64'hFFFF_FFFF_FFFF_FFFF);
            // MIN.D: INT64_MIN vs -1 → INT64_MIN
            test("MIN.D INT64_MIN, -1 → INT64_MIN",
                 AMO_MIN, F3_D,
                 64'h8000_0000_0000_0000,
                 64'hFFFF_FFFF_FFFF_FFFF,
                 64'h8000_0000_0000_0000);
            // MAX.D: INT64_MAX vs -1 → INT64_MAX
            test("MAX.D INT64_MAX, -1 → INT64_MAX",
                 AMO_MAX, F3_D,
                 64'h7FFF_FFFF_FFFF_FFFF,
                 64'hFFFF_FFFF_FFFF_FFFF,
                 64'h7FFF_FFFF_FFFF_FFFF);
            // MINU.D: 0 vs MAX_U64 → 0
            test("MINU.D 0, MAX_U64 → 0",
                 AMO_MINU, F3_D,
                 64'd0, 64'hFFFF_FFFF_FFFF_FFFF, 64'd0);
            // MAXU.D: 0 vs MAX_U64 → MAX_U64
            test("MAXU.D 0, MAX_U64 → MAX_U64",
                 AMO_MAXU, F3_D,
                 64'd0, 64'hFFFF_FFFF_FFFF_FFFF,
                 64'hFFFF_FFFF_FFFF_FFFF);
            test("XOR.D A5A5...A5A5 ^ FFFF...FFFF = 5A5A...5A5A",
                 AMO_XOR, F3_D,
                 64'hA5A5_A5A5_A5A5_A5A5,
                 64'hFFFF_FFFF_FFFF_FFFF,
                 64'h5A5A_5A5A_5A5A_5A5A);
            test("SWAP.D old=1 rs2=0xDEAD → 0xDEAD",
                 AMO_SWAP, F3_D, 64'd1, 64'hDEAD, 64'hDEAD);
        end else begin
            $display("\n[13] D-type skipped (compile with -DRV_XLEN_64 for RV64A tests)");
        end

        // ------------------------------------------------------------------
        // Results
        // ------------------------------------------------------------------
        $display("\n=== Results: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL PASS");
        else
            $display("SOME TESTS FAILED");

        $finish;
    end

    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
