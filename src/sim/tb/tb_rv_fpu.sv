// =============================================================================
/// @file tb_rv_fpu.sv
/// @brief Testbench for rv_fpu (FPU top-level dispatcher)
///
/// Tests: FADD, FSUB, FMUL, FDIV, FSQRT, FMADD, FMSUB, FNMSUB, FNMADD,
///        FSGNJ/FSGNJN/FSGNJX, FMIN/FMAX, FEQ/FLT/FLE,
///        FMV.X.W, FMV.W.X, FCVT.W.S, FCVT.WU.S, FCVT.S.W, FCVT.S.WU,
///        FCLASS, special values (NaN, Inf, zero, subnormal).
///
/// All IEEE 754 single-precision values are passed as 32-bit hex constants.
///
/// @author Naofumi Yoshinaga
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_rv_fpu;

    import rv_pkg::*;

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    logic clk   = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;  // 100 MHz

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    logic [31:0]    fa, fb, fc;
    logic [31:0]    int_a;
    fpu_op_t        fpu_op;
    logic [2:0]     fp_rm;
    logic [2:0]     frm_in;
    logic [4:0]     rs2_sel;
    logic           valid_in;

    logic [31:0]    result_f;
    logic [31:0]    result_i;
    logic [4:0]     fflags;
    logic           fpu_busy;
    logic           result_valid;

    rv_fpu #(.XLEN(32)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .fa          (fa),
        .fb          (fb),
        .fc          (fc),
        .int_a       (int_a),
        .fpu_op      (fpu_op),
        .fp_rm       (fp_rm),
        .frm_in      (frm_in),
        .rs2_sel     (rs2_sel),
        .valid_in    (valid_in),
        .result_f    (result_f),
        .result_i    (result_i),
        .fflags      (fflags),
        .fpu_busy    (fpu_busy),
        .result_valid(result_valid)
    );

    // -------------------------------------------------------------------------
    // Test counters
    // -------------------------------------------------------------------------
    int pass_cnt = 0;
    int fail_cnt = 0;

    // -------------------------------------------------------------------------
    // Tasks
    // -------------------------------------------------------------------------

    // Wait for multi-cycle result (FDIV / FSQRT)
    task automatic wait_result(input int timeout);
        int i;
        i = 0;
        while (i < timeout && !result_valid) begin
            @(posedge clk);
            i = i + 1;
        end
        if (!result_valid)
            $display("TIMEOUT waiting for result_valid");
    endtask

    // Issue a single-cycle FP operation and check result_f
    task automatic check_f(
        input string       name,
        input logic [31:0] a_in,
        input logic [31:0] b_in,
        input logic [31:0] c_in,
        input fpu_op_t     op,
        input logic [2:0]  rm_in,
        input logic [4:0]  sel,
        input logic [31:0] exp_f,
        input logic [4:0]  exp_flags
    );
        @(negedge clk);
        fa      = a_in;
        fb      = b_in;
        fc      = c_in;
        fpu_op  = op;
        fp_rm   = rm_in;
        rs2_sel = sel;
        int_a   = '0;
        valid_in = 1'b1;
        @(posedge clk);
        valid_in = 1'b0;
        // combinational result visible before next clock edge
        if (result_f === exp_f && fflags === exp_flags) begin
            $display("  PASS: %s -> f=%h flags=%b", name, result_f, fflags);
            pass_cnt++;
        end else begin
            $display("  FAIL: %s -> f=%h (exp %h)  flags=%b (exp %b)",
                     name, result_f, exp_f, fflags, exp_flags);
            fail_cnt++;
        end
    endtask

    // Issue a single-cycle FP operation and check result_i (integer output)
    task automatic check_i(
        input string       name,
        input logic [31:0] a_in,
        input logic [31:0] b_in,
        input fpu_op_t     op,
        input logic [2:0]  rm_in,
        input logic [4:0]  sel,
        input logic [31:0] exp_i,
        input logic [4:0]  exp_flags
    );
        @(negedge clk);
        fa      = a_in;
        fb      = b_in;
        fc      = 32'h0;
        fpu_op  = op;
        fp_rm   = rm_in;
        rs2_sel = sel;
        int_a   = '0;
        valid_in = 1'b1;
        @(posedge clk);
        valid_in = 1'b0;
        if (result_i[31:0] === exp_i && fflags === exp_flags) begin
            $display("  PASS: %s -> i=%h flags=%b", name, result_i[31:0], fflags);
            pass_cnt++;
        end else begin
            $display("  FAIL: %s -> i=%h (exp %h)  flags=%b (exp %b)",
                     name, result_i[31:0], exp_i, fflags, exp_flags);
            fail_cnt++;
        end
    endtask

    // Issue FMV.W.X (integer -> float)
    task automatic check_mvwx(
        input string       name,
        input logic [31:0] ia_in,
        input logic [31:0] exp_f
    );
        @(negedge clk);
        fa      = 32'h0;
        fb      = 32'h0;
        fc      = 32'h0;
        int_a   = {32'h0, ia_in};
        fpu_op  = FPU_MVWX;
        fp_rm   = 3'b000;
        rs2_sel = 5'h0;
        valid_in = 1'b1;
        @(posedge clk);
        valid_in = 1'b0;
        if (result_f === exp_f) begin
            $display("  PASS: %s -> f=%h", name, result_f);
            pass_cnt++;
        end else begin
            $display("  FAIL: %s -> f=%h (exp %h)", name, result_f, exp_f);
            fail_cnt++;
        end
    endtask

    // Multi-cycle operation (FDIV / FSQRT)
    task automatic check_multicycle_f(
        input string       name,
        input logic [31:0] a_in,
        input logic [31:0] b_in,
        input fpu_op_t     op,
        input logic [2:0]  rm_in,
        input logic [31:0] exp_f,
        input logic [4:0]  exp_flags
    );
        logic [31:0] r_f;
        logic [4:0]  r_flags;
        @(negedge clk);
        fa      = a_in;
        fb      = b_in;
        fc      = 32'h0;
        fpu_op  = op;
        fp_rm   = rm_in;
        rs2_sel = 5'h0;
        int_a   = '0;
        valid_in = 1'b1;
        @(posedge clk);
        valid_in = 1'b0;
        // Wait for result
        wait_result(60);
        r_f     = result_f;
        r_flags = fflags;
        @(negedge clk);
        if (r_f === exp_f && r_flags === exp_flags) begin
            $display("  PASS: %s -> f=%h flags=%b", name, r_f, r_flags);
            pass_cnt++;
        end else begin
            $display("  FAIL: %s -> f=%h (exp %h)  flags=%b (exp %b)",
                     name, r_f, exp_f, r_flags, exp_flags);
            fail_cnt++;
        end
    endtask

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    // IEEE 754 single-precision constants
    //   1.0  = 0x3F800000
    //   2.0  = 0x40000000
    //   3.0  = 0x40400000
    //   4.0  = 0x40800000
    //   0.5  = 0x3F000000
    //  -1.0  = 0xBF800000
    //  -2.0  = 0xC0000000
    //  +Inf  = 0x7F800000
    //  -Inf  = 0xFF800000
    //  qNaN  = 0x7FC00000
    //  -0    = 0x80000000
    //   9.0  = 0x41100000
    //   3.0  = 0x40400000   (sqrt of 9)

    initial begin
        $dumpfile("wave/tb_rv_fpu.vcd");
        $dumpvars(0, tb_rv_fpu);

        // Reset
        fa = 0; fb = 0; fc = 0; int_a = 0;
        fpu_op = FPU_ADD; fp_rm = 3'b000; frm_in = 3'b000;
        rs2_sel = 5'h0; valid_in = 0;
        repeat(3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // =============================================================
        $display("=== FADD ===");
        // 1.0 + 2.0 = 3.0, no flags
        check_f("1.0+2.0", 32'h3F800000, 32'h40000000, 32'h0,
                FPU_ADD, 3'b000, 5'h0, 32'h40400000, 5'b00000);
        // -1.0 + 1.0 = +0.0, no flags
        check_f("-1+1=0", 32'hBF800000, 32'h3F800000, 32'h0,
                FPU_ADD, 3'b000, 5'h0, 32'h00000000, 5'b00000);
        // Inf + Inf = Inf
        check_f("Inf+Inf", 32'h7F800000, 32'h7F800000, 32'h0,
                FPU_ADD, 3'b000, 5'h0, 32'h7F800000, 5'b00000);
        // Inf + (-Inf) = qNaN, NV flag
        check_f("Inf-Inf", 32'h7F800000, 32'hFF800000, 32'h0,
                FPU_ADD, 3'b000, 5'h0, 32'h7FC00000, 5'b10000);

        // =============================================================
        $display("=== FSUB ===");
        // 3.0 - 2.0 = 1.0
        check_f("3-2=1", 32'h40400000, 32'h40000000, 32'h0,
                FPU_SUB, 3'b000, 5'h0, 32'h3F800000, 5'b00000);

        // =============================================================
        $display("=== FMUL ===");
        // 2.0 * 3.0 = 6.0
        check_f("2*3=6", 32'h40000000, 32'h40400000, 32'h0,
                FPU_MUL, 3'b000, 5'h0, 32'h40C00000, 5'b00000);
        // -1 * 2 = -2
        check_f("-1*2=-2", 32'hBF800000, 32'h40000000, 32'h0,
                FPU_MUL, 3'b000, 5'h0, 32'hC0000000, 5'b00000);

        // =============================================================
        $display("=== FDIV (multi-cycle) ===");
        // 1.0 / 2.0 = 0.5
        check_multicycle_f("1/2=0.5", 32'h3F800000, 32'h40000000,
                FPU_DIV, 3'b000, 32'h3F000000, 5'b00000);
        // 1.0 / 0 = +Inf, DZ flag
        check_multicycle_f("1/0=Inf(DZ)", 32'h3F800000, 32'h00000000,
                FPU_DIV, 3'b000, 32'h7F800000, 5'b01000);

        // ----- Exact-division precision regression (bug: fra[0] truncation set NX) -----
        // 4.0 / 2.0 = 2.0, exact, fflags=0
        check_multicycle_f("4/2=2.0 exact",
                32'h40800000, 32'h40000000,
                FPU_DIV, 3'b000, 32'h40000000, 5'b00000);
        // pi / 1.0 = pi, exact, fflags=0  (fra[0]=1 was the trigger for the bug)
        check_multicycle_f("pi/1.0=pi exact",
                32'h40490FDB, 32'h3F800000,
                FPU_DIV, 3'b000, 32'h40490FDB, 5'b00000);
        // pi / pi = 1.0, exact, fflags=0
        check_multicycle_f("pi/pi=1.0 exact",
                32'h40490FDB, 32'h40490FDB,
                FPU_DIV, 3'b000, 32'h3F800000, 5'b00000);
        // 6.0 / 3.0 = 2.0, exact, fflags=0
        check_multicycle_f("6/3=2.0 exact",
                32'h40C00000, 32'h40400000,
                FPU_DIV, 3'b000, 32'h40000000, 5'b00000);

        // ----- Special-case FDIV (special_pending regression: previously hung pipeline) -----
        // sNaN / 1.0 = qNaN, NV
        check_multicycle_f("sNaN/1=qNaN(NV)",
                32'h7FA00000, 32'h3F800000,
                FPU_DIV, 3'b000, 32'h7FC00000, 5'b10000);
        // qNaN / 1.0 = qNaN, no flag
        check_multicycle_f("qNaN/1=qNaN",
                32'h7FC00000, 32'h3F800000,
                FPU_DIV, 3'b000, 32'h7FC00000, 5'b00000);
        // Inf / Inf = qNaN, NV
        check_multicycle_f("Inf/Inf=qNaN(NV)",
                32'h7F800000, 32'h7F800000,
                FPU_DIV, 3'b000, 32'h7FC00000, 5'b10000);
        // 0 / 0 = qNaN, NV
        check_multicycle_f("0/0=qNaN(NV)",
                32'h00000000, 32'h00000000,
                FPU_DIV, 3'b000, 32'h7FC00000, 5'b10000);
        // -1.0 / 0 = -Inf, DZ
        check_multicycle_f("-1/0=-Inf(DZ)",
                32'hBF800000, 32'h00000000,
                FPU_DIV, 3'b000, 32'hFF800000, 5'b01000);
        // +Inf / 1.0 = +Inf
        check_multicycle_f("Inf/1=Inf",
                32'h7F800000, 32'h3F800000,
                FPU_DIV, 3'b000, 32'h7F800000, 5'b00000);
        // 1.0 / +Inf = 0
        check_multicycle_f("1/Inf=0",
                32'h3F800000, 32'h7F800000,
                FPU_DIV, 3'b000, 32'h00000000, 5'b00000);
        // Consecutive FDIV to verify pipeline recovery
        check_multicycle_f("2/1=2.0(2nd)",
                32'h40000000, 32'h3F800000,
                FPU_DIV, 3'b000, 32'h40000000, 5'b00000);

        // =============================================================
        $display("=== FSQRT (multi-cycle) ===");
        // sqrt(1.0) = 1.0
        check_multicycle_f("sqrt(1.0)=1.0",
            32'h3F800000, 32'h0, FPU_SQRT, 3'b000,
            32'h3F800000, 5'b00000);

        // sqrt(4.0) = 2.0
        check_multicycle_f("sqrt(4.0)=2.0",
            32'h40800000, 32'h0, FPU_SQRT, 3'b000,
            32'h40000000, 5'b00000);

        // sqrt(9.0) = 3.0
        check_multicycle_f("sqrt(9.0)=3.0",
            32'h41100000, 32'h0, FPU_SQRT, 3'b000,
            32'h40400000, 5'b00000);

        // sqrt(16.0) = 4.0
        check_multicycle_f("sqrt(16.0)=4.0",
            32'h41800000, 32'h0, FPU_SQRT, 3'b000,
            32'h40800000, 5'b00000);

        // sqrt(25.0) = 5.0
        check_multicycle_f("sqrt(25.0)=5.0",
            32'h41C80000, 32'h0, FPU_SQRT, 3'b000,
            32'h40A00000, 5'b00000);

        // sqrt(0.25) = 0.5
        check_multicycle_f("sqrt(0.25)=0.5",
            32'h3E800000, 32'h0, FPU_SQRT, 3'b000,
            32'h3F000000, 5'b00000);

        // sqrt(0.0625) = 0.25
        check_multicycle_f("sqrt(0.0625)=0.25",
            32'h3D800000, 32'h0, FPU_SQRT, 3'b000,
            32'h3E800000, 5'b00000);

        // sqrt(2.0) = 1.41421356... = 0x3FB504F3 (RNE)
        check_multicycle_f("sqrt(2.0)=1.4142(NX)",
            32'h40000000, 32'h0, FPU_SQRT, 3'b000,
            32'h3FB504F3, 5'b00001);

        // sqrt(3.0) = 1.7320508... = 0x3FDB3D7 (RNE)
        check_multicycle_f("sqrt(3.0)=1.7320(NX)",
            32'h40400000, 32'h0, FPU_SQRT, 3'b000,
            32'h3FDDB3D7, 5'b00001);

        // sqrt(0.5) = 0.7071067... = 0x3F3504F3 (RNE)
        check_multicycle_f("sqrt(0.5)=0.7071(NX)",
            32'h3F000000, 32'h0, FPU_SQRT, 3'b000,
            32'h3F3504F3, 5'b00001);

        // sqrt(10.0) = 3.16227766... = 0x404A62C2 (RNE)
        check_multicycle_f("sqrt(10.0)=3.1623(NX)",
            32'h41200000, 32'h0, FPU_SQRT, 3'b000,
            32'h404A62C2, 5'b00001);

        check_multicycle_f("sqrt(8.0)=2.8284(NX)",
            32'h41000000, 32'h0, FPU_SQRT, 3'b000,
            32'h403504F3, 5'b00001);

        check_multicycle_f("sqrt(2^100)=2^50",
            32'h71800000, 32'h0, FPU_SQRT, 3'b000,
            32'h58800000, 5'b00000);

        check_multicycle_f("sqrt(2^-100)=2^-50",
            32'h0D800000, 32'h0, FPU_SQRT, 3'b000,
            32'h26800000, 5'b00000);

        // ----- Subnormal -----
        check_multicycle_f("sqrt(2^-149) subnormal",
            32'h00000001, 32'h0, FPU_SQRT, 3'b000,
            32'h1A3504F3, 5'b00001);

        check_multicycle_f("sqrt(2^-126)=2^-63",
            32'h00800000, 32'h0, FPU_SQRT, 3'b000,
            32'h20000000, 5'b00000);

        // ----- Special -----
        // sqrt(+0) = +0
        check_multicycle_f("sqrt(+0)=+0",
            32'h00000000, 32'h0, FPU_SQRT, 3'b000,
            32'h00000000, 5'b00000);

        // sqrt(-0) = -0 (IEEE 754 ����K��)
        check_multicycle_f("sqrt(-0)=-0",
            32'h80000000, 32'h0, FPU_SQRT, 3'b000,
            32'h80000000, 5'b00000);

        // sqrt(+Inf) = +Inf
        check_multicycle_f("sqrt(+Inf)=+Inf",
            32'h7F800000, 32'h0, FPU_SQRT, 3'b000,
            32'h7F800000, 5'b00000);

        // sqrt(-Inf) = qNaN, NV
        check_multicycle_f("sqrt(-Inf)=qNaN(NV)",
            32'hFF800000, 32'h0, FPU_SQRT, 3'b000,
            32'h7FC00000, 5'b10000);

        // sqrt(qNaN) = qNaN, no flag
        check_multicycle_f("sqrt(qNaN)=qNaN",
            32'h7FC00000, 32'h0, FPU_SQRT, 3'b000,
            32'h7FC00000, 5'b00000);

        // sqrt(sNaN) = qNaN, NV
        check_multicycle_f("sqrt(sNaN)=qNaN(NV)",
            32'h7FA00000, 32'h0, FPU_SQRT, 3'b000,
            32'h7FC00000, 5'b10000);

        // sqrt(-1.0) = qNaN, NV
        check_multicycle_f("sqrt(-1.0)=qNaN(NV)",
            32'hBF800000, 32'h0, FPU_SQRT, 3'b000,
            32'h7FC00000, 5'b10000);

        // sqrt(-��������) = qNaN, NV
        check_multicycle_f("sqrt(-0.5)=qNaN(NV)",
            32'hBF000000, 32'h0, FPU_SQRT, 3'b000,
            32'h7FC00000, 5'b10000);

        // ----- round -----
        // RNE: 0x3FB504F3
        check_multicycle_f("sqrt(2) RNE",
            32'h40000000, 32'h0, FPU_SQRT, 3'b000,
            32'h3FB504F3, 5'b00001);

        // RTZ: 0x3FB504F3
        check_multicycle_f("sqrt(2) RTZ",
            32'h40000000, 32'h0, FPU_SQRT, 3'b001,
            32'h3FB504F3, 5'b00001);

        // RDN: 0x3FB504F3
        check_multicycle_f("sqrt(2) RDN",
            32'h40000000, 32'h0, FPU_SQRT, 3'b010,
            32'h3FB504F3, 5'b00001);

        // RUP: 0x3FB504F4
        check_multicycle_f("sqrt(2) RUP",
            32'h40000000, 32'h0, FPU_SQRT, 3'b011,
            32'h3FB504F4, 5'b00001);

        // RMM: 0x3FB504F3
        check_multicycle_f("sqrt(2) RMM",
            32'h40000000, 32'h0, FPU_SQRT, 3'b100,
            32'h3FB504F3, 5'b00001);

        // ===== Subnormal input tests =====
 
        // sqrt(2^-149) = 1.4142 * 2^-75
        check_multicycle_f("sqrt(min_subnormal)",
            32'h00000001, 32'h0, FPU_SQRT, 3'b000,
            32'h1A3504F3, 5'b00001);
 
        // sqrt(2^-148) = 2^-74 (exact)
        check_multicycle_f("sqrt(2^-148) exact",
            32'h00000002, 32'h0, FPU_SQRT, 3'b000,
            32'h1A800000, 5'b00000);
 
        // sqrt(3*2^-149)
        check_multicycle_f("sqrt(3*2^-149)",
            32'h00000003, 32'h0, FPU_SQRT, 3'b000,
            32'h1A9CC471, 5'b00001);
 
        // sqrt(2^-147) = sqrt(2) * 2^-74
        check_multicycle_f("sqrt(2^-147)",
            32'h00000004, 32'h0, FPU_SQRT, 3'b000,
            32'h1AB504F3, 5'b00001);
 
        // sqrt(2^-127) = sqrt(2) * 2^-64
        check_multicycle_f("sqrt(2^-127)",
            32'h00400000, 32'h0, FPU_SQRT, 3'b000,
            32'h1FB504F3, 5'b00001); // �� 0x1F3504F3 -> 0x1FB504F3
 
        // sqrt(max subnormal)
        check_multicycle_f("sqrt(max_subnormal)",
            32'h007FFFFF, 32'h0, FPU_SQRT, 3'b000,
            32'h1FFFFFFF, 5'b00001);
 
        // sqrt(min normal) = 2^-63 (exact)
        check_multicycle_f("sqrt(min_normal)",
            32'h00800000, 32'h0, FPU_SQRT, 3'b000,
            32'h20000000, 5'b00000);
 
        // ===== Large value tests =====
 
        // sqrt(2^127) = 2^63.5 = sqrt(2)*2^63
        check_multicycle_f("sqrt(2^127)",
            32'h7F000000, 32'h0, FPU_SQRT, 3'b000,
            32'h5F3504F3, 5'b00001);
 
        // sqrt(max normal)
        check_multicycle_f("sqrt(max_normal)",
            32'h7F7FFFFF, 32'h0, FPU_SQRT, 3'b000,
            32'h5F7FFFFF, 5'b00001);
 
        // ===== Other boundary tests =====
 
        // sqrt(0.5) = sqrt(2)/2
        check_multicycle_f("sqrt(0.5)",
            32'h3F000000, 32'h0, FPU_SQRT, 3'b000,
            32'h3F3504F3, 5'b00001);
 
        // sqrt(0.25) = 0.5 (exact)
        check_multicycle_f("sqrt(0.25)",
            32'h3E800000, 32'h0, FPU_SQRT, 3'b000,
            32'h3F000000, 5'b00000);
 
        // sqrt(6.0)
        check_multicycle_f("sqrt(6.0)",
            32'h40C00000, 32'h0, FPU_SQRT, 3'b000,
            32'h401CC471, 5'b00001);
 
        // sqrt(8.0) = 2*sqrt(2)
        check_multicycle_f("sqrt(8.0)",
            32'h41000000, 32'h0, FPU_SQRT, 3'b000,
            32'h403504F3, 5'b00001);
 
        // sqrt(10.0)
        check_multicycle_f("sqrt(10.0)",
            32'h41200000, 32'h0, FPU_SQRT, 3'b000,
            32'h404A62C2, 5'b00001);
 
        // ===== Negative subnormal =====
 
        // sqrt(-min subnormal) = qNaN, NV
        check_multicycle_f("sqrt(-min_subnormal)=qNaN",
            32'h80000001, 32'h0, FPU_SQRT, 3'b000,
            32'h7FC00000, 5'b10000);
 

        // =============================================================
        $display("=== FMADD / FMSUB / FNMSUB / FNMADD ===");
        // FMADD: 2*3+4 = 10   (2=0x40000000, 3=0x40400000, 4=0x40800000, 10=0x41200000)
        check_f("FMADD:2*3+4=10",
                32'h40000000, 32'h40400000, 32'h40800000,
                FPU_MADD, 3'b000, 5'h0, 32'h41200000, 5'b00000);
        // FMSUB: 2*3-4 = 2
        check_f("FMSUB:2*3-4=2",
                32'h40000000, 32'h40400000, 32'h40800000,
                FPU_MSUB, 3'b000, 5'h0, 32'h40000000, 5'b00000);
        // FNMSUB: -(2*3-4) = -2
        check_f("FNMSUB:-(2*3-4)=-2",
                32'h40000000, 32'h40400000, 32'h40800000,
                FPU_NMSUB, 3'b000, 5'h0, 32'hC0000000, 5'b00000);
        // FNMADD: -(2*3+4) = -10
        check_f("FNMADD:-(2*3+4)=-10",
                32'h40000000, 32'h40400000, 32'h40800000,
                FPU_NMADD, 3'b000, 5'h0, 32'hC1200000, 5'b00000);

        // =============================================================
        $display("=== FSGNJ / FSGNJN / FSGNJX ===");
        // FSGNJ: sign from fb, magnitude from fa
        // fa=3.0(+), fb=-1.0(-) -> -3.0
        check_f("FSGNJ(3,-1)=-3",
                32'h40400000, 32'hBF800000, 32'h0,
                FPU_SGNJ, 3'b000, 5'h0, 32'hC0400000, 5'b00000);
        // FSGNJN: inverted sign from fb
        // fa=3.0(+), fb=-1.0(-) -> +3.0 (inverted neg -> pos)
        check_f("FSGNJN(3,-1)=+3",
                32'h40400000, 32'hBF800000, 32'h0,
                FPU_SGNJ, 3'b001, 5'h0, 32'h40400000, 5'b00000);
        // FSGNJX: XOR signs
        // fa=+3.0(+), fb=-1.0(-) -> -3.0 (0 XOR 1 = 1)
        check_f("FSGNJX(+3,-1)=-3",
                32'h40400000, 32'hBF800000, 32'h0,
                FPU_SGNJ, 3'b010, 5'h0, 32'hC0400000, 5'b00000);

        // =============================================================
        $display("=== FMIN / FMAX ===");
        // FMIN(1.0, 2.0) = 1.0
        check_f("FMIN(1,2)=1",
                32'h3F800000, 32'h40000000, 32'h0,
                FPU_MINMAX, 3'b000, 5'h0, 32'h3F800000, 5'b00000);
        // FMAX(1.0, 2.0) = 2.0
        check_f("FMAX(1,2)=2",
                32'h3F800000, 32'h40000000, 32'h0,
                FPU_MINMAX, 3'b001, 5'h0, 32'h40000000, 5'b00000);

        // =============================================================
        $display("=== FEQ / FLT / FLE ===");
        // FEQ(1.0, 1.0) = 1
        check_i("FEQ(1,1)=1",
                32'h3F800000, 32'h3F800000, FPU_CMP, 3'b010, 5'h0,
                32'h1, 5'b00000);
        // FEQ(1.0, 2.0) = 0
        check_i("FEQ(1,2)=0",
                32'h3F800000, 32'h40000000, FPU_CMP, 3'b010, 5'h0,
                32'h0, 5'b00000);
        // FLT(1.0, 2.0) = 1
        check_i("FLT(1,2)=1",
                32'h3F800000, 32'h40000000, FPU_CMP, 3'b001, 5'h0,
                32'h1, 5'b00000);
        // FLE(2.0, 2.0) = 1
        check_i("FLE(2,2)=1",
                32'h40000000, 32'h40000000, FPU_CMP, 3'b000, 5'h0,
                32'h1, 5'b00000);

        // =============================================================
        $display("=== FMV.X.W / FMV.W.X ===");
        // FMV.X.W: copy float bits to int
        check_i("FMV.X.W(1.0)=0x3F800000",
                32'h3F800000, 32'h0, FPU_MVXW, 3'b000, 5'h0,
                32'h3F800000, 5'b00000);
        check_i("FMV.X.W(-0)=0x80000000",
                32'h80000000, 32'h0, FPU_MVXW, 3'b000, 5'h0,
                32'h80000000, 5'b00000);
        // FMV.W.X: copy int bits to float
        check_mvwx("FMV.W.X(0x40000000)=2.0", 32'h40000000, 32'h40000000);
        check_mvwx("FMV.W.X(0xBF800000)=-1.0", 32'hBF800000, 32'hBF800000);

        // =============================================================
        $display("=== FCVT.W.S (float->int signed, RNE) ===");
        // 1.5 -> 2 (round to nearest)  1.5=0x3FC00000
        check_i("FCVT.W.S(1.5)=2",
                32'h3FC00000, 32'h0, FPU_CVTWS, 3'b000, 5'h0,
                32'h2, 5'b00001);  // NX: rounded
        // 2.0 -> 2 (exact)
        check_i("FCVT.W.S(2.0)=2",
                32'h40000000, 32'h0, FPU_CVTWS, 3'b000, 5'h0,
                32'h2, 5'b00000);
        // -1.5 -> -2 (RNE)
        check_i("FCVT.W.S(-1.5)=-2",
                32'hBFC00000, 32'h0, FPU_CVTWS, 3'b000, 5'h0,
                32'hFFFFFFFE, 5'b00001);  // NX

        // =============================================================
        $display("=== FCVT.WU.S (float->uint, RNE) ===");
        // rs2_sel[0]=1 selects unsigned
        // 3.7 -> 4  (3.7=0x406CCCCD)
        check_i("FCVT.WU.S(3.7)=4",
                32'h406CCCCD, 32'h0, FPU_CVTWS, 3'b000, 5'h1,
                32'h4, 5'b00001);

        // =============================================================
        $display("=== FCVT.S.W (int->float) ===");
        // rs2_sel[0]=0 -> signed
        // 3 -> 3.0 (exact)  3.0=0x40400000
        @(negedge clk);
        fa      = 32'h0;
        fb      = 32'h0;
        fc      = 32'h0;
        int_a   = 32'd3;
        fpu_op  = FPU_CVTSW;
        fp_rm   = 3'b000;
        rs2_sel = 5'h0;  // signed
        valid_in = 1'b1;
        @(posedge clk);
        valid_in = 1'b0;
        if (result_f === 32'h40400000 && fflags === 5'b00000) begin
            $display("  PASS: FCVT.S.W(3)=3.0 -> f=%h flags=%b", result_f, fflags);
            pass_cnt++;
        end else begin
            $display("  FAIL: FCVT.S.W(3) -> f=%h (exp 40400000) flags=%b (exp 00000)",
                     result_f, fflags);
            fail_cnt++;
        end

        // =============================================================
        $display("=== FCLASS ===");
        // +Inf: bit 7 set -> 0x0080
        check_i("FCLASS(+Inf)",
                32'h7F800000, 32'h0, FPU_CLASS, 3'b000, 5'h0,
                32'h00000080, 5'b00000);
        // -Inf: bit 0 set -> 0x0001
        check_i("FCLASS(-Inf)",
                32'hFF800000, 32'h0, FPU_CLASS, 3'b000, 5'h0,
                32'h00000001, 5'b00000);
        // qNaN: bit 9 set -> 0x0200
        check_i("FCLASS(qNaN)",
                32'h7FC00000, 32'h0, FPU_CLASS, 3'b000, 5'h0,
                32'h00000200, 5'b00000);
        // +zero: bit 4 set -> 0x0010
        check_i("FCLASS(+0)",
                32'h00000000, 32'h0, FPU_CLASS, 3'b000, 5'h0,
                32'h00000010, 5'b00000);
        // -zero: bit 3 set -> 0x0008
        check_i("FCLASS(-0)",
                32'h80000000, 32'h0, FPU_CLASS, 3'b000, 5'h0,
                32'h00000008, 5'b00000);
        // +normal (1.0): bit 6 set -> 0x0040
        check_i("FCLASS(+1.0)",
                32'h3F800000, 32'h0, FPU_CLASS, 3'b000, 5'h0,
                32'h00000040, 5'b00000);
        // -normal (-1.0): bit 1 set -> 0x0002
        check_i("FCLASS(-1.0)",
                32'hBF800000, 32'h0, FPU_CLASS, 3'b000, 5'h0,
                32'h00000002, 5'b00000);

        // =============================================================
        // Summary
        $display("");
        $display("=== Results: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");

        $finish;
    end

    // Timeout safety
    initial begin
        #200000;
        $display("SIMULATION TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
