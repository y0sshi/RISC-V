// =============================================================================
// tb_rv_muldiv_rand.sv - Randomized self-checking test for rv_muldiv divider
// =============================================================================
// Drives random (rs1, rs2, op) through the multi-cycle divider handshake and
// compares against a golden reference computed with SystemVerilog / % operators
// (the exact semantics the old combinational divider used and compliance
// validated).  Targets algorithmic edges that fixed-vector tests miss.
//
//   make sim_mdrand        (XLEN=32)
//   make sim_mdrand64      (XLEN=64, includes W-type ops)
//
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_muldiv_rand;

    import rv_pkg::*;
    localparam int XLEN = rv_pkg::XLEN;
    localparam int NTEST = 200000;

    logic            clk, rst_n;
    logic [XLEN-1:0] rs1, rs2;
    muldiv_op_t       op;
    logic            valid_in;
    logic [XLEN-1:0] result;
    logic            div_busy;

    rv_muldiv #(.XLEN(XLEN)) dut (
        .clk (clk), .rst_n (rst_n),
        .rs1_data (rs1), .rs2_data (rs2), .op (op),
        .valid_in (valid_in), .result (result), .div_busy (div_busy)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    int pass_cnt, fail_cnt;

    // Golden reference (mirrors rv_muldiv's prior combinational semantics).
    function automatic logic [XLEN-1:0] golden(input muldiv_op_t o,
                                               input logic [XLEN-1:0] a,
                                               input logic [XLEN-1:0] b);
        logic dz, dzw, ov, ovw;
        dz  = (b == '0);
        dzw = (b[31:0] == '0);
        ov  = (a == {1'b1, {(XLEN-1){1'b0}}}) && (b == '1);
        ovw = (a[31:0] == 32'h8000_0000) && (b[31:0] == 32'hFFFF_FFFF);
        unique case (o)
            MDU_DIV:  golden = dz ? '1 : ov ? a : xlen_t'($signed(a) / $signed(b));
            MDU_DIVU: golden = dz ? '1 : a / b;
            MDU_REM:  golden = dz ? a  : ov ? '0 : xlen_t'($signed(a) % $signed(b));
            MDU_REMU: golden = dz ? a  : a % b;
            MDU_DIVW:  golden = dzw ? '1 : ovw ? XLEN'($signed(32'h8000_0000))
                              : XLEN'($signed($signed(a[31:0]) / $signed(b[31:0])));
            MDU_DIVUW: golden = dzw ? '1 : XLEN'($signed(a[31:0] / b[31:0]));
            MDU_REMW:  golden = dzw ? XLEN'($signed(a[31:0])) : ovw ? '0
                              : XLEN'($signed($signed(a[31:0]) % $signed(b[31:0])));
            MDU_REMUW: golden = dzw ? XLEN'($signed(a[31:0])) : XLEN'($signed(a[31:0] % b[31:0]));
            default:  golden = '0;
        endcase
    endfunction

    task automatic do_div(input muldiv_op_t o,
                          input logic [XLEN-1:0] a, b);
        logic [XLEN-1:0] exp;
        rs1 = a; rs2 = b; op = o;
        @(negedge clk);
        valid_in = 1'b1;
        do @(negedge clk); while (!div_busy);
        valid_in = 1'b0;
        do @(negedge clk); while (div_busy);
        exp = golden(o, a, b);
        if (result === exp) pass_cnt++;
        else begin
            fail_cnt++;
            if (fail_cnt <= 20)
                $display("  FAIL: op=%0d a=0x%0h b=0x%0h got=0x%0h exp=0x%0h",
                         o, a, b, result, exp);
        end
    endtask

    // Random operand with bias toward edge values.
    function automatic logic [XLEN-1:0] rnd_op();
        int k;
        logic [XLEN-1:0] v;
        k = $urandom_range(0, 9);
        unique case (k)
            0: v = '0;
            1: v = '1;
            2: v = {1'b1, {(XLEN-1){1'b0}}};       // INT_MIN
            3: v = {1'b0, {(XLEN-1){1'b1}}};       // INT_MAX
            4: v = 32'h8000_0000;                  // INT32_MIN (W edge)
            5: v = 32'h7FFF_FFFF;                  // INT32_MAX (W edge)
            6: v = xlen_t'($urandom_range(0, 7));  // tiny
            default: begin
                v = {$urandom(), $urandom()};      // full random (64-bit)
                v = xlen_t'(v);
            end
        endcase
        return v;
    endfunction

    muldiv_op_t base_ops [4]  = '{MDU_DIV, MDU_DIVU, MDU_REM, MDU_REMU};
    muldiv_op_t w_ops    [4]  = '{MDU_DIVW, MDU_DIVUW, MDU_REMW, MDU_REMUW};

    int i, oi;
    logic [XLEN-1:0] a, b;

    initial begin
        pass_cnt = 0; fail_cnt = 0;
        valid_in = 1'b0;
        rst_n = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        $display("=== rv_muldiv randomized divider test (XLEN=%0d, %0d ops) ===",
                 XLEN, NTEST);

        for (i = 0; i < NTEST; i++) begin
            a = rnd_op();
            b = rnd_op();
            // base ops
            oi = $urandom_range(0, 3);
            do_div(base_ops[oi], a, b);
            // W-type ops only meaningful for XLEN=64
            if (XLEN == 64) begin
                oi = $urandom_range(0, 3);
                do_div(w_ops[oi], a, b);
            end
        end

        $display("=== Results: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL PASS");
        else               $display("SOME TESTS FAILED");
        $finish;
    end

    initial begin
        #2000000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
