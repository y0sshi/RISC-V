// =============================================================================
/// @file rv_fpu_add_d.sv
/// @brief IEEE 754 Double-Precision Adder / Subtractor (3-stage pipelined)
///
/// Implements FADD.D and FSUB.D (and the D-extension FMADD family's add step via
/// rv_fpu).  The is_sub flag negates operand B's sign.
///
/// Format: s(1) | e(11) | f(52), bias=1023, canonical NaN=0x7FF8_0000_0000_0000
///
/// PIPELINE (50 MHz step 11; see rv_fpu.sv COMB_LAT note).  The double-precision
/// add was the 50 MHz binding path -- both the stage-0 align+57-bit-add
/// (-> sum_q) and the stage-1 normalize/round/assemble (-> the FPU result mux ->
/// ex_mem_fpu_result_f) sat at ~19.6-19.9 ns (route ~64%).  Split into THREE
/// register stages so each combinational arc is short:
///   stage 0  (comb): extract / classify / swap / align (the variable barrel
///                    shift) + decide eff_sub          -> register {sig_l,
///                    sig_s_shifted, eff_sub, sign, el, classify flags}
///   stage 1  (comb): the 57-bit significand add        -> sum_q
///   stage 2  (comb): LZC / normalize / round / assemble-> result_q / fflags_q
/// result/fflags are valid 3 cycles after stable inputs (was 1).  rv_fpu's
/// COMB_LAT handshake budgets for the deeper latency; increasing COMB_LAT only
/// gives every sub-unit MORE settle time (operands are frozen in ID/EX across the
/// busy window), so this is a pure latency change -- results stay BIT-IDENTICAL.
///
/// Each stage keeps its body in a SINGLE always_comb (driven from that stage's
/// registered inputs) to avoid the iverilog delta-cycle races that plagued the
/// original split-always design.
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_fpu_add_d (
    input  wire         clk,
    input  wire         rst_n,
    input  wire  [63:0] a,
    input  wire  [63:0] b,
    input  wire  [2:0]  rm,
    input  wire         is_sub,
    output logic [63:0] result,
    output logic [4:0]  fflags
);

    localparam logic [63:0] CANONICAL_NAN = 64'h7FF8000000000000;

    // =========================================================================
    // Stage 0 (combinational): extract / classify / swap / align
    // =========================================================================
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

        // ---- Decide effective add vs subtract ----
        eff_sub = (sl != ss);
    end

    // ---- Stage 0 -> Stage 1 register (aligned operands + carried metadata) ----
    logic [55:0] sig_l_s0, sig_s_shifted_s0;
    logic        eff_sub_s0, sl_s0;
    logic [11:0] el_s0;
    logic        sa_s0, sb_s0;
    logic        a_nan_s0, b_nan_s0, a_snan_s0, b_snan_s0, a_inf_s0, b_inf_s0;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sig_l_s0 <= '0; sig_s_shifted_s0 <= '0; eff_sub_s0 <= 1'b0;
            sl_s0 <= 1'b0; el_s0 <= '0; sa_s0 <= 1'b0; sb_s0 <= 1'b0;
            a_nan_s0 <= 1'b0; b_nan_s0 <= 1'b0; a_snan_s0 <= 1'b0;
            b_snan_s0 <= 1'b0; a_inf_s0 <= 1'b0; b_inf_s0 <= 1'b0;
        end else begin
            sig_l_s0 <= sig_l; sig_s_shifted_s0 <= sig_s_shifted;
            eff_sub_s0 <= eff_sub; sl_s0 <= sl; el_s0 <= el;
            sa_s0 <= sa; sb_s0 <= sb;
            a_nan_s0 <= a_nan; b_nan_s0 <= b_nan; a_snan_s0 <= a_snan;
            b_snan_s0 <= b_snan; a_inf_s0 <= a_inf; b_inf_s0 <= b_inf;
        end
    end

    // =========================================================================
    // Stage 1 (combinational): the 57-bit significand add/subtract
    // =========================================================================
    logic [56:0] sum;
    logic        sum_sign;
    always_comb begin
        if (!eff_sub_s0)
            sum = {1'b0, sig_l_s0} + {1'b0, sig_s_shifted_s0};
        else
            sum = {1'b0, sig_l_s0} - {1'b0, sig_s_shifted_s0};
        sum_sign = sl_s0;
    end

    // ---- Stage 1 -> Stage 2 register (post-add) ----
    logic [56:0] sum_q;
    logic        sum_sign_q;
    logic [11:0] el_q;
    logic        sa_q, sb_q;
    logic        a_nan_q, b_nan_q, a_snan_q, b_snan_q, a_inf_q, b_inf_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_q <= '0; sum_sign_q <= 1'b0; el_q <= '0;
            sa_q <= 1'b0; sb_q <= 1'b0;
            a_nan_q <= 1'b0; b_nan_q <= 1'b0; a_snan_q <= 1'b0;
            b_snan_q <= 1'b0; a_inf_q <= 1'b0; b_inf_q <= 1'b0;
        end else begin
            sum_q <= sum; sum_sign_q <= sum_sign; el_q <= el_s0;
            sa_q <= sa_s0; sb_q <= sb_s0;
            a_nan_q <= a_nan_s0; b_nan_q <= b_nan_s0; a_snan_q <= a_snan_s0;
            b_snan_q <= b_snan_s0; a_inf_q <= a_inf_s0; b_inf_q <= b_inf_s0;
        end
    end

    // =========================================================================
    // Stage 2 (combinational): normalize / round / assemble (reads *_q)
    // =========================================================================
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
    logic [63:0] result_c;
    logic [4:0]  fflags_c;

    always_comb begin
        // ---- Leading-zero count of sum_q[55:3] (loop-based priority encoder) ----
        // Scan LSB->MSB so the last (highest) set bit wins; all-zero -> 53.
        lzc = 6'd53;
        for (int i = 0; i <= 52; i++)
            if (sum_q[3 + i]) lzc = 6'(52 - i);   // sum_q[55]->0 ... sum_q[3]->52

        // ---- Normalize ----
        norm_exp      = el_q;
        norm_sig      = sum_q[55:0];
        is_exact_zero = 1'b0;
        shift_amt     = 6'd0;
        lzc_ext       = {6'b0, lzc};

        if (sum_q[56]) begin
            // Overflow: shift right 1, increment exponent
            norm_sig = {1'b0, sum_q[56:4], sum_q[3], sum_q[2], sum_q[1] | sum_q[0]};
            norm_exp = el_q + 12'd1;
        end else if (sum_q[55:0] == 56'h0) begin
            is_exact_zero = 1'b1;
        end else if (!sum_q[55]) begin
            // Compare against full el_q (not truncated el_q[5:0]); el_q can be 1024
            if (lzc_ext >= el_q) begin
                shift_amt = (el_q > 0) ? el_q[5:0] - 6'd1 : 6'd0;
                norm_exp  = 12'd0;
            end else begin
                shift_amt = lzc;
                norm_exp  = el_q - lzc_ext;
            end
            norm_sig = sum_q[55:0] << shift_amt;
        end

        // ---- Round ----
        G     = norm_sig[2];
        R     = norm_sig[1];
        S_bit = norm_sig[0];
        case (rm)
            3'b000: round_up = G & (R | S_bit | norm_sig[3]);
            3'b001: round_up = 1'b0;
            3'b010: round_up = (G | R | S_bit) & sum_sign_q;
            3'b011: round_up = (G | R | S_bit) & !sum_sign_q;
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
        result_c = 64'h0;
        fflags_c = 5'h0;

        if (a_nan_q || b_nan_q) begin
            result_c    = CANONICAL_NAN;
            fflags_c[4] = a_snan_q | b_snan_q;
        end else if (a_inf_q && b_inf_q && (sa_q != sb_q)) begin
            result_c    = CANONICAL_NAN;
            fflags_c[4] = 1'b1;
        end else if (a_inf_q) begin
            result_c = {sa_q, 11'h7FF, 52'h0};
        end else if (b_inf_q) begin
            result_c = {sb_q, 11'h7FF, 52'h0};
        end else if (is_exact_zero) begin
            result_c = {(rm == 3'b010) ? 1'b1 : 1'b0, 63'h0};
        end else begin
            if (final_exp >= 12'd2047) begin
                fflags_c[2] = 1'b1;
                fflags_c[0] = 1'b1;
                case (rm)
                    3'b001: result_c = {sum_sign_q, 11'h7FE, 52'hFFFFFFFFFFFFF};
                    3'b010: result_c = sum_sign_q ? {1'b1,11'h7FF,52'h0} : {1'b0,11'h7FE,52'hFFFFFFFFFFFFF};
                    3'b011: result_c = sum_sign_q ? {1'b1,11'h7FE,52'hFFFFFFFFFFFFF} : {1'b0,11'h7FF,52'h0};
                    default: result_c = {sum_sign_q, 11'h7FF, 52'h0};
                endcase
            end else if (final_exp == 0 && norm_exp == 0) begin
                result_c    = {sum_sign_q, 11'h000, final_frac};
                fflags_c[1] = (G | R | S_bit);
                fflags_c[0] = (G | R | S_bit);
            end else begin
                result_c    = {sum_sign_q, final_exp[10:0], final_frac};
                fflags_c[0] = G | R | S_bit;
            end
        end
    end

    // ---- Stage 2 -> output register (post normalize/round/assemble) ----
    // Breaks the long normalize/round + FPU output-mux + ex_mem route into its own
    // clock period.
    logic [63:0] result_q;
    logic [4:0]  fflags_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_q <= '0;
            fflags_q <= '0;
        end else begin
            result_q <= result_c;
            fflags_q <= fflags_c;
        end
    end

    assign result = result_q;
    assign fflags = fflags_q;

endmodule

`default_nettype wire
