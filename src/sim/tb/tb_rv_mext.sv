// =============================================================================
// tb_rv_mext.sv — Unit testbench for RV32M / RV64M (rv_muldiv)
// =============================================================================
// Tests:
//   [1]  MUL    — basic, overflow (lower half), negative operands
//   [2]  MULH   — upper half signed×signed
//   [3]  MULHSU — upper half signed×unsigned
//   [4]  MULHU  — upper half unsigned×unsigned
//   [5]  DIV    — basic signed division (truncated toward zero)
//   [6]  DIVU   — unsigned division
//   [7]  REM    — signed remainder (sign follows dividend)
//   [8]  REMU   — unsigned remainder
//   [9]  Special cases (div-by-zero, INT_MIN/-1 overflow)
//  [10]  W-type ops (MULW/DIVW/DIVUW/REMW/REMUW) — XLEN=64 only
//
// Compile default (XLEN=32): make sim_mext
// Compile with XLEN=64:       make sim_mext64
//
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_mext;

    import rv_pkg::*;

    localparam int XLEN = rv_pkg::XLEN;

    // =========================================================================
    // DUT
    // =========================================================================
    logic            clk, rst_n;
    logic [XLEN-1:0] rs1, rs2;
    muldiv_op_t       op;
    logic            valid_in;
    logic [XLEN-1:0] result;
    logic            div_busy;

    rv_muldiv #(.XLEN(XLEN)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .rs1_data (rs1),
        .rs2_data (rs2),
        .op       (op),
        .valid_in (valid_in),
        .result   (result),
        .div_busy (div_busy)
    );

    // Clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // True for divide ops (which take the multi-cycle sequential path)
    function automatic logic is_divide(input muldiv_op_t o);
        case (o)
            MDU_DIV, MDU_DIVU, MDU_REM, MDU_REMU,
            MDU_DIVW, MDU_DIVUW, MDU_REMW, MDU_REMUW: is_divide = 1'b1;
            default:                                  is_divide = 1'b0;
        endcase
    endfunction

    // =========================================================================
    // Helpers
    // =========================================================================
    int pass_cnt, fail_cnt;

    task check(input string name,
               input logic [XLEN-1:0] got, exp);
        if (got === exp) begin
            $display("  PASS: %-48s = 0x%0h", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %-48s  got=0x%0h  exp=0x%0h", name, got, exp);
            fail_cnt++;
        end
    endtask

    // Drive with 64-bit literals; auto-truncated to XLEN for XLEN=32.
    // Expected values chosen so xlen_t'(exp64) is correct for both widths.
    // Multiply ops are combinational; divide ops use the valid_in/div_busy
    // handshake (wait for busy to rise then fall, then sample the result).
    task automatic test(
        input string   name,
        input muldiv_op_t top,
        input [63:0]   a, b, exp
    );
        rs1 = xlen_t'(a);
        rs2 = xlen_t'(b);
        op  = top;
        if (is_divide(top)) begin
            // Hold valid_in until the FSM accepts (busy rises); this is robust to
            // starting from any state (e.g. the prior divide's D_DONE cycle).
            @(negedge clk);
            valid_in = 1'b1;
            do @(negedge clk); while (!div_busy);   // iteration started
            valid_in = 1'b0;
            do @(negedge clk); while (div_busy);    // finished, result registered
            check(name, result, xlen_t'(exp));      // sampled at negedge (stable)
        end else begin
            #1;
            check(name, result, xlen_t'(exp));
        end
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    initial begin
        $dumpfile("wave/tb_rv_mext.vcd");
        $dumpvars(0, tb_rv_mext);
        pass_cnt = 0;
        fail_cnt = 0;
        valid_in = 1'b0;

        // Reset the sequential divider FSM
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        $display("=== M-Extension Unit Test (XLEN=%0d) ===", XLEN);

        // ------------------------------------------------------------------
        // [1] MUL — lower XLEN bits of signed×signed
        // ------------------------------------------------------------------
        $display("\n[1] MUL");
        test("3 * 4 = 12",               MDU_MUL, 64'd3,  64'd4,  64'd12);
        test("-1 * 1 = -1",              MDU_MUL,
             64'hFFFF_FFFF_FFFF_FFFF, 64'd1,
             64'hFFFF_FFFF_FFFF_FFFF);
        test("-5 * -3 = 15",             MDU_MUL,
             64'hFFFF_FFFF_FFFF_FFFB, 64'hFFFF_FFFF_FFFF_FFFD, 64'd15);
        // Overflow test: upper bits discarded, only lower XLEN bits kept
        // For XLEN=32: 0xFFFF_FFFF * 0xFFFF_FFFF → lower 32 = 0x0000_0001
        test("0xFFFFFFFF * 0xFFFFFFFF (lower XLEN)",
             MDU_MUL,
             64'hFFFF_FFFF_FFFF_FFFF,
             64'hFFFF_FFFF_FFFF_FFFF,
             64'h0000_0000_0000_0001);

        // ------------------------------------------------------------------
        // [2] MULH — upper XLEN bits of signed×signed
        // ------------------------------------------------------------------
        $display("\n[2] MULH");
        // Small positive: upper half = 0
        test("3 * 4 (upper = 0)",        MDU_MULH, 64'd3, 64'd4, 64'd0);
        // Large positive: INT_MAX*INT_MAX
        // For XLEN=32: 2147483647^2 = 0x3FFF_FFFF_0000_0001  → upper = 0x3FFF_FFFF
        // For XLEN=64: upper 64 bits of 0x3FFF_FFFF_FFFF_FFFF_0000_0000_0000_0001
        //              = 0x3FFF_FFFF_FFFF_FFFF
        test("INT_MAX * INT_MAX (upper)",
             MDU_MULH,
             XLEN == 64 ? 64'h7FFF_FFFF_FFFF_FFFF : 64'h7FFF_FFFF,
             XLEN == 64 ? 64'h7FFF_FFFF_FFFF_FFFF : 64'h7FFF_FFFF,
             XLEN == 64 ? 64'h3FFF_FFFF_FFFF_FFFF : 64'h3FFF_FFFF);
        // Negative × positive: -1 * INT_MAX → -INT_MAX → upper = -1
        test("-1 * INT_MAX (upper = -1)",
             MDU_MULH,
             64'hFFFF_FFFF_FFFF_FFFF,
             XLEN == 64 ? 64'h7FFF_FFFF_FFFF_FFFF : 64'h7FFF_FFFF,
             64'hFFFF_FFFF_FFFF_FFFF);

        // ------------------------------------------------------------------
        // [3] MULHSU — upper XLEN bits of signed×unsigned
        // ------------------------------------------------------------------
        $display("\n[3] MULHSU");
        // 1 * MAX_UINT → upper = 0 (product fits in XLEN bits)
        test("1 * MAX_UINT (upper = 0)",
             MDU_MULHSU, 64'd1,
             64'hFFFF_FFFF_FFFF_FFFF,
             64'd0);
        // -1 * MAX_UINT: product = -(2^XLEN-1) → upper = -1
        test("-1 * MAX_UINT (upper = -1)",
             MDU_MULHSU,
             64'hFFFF_FFFF_FFFF_FFFF,
             64'hFFFF_FFFF_FFFF_FFFF,
             64'hFFFF_FFFF_FFFF_FFFF);

        // ------------------------------------------------------------------
        // [4] MULHU — upper XLEN bits of unsigned×unsigned
        // ------------------------------------------------------------------
        $display("\n[4] MULHU");
        test("3 * 4 (upper = 0)",        MDU_MULHU, 64'd3, 64'd4, 64'd0);
        // MAX_UINT * MAX_UINT:
        //   For XLEN=32: (2^32-1)^2 = 0xFFFF_FFFE_0000_0001 → upper = 0xFFFF_FFFE
        //   For XLEN=64: upper 64 bits of (2^64-1)^2 = 0xFFFF_FFFF_FFFF_FFFE
        test("MAX_UINT * MAX_UINT (upper)",
             MDU_MULHU,
             64'hFFFF_FFFF_FFFF_FFFF,
             64'hFFFF_FFFF_FFFF_FFFF,
             XLEN == 64 ? 64'hFFFF_FFFF_FFFF_FFFE : 64'hFFFF_FFFE);

        // ------------------------------------------------------------------
        // [5] DIV — signed, truncated toward zero
        // ------------------------------------------------------------------
        $display("\n[5] DIV");
        test("10 / 3 = 3",               MDU_DIV, 64'd10,  64'd3, 64'd3);
        test("-10 / 3 = -3",             MDU_DIV,
             64'hFFFF_FFFF_FFFF_FFF6, 64'd3,
             64'hFFFF_FFFF_FFFF_FFFD);
        test("10 / -3 = -3",             MDU_DIV,
             64'd10, 64'hFFFF_FFFF_FFFF_FFFD,
             64'hFFFF_FFFF_FFFF_FFFD);
        test("-10 / -3 = 3",             MDU_DIV,
             64'hFFFF_FFFF_FFFF_FFF6,
             64'hFFFF_FFFF_FFFF_FFFD,
             64'd3);

        // ------------------------------------------------------------------
        // [6] DIVU — unsigned
        // ------------------------------------------------------------------
        $display("\n[6] DIVU");
        test("10 / 3 = 3",               MDU_DIVU, 64'd10,  64'd3, 64'd3);
        // 0xFFFF_FFFF / 2 = 0x7FFF_FFFF (XLEN=32), 0x7FFF_FFFF_FFFF_FFFF (XLEN=64)
        test("MAX_UINT / 2",
             MDU_DIVU,
             64'hFFFF_FFFF_FFFF_FFFF, 64'd2,
             XLEN == 64 ? 64'h7FFF_FFFF_FFFF_FFFF : 64'h7FFF_FFFF);

        // ------------------------------------------------------------------
        // [7] REM — signed (sign of result follows dividend)
        // ------------------------------------------------------------------
        $display("\n[7] REM");
        test("10 % 3 = 1",               MDU_REM, 64'd10,  64'd3, 64'd1);
        test("-10 % 3 = -1",             MDU_REM,
             64'hFFFF_FFFF_FFFF_FFF6, 64'd3,
             64'hFFFF_FFFF_FFFF_FFFF);
        test("10 % -3 = 1",              MDU_REM,
             64'd10, 64'hFFFF_FFFF_FFFF_FFFD, 64'd1);
        test("-10 % -3 = -1",            MDU_REM,
             64'hFFFF_FFFF_FFFF_FFF6,
             64'hFFFF_FFFF_FFFF_FFFD,
             64'hFFFF_FFFF_FFFF_FFFF);

        // ------------------------------------------------------------------
        // [8] REMU — unsigned
        // ------------------------------------------------------------------
        $display("\n[8] REMU");
        test("10 % 3 = 1",               MDU_REMU, 64'd10, 64'd3, 64'd1);
        // For XLEN=32: 0xFFFF_FFFF % 3 = 4294967295 % 3 = 0
        // For XLEN=64: 0xFFFF_FFFF_FFFF_FFFF % 3 = 0
        test("MAX_UINT % 3 = 0",
             MDU_REMU,
             64'hFFFF_FFFF_FFFF_FFFF, 64'd3, 64'd0);

        // ------------------------------------------------------------------
        // [9] Special cases: div-by-zero and signed overflow
        // ------------------------------------------------------------------
        $display("\n[9] Special cases");
        // div-by-zero → DIV/DIVU return -1/MAX, REM/REMU return dividend
        test("DIV x/0 = -1 (all-ones)",
             MDU_DIV, 64'd5, 64'd0, 64'hFFFF_FFFF_FFFF_FFFF);
        test("DIVU x/0 = MAX_UINT",
             MDU_DIVU, 64'd5, 64'd0, 64'hFFFF_FFFF_FFFF_FFFF);
        test("REM x/0 = dividend",
             MDU_REM, 64'd7, 64'd0, 64'd7);
        test("REMU x/0 = dividend",
             MDU_REMU, 64'd7, 64'd0, 64'd7);
        // signed overflow: INT_MIN / -1 = INT_MIN, REM = 0
        test("DIV INT_MIN/-1 = INT_MIN",
             MDU_DIV,
             XLEN == 64 ? 64'h8000_0000_0000_0000 : 64'h8000_0000,
             64'hFFFF_FFFF_FFFF_FFFF,
             XLEN == 64 ? 64'h8000_0000_0000_0000 : 64'h8000_0000);
        test("REM INT_MIN/-1 = 0",
             MDU_REM,
             XLEN == 64 ? 64'h8000_0000_0000_0000 : 64'h8000_0000,
             64'hFFFF_FFFF_FFFF_FFFF,
             64'd0);

        // ------------------------------------------------------------------
        // [10] W-type ops (RV64M) — only meaningful when XLEN=64
        // ------------------------------------------------------------------
        if (XLEN == 64) begin
            $display("\n[10] W-type (XLEN=64)");

            // MULW: lower 32 bits of product, sign-extended to 64
            // 0x7FFF_FFFF * 2 = 0xFFFF_FFFE → lower32 = 0xFFFF_FFFE
            // $signed(32'hFFFF_FFFE) = -2 → sign-ext to 0xFFFF_FFFF_FFFF_FFFE
            test("MULW: 0x7FFF_FFFF * 2 → sign-ext",
                 MDU_MULW,
                 64'h0000_0000_7FFF_FFFF, 64'd2,
                 64'hFFFF_FFFF_FFFF_FFFE);
            test("MULW: 3 * 4 = 12",
                 MDU_MULW, 64'd3, 64'd4, 64'd12);

            // DIVW: signed 32-bit divide, sign-extended
            test("DIVW: -10 / 3 = -3 → sign-ext",
                 MDU_DIVW,
                 64'hFFFF_FFFF_FFFF_FFF6, 64'd3,
                 64'hFFFF_FFFF_FFFF_FFFD);
            test("DIVW: INT32_MIN/-1 = INT32_MIN sign-ext",
                 MDU_DIVW,
                 64'hFFFF_FFFF_8000_0000, 64'hFFFF_FFFF_FFFF_FFFF,
                 64'hFFFF_FFFF_8000_0000);

            // DIVUW: unsigned 32-bit divide, sign-extended
            test("DIVUW: 10 / 3 = 3",
                 MDU_DIVUW, 64'd10, 64'd3, 64'd3);
            // 0xFFFF_FFFF / 3 = 1431655765 = 0x5555_5555 → sign-ext (bit31=0) = 0x5555_5555
            test("DIVUW: 0xFFFF_FFFF / 3 = 0x5555_5555",
                 MDU_DIVUW,
                 64'h0000_0000_FFFF_FFFF, 64'd3,
                 64'h0000_0000_5555_5555);

            // REMW: signed 32-bit remainder, sign-extended
            test("REMW: -10 % 3 = -1 → sign-ext",
                 MDU_REMW,
                 64'hFFFF_FFFF_FFFF_FFF6, 64'd3,
                 64'hFFFF_FFFF_FFFF_FFFF);
            test("REMW: INT32_MIN % -1 = 0",
                 MDU_REMW,
                 64'hFFFF_FFFF_8000_0000, 64'hFFFF_FFFF_FFFF_FFFF,
                 64'd0);

            // REMUW: unsigned 32-bit remainder, sign-extended
            test("REMUW: 10 % 3 = 1",
                 MDU_REMUW, 64'd10, 64'd3, 64'd1);
            // div-by-zero W: returns dividend (lower 32 bits sign-extended)
            test("DIVW x/0 = -1 (all-ones)",
                 MDU_DIVW, 64'd5, 64'd0, 64'hFFFF_FFFF_FFFF_FFFF);
            test("REMW x/0 = dividend sign-ext",
                 MDU_REMW,
                 64'h0000_0000_8000_0000, 64'd0,
                 64'hFFFF_FFFF_8000_0000);
        end else begin
            $display("\n[10] W-type skipped (compile with -DRV_XLEN_64 for XLEN=64 tests)");
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
