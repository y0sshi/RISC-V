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
    input  wire  [63:0] a,
    input  wire  [63:0] b,
    input  wire  [2:0]  rm,
    input  wire         is_sub,
    output logic [63:0] result,
    output logic [4:0]  fflags
);

    localparam logic [63:0] CANONICAL_NAN = 64'h7FF8000000000000;

    // All intermediates are driven and consumed inside the single always_comb
    // below; declared at module level for waveform visibility.
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

        // ---- Leading-zero count of sum[55:3] (loop-based priority encoder) ----
        // Scan LSB->MSB so the last (highest) set bit wins; all-zero -> 53.
        lzc = 6'd53;
        for (int i = 0; i <= 52; i++)
            if (sum[3 + i]) lzc = 6'(52 - i);   // sum[55]->0 ... sum[3]->52

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
