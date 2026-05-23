// =============================================================================
// tb_rv64i.sv — Unit testbench for RV64I W-type ALU operations
// =============================================================================
// Exercises ALU_ADDW, ALU_SUBW, ALU_SLLW, ALU_SRLW, ALU_SRAW in rv_alu.
// These correspond to: ADDW/ADDIW, SUBW, SLLW/SLLIW, SRLW/SRLIW, SRAW/SRAIW.
//
// Compile with -DRV_XLEN_64 so XLEN=64 and sign-extension to 64 bits is tested.
// Without the flag (XLEN=32), the same cases verify 32-bit truncation is correct.
//
// Simulation: iverilog -DRV_XLEN_64 tb_rv64i.sv ../../rtl/alu/rv_alu.sv
//             -I ../../rtl/include -g2012 -o out/tb_rv64i.vvp
//             vvp out/tb_rv64i.vvp
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps

module tb_rv64i;

    import rv_pkg::*;

    localparam int XLEN = rv_pkg::XLEN;

    // =========================================================================
    // DUT
    // =========================================================================
    logic [XLEN-1:0] op_a, op_b;
    alu_op_t          alu_op;
    logic [XLEN-1:0] result;
    logic             zero_flag;

    rv_alu #(.XLEN(XLEN)) dut (
        .op_a   (op_a),
        .op_b   (op_b),
        .alu_op (alu_op),
        .result (result),
        .zero   (zero_flag)
    );

    // =========================================================================
    // Test helpers
    // =========================================================================
    int pass_cnt, fail_cnt;

    task check(input string name,
               input logic [XLEN-1:0] got, exp);
        if (got === exp) begin
            $display("  PASS: %-44s = 0x%0h", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %-44s  got=0x%0h  exp=0x%0h", name, got, exp);
            fail_cnt++;
        end
    endtask

    // Drive op_a/op_b with 64-bit literals; truncated automatically for XLEN=32.
    // Expected values chosen so xlen_t'(exp64) is correct in both XLEN modes.
    task test_op(
        input string   name,
        input alu_op_t op,
        input [63:0]   a, b, exp
    );
        op_a   = xlen_t'(a);
        op_b   = xlen_t'(b);
        alu_op = op;
        #1;
        check(name, result, xlen_t'(exp));
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    initial begin
        $dumpfile("wave/tb_rv64i.vcd");
        $dumpvars(0, tb_rv64i);
        pass_cnt = 0;
        fail_cnt = 0;

        $display("=== RV64I W-type ALU Unit Test (XLEN=%0d) ===", XLEN);

        // ------------------------------------------------------------------
        // [1] ADDW / ADDIW
        //   result = sign_ext32(op_a[31:0] + op_b[31:0])
        // ------------------------------------------------------------------
        $display("\n[1] ADDW / ADDIW");
        test_op("3 + 5 = 8",
                ALU_ADDW, 64'd3, 64'd5,
                64'd8);
        // Upper bits of op_a are discarded; low 32 wraps: 0xFFFF_FFFF + 1 = 0
        test_op("0xFFFF_FFFF_FFFF_FFFF + 1  (low32: -1+1 = 0)",
                ALU_ADDW,
                64'hFFFF_FFFF_FFFF_FFFF, 64'd1,
                64'h0000_0000_0000_0000);
        // Overflow into bit 31 → MSB of 32-bit result is 1 → sign-extends negative
        test_op("0x7FFF_FFFF + 1  → 0x8000_0000 sign-ext",
                ALU_ADDW,
                64'h0000_0000_7FFF_FFFF, 64'h1,
                64'hFFFF_FFFF_8000_0000);

        // ------------------------------------------------------------------
        // [2] SUBW
        //   result = sign_ext32(op_a[31:0] - op_b[31:0])
        // ------------------------------------------------------------------
        $display("\n[2] SUBW");
        test_op("10 - 3 = 7",
                ALU_SUBW, 64'd10, 64'd3,
                64'd7);
        // Underflow: 0 - 1 = -1 in 32-bit → sign-ext fills all XLEN bits with 1s
        test_op("0 - 1  → 0xFFFF_FFFF sign-ext",
                ALU_SUBW, 64'd0, 64'd1,
                64'hFFFF_FFFF_FFFF_FFFF);

        // ------------------------------------------------------------------
        // [3] SLLW / SLLIW
        //   result = sign_ext32(op_a[31:0] << shamt[4:0])
        // ------------------------------------------------------------------
        $display("\n[3] SLLW / SLLIW");
        test_op("1 << 4 = 16",
                ALU_SLLW, 64'd1, 64'd4,
                64'd16);
        // Shift into bit 31 → sign-extends as negative
        test_op("1 << 31  → 0x8000_0000 sign-ext (negative)",
                ALU_SLLW, 64'd1, 64'd31,
                64'hFFFF_FFFF_8000_0000);
        // shamt uses only op_b[4:0]; bit 5 of 32 = 0 → effectively shift by 0
        test_op("1 << 32  (shamt[4:0]=0 → no shift, result=1)",
                ALU_SLLW, 64'd1, 64'd32,
                64'h0000_0000_0000_0001);

        // ------------------------------------------------------------------
        // [4] SRLW / SRLIW  (logical right shift on 32-bit portion)
        //   MSB of 32-bit result after logical shift is always 0 → sign-ext positive
        // ------------------------------------------------------------------
        $display("\n[4] SRLW / SRLIW");
        // Logical shift: MSB cleared even for negative input
        test_op("0x8000_0000 >> 1  (logical → positive 0x4000_0000)",
                ALU_SRLW,
                64'h0000_0000_8000_0000, 64'd1,
                64'h0000_0000_4000_0000);
        test_op("0xFFFF_FFFF >> 4  (logical: = 0x0FFF_FFFF)",
                ALU_SRLW,
                64'hFFFF_FFFF_FFFF_FFFF, 64'd4,
                64'h0000_0000_0FFF_FFFF);

        // ------------------------------------------------------------------
        // [5] SRAW / SRAIW  (arithmetic right shift on 32-bit portion)
        //   Sign bit of 32-bit is propagated; result then sign-extended to XLEN
        // ------------------------------------------------------------------
        $display("\n[5] SRAW / SRAIW");
        // Negative 32-bit input: arithmetic shift fills high bits with 1s → stays negative
        test_op("0x8000_0000 >>> 4  (arith: 0xF800_0000 sign-ext)",
                ALU_SRAW,
                64'h0000_0000_8000_0000, 64'd4,
                64'hFFFF_FFFF_F800_0000);
        // Positive 32-bit input: identical to logical shift
        test_op("0x7FFF_FFFF >>> 1  (arith: 0x3FFF_FFFF positive)",
                ALU_SRAW,
                64'h0000_0000_7FFF_FFFF, 64'd1,
                64'h0000_0000_3FFF_FFFF);

        // ------------------------------------------------------------------
        // Results
        // ------------------------------------------------------------------
        $display("\n=== Results: %0d passed, %0d failed ===",
                 pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL PASS");
        else
            $display("SOME TESTS FAILED");

        $finish;
    end

    initial begin
        #10000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
