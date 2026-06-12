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
    input  wire  [63:0]     fa,
    input  wire  [63:0]     fb,
    input  wire  [63:0]     fc,
    input  wire  [XLEN-1:0] int_a,

    input  wire fpu_op_t     fpu_op,
    input  wire              fp_double,  // 0=single, 1=double
    input  wire  [2:0]       fp_rm,
    input  wire  [2:0]       frm_in,
    input  wire  [4:0]       rs2_sel,

    input  wire              valid_in,

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

    // FMADD pipeline register (C-2c): the S-precision multiply product is
    // registered so the FMADD multiply lands in pipeline stage 0 and the add
    // (u_fma_add) in stage 1, splitting the long serial mul->add->round path.
    logic [31:0] mul_result_q;
    logic [4:0]  mul_fflags_q;

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

    // Named is_sub wires for the add sub-units (FADD vs FSUB select)
    logic add_is_sub, add_d_is_sub;
    assign add_is_sub   = (fpu_op == FPU_SUB);
    assign add_d_is_sub = (fpu_op == FPU_SUB);

    rv_fpu_add u_add (
        .clk    (clk),
        .rst_n  (rst_n),
        .a      (fa_s),
        .b      (fb_s),
        .rm     (rm),
        .is_sub (add_is_sub),
        .result (add_result),
        .fflags (add_fflags)
    );

    rv_fpu_mul u_mul (
        .clk    (clk),
        .rst_n  (rst_n),
        .a      (fa_s),
        .b      (fb_s),
        .rm     (rm),
        .result (mul_result),
        .fflags (mul_fflags)
    );

    // FMADD add reads the REGISTERED product (mul_result_q) so the multiply and
    // the add+round execute in separate pipeline stages (C-2c).
    always @(*) begin
        case (fpu_op)
            FPU_MADD:  begin fma_add_a = mul_result_q;                            fma_add_b = fc_s; fma_add_is_sub = 1'b0; end
            FPU_MSUB:  begin fma_add_a = mul_result_q;                            fma_add_b = fc_s; fma_add_is_sub = 1'b1; end
            FPU_NMSUB: begin fma_add_a = {!mul_result_q[31], mul_result_q[30:0]}; fma_add_b = fc_s; fma_add_is_sub = 1'b0; end
            FPU_NMADD: begin fma_add_a = {!mul_result_q[31], mul_result_q[30:0]}; fma_add_b = fc_s; fma_add_is_sub = 1'b1; end
            default:   begin fma_add_a = mul_result_q;                            fma_add_b = fc_s; fma_add_is_sub = 1'b0; end
        endcase
    end

    rv_fpu_add u_fma_add (
        .clk    (clk),
        .rst_n  (rst_n),
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
        .valid_in     (valid_in && !fp_double && (fpu_op == FPU_DIV)),
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
        .valid_in     (valid_in && !fp_double && (fpu_op == FPU_SQRT)),
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

    // FMADD.D pipeline register (C-2c): D-precision multiply product, see the
    // S-precision mul_result_q note above.
    logic [63:0] mul_d_result_q;
    logic [4:0]  mul_d_fflags_q;

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
        .clk    (clk),
        .rst_n  (rst_n),
        .a      (fa),
        .b      (fb),
        .rm     (rm),
        .is_sub (add_d_is_sub),
        .result (add_d_result),
        .fflags (add_d_fflags)
    );

    rv_fpu_mul_d u_mul_d (
        .clk    (clk),
        .rst_n  (rst_n),
        .a      (fa),
        .b      (fb),
        .rm     (rm),
        .result (mul_d_result),
        .fflags (mul_d_fflags)
    );

    // FMADD.D add reads the REGISTERED product (mul_d_result_q), see S-prec note.
    always @(*) begin
        case (fpu_op)
            FPU_MADD:  begin fma_d_add_a = mul_d_result_q;                              fma_d_add_b = fc; fma_d_add_is_sub = 1'b0; end
            FPU_MSUB:  begin fma_d_add_a = mul_d_result_q;                              fma_d_add_b = fc; fma_d_add_is_sub = 1'b1; end
            FPU_NMSUB: begin fma_d_add_a = {!mul_d_result_q[63], mul_d_result_q[62:0]}; fma_d_add_b = fc; fma_d_add_is_sub = 1'b0; end
            FPU_NMADD: begin fma_d_add_a = {!mul_d_result_q[63], mul_d_result_q[62:0]}; fma_d_add_b = fc; fma_d_add_is_sub = 1'b1; end
            default:   begin fma_d_add_a = mul_d_result_q;                              fma_d_add_b = fc; fma_d_add_is_sub = 1'b0; end
        endcase
    end

    rv_fpu_add_d u_fma_add_d (
        .clk    (clk),
        .rst_n  (rst_n),
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
        .valid_in     (valid_in && fp_double && (fpu_op == FPU_DIV)),
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
        .valid_in     (valid_in && fp_double && (fpu_op == FPU_SQRT)),
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
    // Combinational-op pipeline (C-2c, 2-stage)
    //
    // FADD/FSUB, FMUL, the FMADD family, and the misc ops (FSGNJ/FMINMAX/FCMP/
    // FCLASS/FMV/FCVT) were a single-cycle combinational path whose IEEE
    // significand align/normalize/round -- and for FMADD a serial multiply->add
    // -- dominated the FPGA critical path (WNS -54 ns; all top failing paths end
    // in this FPU).  Give every such op a fixed extra-cycle latency so a pipeline
    // register can split the path: the FMADD product is registered above
    // (mul_result_q / mul_d_result_q), placing the multiply in stage 0 and the
    // add+round in stage 1.  The busy / start-stall / done handshake MIRRORS the
    // FDIV/FSQRT (and integer-divide) protocol, so rv_core stalls EX while the
    // op is in flight and captures the result on the cycle busy drops.
    //
    // This is a LATENCY-only change (results stay bit-identical); it is NOT a
    // no-op (combinational ops now occupy EX for extra cycles), validated by
    // result equivalence.  Mutually exclusive with FDIV/FSQRT (their own units).
    //
    // C-2c third step: the multipliers (rv_fpu_mul / rv_fpu_mul_d) are now
    // 1-cycle pipelined too, so the FMADD serial chain is 3 register deep --
    //   multiply internal reg (T+1) -> mul_result_q (T+2) -> adder internal reg
    //   (T+3) -> add stage-1 result (T+3) --
    // and the combinational op must occupy EX for 2 busy cycles, with the result
    // captured at T+3 (busy falling).  A counter (COMB_LAT busy cycles) replaces
    // the old single-busy-cycle flop.
    //
    // mul_result_q / mul_d_result_q are now FREE-RUNNING (latched every cycle):
    // because the multiply result is only valid at T+1 (it is registered), the
    // old start-cycle (T) latch would capture a stale product.  Free-running, the
    // FMADD add reads mul_result_q at T+2 = multiply result(T+1) = correct.  Stale
    // fills on the non-capture cycles are harmless: rv_core only captures on the
    // T+3 (busy-falling) cycle, by which time the correct product has propagated.
    //
    // Timeline (start cycle T): T raises busy on the next edge (NBA); T+1,T+2 hold
    // busy=1 (EX stalled, multiply then add execute from registered operands);
    // T+3 busy drops -> rv_core captures result_f/fflags, comb_done pulses once.
    // Operands are frozen in ID/EX across the stall, so every sub-unit's pipelined
    // result is stable by its respective cycle.
    logic comb_op_in;
    assign comb_op_in = valid_in && (fpu_op != FPU_DIV) && (fpu_op != FPU_SQRT);

    localparam int unsigned COMB_LAT = 2;  // busy cycles (capture at T+1+COMB_LAT)
    logic [1:0] comb_cnt;
    logic       comb_busy, comb_busy_q, comb_done;
    assign comb_busy = (comb_cnt != 2'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            comb_cnt       <= 2'd0;
            comb_busy_q    <= 1'b0;
            mul_result_q   <= '0;
            mul_fflags_q   <= '0;
            mul_d_result_q <= '0;
            mul_d_fflags_q <= '0;
        end else begin
            comb_busy_q <= comb_busy;
            // Free-running capture of the pipelined multiply product / flags.
            mul_result_q   <= mul_result;
            mul_fflags_q   <= mul_fflags;
            mul_d_result_q <= mul_d_result;
            mul_d_fflags_q <= mul_d_fflags;

            if (comb_op_in && comb_cnt == 2'd0)
                comb_cnt <= COMB_LAT[1:0];      // start: span COMB_LAT busy cycles
            else if (comb_cnt != 2'd0)
                comb_cnt <= comb_cnt - 2'd1;    // count down to capture cycle
        end
    end
    // Result ready / capture cycle: busy was high last cycle and is now low.
    assign comb_done = comb_busy_q && !comb_busy;

    // =========================================================================
    // Output mux
    // =========================================================================
    assign fpu_busy     = div_busy | sqrt_busy | div_d_busy | sqrt_d_busy |
                          comb_busy;
    assign result_valid = div_result_valid | sqrt_result_valid |
                          div_d_result_valid | sqrt_d_result_valid |
                          comb_done;

    // Single-precision result/flags mux
    logic [31:0] sp_result_f;
    logic [4:0]  sp_fflags;
    logic        sp_to_int;  // 1 = result_i output, 0 = result_f output

    always @(*) begin
        sp_result_f = 32'h0;
        sp_fflags   = 5'h0;
        sp_to_int   = 1'b0;

        case (fpu_op)
            FPU_ADD, FPU_SUB: begin sp_result_f = add_result;  sp_fflags = add_fflags;  end
            FPU_MUL:          begin sp_result_f = mul_result;  sp_fflags = mul_fflags;  end
            FPU_DIV:          begin sp_result_f = div_result;  sp_fflags = div_fflags;  end
            FPU_SQRT:         begin sp_result_f = sqrt_result; sp_fflags = sqrt_fflags; end
            FPU_MADD, FPU_MSUB, FPU_NMSUB, FPU_NMADD: begin
                sp_result_f = fma_add_result;
                sp_fflags   = mul_fflags_q | fma_add_fflags;
            end
            FPU_SGNJ, FPU_MINMAX: begin
                sp_result_f = misc_result_f;
                sp_fflags   = misc_fflags;
            end
            FPU_CMP, FPU_CLASS, FPU_MVXW, FPU_CVTWS: begin
                sp_to_int   = 1'b1;
                sp_fflags   = misc_fflags;
            end
            FPU_MVWX, FPU_CVTSW: begin
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
                if (fpu_op == FPU_MVXW)
                    result_i = {{(XLEN-32){fa[31]}}, fa[31:0]};
                else
                    result_i = misc_result_i;
            end else begin
                result_f = {32'hFFFFFFFF, sp_result_f};
            end
            fflags = sp_fflags;

        end else begin
            // Double-precision path
            case (fpu_op)
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
                    fflags   = mul_d_fflags_q | fma_d_add_fflags;
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
