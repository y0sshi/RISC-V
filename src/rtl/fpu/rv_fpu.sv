// =============================================================================
/// @file rv_fpu.sv
/// @brief Floating-Point Unit Top-Level Dispatcher
///
/// Instantiates and routes between FPU sub-units:
///   rv_fpu_add  : FADD.S / FSUB.S (combinational)
///   rv_fpu_mul  : FMUL.S (combinational)
///   rv_fpu_div  : FDIV.S (multi-cycle, 27 cycles)
///   rv_fpu_sqrt : FSQRT.S (multi-cycle, 27 cycles)
///   rv_fpu_misc : FSGNJ/FMIN/FMAX/FCMP/FCLASS/FMV/FCVT (combinational)
///
/// For FMADD/FMSUB/FNMADD/FNMSUB: computed as FMUL then FADD (non-fused).
///
/// Rounding mode: if fp_rm == 3'b111 (DYN), use frm from fcsr (frm_in).
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

    // Operands
    input  logic [31:0]     fa,         // FP rs1
    input  logic [31:0]     fb,         // FP rs2
    input  logic [31:0]     fc,         // FP rs3 (for FMADD family)
    input  logic [XLEN-1:0] int_a,      // Integer rs1 (FMV.W.X / FCVT.S.W)

    input  fpu_op_t          fpu_op,    // Operation
    input  logic [2:0]       fp_rm,     // Rounding mode from instruction
    input  logic [2:0]       frm_in,    // fcsr.frm (used when fp_rm == 3'b111)
    input  logic [4:0]       rs2_sel,   // inst[24:20]: FCVT sub-type

    input  logic             valid_in,  // Start computation (1-cycle pulse)

    output logic [31:0]      result_f,  // Float result -> f-regfile
    output logic [XLEN-1:0]  result_i,  // Integer result -> int-regfile
    output logic [4:0]       fflags,    // Accrued exception flags

    output logic             fpu_busy,  // 1 = pipeline stall
    output logic             result_valid  // 1-cycle pulse when done
);

    // Resolve rounding mode (DYN -> use fcsr.frm)
    logic [2:0] rm;
    assign rm = (fp_rm == 3'b111) ? frm_in : fp_rm;

    // -------------------------------------------------------------------------
    // Sub-unit wires
    // -------------------------------------------------------------------------
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

    // MISC
    logic [31:0]     misc_result_f;
    logic [XLEN-1:0] misc_result_i;
    logic [4:0]      misc_fflags;

    // FMADD intermediate (non-fused: mul result fed into add)
    logic [31:0] fma_mul_result;
    logic [4:0]  fma_mul_fflags;
    logic [31:0] fma_add_a, fma_add_b;
    logic        fma_add_is_sub;
    logic [31:0] fma_add_result;
    logic [4:0]  fma_add_fflags;

    // -------------------------------------------------------------------------
    // FADD/FSUB instantiation
    // -------------------------------------------------------------------------
    rv_fpu_add u_add (
        .a      (fa),
        .b      (fb),
        .rm     (rm),
        .is_sub (fpu_op == FPU_SUB),
        .result (add_result),
        .fflags (add_fflags)
    );

    // -------------------------------------------------------------------------
    // FMUL instantiation (used for FMUL and FMADD family)
    // -------------------------------------------------------------------------
    rv_fpu_mul u_mul (
        .a      (fa),
        .b      (fb),
        .rm     (rm),
        .result (mul_result),
        .fflags (mul_fflags)
    );

    // FMADD family: second operand to FADD is fc (with possible negate)
    // FMADD:  rd = fa*fb + fc
    // FMSUB:  rd = fa*fb - fc
    // FNMSUB: rd = -(fa*fb - fc) = fc - fa*fb  (negate product)
    // FNMADD: rd = -(fa*fb + fc)               (negate product)
    always_comb begin
        case (fpu_op)
            FPU_MADD:  begin fma_add_a = mul_result;               fma_add_b = fc; fma_add_is_sub = 1'b0; end
            FPU_MSUB:  begin fma_add_a = mul_result;               fma_add_b = fc; fma_add_is_sub = 1'b1; end
            FPU_NMSUB: begin fma_add_a = {!mul_result[31], mul_result[30:0]}; fma_add_b = fc; fma_add_is_sub = 1'b0; end  // -(fa*fb) + fc
            FPU_NMADD: begin fma_add_a = {!mul_result[31], mul_result[30:0]}; fma_add_b = fc; fma_add_is_sub = 1'b1; end  // -(fa*fb) - fc
            default:   begin fma_add_a = mul_result; fma_add_b = fc; fma_add_is_sub = 1'b0; end
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

    // -------------------------------------------------------------------------
    // FDIV instantiation
    // -------------------------------------------------------------------------
    rv_fpu_div u_div (
        .clk          (clk),
        .rst_n        (rst_n),
        .a            (fa),
        .b            (fb),
        .rm           (rm),
        .valid_in     (valid_in && (fpu_op == FPU_DIV)),
        .result       (div_result),
        .fflags       (div_fflags),
        .result_valid (div_result_valid),
        .fpu_busy     (div_busy)
    );

    // -------------------------------------------------------------------------
    // FSQRT instantiation
    // -------------------------------------------------------------------------
    rv_fpu_sqrt u_sqrt (
        .clk          (clk),
        .rst_n        (rst_n),
        .a            (fa),
        .rm           (rm),
        .valid_in     (valid_in && (fpu_op == FPU_SQRT)),
        .result       (sqrt_result),
        .fflags       (sqrt_fflags),
        .result_valid (sqrt_result_valid),
        .fpu_busy     (sqrt_busy)
    );

    // -------------------------------------------------------------------------
    // MISC instantiation
    // -------------------------------------------------------------------------
    rv_fpu_misc #(.XLEN(XLEN)) u_misc (
        .fa        (fa),
        .fb        (fb),
        .int_a     (int_a),
        .fpu_op    (fpu_op),
        .rm        (rm),
        .rs2_sel   (rs2_sel),
        .result_f  (misc_result_f),
        .result_i  (misc_result_i),
        .fflags    (misc_fflags)
    );

    // -------------------------------------------------------------------------
    // Output mux
    // -------------------------------------------------------------------------
    assign fpu_busy     = div_busy | sqrt_busy;
    assign result_valid = div_result_valid | sqrt_result_valid |
                          (valid_in && fpu_op != FPU_DIV && fpu_op != FPU_SQRT);

    always_comb begin
        result_f = 32'h0;
        result_i = '0;
        fflags   = 5'h0;

        case (fpu_op)
            FPU_ADD, FPU_SUB: begin
                result_f = add_result;
                fflags   = add_fflags;
            end
            FPU_MUL: begin
                result_f = mul_result;
                fflags   = mul_fflags;
            end
            FPU_DIV: begin
                result_f = div_result;
                fflags   = div_fflags;
            end
            FPU_SQRT: begin
                result_f = sqrt_result;
                fflags   = sqrt_fflags;
            end
            FPU_MADD, FPU_MSUB, FPU_NMSUB, FPU_NMADD: begin
                result_f = fma_add_result;
                fflags   = mul_fflags | fma_add_fflags;
            end
            FPU_SGNJ, FPU_MINMAX: begin
                result_f = misc_result_f;
                fflags   = misc_fflags;
            end
            FPU_CMP, FPU_CLASS, FPU_MVXW, FPU_CVTWS: begin
                result_i = misc_result_i;
                fflags   = misc_fflags;
            end
            FPU_MVWX, FPU_CVTSW: begin
                result_f = misc_result_f;
                fflags   = misc_fflags;
            end
            default: ;
        endcase
    end

endmodule

`default_nettype wire
