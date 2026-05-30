// =============================================================================
/// @file rv_fpu.sv
/// @brief Floating-Point Unit Top-Level Dispatcher (F+D extensions)
///
/// Dispatches to single-precision (F) or double-precision (D) sub-units
/// based on the fp_double control signal:
///   fp_double=0: S-precision (rv_fpu_add/mul/div/sqrt/misc)
///   fp_double=1: D-precision (rv_fpu_add_d/mul_d/div_d/sqrt_d/misc_d)
///
/// Inputs fa/fb/fc are always 64-bit:
///   F-extension: lower 32 bits hold the single-precision value (NaN-boxed in
///                regfile: upper 32 bits should be all 1s).
///   D-extension: full 64 bits hold the double-precision value.
///
/// NaN-boxing check for F-extension inputs: if upper 32 bits are not all 1s,
/// the value is treated as a canonical single-precision NaN (per RISC-V spec).
///
/// result_f is 64-bit:
///   F-extension: lower 32 bits = SP result, upper 32 bits = 0xFFFFFFFF (NaN-boxed)
///   D-extension: full 64 bits = DP result
///
/// For FMADD/FMSUB/FNMADD/FNMSUB: implemented as non-fused (mul then add).
///
/// fpu_busy is asserted during FDIV and FSQRT iterations.
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_fpu
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    input  wire        clk,
    input  wire        rst_n,

    // Operands (64-bit for D-ext; F-ext uses lower 32 bits)
    input  logic [63:0]     fa,
    input  logic [63:0]     fb,
    input  logic [63:0]     fc,
    input  logic [XLEN-1:0] int_a,

    input  fpu_op_t          fpu_op,
    input  logic             fp_double,  // 0=single, 1=double
    input  logic [2:0]       fp_rm,
    input  logic [2:0]       frm_in,
    input  logic [4:0]       rs2_sel,

    input  logic             valid_in,

    output logic [63:0]      result_f,
    output logic [XLEN-1:0]  result_i,
    output logic [4:0]       fflags,

    output logic             fpu_busy,
    output logic             result_valid
);

    // Resolve rounding mode
    logic [2:0] rm;
    assign rm = (fp_rm == 3'b111) ? frm_in : fp_rm;

    // NaN-boxing check for F-extension inputs (RISC-V spec 11.3).
    // When XLEN=64 and D-ext is present: if a 64-bit FP register is read by an
    // S-instruction and the upper 32 bits are not all 1s, the value is canonical NaN.
    localparam logic [31:0] CANONICAL_NAN_S = 32'h7FC00000;

    logic [31:0] fa_s, fb_s, fc_s;
    assign fa_s = (fa[63:32] == 32'hFFFFFFFF) ? fa[31:0] : CANONICAL_NAN_S;
    assign fb_s = (fb[63:32] == 32'hFFFFFFFF) ? fb[31:0] : CANONICAL_NAN_S;
    assign fc_s = (fc[63:32] == 32'hFFFFFFFF) ? fc[31:0] : CANONICAL_NAN_S;

    // =========================================================================
    // Single-precision sub-units
    // =========================================================================

    // FADD/FSUB
    logic [31:0] add_result;
    logic [4:0]  add_fflags;

    // FMUL
    logic [31:0] mul_result;
    logic [4:0]  mul_fflags;

    // FDIV
    logic [31:0] div_result;
    logic [4:0]  div_fflags;
    logic        div_result_valid;
    logic        div_busy;

    // FSQRT
    logic [31:0] sqrt_result;
    logic [4:0]  sqrt_fflags;
    logic        sqrt_result_valid;
    logic        sqrt_busy;

    // MISC (S)
    logic [31:0]     misc_result_f;
    logic [XLEN-1:0] misc_result_i;
    logic [4:0]      misc_fflags;

    // FMADD intermediate
    logic [31:0] fma_mul_result;
    logic [4:0]  fma_mul_fflags;
    logic [31:0] fma_add_a, fma_add_b;
    logic        fma_add_is_sub;
    logic [31:0] fma_add_result;
    logic [4:0]  fma_add_fflags;

    // fpu_op as plain logic to avoid iverilog enum sensitivity bugs in always_comb/port exprs
    logic [4:0] fpu_op_bits;
    assign fpu_op_bits = fpu_op;

    // Explicit is_sub signals to ensure sensitivity tracking (iverilog port expr limitation)
    logic add_is_sub, add_d_is_sub;
    assign add_is_sub   = (fpu_op_bits == 5'd1);  // FPU_SUB
    assign add_d_is_sub = (fpu_op_bits == 5'd1);

    rv_fpu_add u_add (
        .a      (fa_s),
        .b      (fb_s),
        .rm     (rm),
        .is_sub (add_is_sub),
        .result (add_result),
        .fflags (add_fflags)
    );

    rv_fpu_mul u_mul (
        .a      (fa_s),
        .b      (fb_s),
        .rm     (rm),
        .result (mul_result),
        .fflags (mul_fflags)
    );

    always @(*) begin
        case (fpu_op_bits)
            5'd13: begin fma_add_a = mul_result;                               fma_add_b = fc_s; fma_add_is_sub = 1'b0; end  // FPU_MADD
            5'd14: begin fma_add_a = mul_result;                               fma_add_b = fc_s; fma_add_is_sub = 1'b1; end  // FPU_MSUB
            5'd15: begin fma_add_a = {!mul_result[31], mul_result[30:0]};      fma_add_b = fc_s; fma_add_is_sub = 1'b0; end  // FPU_NMSUB
            5'd16: begin fma_add_a = {!mul_result[31], mul_result[30:0]};      fma_add_b = fc_s; fma_add_is_sub = 1'b1; end  // FPU_NMADD
            default: begin fma_add_a = mul_result; fma_add_b = fc_s; fma_add_is_sub = 1'b0; end
        endcase
    end

    rv_fpu_add u_fma_add (
        .a      (fma_add_a),
        .b      (fma_add_b),
        .rm     (rm),
        .is_sub (fma_add_is_sub),
        .result (fma_add_result),
        .fflags (fma_add_fflags)
    );

    rv_fpu_div u_div (
        .clk          (clk),
        .rst_n        (rst_n),
        .a            (fa_s),
        .b            (fb_s),
        .rm           (rm),
        .valid_in     (valid_in && !fp_double && (fpu_op_bits == 5'd3)),  // FPU_DIV
        .result       (div_result),
        .fflags       (div_fflags),
        .result_valid (div_result_valid),
        .fpu_busy     (div_busy)
    );

    rv_fpu_sqrt u_sqrt (
        .clk          (clk),
        .rst_n        (rst_n),
        .a            (fa_s),
        .rm           (rm),
        .valid_in     (valid_in && !fp_double && (fpu_op_bits == 5'd4)),  // FPU_SQRT
        .result       (sqrt_result),
        .fflags       (sqrt_fflags),
        .result_valid (sqrt_result_valid),
        .fpu_busy     (sqrt_busy)
    );

    rv_fpu_misc #(.XLEN(XLEN)) u_misc (
        .fa        (fa_s),
        .fb        (fb_s),
        .int_a     (int_a),
        .fpu_op    (fpu_op),
        .rm        (rm),
        .rs2_sel   (rs2_sel),
        .result_f  (misc_result_f),
        .result_i  (misc_result_i),
        .fflags    (misc_fflags)
    );

    // =========================================================================
    // Double-precision sub-units
    // =========================================================================

    // FADD.D / FSUB.D
    logic [63:0] add_d_result;
    logic [4:0]  add_d_fflags;

    // FMUL.D
    logic [63:0] mul_d_result;
    logic [4:0]  mul_d_fflags;

    // FDIV.D
    logic [63:0] div_d_result;
    logic [4:0]  div_d_fflags;
    logic        div_d_result_valid;
    logic        div_d_busy;

    // FSQRT.D
    logic [63:0] sqrt_d_result;
    logic [4:0]  sqrt_d_fflags;
    logic        sqrt_d_result_valid;
    logic        sqrt_d_busy;

    // MISC (D)
    logic [63:0]     misc_d_result_f;
    logic [XLEN-1:0] misc_d_result_i;
    logic [4:0]      misc_d_fflags;

    // FMADD.D intermediate
    logic [63:0] fma_d_mul_result;
    logic [4:0]  fma_d_mul_fflags;
    logic [63:0] fma_d_add_a, fma_d_add_b;
    logic        fma_d_add_is_sub;
    logic [63:0] fma_d_add_result;
    logic [4:0]  fma_d_add_fflags;

    rv_fpu_add_d u_add_d (
        .a      (fa),
        .b      (fb),
        .rm     (rm),
        .is_sub (add_d_is_sub),
        .result (add_d_result),
        .fflags (add_d_fflags)
    );

    rv_fpu_mul_d u_mul_d (
        .a      (fa),
        .b      (fb),
        .rm     (rm),
        .result (mul_d_result),
        .fflags (mul_d_fflags)
    );

    always @(*) begin
        case (fpu_op_bits)
            5'd13: begin fma_d_add_a = mul_d_result;                               fma_d_add_b = fc; fma_d_add_is_sub = 1'b0; end  // FPU_MADD
            5'd14: begin fma_d_add_a = mul_d_result;                               fma_d_add_b = fc; fma_d_add_is_sub = 1'b1; end  // FPU_MSUB
            5'd15: begin fma_d_add_a = {!mul_d_result[63], mul_d_result[62:0]};    fma_d_add_b = fc; fma_d_add_is_sub = 1'b0; end  // FPU_NMSUB
            5'd16: begin fma_d_add_a = {!mul_d_result[63], mul_d_result[62:0]};    fma_d_add_b = fc; fma_d_add_is_sub = 1'b1; end  // FPU_NMADD
            default: begin fma_d_add_a = mul_d_result; fma_d_add_b = fc; fma_d_add_is_sub = 1'b0; end
        endcase
    end

    rv_fpu_add_d u_fma_add_d (
        .a      (fma_d_add_a),
        .b      (fma_d_add_b),
        .rm     (rm),
        .is_sub (fma_d_add_is_sub),
        .result (fma_d_add_result),
        .fflags (fma_d_add_fflags)
    );

    rv_fpu_div_d u_div_d (
        .clk          (clk),
        .rst_n        (rst_n),
        .a            (fa),
        .b            (fb),
        .rm           (rm),
        .valid_in     (valid_in && fp_double && (fpu_op_bits == 5'd3)),  // FPU_DIV
        .result       (div_d_result),
        .fflags       (div_d_fflags),
        .result_valid (div_d_result_valid),
        .fpu_busy     (div_d_busy)
    );

    rv_fpu_sqrt_d u_sqrt_d (
        .clk          (clk),
        .rst_n        (rst_n),
        .a            (fa),
        .rm           (rm),
        .valid_in     (valid_in && fp_double && (fpu_op_bits == 5'd4)),  // FPU_SQRT
        .result       (sqrt_d_result),
        .fflags       (sqrt_d_fflags),
        .result_valid (sqrt_d_result_valid),
        .fpu_busy     (sqrt_d_busy)
    );

    rv_fpu_misc_d #(.XLEN(XLEN)) u_misc_d (
        .fa        (fa),
        .fb        (fb),
        .int_a     (int_a),
        .fpu_op    (fpu_op),
        .rm        (rm),
        .rs2_sel   (rs2_sel),
        .result_f  (misc_d_result_f),
        .result_i  (misc_d_result_i),
        .fflags    (misc_d_fflags)
    );

    // =========================================================================
    // Output mux
    // =========================================================================
    assign fpu_busy     = div_busy | sqrt_busy | div_d_busy | sqrt_d_busy;
    assign result_valid = div_result_valid | sqrt_result_valid |
                          div_d_result_valid | sqrt_d_result_valid |
                          (valid_in && fpu_op_bits != 5'd3 && fpu_op_bits != 5'd4);

    // Module-level intermediates for single-precision path (avoid iverilog
    // sensitivity-list issues with local variable declarations inside always_comb)
    logic [31:0] sp_result_f;
    logic [4:0]  sp_fflags;
    logic        sp_to_int;  // 1 = result_i output, 0 = result_f output

    always @(*) begin
        sp_result_f = 32'h0;
        sp_fflags   = 5'h0;
        sp_to_int   = 1'b0;

        case (fpu_op_bits)
            5'd0, 5'd1: begin sp_result_f = add_result;  sp_fflags = add_fflags;  end  // FPU_ADD, FPU_SUB
            5'd2:        begin sp_result_f = mul_result;  sp_fflags = mul_fflags;  end  // FPU_MUL
            5'd3:        begin sp_result_f = div_result;  sp_fflags = div_fflags;  end  // FPU_DIV
            5'd4:        begin sp_result_f = sqrt_result; sp_fflags = sqrt_fflags; end  // FPU_SQRT
            5'd13, 5'd14, 5'd15, 5'd16: begin                                          // FMADD family
                sp_result_f = fma_add_result;
                sp_fflags   = mul_fflags | fma_add_fflags;
            end
            5'd5, 5'd6: begin                                                          // FPU_SGNJ, FPU_MINMAX
                sp_result_f = misc_result_f;
                sp_fflags   = misc_fflags;
            end
            5'd7, 5'd12, 5'd10, 5'd8: begin                                           // FPU_CMP, CLASS, MVXW, CVTWS
                sp_to_int   = 1'b1;
                sp_fflags   = misc_fflags;
            end
            5'd11, 5'd9: begin                                                         // FPU_MVWX, FPU_CVTSW
                sp_result_f = misc_result_f;
                sp_fflags   = misc_fflags;
            end
            default: ;
        endcase
    end

    always @(*) begin
        result_f = 64'h0;
        result_i = '0;
        fflags   = 5'h0;

        if (!fp_double) begin
            // Single-precision path: output is NaN-boxed
            if (sp_to_int) begin
                // FMV.X.W transfers the raw low 32 bits (not the NaN-box-checked
                // fa_s); all other int-producing ops use the misc result.
                if (fpu_op_bits == 5'd10)  // FPU_MVXW
                    result_i = {{(XLEN-32){fa[31]}}, fa[31:0]};
                else
                    result_i = misc_result_i;
            end else begin
                result_f = {32'hFFFFFFFF, sp_result_f};
            end
            fflags = sp_fflags;

        end else begin
            // Double-precision path
            case (fpu_op_bits)
                FPU_ADD, FPU_SUB: begin
                    result_f = add_d_result;
                    fflags   = add_d_fflags;
                end
                FPU_MUL: begin
                    result_f = mul_d_result;
                    fflags   = mul_d_fflags;
                end
                FPU_DIV: begin
                    result_f = div_d_result;
                    fflags   = div_d_fflags;
                end
                FPU_SQRT: begin
                    result_f = sqrt_d_result;
                    fflags   = sqrt_d_fflags;
                end
                FPU_MADD, FPU_MSUB, FPU_NMSUB, FPU_NMADD: begin
                    result_f = fma_d_add_result;
                    fflags   = mul_d_fflags | fma_d_add_fflags;
                end
                FPU_SGNJ, FPU_MINMAX: begin
                    result_f = misc_d_result_f;
                    fflags   = misc_d_fflags;
                end
                FPU_CMP, FPU_CLASS, FPU_MVXW, FPU_CVTWS: begin
                    result_i = misc_d_result_i;
                    fflags   = misc_d_fflags;
                end
                FPU_MVWX, FPU_CVTSW,
                FPU_CVTSD, FPU_CVTDS: begin
                    result_f = misc_d_result_f;
                    fflags   = misc_d_fflags;
                end
                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
