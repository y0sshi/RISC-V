// =============================================================================
/// @file rv_fpu_add.sv
/// @brief IEEE 754 Single-Precision Adder / Subtractor (combinational)
///
/// Implements FADD.S and FSUB.S.  The is_sub flag negates operand B's sign
/// before the computation, turning subtraction into addition.
///
/// Algorithm:
///   1. Classify inputs (NaN, Inf, Zero, subnormal)
///   2. Handle special cases (NaN propagation, Inf arithmetic)
///   3. Swap operands so the larger exponent is always on the "a" side
///   4. Align smaller operand (right-shift with G/R/S sticky bit tracking)
///   5. Add or subtract 24-bit significands
///   6. Normalize (post-add: check carry; post-sub: count leading zeros)
///   7. Round per rounding mode (RNE / RTZ / RDN / RUP / RMM)
///   8. Assemble result and set fflags
///
/// fflags: {NV, DZ, OF, UF, NX}
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

// C-2c second step: 1-cycle PIPELINED adder.  The IEEE align+add and the
// normalize+round+assemble were a single combinational cloud that became the
// FPGA critical path once the FMADD multiply was split off (~43 ns -> fflags).
// A pipeline register at the post-add `sum` boundary splits it: stage 0 does
// field-extract / classify / align / add; stage 1 does LZC / normalize / round
// / assemble.  `result`/`fflags` are valid 1 cycle after stable inputs (the
// internal register is free-running).  rv_fpu's 2-cycle combinational-op
// handshake already budgets for this (FADD: op-in cycle 0 -> result cycle 1;
// FMADD: product registered cycle 0 -> add-in cycle 1 -> result cycle 2),
// captured on the busy-drop cycle.  Pure latency change; results bit-identical.
module rv_fpu_add (
    input  wire         clk,
    input  wire         rst_n,
    input  wire  [31:0] a,        // Operand A
    input  wire  [31:0] b,        // Operand B
    input  wire  [2:0]  rm,       // Rounding mode (resolved, no DYN)
    input  wire         is_sub,   // 0=FADD, 1=FSUB (negates b sign)
    output logic [31:0] result,
    output logic [4:0]  fflags    // {NV, DZ, OF, UF, NX}
);

    localparam logic [31:0] CANONICAL_NAN = 32'h7FC00000;

    // -------------------------------------------------------------------------
    // Extract fields; apply is_sub to b's sign
    // -------------------------------------------------------------------------
    logic        sa, sb;
    logic [7:0]  ea, eb;
    logic [22:0] fra, frb;

    assign sa  = a[31];
    assign ea  = a[30:23];
    assign fra = a[22:0];
    assign sb  = b[31] ^ is_sub;
    assign eb  = b[30:23];
    assign frb = b[22:0];

    // -------------------------------------------------------------------------
    // Classify
    // -------------------------------------------------------------------------
    logic a_nan, b_nan, a_snan, b_snan;
    logic a_inf, b_inf, a_zero, b_zero, a_sub, b_sub;

    assign a_nan  = (ea == 8'hFF) && (fra != 0);
    assign b_nan  = (eb == 8'hFF) && (frb != 0);
    assign a_snan = a_nan && !fra[22];
    assign b_snan = b_nan && !frb[22];
    assign a_inf  = (ea == 8'hFF) && (fra == 0);
    assign b_inf  = (eb == 8'hFF) && (frb == 0);
    assign a_zero = (ea == 0) && (fra == 0);
    assign b_zero = (eb == 0) && (frb == 0);
    assign a_sub  = (ea == 0) && (fra != 0);
    assign b_sub  = (eb == 0) && (frb != 0);

    // Effective exponent: subnormals use 1 (no implicit leading 1)
    logic [8:0] ea_eff, eb_eff;
    assign ea_eff = a_sub ? 9'd1 : {1'b0, ea};
    assign eb_eff = b_sub ? 9'd1 : {1'b0, eb};

    // 24-bit mantissa with implicit leading bit
    logic [23:0] ma, mb;
    assign ma = {!a_sub && !a_zero, fra};
    assign mb = {!b_sub && !b_zero, frb};

    // -------------------------------------------------------------------------
    // Swap: ensure the operand with the larger magnitude is on the "l" side
    // -------------------------------------------------------------------------
    logic        sl, ss;
    logic [8:0]  el, es;
    logic [23:0] ml, ms;

    logic swap;
    assign swap = (ea_eff < eb_eff) || (ea_eff == eb_eff && ma < mb);

    always_comb begin
        if (swap) begin
            sl = sb; el = eb_eff; ml = mb;
            ss = sa; es = ea_eff; ms = ma;
        end else begin
            sl = sa; el = ea_eff; ml = ma;
            ss = sb; es = eb_eff; ms = mb;
        end
    end

    // -------------------------------------------------------------------------
    // Align: right-shift smaller operand, track GRS bits
    // -------------------------------------------------------------------------
    // Working significand: 27 bits = {ml, 3'b_GRS}
    // sig_l = {ml, 3'b0}        (27 bits, bit26=implicit1, bits2:0=GRS)
    // sig_s is shifted right by exp_diff

    logic [5:0]  exp_diff;
    logic [26:0] sig_l;
    logic [26:0] ms_ext;
    logic [26:0] sig_s_shifted;
    logic        sticky_shift;
    logic [8:0]  raw_diff;   // exponent difference (pre-clamp)

    always_comb begin
        raw_diff = el - es;
        exp_diff = (raw_diff > 9'd26) ? 6'd26 : raw_diff[5:0];
    end

    assign sig_l  = {ml, 3'b0};
    assign ms_ext = {ms, 3'b0};

    always_comb begin
        sticky_shift    = 1'b0;
        sig_s_shifted   = 27'h0;
        if (exp_diff == 0) begin
            sig_s_shifted = ms_ext;
        end else if (exp_diff >= 27) begin
            sticky_shift  = |ms;
        end else begin
            sig_s_shifted = ms_ext >> exp_diff;
            sticky_shift  = |(ms_ext << (27 - exp_diff));
        end
        sig_s_shifted[0] = sig_s_shifted[0] | sticky_shift;
    end

    // -------------------------------------------------------------------------
    // Add or subtract
    // -------------------------------------------------------------------------
    logic        eff_sub;
    assign eff_sub = (sl != ss);

    logic [27:0] sum;     // 28-bit (27 + carry)
    logic        sum_sign;

    always_comb begin
        if (!eff_sub) begin
            sum      = {1'b0, sig_l} + {1'b0, sig_s_shifted};
            sum_sign = sl;
        end else begin
            sum      = {1'b0, sig_l} - {1'b0, sig_s_shifted};
            sum_sign = sl;
        end
    end

    // =========================================================================
    // Pipeline register (stage 0 -> stage 1).  Free-running: latches the post-add
    // signals every cycle; the rv_fpu handshake captures the stage-1 result on
    // the correct cycle (stale fill cycles are never captured).
    // =========================================================================
    logic [27:0] sum_q;
    logic        sum_sign_q;
    logic [8:0]  el_q;
    logic        sa_q, sb_q;
    logic        a_nan_q, b_nan_q, a_snan_q, b_snan_q, a_inf_q, b_inf_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_q <= '0; sum_sign_q <= 1'b0; el_q <= '0;
            sa_q <= 1'b0; sb_q <= 1'b0;
            a_nan_q <= 1'b0; b_nan_q <= 1'b0; a_snan_q <= 1'b0;
            b_snan_q <= 1'b0; a_inf_q <= 1'b0; b_inf_q <= 1'b0;
        end else begin
            sum_q <= sum; sum_sign_q <= sum_sign; el_q <= el;
            sa_q <= sa; sb_q <= sb;
            a_nan_q <= a_nan; b_nan_q <= b_nan; a_snan_q <= a_snan;
            b_snan_q <= b_snan; a_inf_q <= a_inf; b_inf_q <= b_inf;
        end
    end

    // -------------------------------------------------------------------------
    // Normalize (stage 1: reads the registered *_q signals)
    // -------------------------------------------------------------------------
    // Leading-zero count of sum[26:3] (24-bit mantissa when no overflow).
    // Loop-based priority encoder: scan LSB->MSB so the last (highest) set bit
    // wins (last-write-wins), giving the leading-zero count; all-zero -> 24.
    logic [4:0] lzc;
    always_comb begin
        lzc = 5'd24;
        for (int i = 0; i <= 23; i++)
            if (sum_q[3 + i]) lzc = 5'(23 - i);   // sum_q[26]->0 ... sum_q[3]->23
    end

    // After normalization: norm_sig[26:3]=mantissa, norm_sig[2:0]=GRS
    logic [8:0]  norm_exp;
    logic [26:0] norm_sig;
    logic        is_exact_zero;
    logic [4:0]  shift_amt;   // normalization left-shift amount

    always_comb begin
        norm_exp       = el_q;
        norm_sig       = sum_q[26:0];
        is_exact_zero  = 1'b0;
        shift_amt      = 5'd0;

        if (sum_q[27]) begin
            // Overflow bit set: shift right 1, increment exponent
            // New GRS: G=old_bit3, R=old_bit2, S=old_bit1|old_bit0
            norm_sig    = {1'b0, sum_q[27:4], sum_q[3], sum_q[2], sum_q[1] | sum_q[0]};
            norm_exp    = el_q + 9'd1;
        end else if (sum_q[26:0] == 27'h0) begin
            // Exact zero from subtraction
            is_exact_zero = 1'b1;
        end else if (!sum_q[26]) begin
            // Need to shift left (subtraction cancellation)
            // Max shift: el_q - 1 (to keep exp >= 1), or further into subnormal
            if ({4'b0, lzc} >= el_q) begin
                // Result is subnormal: shift until exp reaches 0
                shift_amt = (el_q > 0) ? el_q[4:0] - 5'd1 : 5'd0;
                norm_exp  = 9'd0;
            end else begin
                shift_amt = lzc;
                norm_exp  = el_q - {4'b0, lzc};
            end
            norm_sig = sum_q[26:0] << shift_amt;
        end
        // else: sum_q[26]=1 and no overflow — already normalized, norm_sig=sum_q[26:0]
    end

    // -------------------------------------------------------------------------
    // Round
    // -------------------------------------------------------------------------
    logic G, R, S_bit, round_up;

    assign G     = norm_sig[2];
    assign R     = norm_sig[1];
    assign S_bit = norm_sig[0];

    always_comb begin
        case (rm)
            3'b000: round_up = G & (R | S_bit | norm_sig[3]);  // RNE (norm_sig[3]=result LSB)
            3'b001: round_up = 1'b0;                             // RTZ
            3'b010: round_up = (G | R | S_bit) & sum_sign_q;    // RDN
            3'b011: round_up = (G | R | S_bit) & !sum_sign_q;   // RUP
            3'b100: round_up = G;                                 // RMM
            default: round_up = 1'b0;
        endcase
    end

    // norm_sig layout: [26]=hidden1, [25:3]=frac[22:0], [2:0]=GRS
    // Correct fraction extraction: norm_sig[25:3] (not norm_sig[26:4])
    logic [23:0] mant_rounded;
    assign mant_rounded = {1'b0, norm_sig[25:3]} + {23'h0, round_up};

    logic [8:0] final_exp;
    logic [22:0] final_frac;

    always_comb begin
        if (mant_rounded[23]) begin
            // Rounding carry: fraction overflowed, frac = 0, exp++
            final_exp  = norm_exp + 9'd1;
            final_frac = mant_rounded[22:0];  // = 23'h0 when fully overflowed
        end else begin
            final_exp  = norm_exp;
            final_frac = mant_rounded[22:0];
        end
    end

    // =========================================================================
    // Output assembly with special-case overrides
    // =========================================================================
    always_comb begin
        result = 32'h0;
        fflags = 5'h0;

        // --- Special cases have priority ---
        if (a_nan_q || b_nan_q) begin
            result    = CANONICAL_NAN;
            fflags[4] = a_snan_q | b_snan_q;  // NV if any sNaN
        end else if (a_inf_q && b_inf_q && (sa_q != sb_q)) begin
            // (+inf) + (-inf) = NaN
            result    = CANONICAL_NAN;
            fflags[4] = 1'b1;
        end else if (a_inf_q) begin
            result = {sa_q, 8'hFF, 23'h0};
        end else if (b_inf_q) begin
            result = {sb_q, 8'hFF, 23'h0};
        end else if (is_exact_zero) begin
            // +0 + (-0) = +0 (RDN -> -0)
            result = {(rm == 3'b010) ? 1'b1 : 1'b0, 31'h0};
        end else begin
            // Normal result
            if (final_exp >= 9'd255) begin
                // Overflow: infinity (except RTZ/directed)
                fflags[2] = 1'b1;  // OF
                fflags[0] = 1'b1;  // NX
                case (rm)
                    3'b001: result = {sum_sign_q, 8'hFE, 23'h7FFFFF};  // RTZ -> max finite
                    3'b010: result = sum_sign_q ? {1'b1,8'hFF,23'h0} : {1'b0,8'hFE,23'h7FFFFF};
                    3'b011: result = sum_sign_q ? {1'b1,8'hFE,23'h7FFFFF} : {1'b0,8'hFF,23'h0};
                    default: result = {sum_sign_q, 8'hFF, 23'h0};  // round to infinity
                endcase
            end else if (final_exp == 0 && norm_exp == 0) begin
                // Subnormal result
                result    = {sum_sign_q, 8'h00, final_frac};
                fflags[1] = (G | R | S_bit);  // UF
                fflags[0] = (G | R | S_bit);  // NX
            end else begin
                result = {sum_sign_q, final_exp[7:0], final_frac};
                fflags[0] = G | R | S_bit;  // NX (inexact)
            end
        end
    end

endmodule

`default_nettype wire
