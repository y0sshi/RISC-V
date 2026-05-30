// =============================================================================
/// @file rv_fpu_add_d.sv
/// @brief IEEE 754 Double-Precision Adder / Subtractor (combinational)
///
/// Implements FADD.D and FSUB.D.  The is_sub flag negates operand B's sign.
///
/// Format: s(1) | e(11) | f(52), bias=1023, canonical NaN=0x7FF8_0000_0000_0000
///
/// Implemented as a SINGLE always_comb block computing everything from the
/// primary inputs (a, b, is_sub, rm).  This avoids iverilog delta-cycle races
/// where a chain of separate always blocks feeding continuous-assign nets can
/// evaluate with stale intermediate values and never re-trigger.
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_fpu_add_d (
    input  logic [63:0] a,
    input  logic [63:0] b,
    input  logic [2:0]  rm,
    input  logic        is_sub,
    output logic [63:0] result,
    output logic [4:0]  fflags
);

    localparam logic [63:0] CANONICAL_NAN = 64'h7FF8000000000000;

    // All intermediates declared at module level (iverilog: no local decls in
    // always blocks for some constructs).  Driven inside one always_comb.
    logic        sa, sb;
    logic [10:0] ea, eb;
    logic [51:0] fra, frb;
    logic        a_nan, b_nan, a_snan, b_snan;
    logic        a_inf, b_inf, a_zero, b_zero, a_sub_n, b_sub_n;
    logic [11:0] ea_eff, eb_eff;
    logic [52:0] ma, mb;
    logic        swap;
    logic        sl, ss;
    logic [11:0] el, es;
    logic [52:0] ml, ms;
    logic [12:0] raw_diff;
    logic [7:0]  exp_diff;
    logic [55:0] sig_l, ms_ext, sig_s_shifted;
    logic        sticky_shift;
    logic        eff_sub;
    logic [56:0] sum;
    logic        sum_sign;
    logic [5:0]  lzc;
    logic [11:0] norm_exp;
    logic [55:0] norm_sig;
    logic        is_exact_zero;
    logic [5:0]  shift_amt;
    logic [11:0] lzc_ext;
    logic        G, R, S_bit, round_up;
    logic [52:0] mant_rounded;
    logic [11:0] final_exp;
    logic [51:0] final_frac;

    always_comb begin
        // ---- Field extraction; apply is_sub to b's sign ----
        sa  = a[63];
        ea  = a[62:52];
        fra = a[51:0];
        sb  = b[63] ^ is_sub;
        eb  = b[62:52];
        frb = b[51:0];

        // ---- Classify ----
        a_nan   = (ea == 11'h7FF) && (fra != 0);
        b_nan   = (eb == 11'h7FF) && (frb != 0);
        a_snan  = a_nan && !fra[51];
        b_snan  = b_nan && !frb[51];
        a_inf   = (ea == 11'h7FF) && (fra == 0);
        b_inf   = (eb == 11'h7FF) && (frb == 0);
        a_zero  = (ea == 0) && (fra == 0);
        b_zero  = (eb == 0) && (frb == 0);
        a_sub_n = (ea == 0) && (fra != 0);
        b_sub_n = (eb == 0) && (frb != 0);

        ea_eff = a_sub_n ? 12'd1 : {1'b0, ea};
        eb_eff = b_sub_n ? 12'd1 : {1'b0, eb};

        ma = {!a_sub_n && !a_zero, fra};
        mb = {!b_sub_n && !b_zero, frb};

        // ---- Swap so the larger magnitude is on the "l" side ----
        swap = (ea_eff < eb_eff) || (ea_eff == eb_eff && ma < mb);
        if (swap) begin
            sl = sb; el = eb_eff; ml = mb;
            ss = sa; es = ea_eff; ms = ma;
        end else begin
            sl = sa; el = ea_eff; ml = ma;
            ss = sb; es = eb_eff; ms = mb;
        end

        // ---- Align smaller operand (56-bit working significand) ----
        raw_diff = {1'b0, el} - {1'b0, es};
        exp_diff = (raw_diff > 13'd55) ? 8'd55 : raw_diff[7:0];

        sig_l  = {ml, 3'b0};
        ms_ext = {ms, 3'b0};

        sticky_shift  = 1'b0;
        sig_s_shifted = 56'h0;
        if (exp_diff == 0) begin
            sig_s_shifted = ms_ext;
        end else if (exp_diff >= 56) begin
            sticky_shift = |ms;
        end else begin
            sig_s_shifted = ms_ext >> exp_diff;
            sticky_shift  = |(ms_ext << (56 - exp_diff));
        end
        sig_s_shifted[0] = sig_s_shifted[0] | sticky_shift;

        // ---- Add or subtract ----
        eff_sub = (sl != ss);
        if (!eff_sub)
            sum = {1'b0, sig_l} + {1'b0, sig_s_shifted};
        else
            sum = {1'b0, sig_l} - {1'b0, sig_s_shifted};
        sum_sign = sl;

        // ---- Leading-zero count of sum[55:3] (priority encoder) ----
        // Use an explicit priority if-else (not casez) — iverilog miscomputed the
        // casez result for a 53-bit part-select of a 57-bit reg, returning lzc=0
        // for inputs whose MSB was 0 (e.g. 2.5-1.0).
        if      (sum[55]) lzc = 6'd0;
        else if (sum[54]) lzc = 6'd1;
        else if (sum[53]) lzc = 6'd2;
        else if (sum[52]) lzc = 6'd3;
        else if (sum[51]) lzc = 6'd4;
        else if (sum[50]) lzc = 6'd5;
        else if (sum[49]) lzc = 6'd6;
        else if (sum[48]) lzc = 6'd7;
        else if (sum[47]) lzc = 6'd8;
        else if (sum[46]) lzc = 6'd9;
        else if (sum[45]) lzc = 6'd10;
        else if (sum[44]) lzc = 6'd11;
        else if (sum[43]) lzc = 6'd12;
        else if (sum[42]) lzc = 6'd13;
        else if (sum[41]) lzc = 6'd14;
        else if (sum[40]) lzc = 6'd15;
        else if (sum[39]) lzc = 6'd16;
        else if (sum[38]) lzc = 6'd17;
        else if (sum[37]) lzc = 6'd18;
        else if (sum[36]) lzc = 6'd19;
        else if (sum[35]) lzc = 6'd20;
        else if (sum[34]) lzc = 6'd21;
        else if (sum[33]) lzc = 6'd22;
        else if (sum[32]) lzc = 6'd23;
        else if (sum[31]) lzc = 6'd24;
        else if (sum[30]) lzc = 6'd25;
        else if (sum[29]) lzc = 6'd26;
        else if (sum[28]) lzc = 6'd27;
        else if (sum[27]) lzc = 6'd28;
        else if (sum[26]) lzc = 6'd29;
        else if (sum[25]) lzc = 6'd30;
        else if (sum[24]) lzc = 6'd31;
        else if (sum[23]) lzc = 6'd32;
        else if (sum[22]) lzc = 6'd33;
        else if (sum[21]) lzc = 6'd34;
        else if (sum[20]) lzc = 6'd35;
        else if (sum[19]) lzc = 6'd36;
        else if (sum[18]) lzc = 6'd37;
        else if (sum[17]) lzc = 6'd38;
        else if (sum[16]) lzc = 6'd39;
        else if (sum[15]) lzc = 6'd40;
        else if (sum[14]) lzc = 6'd41;
        else if (sum[13]) lzc = 6'd42;
        else if (sum[12]) lzc = 6'd43;
        else if (sum[11]) lzc = 6'd44;
        else if (sum[10]) lzc = 6'd45;
        else if (sum[9])  lzc = 6'd46;
        else if (sum[8])  lzc = 6'd47;
        else if (sum[7])  lzc = 6'd48;
        else if (sum[6])  lzc = 6'd49;
        else if (sum[5])  lzc = 6'd50;
        else if (sum[4])  lzc = 6'd51;
        else if (sum[3])  lzc = 6'd52;
        else              lzc = 6'd53;

        // ---- Normalize ----
        norm_exp      = el;
        norm_sig      = sum[55:0];
        is_exact_zero = 1'b0;
        shift_amt     = 6'd0;
        lzc_ext       = {6'b0, lzc};

        if (sum[56]) begin
            // Overflow: shift right 1, increment exponent
            norm_sig = {1'b0, sum[56:4], sum[3], sum[2], sum[1] | sum[0]};
            norm_exp = el + 12'd1;
        end else if (sum[55:0] == 56'h0) begin
            is_exact_zero = 1'b1;
        end else if (!sum[55]) begin
            // Compare against full el (not truncated el[5:0]); el can be 1024
            if (lzc_ext >= el) begin
                shift_amt = (el > 0) ? el[5:0] - 6'd1 : 6'd0;
                norm_exp  = 12'd0;
            end else begin
                shift_amt = lzc;
                norm_exp  = el - lzc_ext;
            end
            norm_sig = sum[55:0] << shift_amt;
        end

        // ---- Round ----
        G     = norm_sig[2];
        R     = norm_sig[1];
        S_bit = norm_sig[0];
        case (rm)
            3'b000: round_up = G & (R | S_bit | norm_sig[3]);
            3'b001: round_up = 1'b0;
            3'b010: round_up = (G | R | S_bit) & sum_sign;
            3'b011: round_up = (G | R | S_bit) & !sum_sign;
            3'b100: round_up = G;
            default: round_up = 1'b0;
        endcase

        // norm_sig layout: [55]=hidden1, [54:3]=frac[51:0], [2:0]=GRS
        mant_rounded = {1'b0, norm_sig[54:3]} + {52'h0, round_up};
        if (mant_rounded[52]) begin
            final_exp  = norm_exp + 12'd1;
            final_frac = mant_rounded[51:0];
        end else begin
            final_exp  = norm_exp;
            final_frac = mant_rounded[51:0];
        end

        // ---- Output assembly with special-case overrides ----
        result = 64'h0;
        fflags = 5'h0;

        if (a_nan || b_nan) begin
            result    = CANONICAL_NAN;
            fflags[4] = a_snan | b_snan;
        end else if (a_inf && b_inf && (sa != sb)) begin
            result    = CANONICAL_NAN;
            fflags[4] = 1'b1;
        end else if (a_inf) begin
            result = {sa, 11'h7FF, 52'h0};
        end else if (b_inf) begin
            result = {sb, 11'h7FF, 52'h0};
        end else if (is_exact_zero) begin
            result = {(rm == 3'b010) ? 1'b1 : 1'b0, 63'h0};
        end else begin
            if (final_exp >= 12'd2047) begin
                fflags[2] = 1'b1;
                fflags[0] = 1'b1;
                case (rm)
                    3'b001: result = {sum_sign, 11'h7FE, 52'hFFFFFFFFFFFFF};
                    3'b010: result = sum_sign ? {1'b1,11'h7FF,52'h0} : {1'b0,11'h7FE,52'hFFFFFFFFFFFFF};
                    3'b011: result = sum_sign ? {1'b1,11'h7FE,52'hFFFFFFFFFFFFF} : {1'b0,11'h7FF,52'h0};
                    default: result = {sum_sign, 11'h7FF, 52'h0};
                endcase
            end else if (final_exp == 0 && norm_exp == 0) begin
                result    = {sum_sign, 11'h000, final_frac};
                fflags[1] = (G | R | S_bit);
                fflags[0] = (G | R | S_bit);
            end else begin
                result    = {sum_sign, final_exp[10:0], final_frac};
                fflags[0] = G | R | S_bit;
            end
        end
    end

endmodule

`default_nettype wire
