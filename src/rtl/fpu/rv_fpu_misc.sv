// =============================================================================
/// @file rv_fpu_misc.sv
/// @brief FPU Miscellaneous Single-Cycle Operations
///
/// Implements:
///   FSGNJ.S / FSGNJN.S / FSGNJX.S  -- Sign injection (rm selects variant)
///   FMIN.S  / FMAX.S                -- Min/Max
///   FEQ.S   / FLT.S  / FLE.S       -- Comparison (result to int reg)
///   FCLASS.S                         -- Classify
///   FMV.X.W                          -- Float bits -> int reg
///   FMV.W.X                          -- Int bits -> float reg
///   FCVT.W.S  / FCVT.WU.S           -- Float -> integer
///   FCVT.S.W  / FCVT.S.WU           -- Integer -> float
///
/// All outputs are purely combinational (no state).
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_fpu_misc
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    input  logic [31:0]     fa,
    input  logic [31:0]     fb,
    input  logic [XLEN-1:0] int_a,

    input  fpu_op_t         fpu_op,
    input  logic [2:0]      rm,
    input  logic [4:0]      rs2_sel,

    output logic [31:0]     result_f,
    output logic [XLEN-1:0] result_i,
    output logic [4:0]      fflags
);

    localparam logic [31:0] CANONICAL_NAN = 32'h7FC00000;

    // Field extraction
    logic        sa, sb;
    logic [7:0]  ea, eb;
    logic [22:0] frac_a, frac_b;

    assign sa     = fa[31];
    assign ea     = fa[30:23];
    assign frac_a = fa[22:0];
    assign sb     = fb[31];
    assign eb     = fb[30:23];
    assign frac_b = fb[22:0];

    // Classification
    logic a_nan, b_nan, a_snan, b_snan, a_qnan, b_qnan;
    logic a_inf, b_inf, a_zero, b_zero, a_sub, b_sub;

    assign a_nan  = (ea == 8'hFF) && (frac_a != 0);
    assign b_nan  = (eb == 8'hFF) && (frac_b != 0);
    assign a_snan = a_nan && !frac_a[22];
    assign b_snan = b_nan && !frac_b[22];
    assign a_qnan = a_nan &&  frac_a[22];
    assign b_qnan = b_nan &&  frac_b[22];
    assign a_inf  = (ea == 8'hFF) && (frac_a == 0);
    assign b_inf  = (eb == 8'hFF) && (frac_b == 0);
    assign a_zero = (ea == 0) && (frac_a == 0);
    assign b_zero = (eb == 0) && (frac_b == 0);
    assign a_sub  = (ea == 0) && (frac_a != 0);
    assign b_sub  = (eb == 0) && (frac_b != 0);

    // -------------------------------------------------------------------------
    // FCLASS.S
    // -------------------------------------------------------------------------
    logic [9:0] fclass_bits;
    always_comb begin
        fclass_bits = 10'b0;
        if      (a_snan)                                        fclass_bits[8] = 1'b1;
        else if (a_qnan)                                        fclass_bits[9] = 1'b1;
        else if (a_inf   &&  sa)                                fclass_bits[0] = 1'b1;
        else if (!a_nan && !a_inf && sa && !a_zero && !a_sub)   fclass_bits[1] = 1'b1;
        else if (a_sub   &&  sa)                                fclass_bits[2] = 1'b1;
        else if (a_zero  &&  sa)                                fclass_bits[3] = 1'b1;
        else if (a_zero  && !sa)                                fclass_bits[4] = 1'b1;
        else if (a_sub   && !sa)                                fclass_bits[5] = 1'b1;
        else if (!a_nan && !a_inf && !sa && !a_zero && !a_sub)  fclass_bits[6] = 1'b1;
        else if (a_inf   && !sa)                                fclass_bits[7] = 1'b1;
    end

    // -------------------------------------------------------------------------
    // Comparison helpers
    // -------------------------------------------------------------------------
    logic a_lt_b_mag;
    assign a_lt_b_mag = ({ea, frac_a} < {eb, frac_b});

    logic a_lt_b, a_eq_b;
    always_comb begin
        a_eq_b = (fa == fb) || (a_zero && b_zero);
        a_lt_b = 1'b0;
        if (!a_nan && !b_nan) begin
            if (sa && !sb)
                a_lt_b = !a_zero || !b_zero;
            else if (!sa && sb)
                a_lt_b = 1'b0;
            else if (!sa && !sb)
                a_lt_b = {ea, frac_a} < {eb, frac_b};
            else
                a_lt_b = {ea, frac_a} > {eb, frac_b};
        end
        if (a_nan || b_nan) begin
            a_eq_b = 1'b0;
            a_lt_b = 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // FCVT.S.W / FCVT.S.WU  (integer -> float)
    // All intermediates at module level (iverilog restriction)
    // -------------------------------------------------------------------------
    logic        cvt_sw_sign;
    logic [32:0] cvt_sw_mag;
    logic [31:0] cvt_sw_result;
    logic        cvt_sw_nx;
    logic [4:0]  csw_lz;
    logic [7:0]  csw_biased_exp;
    logic [31:0] csw_shifted_mag;
    logic [22:0] csw_mant_frac;
    logic        csw_G, csw_R, csw_S;
    logic        csw_round_up;
    logic [23:0] csw_mant_rounded;

    always_comb begin
        cvt_sw_result   = 32'h0;
        cvt_sw_nx       = 1'b0;
        csw_lz          = 5'd0;
        csw_biased_exp  = 8'd0;
        csw_shifted_mag = 32'h0;
        csw_mant_frac   = 23'h0;
        csw_G           = 1'b0;
        csw_R           = 1'b0;
        csw_S           = 1'b0;
        csw_round_up    = 1'b0;
        csw_mant_rounded = 24'h0;

        if (rs2_sel[0]) begin
            cvt_sw_sign = 1'b0;
            cvt_sw_mag  = {1'b0, int_a[31:0]};
        end else begin
            cvt_sw_sign = int_a[XLEN-1];
            cvt_sw_mag  = cvt_sw_sign ? {1'b0, ~int_a[31:0] + 32'd1}
                                      : {1'b0, int_a[31:0]};
        end

        if (cvt_sw_mag == 0) begin
            cvt_sw_result = {cvt_sw_sign, 31'h0};
        end else begin
            // Priority encode leading 1 in cvt_sw_mag[31:0]
            if      (cvt_sw_mag[31]) csw_lz = 5'd0;
            else if (cvt_sw_mag[30]) csw_lz = 5'd1;
            else if (cvt_sw_mag[29]) csw_lz = 5'd2;
            else if (cvt_sw_mag[28]) csw_lz = 5'd3;
            else if (cvt_sw_mag[27]) csw_lz = 5'd4;
            else if (cvt_sw_mag[26]) csw_lz = 5'd5;
            else if (cvt_sw_mag[25]) csw_lz = 5'd6;
            else if (cvt_sw_mag[24]) csw_lz = 5'd7;
            else if (cvt_sw_mag[23]) csw_lz = 5'd8;
            else if (cvt_sw_mag[22]) csw_lz = 5'd9;
            else if (cvt_sw_mag[21]) csw_lz = 5'd10;
            else if (cvt_sw_mag[20]) csw_lz = 5'd11;
            else if (cvt_sw_mag[19]) csw_lz = 5'd12;
            else if (cvt_sw_mag[18]) csw_lz = 5'd13;
            else if (cvt_sw_mag[17]) csw_lz = 5'd14;
            else if (cvt_sw_mag[16]) csw_lz = 5'd15;
            else if (cvt_sw_mag[15]) csw_lz = 5'd16;
            else if (cvt_sw_mag[14]) csw_lz = 5'd17;
            else if (cvt_sw_mag[13]) csw_lz = 5'd18;
            else if (cvt_sw_mag[12]) csw_lz = 5'd19;
            else if (cvt_sw_mag[11]) csw_lz = 5'd20;
            else if (cvt_sw_mag[10]) csw_lz = 5'd21;
            else if (cvt_sw_mag[9])  csw_lz = 5'd22;
            else if (cvt_sw_mag[8])  csw_lz = 5'd23;
            else if (cvt_sw_mag[7])  csw_lz = 5'd24;
            else if (cvt_sw_mag[6])  csw_lz = 5'd25;
            else if (cvt_sw_mag[5])  csw_lz = 5'd26;
            else if (cvt_sw_mag[4])  csw_lz = 5'd27;
            else if (cvt_sw_mag[3])  csw_lz = 5'd28;
            else if (cvt_sw_mag[2])  csw_lz = 5'd29;
            else if (cvt_sw_mag[1])  csw_lz = 5'd30;
            else                     csw_lz = 5'd31;

            csw_biased_exp  = 8'd127 + 8'd31 - {3'b0, csw_lz};
            csw_shifted_mag = cvt_sw_mag[31:0] << (csw_lz + 1);
            csw_mant_frac   = csw_shifted_mag[31:9];
            csw_G           = csw_shifted_mag[8];
            csw_R           = csw_shifted_mag[7];
            csw_S           = |csw_shifted_mag[6:0];

            case (rm)
                3'b000: csw_round_up = csw_G & (csw_R | csw_S | csw_mant_frac[0]);
                3'b001: csw_round_up = 1'b0;
                3'b010: csw_round_up = (csw_G | csw_R | csw_S) & cvt_sw_sign;
                3'b011: csw_round_up = (csw_G | csw_R | csw_S) & !cvt_sw_sign;
                3'b100: csw_round_up = csw_G;
                default: csw_round_up = 1'b0;
            endcase

            csw_mant_rounded = {1'b0, csw_mant_frac} + {23'h0, csw_round_up};
            if (csw_mant_rounded[23]) csw_biased_exp = csw_biased_exp + 8'd1;

            cvt_sw_result = {cvt_sw_sign, csw_biased_exp, csw_mant_rounded[22:0]};
            cvt_sw_nx     = csw_G | csw_R | csw_S;
        end
    end

    // -------------------------------------------------------------------------
    // FCVT.W.S / FCVT.WU.S  (float -> integer)
    // -------------------------------------------------------------------------
    logic [XLEN-1:0] cvt_ws_result;
    logic            cvt_ws_nv, cvt_ws_nx;
    logic signed [8:0]  cws_exp_unbiased;
    logic [55:0]        cws_sig_shifted;
    logic [31:0]        cws_uint_val;

    always_comb begin
        cvt_ws_result   = '0;
        cvt_ws_nv       = 1'b0;
        cvt_ws_nx       = 1'b0;
        cws_exp_unbiased = 9'd0;
        cws_sig_shifted = 56'h0;
        cws_uint_val    = 32'h0;

        if (a_nan) begin
            cvt_ws_result = rs2_sel[0] ? {XLEN{1'b1}} : {{1'b0},{(XLEN-1){1'b1}}};
            cvt_ws_nv     = 1'b1;
        end else if (a_inf) begin
            if (rs2_sel[0]) begin
                cvt_ws_result = sa ? {XLEN{1'b0}} : {XLEN{1'b1}};
            end else begin
                cvt_ws_result = sa ? {1'b1,{(XLEN-1){1'b0}}} : {{1'b0},{(XLEN-1){1'b1}}};
            end
            cvt_ws_nv = 1'b1;
        end else if (a_zero) begin
            cvt_ws_result = '0;
        end else begin
            cws_exp_unbiased = $signed({1'b0, ea}) - 9'sd127;

            if (cws_exp_unbiased < 0) begin
                cvt_ws_result = '0;
                cvt_ws_nx     = 1'b1;
            end else if (rs2_sel[0]) begin
                // Unsigned
                if (cws_exp_unbiased >= 32) begin
                    cvt_ws_result = {XLEN{1'b1}};
                    cvt_ws_nv     = 1'b1;
                end else begin
                    cws_sig_shifted   = {1'b1, frac_a, 32'h0} >> (31 - cws_exp_unbiased);
                    cvt_ws_result     = {{(XLEN-32){1'b0}}, cws_sig_shifted[55:24]};
                    cvt_ws_nx         = |cws_sig_shifted[23:0];
                    if (cvt_ws_nx) begin
                        case (rm)
                            3'b001: ; // RTZ
                            3'b010: ; // RDN (positive)
                            3'b011: cvt_ws_result = cvt_ws_result + 1; // RUP
                            3'b000: begin
                                if (cws_sig_shifted[23] && (|cws_sig_shifted[22:0] ||
                                    cvt_ws_result[0]))
                                    cvt_ws_result = cvt_ws_result + 1;
                            end
                            3'b100: begin
                                if (cws_sig_shifted[23]) cvt_ws_result = cvt_ws_result + 1;
                            end
                            default: ;
                        endcase
                    end
                    if (sa) begin
                        cvt_ws_result = {XLEN{1'b1}};
                        cvt_ws_nv     = 1'b1;
                    end
                end
            end else begin
                // Signed
                if (cws_exp_unbiased >= 31) begin
                    cvt_ws_result = sa ? {1'b1,{(XLEN-1){1'b0}}} : {{1'b0},{(XLEN-1){1'b1}}};
                    cvt_ws_nv     = 1'b1;
                end else begin
                    cws_sig_shifted = {1'b1, frac_a, 32'h0} >> (31 - cws_exp_unbiased);
                    cws_uint_val    = cws_sig_shifted[55:24];
                    cvt_ws_nx       = |cws_sig_shifted[23:0];
                    if (cvt_ws_nx) begin
                        case (rm)
                            3'b001: ; // RTZ
                            3'b010: if (sa) cws_uint_val = cws_uint_val + 1; // RDN
                            3'b011: if (!sa) cws_uint_val = cws_uint_val + 1; // RUP
                            3'b000: begin
                                if (cws_sig_shifted[23] && (|cws_sig_shifted[22:0] ||
                                    cws_uint_val[0]))
                                    cws_uint_val = cws_uint_val + 1;
                            end
                            3'b100: begin
                                if (cws_sig_shifted[23]) cws_uint_val = cws_uint_val + 1;
                            end
                            default: ;
                        endcase
                    end
                    if (sa) begin
                        cvt_ws_result = {{(XLEN-32){1'b1}}, ~cws_uint_val + 32'd1};
                        if (cws_uint_val > 32'h80000000) begin
                            cvt_ws_result = {1'b1, {(XLEN-1){1'b0}}};
                            cvt_ws_nv     = 1'b1;
                        end
                    end else begin
                        cvt_ws_result = {{(XLEN-32){1'b0}}, cws_uint_val};
                        if (cws_uint_val >= 32'h80000000) begin
                            cvt_ws_result = {{1'b0},{(XLEN-1){1'b1}}};
                            cvt_ws_nv     = 1'b1;
                        end
                    end
                end
            end
        end
    end

    // =========================================================================
    // Output mux
    // =========================================================================
    always_comb begin
        result_f = 32'h0;
        result_i = '0;
        fflags   = 5'h0;

        case (fpu_op)
            FPU_SGNJ: begin
                case (rm)
                    3'b000: result_f = {sb,      fa[30:0]};  // FSGNJ
                    3'b001: result_f = {!sb,     fa[30:0]};  // FSGNJN
                    3'b010: result_f = {sa ^ sb, fa[30:0]};  // FSGNJX
                    default: result_f = fa;
                endcase
            end

            FPU_MINMAX: begin
                fflags[4] = a_snan | b_snan;
                if (a_nan && b_nan) begin
                    result_f = CANONICAL_NAN;
                end else if (a_nan) begin
                    result_f = fb;
                end else if (b_nan) begin
                    result_f = fa;
                end else begin
                    if (rm[0] == 0) begin
                        // FMIN
                        if (a_zero && b_zero)
                            result_f = sa ? fa : fb;
                        else
                            result_f = a_lt_b ? fa : fb;
                    end else begin
                        // FMAX
                        if (a_zero && b_zero)
                            result_f = !sa ? fa : fb;
                        else
                            result_f = a_lt_b ? fb : fa;
                    end
                end
            end

            FPU_CMP: begin
                case (rm)
                    3'b010: begin  // FEQ
                        result_i  = {{(XLEN-1){1'b0}}, a_eq_b};
                        fflags[4] = a_snan | b_snan;
                    end
                    3'b001: begin  // FLT
                        result_i  = {{(XLEN-1){1'b0}}, a_lt_b};
                        fflags[4] = a_nan | b_nan;
                    end
                    3'b000: begin  // FLE
                        result_i  = {{(XLEN-1){1'b0}}, a_lt_b | a_eq_b};
                        fflags[4] = a_nan | b_nan;
                    end
                    default: result_i = '0;
                endcase
            end

            FPU_CLASS: begin
                result_i = {{(XLEN-10){1'b0}}, fclass_bits};
            end

            FPU_MVXW: begin
                result_i = {{(XLEN-32){fa[31]}}, fa};
            end

            FPU_MVWX: begin
                result_f = int_a[31:0];
            end

            FPU_CVTSW: begin
                result_f  = cvt_sw_result;
                fflags[0] = cvt_sw_nx;
            end

            FPU_CVTWS: begin
                result_i  = cvt_ws_result;
                fflags[4] = cvt_ws_nv;
                fflags[0] = cvt_ws_nx & !cvt_ws_nv;
            end

            default: ;
        endcase
    end

endmodule

`default_nettype wire
