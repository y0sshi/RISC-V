// =============================================================================
/// @file rv_fpu_misc_d.sv
/// @brief FPU Miscellaneous Double-Precision Operations (2-stage pipelined)
///
/// Implements (all D-extension):
///   FSGNJ.D / FSGNJN.D / FSGNJX.D
///   FMIN.D  / FMAX.D
///   FEQ.D   / FLT.D  / FLE.D
///   FCLASS.D
///   FMV.X.D  (RV64D: move 64-bit float bits to int reg)
///   FMV.D.X  (RV64D: move int reg bits to 64-bit float reg)
///   FCVT.W.D / FCVT.WU.D / FCVT.L.D / FCVT.LU.D  (double -> integer)
///   FCVT.D.W / FCVT.D.WU / FCVT.D.L / FCVT.D.LU  (integer -> double)
///   FCVT.S.D (double -> single, fpu_op=FPU_CVTSD)
///   FCVT.D.S (single -> double, fpu_op=FPU_CVTDS)
///
/// 50MHz step 9 (default-strategy timing closure): this unit used to be a single
/// combinational cloud (operand reg -> compute -> result reg in rv_fpu).  At
/// 50 MHz that single arc (worst = FCVT.D.W's LZC+barrel-shift driving the
/// result exponent, and FCVT.W.D's 117-bit barrel-shift driving the integer
/// result) was the default-strategy binding path (~20 ns, route ~66 %).  Split
/// it with ONE internal free-running pipeline register: stage 1 does the heavy
/// FCVT.D.W normalize/shift (and the cheap ops + FCVT.W.D special-case detect +
/// FCVT.S.D/D.S), stage 2 does FCVT.D.W rounding, the heavy FCVT.W.D
/// shift+round+sign, and the output mux.  Free-running is latency-neutral: the
/// op occupies EX for COMB_LAT busy cycles and rv_core captures the result on
/// the busy-falling cycle (T+3 for COMB_LAT=2); the original misc path had one
/// cycle of capture slack (result valid T+2, captured T+3), so the extra stage
/// consumes exactly that slack -- the registered result is now valid T+3,
/// captured T+3.  COMB_LAT is unchanged.  Bit-identical to the old combinational
/// version (validated by sim_fpu_d / compliance rv64ud+rv32ud).
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_fpu_misc_d
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    input  wire             clk,
    input  wire             rst_n,

    input  wire  [63:0]     fa,
    input  wire  [63:0]     fb,
    input  wire  [XLEN-1:0] int_a,

    input  wire fpu_op_t    fpu_op,
    input  wire  [2:0]      rm,
    input  wire  [4:0]      rs2_sel,

    output logic [63:0]     result_f,
    output logic [XLEN-1:0] result_i,
    output logic [4:0]      fflags
);

    localparam logic [63:0] CANONICAL_NAN_D = 64'h7FF8000000000000;
    localparam logic [31:0] CANONICAL_NAN_S = 32'h7FC00000;

    // =========================================================================
    // Combinational classification of fa / fb (feeds stage-1 cheap ops and the
    // FCVT special-case detection).
    // =========================================================================
    logic         sa, sb;
    logic [10:0]  ea, eb;
    logic [51:0]  frac_a, frac_b;

    assign sa     = fa[63];
    assign ea     = fa[62:52];
    assign frac_a = fa[51:0];
    assign sb     = fb[63];
    assign eb     = fb[62:52];
    assign frac_b = fb[51:0];

    logic a_nan, b_nan, a_snan, b_snan, a_qnan, b_qnan;
    logic a_inf, b_inf, a_zero, b_zero, a_sub, b_sub;

    assign a_nan  = (ea == 11'h7FF) && (frac_a != 0);
    assign b_nan  = (eb == 11'h7FF) && (frac_b != 0);
    assign a_snan = a_nan && !frac_a[51];
    assign b_snan = b_nan && !frac_b[51];
    assign a_qnan = a_nan &&  frac_a[51];
    assign b_qnan = b_nan &&  frac_b[51];
    assign a_inf  = (ea == 11'h7FF) && (frac_a == 0);
    assign b_inf  = (eb == 11'h7FF) && (frac_b == 0);
    assign a_zero = (ea == 0) && (frac_a == 0);
    assign b_zero = (eb == 0) && (frac_b == 0);
    assign a_sub  = (ea == 0) && (frac_a != 0);
    assign b_sub  = (eb == 0) && (frac_b != 0);

    // FCLASS.D
    logic [9:0] fclass_bits;
    always @(*) begin
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

    // Comparison helpers
    logic a_lt_b, a_eq_b;
    always @(*) begin
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

    // =========================================================================
    // STAGE 1 (combinational): cheap ops + FCVT.D.W normalize/shift +
    // FCVT.W.D special-case detect + FCVT.S.D + FCVT.D.S.  Outputs are latched
    // into the s1_* pipeline registers below.
    // =========================================================================

    // ---- Cheap ops (results fed straight to the stage-2 output mux) ----
    logic [63:0]     s1_sgnj_result_n;
    logic [63:0]     s1_minmax_result_n;
    logic            s1_minmax_nv_n;          // fflags[4] for FMINMAX
    logic [XLEN-1:0] s1_cmp_result_i_n;
    logic            s1_cmp_nv_n;             // fflags[4] for FCMP
    logic [XLEN-1:0] s1_class_result_i_n;
    logic [XLEN-1:0] s1_mvxw_result_i_n;
    logic [63:0]     s1_mvwx_result_f_n;

    always @(*) begin
        // FSGNJ.D family
        case (rm)
            3'b000: s1_sgnj_result_n = {sb,      fa[62:0]};
            3'b001: s1_sgnj_result_n = {!sb,     fa[62:0]};
            3'b010: s1_sgnj_result_n = {sa ^ sb, fa[62:0]};
            default: s1_sgnj_result_n = fa;
        endcase

        // FMIN.D / FMAX.D
        s1_minmax_nv_n     = a_snan | b_snan;
        if (a_nan && b_nan) begin
            s1_minmax_result_n = CANONICAL_NAN_D;
        end else if (a_nan) begin
            s1_minmax_result_n = fb;
        end else if (b_nan) begin
            s1_minmax_result_n = fa;
        end else begin
            if (rm[0] == 0) begin
                if (a_zero && b_zero)
                    s1_minmax_result_n = sa ? fa : fb;
                else
                    s1_minmax_result_n = a_lt_b ? fa : fb;
            end else begin
                if (a_zero && b_zero)
                    s1_minmax_result_n = !sa ? fa : fb;
                else
                    s1_minmax_result_n = a_lt_b ? fb : fa;
            end
        end

        // FEQ.D / FLT.D / FLE.D
        s1_cmp_result_i_n = '0;
        s1_cmp_nv_n       = 1'b0;
        case (rm)
            3'b010: begin
                s1_cmp_result_i_n = {{(XLEN-1){1'b0}}, a_eq_b};
                s1_cmp_nv_n       = a_snan | b_snan;
            end
            3'b001: begin
                s1_cmp_result_i_n = {{(XLEN-1){1'b0}}, a_lt_b};
                s1_cmp_nv_n       = a_nan | b_nan;
            end
            3'b000: begin
                s1_cmp_result_i_n = {{(XLEN-1){1'b0}}, a_lt_b | a_eq_b};
                s1_cmp_nv_n       = a_nan | b_nan;
            end
            default: s1_cmp_result_i_n = '0;
        endcase

        // FCLASS.D
        s1_class_result_i_n = {{(XLEN-10){1'b0}}, fclass_bits};

        // FMV.X.D : raw 64-bit float bits -> int reg
        s1_mvxw_result_i_n = fa[XLEN-1:0];

        // FMV.D.X : int reg bits -> 64-bit float reg
        s1_mvwx_result_f_n = {{(64-XLEN){1'b0}}, int_a};
    end

    // -------------------------------------------------------------------------
    // FCVT.D.W/WU/L/LU: integer -> double  (STAGE-1 half: sign/mag + LZC +
    // barrel shift + G/R/S extraction; rounding deferred to stage 2)
    // -------------------------------------------------------------------------
    logic        cvt_dw_sign;
    logic [64:0] cvt_dw_mag;
    logic        s1_dw_mag_zero_n;
    logic        s1_dw_sign_n;
    logic [10:0] s1_dw_biased_exp_n;
    logic [51:0] s1_dw_mant_frac_n;
    logic        s1_dw_G_n, s1_dw_R_n, s1_dw_S_n;

    logic [5:0]  cdw_lz;
    logic [63:0] cdw_shifted_mag;

    always @(*) begin
        cvt_dw_sign        = 1'b0;
        s1_dw_mag_zero_n   = 1'b0;
        s1_dw_sign_n       = 1'b0;
        s1_dw_biased_exp_n = 11'd0;
        s1_dw_mant_frac_n  = 52'h0;
        s1_dw_G_n          = 1'b0;
        s1_dw_R_n          = 1'b0;
        s1_dw_S_n          = 1'b0;
        cdw_lz             = 6'd0;
        cdw_shifted_mag    = 64'h0;

        if (rs2_sel[1]) begin
            if (rs2_sel[0]) begin
                cvt_dw_sign = 1'b0;
                cvt_dw_mag  = {1'b0, int_a[63:0]};
            end else begin
                cvt_dw_sign = int_a[63];
                cvt_dw_mag  = cvt_dw_sign ? {1'b0, ~int_a[63:0] + 64'd1}
                                           : {1'b0, int_a[63:0]};
            end
        end else begin
            if (rs2_sel[0]) begin
                cvt_dw_sign = 1'b0;
                cvt_dw_mag  = {33'h0, int_a[31:0]};
            end else begin
                cvt_dw_sign = int_a[31];
                cvt_dw_mag  = cvt_dw_sign ? {33'h0, ~int_a[31:0] + 32'd1}
                                           : {33'h0, int_a[31:0]};
            end
        end

        s1_dw_sign_n = cvt_dw_sign;

        if (cvt_dw_mag == 0) begin
            s1_dw_mag_zero_n = 1'b1;
        end else begin
            if      (cvt_dw_mag[63]) cdw_lz = 6'd0;
            else if (cvt_dw_mag[62]) cdw_lz = 6'd1;
            else if (cvt_dw_mag[61]) cdw_lz = 6'd2;
            else if (cvt_dw_mag[60]) cdw_lz = 6'd3;
            else if (cvt_dw_mag[59]) cdw_lz = 6'd4;
            else if (cvt_dw_mag[58]) cdw_lz = 6'd5;
            else if (cvt_dw_mag[57]) cdw_lz = 6'd6;
            else if (cvt_dw_mag[56]) cdw_lz = 6'd7;
            else if (cvt_dw_mag[55]) cdw_lz = 6'd8;
            else if (cvt_dw_mag[54]) cdw_lz = 6'd9;
            else if (cvt_dw_mag[53]) cdw_lz = 6'd10;
            else if (cvt_dw_mag[52]) cdw_lz = 6'd11;
            else if (cvt_dw_mag[51]) cdw_lz = 6'd12;
            else if (cvt_dw_mag[50]) cdw_lz = 6'd13;
            else if (cvt_dw_mag[49]) cdw_lz = 6'd14;
            else if (cvt_dw_mag[48]) cdw_lz = 6'd15;
            else if (cvt_dw_mag[47]) cdw_lz = 6'd16;
            else if (cvt_dw_mag[46]) cdw_lz = 6'd17;
            else if (cvt_dw_mag[45]) cdw_lz = 6'd18;
            else if (cvt_dw_mag[44]) cdw_lz = 6'd19;
            else if (cvt_dw_mag[43]) cdw_lz = 6'd20;
            else if (cvt_dw_mag[42]) cdw_lz = 6'd21;
            else if (cvt_dw_mag[41]) cdw_lz = 6'd22;
            else if (cvt_dw_mag[40]) cdw_lz = 6'd23;
            else if (cvt_dw_mag[39]) cdw_lz = 6'd24;
            else if (cvt_dw_mag[38]) cdw_lz = 6'd25;
            else if (cvt_dw_mag[37]) cdw_lz = 6'd26;
            else if (cvt_dw_mag[36]) cdw_lz = 6'd27;
            else if (cvt_dw_mag[35]) cdw_lz = 6'd28;
            else if (cvt_dw_mag[34]) cdw_lz = 6'd29;
            else if (cvt_dw_mag[33]) cdw_lz = 6'd30;
            else if (cvt_dw_mag[32]) cdw_lz = 6'd31;
            else if (cvt_dw_mag[31]) cdw_lz = 6'd32;
            else if (cvt_dw_mag[30]) cdw_lz = 6'd33;
            else if (cvt_dw_mag[29]) cdw_lz = 6'd34;
            else if (cvt_dw_mag[28]) cdw_lz = 6'd35;
            else if (cvt_dw_mag[27]) cdw_lz = 6'd36;
            else if (cvt_dw_mag[26]) cdw_lz = 6'd37;
            else if (cvt_dw_mag[25]) cdw_lz = 6'd38;
            else if (cvt_dw_mag[24]) cdw_lz = 6'd39;
            else if (cvt_dw_mag[23]) cdw_lz = 6'd40;
            else if (cvt_dw_mag[22]) cdw_lz = 6'd41;
            else if (cvt_dw_mag[21]) cdw_lz = 6'd42;
            else if (cvt_dw_mag[20]) cdw_lz = 6'd43;
            else if (cvt_dw_mag[19]) cdw_lz = 6'd44;
            else if (cvt_dw_mag[18]) cdw_lz = 6'd45;
            else if (cvt_dw_mag[17]) cdw_lz = 6'd46;
            else if (cvt_dw_mag[16]) cdw_lz = 6'd47;
            else if (cvt_dw_mag[15]) cdw_lz = 6'd48;
            else if (cvt_dw_mag[14]) cdw_lz = 6'd49;
            else if (cvt_dw_mag[13]) cdw_lz = 6'd50;
            else if (cvt_dw_mag[12]) cdw_lz = 6'd51;
            else if (cvt_dw_mag[11]) cdw_lz = 6'd52;
            else if (cvt_dw_mag[10]) cdw_lz = 6'd53;
            else if (cvt_dw_mag[9])  cdw_lz = 6'd54;
            else if (cvt_dw_mag[8])  cdw_lz = 6'd55;
            else if (cvt_dw_mag[7])  cdw_lz = 6'd56;
            else if (cvt_dw_mag[6])  cdw_lz = 6'd57;
            else if (cvt_dw_mag[5])  cdw_lz = 6'd58;
            else if (cvt_dw_mag[4])  cdw_lz = 6'd59;
            else if (cvt_dw_mag[3])  cdw_lz = 6'd60;
            else if (cvt_dw_mag[2])  cdw_lz = 6'd61;
            else if (cvt_dw_mag[1])  cdw_lz = 6'd62;
            else                     cdw_lz = 6'd63;

            // biased_exp = 1023 + 63 - cdw_lz
            s1_dw_biased_exp_n = 11'd1023 + 11'd63 - {5'b0, cdw_lz};
            cdw_shifted_mag    = cvt_dw_mag[63:0] << ({1'b0, cdw_lz} + 7'd1);
            s1_dw_mant_frac_n  = cdw_shifted_mag[63:12];
            s1_dw_G_n          = cdw_shifted_mag[11];
            s1_dw_R_n          = cdw_shifted_mag[10];
            s1_dw_S_n          = |cdw_shifted_mag[9:0];
        end
    end

    // -------------------------------------------------------------------------
    // FCVT.W.D/WU/L/LU: double -> integer (STAGE-1 half: special-case detect +
    // special results; the in-range "normal" shift+round+sign is in stage 2)
    // -------------------------------------------------------------------------
    logic                s1_wd_special_n;
    logic [XLEN-1:0]     s1_wd_special_result_n;
    logic                s1_wd_special_nv_n;
    logic                s1_wd_special_nx_n;
    logic signed [11:0]  wd_exp_unbiased;     // local
    logic signed [11:0]  s1_wd_exp_n;
    logic [51:0]         s1_wd_frac_n;
    logic                s1_wd_sa_n;

    always @(*) begin
        s1_wd_special_n        = 1'b1;   // assume special; cleared on the in-range paths
        s1_wd_special_result_n = '0;
        s1_wd_special_nv_n     = 1'b0;
        s1_wd_special_nx_n     = 1'b0;
        wd_exp_unbiased        = 12'sd0;
        s1_wd_frac_n           = frac_a;
        s1_wd_sa_n             = sa;

        if (a_nan) begin
            s1_wd_special_result_n = !rs2_sel[0]
                ? (!rs2_sel[1] ? {{(XLEN-32){1'b0}}, 32'h7FFFFFFF}
                               : {1'b0, {(XLEN-1){1'b1}}})
                : {XLEN{1'b1}};
            s1_wd_special_nv_n = 1'b1;

        end else if (a_inf) begin
            if (!rs2_sel[0]) begin
                s1_wd_special_result_n = sa
                    ? (!rs2_sel[1] ? {{(XLEN-32){1'b1}}, 32'h80000000}
                                   : {1'b1, {(XLEN-1){1'b0}}})
                    : (!rs2_sel[1] ? {{(XLEN-32){1'b0}}, 32'h7FFFFFFF}
                                   : {1'b0, {(XLEN-1){1'b1}}});
            end else begin
                s1_wd_special_result_n = sa ? '0 : {XLEN{1'b1}};
            end
            s1_wd_special_nv_n = 1'b1;

        end else if (a_zero) begin
            s1_wd_special_result_n = '0;

        end else begin
            wd_exp_unbiased = $signed({1'b0, ea}) - 12'sd1023;

            if (wd_exp_unbiased < 0) begin
                s1_wd_special_result_n = '0;
                s1_wd_special_nx_n     = 1'b1;

            end else if (!rs2_sel[0]) begin
                // Signed path
                if ((!rs2_sel[1] && wd_exp_unbiased >= 12'sd31) ||
                    ( rs2_sel[1] && wd_exp_unbiased >= 12'sd63)) begin
                    s1_wd_special_result_n = sa
                        ? (!rs2_sel[1] ? {{(XLEN-32){1'b1}}, 32'h80000000}
                                       : {1'b1, {(XLEN-1){1'b0}}})
                        : (!rs2_sel[1] ? {{(XLEN-32){1'b0}}, 32'h7FFFFFFF}
                                       : {1'b0, {(XLEN-1){1'b1}}});
                    s1_wd_special_nv_n = 1'b1;
                end else begin
                    s1_wd_special_n = 1'b0;   // in-range signed -> normal (stage 2)
                end

            end else begin
                // Unsigned path
                if (sa) begin
                    s1_wd_special_result_n = '0;
                    s1_wd_special_nv_n     = 1'b1;
                end else if ((!rs2_sel[1] && wd_exp_unbiased >= 12'sd32) ||
                             ( rs2_sel[1] && wd_exp_unbiased >= 12'sd64)) begin
                    s1_wd_special_result_n = {XLEN{1'b1}};
                    s1_wd_special_nv_n     = 1'b1;
                end else begin
                    s1_wd_special_n = 1'b0;   // in-range unsigned -> normal (stage 2)
                end
            end
        end
        s1_wd_exp_n = wd_exp_unbiased;
    end

    // -------------------------------------------------------------------------
    // FCVT.S.D: double -> single (STAGE-1; result registered directly)
    // -------------------------------------------------------------------------
    logic [31:0] cvt_sd_result;
    logic [4:0]  cvt_sd_fflags;
    logic [22:0] cvt_sd_frac;
    logic        cvt_sd_G, cvt_sd_R, cvt_sd_S, cvt_sd_rup;
    logic [23:0] cvt_sd_mant_r;
    logic signed [11:0] cvt_sd_exp_biased_s;
    logic [52:0]  sd_mant_full;
    logic [10:0]  sd_rshift;
    logic [105:0] sd_wide, sd_shifted;

    always @(*) begin
        cvt_sd_result   = 32'h0;
        cvt_sd_fflags   = 5'h0;
        cvt_sd_frac     = 23'h0;
        cvt_sd_G        = 1'b0;
        cvt_sd_R        = 1'b0;
        cvt_sd_S        = 1'b0;
        cvt_sd_rup      = 1'b0;
        cvt_sd_mant_r   = 24'h0;
        sd_mant_full    = 53'h0;
        sd_rshift       = 11'h0;
        sd_wide         = 106'h0;
        sd_shifted      = 106'h0;
        cvt_sd_exp_biased_s = 12'sd0;

        if (a_nan) begin
            cvt_sd_result    = CANONICAL_NAN_S;
            cvt_sd_fflags[4] = a_snan;
        end else if (a_inf) begin
            cvt_sd_result = {sa, 8'hFF, 23'h0};
        end else if (a_zero) begin
            cvt_sd_result = {sa, 31'h0};
        end else begin
            cvt_sd_exp_biased_s = $signed({1'b0, ea}) - 12'sd1023 + 12'sd127;

            if (cvt_sd_exp_biased_s >= 12'sd255) begin
                cvt_sd_fflags[2] = 1'b1;
                cvt_sd_fflags[0] = 1'b1;
                case (rm)
                    3'b001: cvt_sd_result = {sa, 8'hFE, 23'h7FFFFF};
                    3'b010: cvt_sd_result = sa ? {1'b1,8'hFF,23'h0} : {1'b0,8'hFE,23'h7FFFFF};
                    3'b011: cvt_sd_result = sa ? {1'b1,8'hFE,23'h7FFFFF} : {1'b0,8'hFF,23'h0};
                    default: cvt_sd_result = {sa, 8'hFF, 23'h0};
                endcase
            end else if (cvt_sd_exp_biased_s <= 12'sd0) begin
                sd_mant_full = {1'b1, frac_a};
                sd_rshift    = 11'd926 - ea;
                sd_wide      = {sd_mant_full, 53'h0};
                sd_shifted   = (sd_rshift < 11'd106) ? (sd_wide >> sd_rshift) : 106'h0;
                cvt_sd_frac  = sd_shifted[75:53];
                cvt_sd_G     = sd_shifted[52];
                cvt_sd_R     = sd_shifted[51];
                cvt_sd_S     = |sd_shifted[50:0];

                case (rm)
                    3'b000: cvt_sd_rup = cvt_sd_G & (cvt_sd_R | cvt_sd_S | cvt_sd_frac[0]);
                    3'b001: cvt_sd_rup = 1'b0;
                    3'b010: cvt_sd_rup = (cvt_sd_G | cvt_sd_R | cvt_sd_S) & sa;
                    3'b011: cvt_sd_rup = (cvt_sd_G | cvt_sd_R | cvt_sd_S) & !sa;
                    3'b100: cvt_sd_rup = cvt_sd_G;
                    default: cvt_sd_rup = 1'b0;
                endcase

                cvt_sd_mant_r = {1'b0, cvt_sd_frac} + {23'h0, cvt_sd_rup};
                if (cvt_sd_mant_r[23])
                    cvt_sd_result = {sa, 8'h01, cvt_sd_mant_r[22:0]};
                else
                    cvt_sd_result = {sa, 8'h00, cvt_sd_mant_r[22:0]};

                cvt_sd_fflags[1] = cvt_sd_G | cvt_sd_R | cvt_sd_S;  // UF
                cvt_sd_fflags[0] = cvt_sd_G | cvt_sd_R | cvt_sd_S;  // NX
            end else begin
                cvt_sd_frac  = frac_a[51:29];
                cvt_sd_G     = frac_a[28];
                cvt_sd_R     = frac_a[27];
                cvt_sd_S     = |frac_a[26:0];

                case (rm)
                    3'b000: cvt_sd_rup = cvt_sd_G & (cvt_sd_R | cvt_sd_S | cvt_sd_frac[0]);
                    3'b001: cvt_sd_rup = 1'b0;
                    3'b010: cvt_sd_rup = (cvt_sd_G | cvt_sd_R | cvt_sd_S) & sa;
                    3'b011: cvt_sd_rup = (cvt_sd_G | cvt_sd_R | cvt_sd_S) & !sa;
                    3'b100: cvt_sd_rup = cvt_sd_G;
                    default: cvt_sd_rup = 1'b0;
                endcase

                cvt_sd_mant_r = {1'b0, cvt_sd_frac} + {23'h0, cvt_sd_rup};
                if (cvt_sd_mant_r[23]) begin
                    cvt_sd_result = {sa, cvt_sd_exp_biased_s[7:0] + 8'd1, cvt_sd_mant_r[22:0]};
                end else begin
                    cvt_sd_result = {sa, cvt_sd_exp_biased_s[7:0], cvt_sd_mant_r[22:0]};
                end
                cvt_sd_fflags[0] = cvt_sd_G | cvt_sd_R | cvt_sd_S;
            end
        end
    end

    // -------------------------------------------------------------------------
    // FCVT.D.S: single -> double (STAGE-1; result registered directly)
    // Input is in fa[31:0] (lower 32 bits, NaN-boxed)
    // -------------------------------------------------------------------------
    logic [63:0] cvt_ds_result;

    logic        ds_s;
    logic [7:0]  ds_e;
    logic [22:0] ds_f;
    logic        ds_nan, ds_snan, ds_inf, ds_zero, ds_sub;

    assign ds_s   = fa[31];
    assign ds_e   = fa[30:23];
    assign ds_f   = fa[22:0];
    assign ds_nan = (ds_e == 8'hFF) && (ds_f != 0);
    assign ds_snan= ds_nan && !ds_f[22];
    assign ds_inf = (ds_e == 8'hFF) && (ds_f == 0);
    assign ds_zero= (ds_e == 0) && (ds_f == 0);
    assign ds_sub = (ds_e == 0) && (ds_f != 0);

    always @(*) begin
        cvt_ds_result = 64'h0;

        if (ds_nan) begin
            cvt_ds_result    = CANONICAL_NAN_D;
        end else if (ds_inf) begin
            cvt_ds_result = {ds_s, 11'h7FF, 52'h0};
        end else if (ds_zero) begin
            cvt_ds_result = {ds_s, 63'h0};
        end else if (ds_sub) begin
            logic [4:0]  ds_lz;
            logic [22:0] ds_norm_f;
            logic [10:0] ds_exp_d;

            ds_lz = 5'd23;
            for (int i = 0; i <= 22; i++)
                if (ds_f[i]) ds_lz = 5'(22 - i);

            ds_norm_f = ds_f << (ds_lz + 5'd1);
            ds_exp_d  = 11'd897 - {6'd0, ds_lz};
            cvt_ds_result = {ds_s, ds_exp_d, ds_norm_f, 29'h0};
        end else begin
            logic [10:0] ds_exp_d_n;
            ds_exp_d_n    = {3'b0, ds_e} + 11'd896;
            cvt_ds_result = {ds_s, ds_exp_d_n, ds_f, 29'h0};
        end
    end

    // =========================================================================
    // Pipeline register (stage 1 -> stage 2).  Free-running; rv_fpu's
    // combinational-op handshake captures the stage-2 result on the correct
    // cycle (stale fills on non-capture cycles are harmless).
    // =========================================================================
    fpu_op_t         s1_fpu_op;
    logic [2:0]      s1_rm;
    logic [4:0]      s1_rs2_sel;

    logic [63:0]     s1_sgnj_result, s1_minmax_result;
    logic            s1_minmax_nv;
    logic [XLEN-1:0] s1_cmp_result_i;
    logic            s1_cmp_nv;
    logic [XLEN-1:0] s1_class_result_i;
    logic [XLEN-1:0] s1_mvxw_result_i;
    logic [63:0]     s1_mvwx_result_f;

    logic            s1_dw_mag_zero, s1_dw_sign;
    logic [10:0]     s1_dw_biased_exp;
    logic [51:0]     s1_dw_mant_frac;
    logic            s1_dw_G, s1_dw_R, s1_dw_S;

    logic            s1_wd_special, s1_wd_special_nv, s1_wd_special_nx;
    logic [XLEN-1:0] s1_wd_special_result;
    logic signed [11:0] s1_wd_exp;
    logic [51:0]     s1_wd_frac;
    logic            s1_wd_sa;

    logic [31:0]     s1_sd_result;
    logic [4:0]      s1_sd_fflags;
    logic [63:0]     s1_ds_result;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_fpu_op            <= fpu_op_t'(0);
            s1_rm                <= 3'b0;
            s1_rs2_sel           <= 5'b0;
            s1_sgnj_result       <= '0;
            s1_minmax_result     <= '0;
            s1_minmax_nv         <= 1'b0;
            s1_cmp_result_i      <= '0;
            s1_cmp_nv            <= 1'b0;
            s1_class_result_i    <= '0;
            s1_mvxw_result_i     <= '0;
            s1_mvwx_result_f     <= '0;
            s1_dw_mag_zero       <= 1'b0;
            s1_dw_sign           <= 1'b0;
            s1_dw_biased_exp     <= 11'b0;
            s1_dw_mant_frac      <= 52'b0;
            s1_dw_G              <= 1'b0;
            s1_dw_R              <= 1'b0;
            s1_dw_S              <= 1'b0;
            s1_wd_special        <= 1'b0;
            s1_wd_special_nv     <= 1'b0;
            s1_wd_special_nx     <= 1'b0;
            s1_wd_special_result <= '0;
            s1_wd_exp            <= 12'sd0;
            s1_wd_frac           <= 52'b0;
            s1_wd_sa             <= 1'b0;
            s1_sd_result         <= 32'b0;
            s1_sd_fflags         <= 5'b0;
            s1_ds_result         <= 64'b0;
        end else begin
            s1_fpu_op            <= fpu_op;
            s1_rm                <= rm;
            s1_rs2_sel           <= rs2_sel;
            s1_sgnj_result       <= s1_sgnj_result_n;
            s1_minmax_result     <= s1_minmax_result_n;
            s1_minmax_nv         <= s1_minmax_nv_n;
            s1_cmp_result_i      <= s1_cmp_result_i_n;
            s1_cmp_nv            <= s1_cmp_nv_n;
            s1_class_result_i    <= s1_class_result_i_n;
            s1_mvxw_result_i     <= s1_mvxw_result_i_n;
            s1_mvwx_result_f     <= s1_mvwx_result_f_n;
            s1_dw_mag_zero       <= s1_dw_mag_zero_n;
            s1_dw_sign           <= s1_dw_sign_n;
            s1_dw_biased_exp     <= s1_dw_biased_exp_n;
            s1_dw_mant_frac      <= s1_dw_mant_frac_n;
            s1_dw_G              <= s1_dw_G_n;
            s1_dw_R              <= s1_dw_R_n;
            s1_dw_S              <= s1_dw_S_n;
            s1_wd_special        <= s1_wd_special_n;
            s1_wd_special_nv     <= s1_wd_special_nv_n;
            s1_wd_special_nx     <= s1_wd_special_nx_n;
            s1_wd_special_result <= s1_wd_special_result_n;
            s1_wd_exp            <= s1_wd_exp_n;
            s1_wd_frac           <= s1_wd_frac_n;
            s1_wd_sa             <= s1_wd_sa_n;
            s1_sd_result         <= cvt_sd_result;
            s1_sd_fflags         <= cvt_sd_fflags;
            s1_ds_result         <= cvt_ds_result;
        end
    end

    // =========================================================================
    // STAGE 2 (combinational from the registered s1_*): FCVT.D.W rounding,
    // FCVT.W.D normal shift+round+sign, and the final output mux.
    // =========================================================================

    // ---- FCVT.D.W stage-2: round + assemble ----
    logic        cdw_round_up;
    logic [52:0] cdw_mant_rounded;
    logic [10:0] cdw_biased_exp2;
    logic [63:0] cvt_dw_result;
    logic        cvt_dw_nx;

    always @(*) begin
        cdw_round_up     = 1'b0;
        cdw_mant_rounded = 53'h0;
        cdw_biased_exp2  = s1_dw_biased_exp;
        cvt_dw_result    = 64'h0;
        cvt_dw_nx        = 1'b0;

        if (s1_dw_mag_zero) begin
            cvt_dw_result = {s1_dw_sign, 63'h0};
        end else begin
            case (s1_rm)
                3'b000: cdw_round_up = s1_dw_G & (s1_dw_R | s1_dw_S | s1_dw_mant_frac[0]);
                3'b001: cdw_round_up = 1'b0;
                3'b010: cdw_round_up = (s1_dw_G | s1_dw_R | s1_dw_S) & s1_dw_sign;
                3'b011: cdw_round_up = (s1_dw_G | s1_dw_R | s1_dw_S) & !s1_dw_sign;
                3'b100: cdw_round_up = s1_dw_G;
                default: cdw_round_up = 1'b0;
            endcase

            cdw_mant_rounded = {1'b0, s1_dw_mant_frac} + {52'h0, cdw_round_up};
            if (cdw_mant_rounded[52]) cdw_biased_exp2 = s1_dw_biased_exp + 11'd1;

            cvt_dw_result = {s1_dw_sign, cdw_biased_exp2, cdw_mant_rounded[51:0]};
            cvt_dw_nx     = s1_dw_G | s1_dw_R | s1_dw_S;
        end
    end

    // ---- FCVT.W.D stage-2: normal shift+round+sign (special handled below) ----
    logic [XLEN-1:0] cvt_wd_result;
    logic            cvt_wd_nv, cvt_wd_nx;
    logic [116:0]    cwd_sig117;
    logic [63:0]     cwd_uint64;

    always @(*) begin
        cvt_wd_result = '0;
        cvt_wd_nv     = 1'b0;
        cvt_wd_nx     = 1'b0;
        cwd_sig117    = 117'h0;
        cwd_uint64    = 64'h0;

        if (s1_wd_special) begin
            cvt_wd_result = s1_wd_special_result;
            cvt_wd_nv     = s1_wd_special_nv;
            cvt_wd_nx     = s1_wd_special_nx;
        end else begin
            // In-range normal: {1'b1, frac_a, 64'h0} >> (63 - exp_unbiased)
            cwd_sig117 = {1'b1, s1_wd_frac, 64'h0} >> (12'sd63 - s1_wd_exp);
            cwd_uint64 = cwd_sig117[116:53];
            cvt_wd_nx  = |cwd_sig117[52:0];

            if (!s1_rs2_sel[0]) begin
                // Signed
                if (cvt_wd_nx) begin
                    case (s1_rm)
                        3'b001: ;
                        3'b010: if (s1_wd_sa) cwd_uint64 = cwd_uint64 + 1;
                        3'b011: if (!s1_wd_sa) cwd_uint64 = cwd_uint64 + 1;
                        3'b000: begin
                            if (cwd_sig117[52] && (|cwd_sig117[51:0] || cwd_uint64[0]))
                                cwd_uint64 = cwd_uint64 + 1;
                        end
                        3'b100: begin
                            if (cwd_sig117[52]) cwd_uint64 = cwd_uint64 + 1;
                        end
                        default: ;
                    endcase
                end
                if (s1_wd_sa) begin
                    if (!s1_rs2_sel[1]) begin
                        cvt_wd_result = {{(XLEN-32){1'b1}}, ~cwd_uint64[31:0] + 32'd1};
                        if (cwd_uint64[31:0] > 32'h80000000) begin
                            cvt_wd_result = {{(XLEN-32){1'b1}}, 32'h80000000};
                            cvt_wd_nv     = 1'b1;
                        end
                    end else begin
                        cvt_wd_result = ~cwd_uint64 + 64'd1;
                        if (cwd_uint64 > 64'h8000000000000000) begin
                            cvt_wd_result = {1'b1, {(XLEN-1){1'b0}}};
                            cvt_wd_nv     = 1'b1;
                        end
                    end
                end else begin
                    if (!s1_rs2_sel[1]) begin
                        cvt_wd_result = {{(XLEN-32){1'b0}}, cwd_uint64[31:0]};
                        if (cwd_uint64[31:0] >= 32'h80000000) begin
                            cvt_wd_result = {{(XLEN-32){1'b0}}, 32'h7FFFFFFF};
                            cvt_wd_nv     = 1'b1;
                        end
                    end else begin
                        cvt_wd_result = cwd_uint64;
                        if (cwd_uint64 >= 64'h8000000000000000) begin
                            cvt_wd_result = {1'b0, {(XLEN-1){1'b1}}};
                            cvt_wd_nv     = 1'b1;
                        end
                    end
                end

            end else begin
                // Unsigned (sa==0 guaranteed: sa case is special)
                if (cvt_wd_nx) begin
                    case (s1_rm)
                        3'b001: ;
                        3'b010: ;
                        3'b011: cwd_uint64 = cwd_uint64 + 1;
                        3'b000: begin
                            if (cwd_sig117[52] && (|cwd_sig117[51:0] || cwd_uint64[0]))
                                cwd_uint64 = cwd_uint64 + 1;
                        end
                        3'b100: begin
                            if (cwd_sig117[52]) cwd_uint64 = cwd_uint64 + 1;
                        end
                        default: ;
                    endcase
                end
                if (!s1_rs2_sel[1]) begin
                    cvt_wd_result = {{(XLEN-32){cwd_uint64[31]}}, cwd_uint64[31:0]};
                end else begin
                    cvt_wd_result = cwd_uint64;
                end
            end
        end
    end

    // ---- Final output mux (selects on the registered fpu_op) ----
    always @(*) begin
        result_f = 64'h0;
        result_i = '0;
        fflags   = 5'h0;

        case (s1_fpu_op)
            FPU_SGNJ: begin
                result_f = s1_sgnj_result;
            end

            FPU_MINMAX: begin
                result_f  = s1_minmax_result;
                fflags[4] = s1_minmax_nv;
            end

            FPU_CMP: begin
                result_i  = s1_cmp_result_i;
                fflags[4] = s1_cmp_nv;
            end

            FPU_CLASS: begin
                result_i = s1_class_result_i;
            end

            FPU_MVXW: begin
                result_i = s1_mvxw_result_i;
            end

            FPU_MVWX: begin
                result_f = s1_mvwx_result_f;
            end

            FPU_CVTSW: begin
                // FCVT.D.W/WU/L/LU: integer -> double
                result_f  = cvt_dw_result;
                fflags[0] = cvt_dw_nx;
            end

            FPU_CVTWS: begin
                // FCVT.W.D/WU.D/L.D/LU.D: double -> integer
                result_i  = cvt_wd_result;
                fflags[4] = cvt_wd_nv;
                fflags[0] = cvt_wd_nx & !cvt_wd_nv;
            end

            FPU_CVTSD: begin
                // FCVT.S.D: double -> single
                result_f  = {32'hFFFFFFFF, s1_sd_result};  // NaN-box result
                fflags    = s1_sd_fflags;
            end

            FPU_CVTDS: begin
                // FCVT.D.S: single -> double
                result_f  = s1_ds_result;
                fflags    = 5'h0;
            end

            default: ;
        endcase
    end

endmodule

`default_nettype wire
