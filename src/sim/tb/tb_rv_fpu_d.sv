// =============================================================================
// tb_rv_fpu_d.sv - D-extension FPU Testbench
//
// Tests for double-precision (64-bit) floating-point operations:
//   FADD.D, FSUB.D, FMUL.D, FDIV.D, FSQRT.D
//   FMADD.D, FMSUB.D, FNMSUB.D, FNMADD.D
//   FSGNJ.D, FSGNJN.D, FSGNJX.D
//   FMIN.D, FMAX.D
//   FEQ.D, FLT.D, FLE.D
//   FCLASS.D
//   FCVT.W.D, FCVT.WU.D, FCVT.L.D, FCVT.LU.D
//   FCVT.D.W, FCVT.D.WU, FCVT.D.L, FCVT.D.LU
//   FCVT.S.D, FCVT.D.S
//   FMV.X.D, FMV.D.X
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_rv_fpu_d;

    import rv_pkg::*;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic        clk, rst_n;
    logic [63:0] fa, fb, fc;
    logic [63:0] int_a;
    fpu_op_t     fpu_op;
    logic        fp_double;
    logic [2:0]  fp_rm, frm_in;
    logic [4:0]  rs2_sel;
    logic        valid_in;

    logic [63:0] result_f;
    logic [63:0] result_i;
    logic [4:0]  fflags;
    logic        fpu_busy;
    logic        result_valid;

    rv_fpu #(.XLEN(64)) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .fa           (fa),
        .fb           (fb),
        .fc           (fc),
        .int_a        (int_a[63:0]),
        .fpu_op       (fpu_op),
        .fp_double    (fp_double),
        .fp_rm        (fp_rm),
        .frm_in       (frm_in),
        .rs2_sel      (rs2_sel),
        .valid_in     (valid_in),
        .result_f     (result_f),
        .result_i     (result_i),
        .fflags       (fflags),
        .fpu_busy     (fpu_busy),
        .result_valid (result_valid)
    );

    // -------------------------------------------------------------------------
    // Clock and reset
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Test infrastructure
    // -------------------------------------------------------------------------
    int pass_cnt, fail_cnt;

    task automatic check_result_f(
        input string test_name,
        input logic [63:0] got,
        input logic [63:0] exp
    );
        if (got === exp) begin
            $display("  PASS: %s = 0x%016h", test_name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %s got=0x%016h exp=0x%016h", test_name, got, exp);
            fail_cnt++;
        end
    endtask

    task automatic check_result_i(
        input string test_name,
        input logic [63:0] got,
        input logic [63:0] exp
    );
        if (got === exp) begin
            $display("  PASS: %s = 0x%016h", test_name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %s got=0x%016h exp=0x%016h", test_name, got, exp);
            fail_cnt++;
        end
    endtask

    // Single-cycle operation (combinational result)
    task automatic run_op_comb(
        input fpu_op_t op,
        input logic    dbl,
        input logic [63:0] a, b, c,
        input logic [63:0] ia,
        input logic [2:0]  rm,
        input logic [4:0]  r2
    );
        @(negedge clk);
        fpu_op    = op;
        fp_double = dbl;
        fa        = a;
        fb        = b;
        fc        = c;
        int_a     = ia;
        fp_rm     = rm;
        frm_in    = 3'b000;
        rs2_sel   = r2;
        valid_in  = 1'b1;
        @(posedge clk); #1;
        valid_in = 1'b0;
    endtask

    // Multi-cycle operation: wait for result_valid
    task automatic run_op_multi(
        input fpu_op_t op,
        input logic    dbl,
        input logic [63:0] a, b,
        input logic [2:0]  rm
    );
        @(negedge clk);
        fpu_op    = op;
        fp_double = dbl;
        fa        = a;
        fb        = b;
        fp_rm     = rm;
        frm_in    = 3'b000;
        valid_in  = 1'b1;
        @(posedge clk); #1;
        valid_in = 1'b0;
        // wait for result_valid
        while (!result_valid) @(posedge clk);
        #1;
    endtask

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------
    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        rst_n    = 0;
        fa       = 64'h0;
        fb       = 64'h0;
        fc       = 64'h0;
        int_a    = 64'h0;
        fpu_op   = FPU_ADD;
        fp_double = 1'b1;
        fp_rm    = 3'b000;
        frm_in   = 3'b000;
        rs2_sel  = 5'h0;
        valid_in = 1'b0;

        repeat(2) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("=== D-extension FPU Tests ===");

        // --- FADD.D: 1.0 + 2.0 = 3.0 ---
        $display("[1] FADD.D");
        run_op_comb(FPU_ADD, 1'b1,
            64'h3FF0000000000000,  // 1.0
            64'h4000000000000000,  // 2.0
            64'h0, 64'h0, 3'b000, 5'h0);
        check_result_f("1.0+2.0", result_f, 64'h4008000000000000);  // 3.0

        // --- FSUB.D: 3.0 - 1.0 = 2.0 ---
        $display("[2] FSUB.D");
        run_op_comb(FPU_SUB, 1'b1,
            64'h4008000000000000,  // 3.0
            64'h3FF0000000000000,  // 1.0
            64'h0, 64'h0, 3'b000, 5'h0);
        check_result_f("3.0-1.0", result_f, 64'h4000000000000000);  // 2.0

        // --- FMUL.D: 2.0 * 3.0 = 6.0 ---
        $display("[3] FMUL.D");
        run_op_comb(FPU_MUL, 1'b1,
            64'h4000000000000000,  // 2.0
            64'h4008000000000000,  // 3.0
            64'h0, 64'h0, 3'b000, 5'h0);
        check_result_f("2.0*3.0", result_f, 64'h4018000000000000);  // 6.0

        // --- FMADD.D: 2.0*3.0+1.0 = 7.0 ---
        $display("[4] FMADD.D");
        run_op_comb(FPU_MADD, 1'b1,
            64'h4000000000000000,  // 2.0
            64'h4008000000000000,  // 3.0
            64'h3FF0000000000000,  // 1.0
            64'h0, 3'b000, 5'h0);
        check_result_f("2.0*3.0+1.0", result_f, 64'h401C000000000000);  // 7.0

        // --- FMSUB.D: 2.0*3.0-1.0 = 5.0 ---
        $display("[5] FMSUB.D");
        run_op_comb(FPU_MSUB, 1'b1,
            64'h4000000000000000,  // 2.0
            64'h4008000000000000,  // 3.0
            64'h3FF0000000000000,  // 1.0
            64'h0, 3'b000, 5'h0);
        check_result_f("2.0*3.0-1.0", result_f, 64'h4014000000000000);  // 5.0

        // --- FNMSUB.D: -(2.0*3.0)+1.0 = -5.0 ---
        $display("[6] FNMSUB.D");
        run_op_comb(FPU_NMSUB, 1'b1,
            64'h4000000000000000,  // 2.0
            64'h4008000000000000,  // 3.0
            64'h3FF0000000000000,  // 1.0
            64'h0, 3'b000, 5'h0);
        check_result_f("-(2.0*3.0)+1.0", result_f, 64'hC014000000000000);  // -5.0

        // --- FDIV.D: 1.0 / 2.0 = 0.5 ---
        $display("[7] FDIV.D");
        run_op_multi(FPU_DIV, 1'b1,
            64'h3FF0000000000000,  // 1.0
            64'h4000000000000000,  // 2.0
            3'b000);
        check_result_f("1.0/2.0", result_f, 64'h3FE0000000000000);  // 0.5

        // --- FSQRT.D: sqrt(4.0) = 2.0 ---
        $display("[8] FSQRT.D");
        run_op_multi(FPU_SQRT, 1'b1,
            64'h4010000000000000,  // 4.0
            64'h0, 3'b000);
        check_result_f("sqrt(4.0)", result_f, 64'h4000000000000000);  // 2.0

        // --- FSGNJ.D ---
        $display("[9] FSGNJ.D");
        run_op_comb(FPU_SGNJ, 1'b1,
            64'hBFF0000000000000,  // -1.0
            64'h4000000000000000,  // +2.0 (positive sign)
            64'h0, 64'h0, 3'b000, 5'h0);  // rm=000: FSGNJ
        check_result_f("fsgnj(-1.0, +2.0)", result_f, 64'h3FF0000000000000);  // +1.0

        // FSGNJN: rm=001
        run_op_comb(FPU_SGNJ, 1'b1,
            64'hBFF0000000000000,  // -1.0
            64'h4000000000000000,  // +2.0 (negate its sign -> negative)
            64'h0, 64'h0, 3'b001, 5'h0);
        check_result_f("fsgnjn(-1.0, +2.0)", result_f, 64'hBFF0000000000000);  // -1.0

        // --- FMIN.D: min(1.0, 2.0) = 1.0 ---
        $display("[10] FMIN.D / FMAX.D");
        run_op_comb(FPU_MINMAX, 1'b1,
            64'h3FF0000000000000,  // 1.0
            64'h4000000000000000,  // 2.0
            64'h0, 64'h0, 3'b000, 5'h0);  // rm=0: MIN
        check_result_f("min(1.0,2.0)", result_f, 64'h3FF0000000000000);  // 1.0

        run_op_comb(FPU_MINMAX, 1'b1,
            64'h3FF0000000000000,  // 1.0
            64'h4000000000000000,  // 2.0
            64'h0, 64'h0, 3'b001, 5'h0);  // rm=1: MAX
        check_result_f("max(1.0,2.0)", result_f, 64'h4000000000000000);  // 2.0

        // --- FEQ.D: 1.0 == 1.0 -> 1 ---
        $display("[11] FEQ.D / FLT.D / FLE.D");
        run_op_comb(FPU_CMP, 1'b1,
            64'h3FF0000000000000,
            64'h3FF0000000000000,
            64'h0, 64'h0, 3'b010, 5'h0);  // rm=010: FEQ
        check_result_i("feq(1.0,1.0)", result_i, 64'h1);

        run_op_comb(FPU_CMP, 1'b1,
            64'h3FF0000000000000,  // 1.0
            64'h4000000000000000,  // 2.0
            64'h0, 64'h0, 3'b001, 5'h0);  // FLT
        check_result_i("flt(1.0,2.0)", result_i, 64'h1);

        run_op_comb(FPU_CMP, 1'b1,
            64'h4000000000000000,  // 2.0
            64'h3FF0000000000000,  // 1.0
            64'h0, 64'h0, 3'b001, 5'h0);  // FLT
        check_result_i("flt(2.0,1.0)", result_i, 64'h0);

        // --- FCLASS.D: +infinity -> bit[7] ---
        $display("[12] FCLASS.D");
        run_op_comb(FPU_CLASS, 1'b1,
            64'h7FF0000000000000,  // +inf
            64'h0, 64'h0, 64'h0, 3'b001, 5'h0);
        check_result_i("fclass(+inf)", result_i, 64'h0080);  // bit 7

        run_op_comb(FPU_CLASS, 1'b1,
            64'h7FF8000000000000,  // quiet NaN
            64'h0, 64'h0, 64'h0, 3'b001, 5'h0);
        check_result_i("fclass(qNaN)", result_i, 64'h0200);  // bit 9

        // --- FMV.X.D: move double bits to integer reg ---
        $display("[13] FMV.X.D");
        run_op_comb(FPU_MVXW, 1'b1,
            64'h4000000000000000,  // 2.0
            64'h0, 64'h0, 64'h0, 3'b000, 5'h0);
        check_result_i("fmv.x.d(2.0)", result_i, 64'h4000000000000000);

        // --- FMV.D.X: move integer bits to double reg ---
        $display("[14] FMV.D.X");
        run_op_comb(FPU_MVWX, 1'b1,
            64'h0, 64'h0, 64'h0,
            64'h4000000000000000,  // int = 2.0 pattern
            3'b000, 5'h0);
        check_result_f("fmv.d.x(0x4000...)", result_f, 64'h4000000000000000);

        // --- FCVT.W.D: 3.7 -> 3 (signed 32-bit) ---
        $display("[15] FCVT.W.D");
        run_op_comb(FPU_CVTWS, 1'b1,
            64'h400D999999999999,  // ~3.7
            64'h0, 64'h0, 64'h0, 3'b001,  // RTZ
            5'b00000);  // W (signed 32-bit)
        check_result_i("fcvt.w.d(3.7,RTZ)", result_i, 64'h0000000000000003);

        // --- FCVT.D.W: 42 -> 42.0 ---
        $display("[16] FCVT.D.W");
        run_op_comb(FPU_CVTSW, 1'b1,
            64'h0, 64'h0, 64'h0,
            64'h000000000000002A,  // int = 42
            3'b000, 5'b00000);  // W (signed 32-bit)
        check_result_f("fcvt.d.w(42)", result_f, 64'h4045000000000000);  // 42.0

        // --- FCVT.L.D: 2^60 -> 1152921504606846976 ---
        $display("[17] FCVT.L.D (double->int64)");
        run_op_comb(FPU_CVTWS, 1'b1,
            64'h43B0000000000000,  // 2.0^60 as double (biased_exp=1083)
            64'h0, 64'h0, 64'h0, 3'b001,  // RTZ
            5'b00010);  // L (signed 64-bit)
        check_result_i("fcvt.l.d(2^60)", result_i, 64'h1000000000000000);

        // --- FCVT.D.L: int64 -> double ---
        $display("[18] FCVT.D.L (int64->double)");
        run_op_comb(FPU_CVTSW, 1'b1,
            64'h0, 64'h0, 64'h0,
            64'h0000000000000001,  // int = 1
            3'b000, 5'b00010);  // L (signed 64-bit)
        check_result_f("fcvt.d.l(1)", result_f, 64'h3FF0000000000000);  // 1.0

        // --- FCVT.S.D: 2.0(double) -> 2.0(single, NaN-boxed) ---
        $display("[19] FCVT.S.D (double->single)");
        run_op_comb(FPU_CVTSD, 1'b1,
            64'h4000000000000000,  // 2.0 double
            64'h0, 64'h0, 64'h0, 3'b000, 5'b00001);
        check_result_f("fcvt.s.d(2.0)", result_f, 64'hFFFFFFFF40000000);  // NaN-boxed 2.0f

        // --- FCVT.D.S: 2.0f(single) -> 2.0(double) ---
        $display("[20] FCVT.D.S (single->double)");
        run_op_comb(FPU_CVTDS, 1'b1,
            64'hFFFFFFFF40000000,  // NaN-boxed 2.0f
            64'h0, 64'h0, 64'h0, 3'b000, 5'b00000);
        check_result_f("fcvt.d.s(2.0f)", result_f, 64'h4000000000000000);  // 2.0 double

        // --- Regression: rv64ud-p-fadd test_5 exact case ---
        $display("[21b] FSUB.D(2.5, 1.0) regression test (rv64ud-p-fadd t5)");
        run_op_comb(FPU_SUB, 1'b1,
            64'h4004000000000000,  // 2.5
            64'h3FF0000000000000,  // 1.0
            64'h0, 64'h0, 3'b000, 5'h0);
        check_result_f("2.5-1.0=1.5", result_f, 64'h3FF8000000000000);
        // FADD.D(2.5, 1.0) = 3.5
        run_op_comb(FPU_ADD, 1'b1,
            64'h4004000000000000,
            64'h3FF0000000000000,
            64'h0, 64'h0, 3'b000, 5'h0);
        check_result_f("2.5+1.0=3.5", result_f, 64'h400C000000000000);
        // FSUB.D(1.25, 0.25) = 1.0 (both subnormal-adjacent)
        run_op_comb(FPU_SUB, 1'b1,
            64'h3FF4000000000000,  // 1.25
            64'h3FD0000000000000,  // 0.25
            64'h0, 64'h0, 3'b000, 5'h0);
        check_result_f("1.25-0.25=1.0", result_f, 64'h3FF0000000000000);

        // --- NaN propagation: NaN + 1.0 = NaN ---
        $display("[21] NaN propagation");
        run_op_comb(FPU_ADD, 1'b1,
            64'h7FF8000000000000,  // qNaN
            64'h3FF0000000000000,  // 1.0
            64'h0, 64'h0, 3'b000, 5'h0);
        check_result_f("qNaN+1.0", result_f, 64'h7FF8000000000000);

        // --- FDIV.D special: inf/inf = NaN ---
        $display("[22] FDIV.D special: inf/inf");
        run_op_multi(FPU_DIV, 1'b1,
            64'h7FF0000000000000,  // +inf
            64'h7FF0000000000000,  // +inf
            3'b000);
        check_result_f("inf/inf", result_f, 64'h7FF8000000000000);  // NaN

        // --- FSQRT.D: sqrt(-1.0) = NaN, NV flag ---
        $display("[23] FSQRT.D special: sqrt(-1.0)");
        run_op_multi(FPU_SQRT, 1'b1,
            64'hBFF0000000000000,  // -1.0
            64'h0, 3'b000);
        check_result_f("sqrt(-1.0)", result_f, 64'h7FF8000000000000);  // NaN
        if (fflags[4]) begin
            $display("  PASS: NV flag set");
            pass_cnt++;
        end else begin
            $display("  FAIL: NV flag not set");
            fail_cnt++;
        end

        // --- FADD.D: +inf + (-inf) = NaN ---
        $display("[24] FADD.D: inf cancellation");
        run_op_comb(FPU_ADD, 1'b1,
            64'h7FF0000000000000,  // +inf
            64'hFFF0000000000000,  // -inf
            64'h0, 64'h0, 3'b000, 5'h0);
        check_result_f("+inf+(-inf)", result_f, 64'h7FF8000000000000);  // NaN

        // Summary
        $display("=== Results: %0d PASS, %0d FAIL ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL PASS");
        else
            $display("SOME FAIL");

        $finish;
    end

    // Timeout
    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
