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
    input  wire  [31:0]     fa,
    input  wire  [31:0]     fb,
    input  wire  [XLEN-1:0] int_a,

    input  wire fpu_op_t    fpu_op,
    input  wire  [2:0]      rm,
    input  wire  [4:0]      rs2_sel,

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
    // FCVT.S.W / FCVT.S.WU / FCVT.S.L / FCVT.S.LU  (integer -> float)
    // rs2_sel[0]: 0=signed, 1=unsigned
    // rs2_sel[1]: 0=32-bit W/WU, 1=64-bit L/LU
    // Uses unified 64-bit magnitude path; W/WU zero-extend to 64 bits.
    // biased_exp = 127 + 63 - csw_lz (same formula for both widths since
    // W/WU have zeros in the upper 32 bits, making csw_lz >= 32).
    // All intermediates at module level (shared across the comb blocks below).
    // -------------------------------------------------------------------------
    logic        cvt_sw_sign;
    logic [64:0] cvt_sw_mag;
    logic [31:0] cvt_sw_result;
    logic        cvt_sw_nx;
    logic [5:0]  csw_lz;
    logic [7:0]  csw_biased_exp;
    logic [63:0] csw_shifted_mag;
    logic [22:0] csw_mant_frac;
    logic        csw_G, csw_R, csw_S;
    logic        csw_round_up;
    logic [23:0] csw_mant_rounded;

    always_comb begin
        cvt_sw_result    = 32'h0;
        cvt_sw_nx        = 1'b0;
        csw_lz           = 6'd0;
        csw_biased_exp   = 8'd0;
        csw_shifted_mag  = 64'h0;
        csw_mant_frac    = 23'h0;
        csw_G            = 1'b0;
        csw_R            = 1'b0;
        csw_S            = 1'b0;
        csw_round_up     = 1'b0;
        csw_mant_rounded = 24'h0;

        if (rs2_sel[1]) begin
            // L / LU: use full 64-bit integer
            if (rs2_sel[0]) begin
                cvt_sw_sign = 1'b0;
                cvt_sw_mag  = {1'b0, int_a[63:0]};
            end else begin
                cvt_sw_sign = int_a[63];
                cvt_sw_mag  = cvt_sw_sign ? {1'b0, ~int_a[63:0] + 64'd1}
                                          : {1'b0, int_a[63:0]};
            end
        end else begin
            // W / WU: use lower 32 bits, zero-extend to 64 bits for uniform path
            if (rs2_sel[0]) begin
                cvt_sw_sign = 1'b0;
                cvt_sw_mag  = {33'h0, int_a[31:0]};
            end else begin
                cvt_sw_sign = int_a[31];
                cvt_sw_mag  = cvt_sw_sign ? {33'h0, ~int_a[31:0] + 32'd1}
                                          : {33'h0, int_a[31:0]};
            end
        end

        if (cvt_sw_mag == 0) begin
            cvt_sw_result = {cvt_sw_sign, 31'h0};
        end else begin
            // Priority-encode leading 1 in cvt_sw_mag[63:0]
            if      (cvt_sw_mag[63]) csw_lz = 6'd0;
            else if (cvt_sw_mag[62]) csw_lz = 6'd1;
            else if (cvt_sw_mag[61]) csw_lz = 6'd2;
            else if (cvt_sw_mag[60]) csw_lz = 6'd3;
            else if (cvt_sw_mag[59]) csw_lz = 6'd4;
            else if (cvt_sw_mag[58]) csw_lz = 6'd5;
            else if (cvt_sw_mag[57]) csw_lz = 6'd6;
            else if (cvt_sw_mag[56]) csw_lz = 6'd7;
            else if (cvt_sw_mag[55]) csw_lz = 6'd8;
            else if (cvt_sw_mag[54]) csw_lz = 6'd9;
            else if (cvt_sw_mag[53]) csw_lz = 6'd10;
            else if (cvt_sw_mag[52]) csw_lz = 6'd11;
            else if (cvt_sw_mag[51]) csw_lz = 6'd12;
            else if (cvt_sw_mag[50]) csw_lz = 6'd13;
            else if (cvt_sw_mag[49]) csw_lz = 6'd14;
            else if (cvt_sw_mag[48]) csw_lz = 6'd15;
            else if (cvt_sw_mag[47]) csw_lz = 6'd16;
            else if (cvt_sw_mag[46]) csw_lz = 6'd17;
            else if (cvt_sw_mag[45]) csw_lz = 6'd18;
            else if (cvt_sw_mag[44]) csw_lz = 6'd19;
            else if (cvt_sw_mag[43]) csw_lz = 6'd20;
            else if (cvt_sw_mag[42]) csw_lz = 6'd21;
            else if (cvt_sw_mag[41]) csw_lz = 6'd22;
            else if (cvt_sw_mag[40]) csw_lz = 6'd23;
            else if (cvt_sw_mag[39]) csw_lz = 6'd24;
            else if (cvt_sw_mag[38]) csw_lz = 6'd25;
            else if (cvt_sw_mag[37]) csw_lz = 6'd26;
            else if (cvt_sw_mag[36]) csw_lz = 6'd27;
            else if (cvt_sw_mag[35]) csw_lz = 6'd28;
            else if (cvt_sw_mag[34]) csw_lz = 6'd29;
            else if (cvt_sw_mag[33]) csw_lz = 6'd30;
            else if (cvt_sw_mag[32]) csw_lz = 6'd31;
            else if (cvt_sw_mag[31]) csw_lz = 6'd32;
            else if (cvt_sw_mag[30]) csw_lz = 6'd33;
            else if (cvt_sw_mag[29]) csw_lz = 6'd34;
            else if (cvt_sw_mag[28]) csw_lz = 6'd35;
            else if (cvt_sw_mag[27]) csw_lz = 6'd36;
            else if (cvt_sw_mag[26]) csw_lz = 6'd37;
            else if (cvt_sw_mag[25]) csw_lz = 6'd38;
            else if (cvt_sw_mag[24]) csw_lz = 6'd39;
            else if (cvt_sw_mag[23]) csw_lz = 6'd40;
            else if (cvt_sw_mag[22]) csw_lz = 6'd41;
            else if (cvt_sw_mag[21]) csw_lz = 6'd42;
            else if (cvt_sw_mag[20]) csw_lz = 6'd43;
            else if (cvt_sw_mag[19]) csw_lz = 6'd44;
            else if (cvt_sw_mag[18]) csw_lz = 6'd45;
            else if (cvt_sw_mag[17]) csw_lz = 6'd46;
            else if (cvt_sw_mag[16]) csw_lz = 6'd47;
            else if (cvt_sw_mag[15]) csw_lz = 6'd48;
            else if (cvt_sw_mag[14]) csw_lz = 6'd49;
            else if (cvt_sw_mag[13]) csw_lz = 6'd50;
            else if (cvt_sw_mag[12]) csw_lz = 6'd51;
            else if (cvt_sw_mag[11]) csw_lz = 6'd52;
            else if (cvt_sw_mag[10]) csw_lz = 6'd53;
            else if (cvt_sw_mag[9])  csw_lz = 6'd54;
            else if (cvt_sw_mag[8])  csw_lz = 6'd55;
            else if (cvt_sw_mag[7])  csw_lz = 6'd56;
            else if (cvt_sw_mag[6])  csw_lz = 6'd57;
            else if (cvt_sw_mag[5])  csw_lz = 6'd58;
            else if (cvt_sw_mag[4])  csw_lz = 6'd59;
            else if (cvt_sw_mag[3])  csw_lz = 6'd60;
            else if (cvt_sw_mag[2])  csw_lz = 6'd61;
            else if (cvt_sw_mag[1])  csw_lz = 6'd62;
            else                     csw_lz = 6'd63;

            // biased_exp = 127 + 63 - csw_lz
            // Works for W/WU too: W values have csw_lz in [32,63], giving exp = 127+63-32..63 = 158..127
            // which is exactly 127 + 31..0, matching the 32-bit formula 127+31-lz32.
            csw_biased_exp  = 8'd127 + 8'd63 - {2'b0, csw_lz};
            // Shift left by (csw_lz+1) to remove leading 1 and align mantissa at bit[63]
            // Use 7-bit shift amount to avoid 6-bit overflow when csw_lz=63
            csw_shifted_mag = cvt_sw_mag[63:0] << ({1'b0, csw_lz} + 7'd1);
            csw_mant_frac   = csw_shifted_mag[63:41];
            csw_G           = csw_shifted_mag[40];
            csw_R           = csw_shifted_mag[39];
            csw_S           = |csw_shifted_mag[38:0];

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
    // FCVT.W.S / FCVT.WU.S / FCVT.L.S / FCVT.LU.S  (float -> integer)
    // rs2_sel[0]: 0=signed, 1=unsigned
    // rs2_sel[1]: 0=32-bit W/WU, 1=64-bit L/LU
    //
    // Per RISC-V spec (RV64): FCVT.W.S and FCVT.WU.S sign-extend their 32-bit
    // result to XLEN bits (using bit[31] of the 32-bit result as the sign bit,
    // regardless of signed/unsigned semantics).
    //
    // Saturation values (sign-extended to XLEN):
    //   W  NaN/+inf/+overflow : {{XLEN-32{0}}, 32'h7FFF_FFFF} = 0x0000_0000_7FFF_FFFF
    //   W  -inf/-overflow     : {{XLEN-32{1}}, 32'h8000_0000} = 0xFFFF_FFFF_8000_0000
    //   WU NaN/+inf/+overflow : {XLEN{1}} (= UINT32_MAX sign-extended, all ones)
    //   WU negative           : 0
    //   L  NaN/+inf/+overflow : {0, {XLEN-1{1}}}
    //   L  -inf/-overflow     : {1, {XLEN-1{0}}}
    //   LU NaN/+inf/+overflow : {XLEN{1}}
    //   LU negative           : 0
    //
    // Normal-path integer is computed via 88-bit intermediate:
    //   {1'b1, frac_a, 64'h0} >> (63 - exp_unbiased)
    //   -> integer in bits[87:24], fraction (G/R/S) in bits[23:0]
    // -------------------------------------------------------------------------
    logic [XLEN-1:0] cvt_ws_result;
    logic            cvt_ws_nv, cvt_ws_nx;
    logic signed [8:0] cws_exp_unbiased;
    logic [87:0]       cws_sig88;
    logic [63:0]       cws_uint64;

    always_comb begin
        cvt_ws_result    = '0;
        cvt_ws_nv        = 1'b0;
        cvt_ws_nx        = 1'b0;
        cws_exp_unbiased = 9'd0;
        cws_sig88        = 88'h0;
        cws_uint64       = 64'h0;

        if (a_nan) begin
            // NaN: return saturated max for the type
            if (!rs2_sel[0]) begin
                // Signed: INT_MAX
                cvt_ws_result = !rs2_sel[1]
                    ? {{(XLEN-32){1'b0}}, 32'h7FFFFFFF}     // W
                    : {1'b0, {(XLEN-1){1'b1}}};              // L
            end else begin
                // Unsigned: UINT_MAX (sign-extended all-ones for WU)
                cvt_ws_result = {XLEN{1'b1}};
            end
            cvt_ws_nv = 1'b1;

        end else if (a_inf) begin
            if (!rs2_sel[0]) begin
                // Signed inf
                cvt_ws_result = sa
                    ? (!rs2_sel[1] ? {{(XLEN-32){1'b1}}, 32'h80000000}  // W -inf
                                   : {1'b1, {(XLEN-1){1'b0}}})           // L -inf
                    : (!rs2_sel[1] ? {{(XLEN-32){1'b0}}, 32'h7FFFFFFF}  // W +inf
                                   : {1'b0, {(XLEN-1){1'b1}}});          // L +inf
            end else begin
                // Unsigned inf: -inf -> 0, +inf -> all-ones
                cvt_ws_result = sa ? '0 : {XLEN{1'b1}};
            end
            cvt_ws_nv = 1'b1;

        end else if (a_zero) begin
            cvt_ws_result = '0;

        end else begin
            cws_exp_unbiased = $signed({1'b0, ea}) - 9'sd127;

            if (cws_exp_unbiased < 0) begin
                // |value| < 1: truncates to 0
                // For unsigned: negative-zero rounds to 0 with NX (not NV)
                cvt_ws_result = '0;
                cvt_ws_nx     = 1'b1;

            end else if (!rs2_sel[0]) begin
                // --------------- Signed path ---------------
                // Overflow thresholds: W needs exp < 31, L needs exp < 63
                if ((!rs2_sel[1] && cws_exp_unbiased >= 9'd31) ||
                    ( rs2_sel[1] && cws_exp_unbiased >= 9'd63)) begin
                    cvt_ws_result = sa
                        ? (!rs2_sel[1] ? {{(XLEN-32){1'b1}}, 32'h80000000}
                                       : {1'b1, {(XLEN-1){1'b0}}})
                        : (!rs2_sel[1] ? {{(XLEN-32){1'b0}}, 32'h7FFFFFFF}
                                       : {1'b0, {(XLEN-1){1'b1}}});
                    cvt_ws_nv = 1'b1;
                end else begin
                    // cws_sig88 = {1'b1, frac_a, 64'h0} >> (63 - exp_unbiased)
                    // integer in [87:24], fraction in [23:0]
                    cws_sig88    = {1'b1, frac_a, 64'h0} >> (9'd63 - cws_exp_unbiased);
                    cws_uint64   = cws_sig88[87:24];
                    cvt_ws_nx    = |cws_sig88[23:0];
                    if (cvt_ws_nx) begin
                        case (rm)
                            3'b001: ;                                          // RTZ
                            3'b010: if (sa) cws_uint64 = cws_uint64 + 1;      // RDN
                            3'b011: if (!sa) cws_uint64 = cws_uint64 + 1;     // RUP
                            3'b000: begin
                                if (cws_sig88[23] && (|cws_sig88[22:0] || cws_uint64[0]))
                                    cws_uint64 = cws_uint64 + 1;
                            end
                            3'b100: begin
                                if (cws_sig88[23]) cws_uint64 = cws_uint64 + 1;
                            end
                            default: ;
                        endcase
                    end
                    if (sa) begin
                        if (!rs2_sel[1]) begin
                            // W: negate 32-bit, sign-extend
                            cvt_ws_result = {{(XLEN-32){1'b1}},
                                            ~cws_uint64[31:0] + 32'd1};
                            if (cws_uint64[31:0] > 32'h80000000) begin
                                cvt_ws_result = {{(XLEN-32){1'b1}}, 32'h80000000};
                                cvt_ws_nv     = 1'b1;
                            end
                        end else begin
                            // L: negate 64-bit
                            cvt_ws_result = ~cws_uint64 + 64'd1;
                            if (cws_uint64 > 64'h8000000000000000) begin
                                cvt_ws_result = {1'b1, {(XLEN-1){1'b0}}};
                                cvt_ws_nv     = 1'b1;
                            end
                        end
                    end else begin
                        if (!rs2_sel[1]) begin
                            // W: zero-extend to XLEN, check overflow
                            cvt_ws_result = {{(XLEN-32){1'b0}}, cws_uint64[31:0]};
                            if (cws_uint64[31:0] >= 32'h80000000) begin
                                cvt_ws_result = {{(XLEN-32){1'b0}}, 32'h7FFFFFFF};
                                cvt_ws_nv     = 1'b1;
                            end
                        end else begin
                            // L: full 64-bit result, check overflow
                            cvt_ws_result = cws_uint64;
                            if (cws_uint64 >= 64'h8000000000000000) begin
                                cvt_ws_result = {1'b0, {(XLEN-1){1'b1}}};
                                cvt_ws_nv     = 1'b1;
                            end
                        end
                    end
                end

            end else begin
                // --------------- Unsigned path ---------------
                if (sa) begin
                    // Negative float (exp >= 0 means |val| >= 1): out of [0, UINT_MAX] -> 0, NV
                    cvt_ws_result = '0;
                    cvt_ws_nv     = 1'b1;
                end else begin
                    // Overflow thresholds: WU needs exp < 32, LU needs exp < 64
                    if ((!rs2_sel[1] && cws_exp_unbiased >= 9'd32) ||
                        ( rs2_sel[1] && cws_exp_unbiased >= 9'd64)) begin
                        cvt_ws_result = {XLEN{1'b1}};
                        cvt_ws_nv     = 1'b1;
                    end else begin
                        cws_sig88  = {1'b1, frac_a, 64'h0} >> (9'd63 - cws_exp_unbiased);
                        cws_uint64 = cws_sig88[87:24];
                        cvt_ws_nx  = |cws_sig88[23:0];
                        if (cvt_ws_nx) begin
                            case (rm)
                                3'b001: ;                                     // RTZ
                                3'b010: ;                                     // RDN (positive)
                                3'b011: cws_uint64 = cws_uint64 + 1;         // RUP
                                3'b000: begin
                                    if (cws_sig88[23] && (|cws_sig88[22:0] ||
                                        cws_uint64[0]))
                                        cws_uint64 = cws_uint64 + 1;
                                end
                                3'b100: begin
                                    if (cws_sig88[23]) cws_uint64 = cws_uint64 + 1;
                                end
                                default: ;
                            endcase
                        end
                        if (!rs2_sel[1]) begin
                            // WU: sign-extend the 32-bit result to XLEN bits
                            // (spec: FCVT.WU.S sign-extends its 32-bit result)
                            cvt_ws_result = {{(XLEN-32){cws_uint64[31]}},
                                            cws_uint64[31:0]};
                        end else begin
                            // LU: full 64-bit result
                            cvt_ws_result = cws_uint64;
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
