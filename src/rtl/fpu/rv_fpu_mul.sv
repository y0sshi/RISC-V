// =============================================================================
/// @file rv_fpu_mul.sv
/// @brief IEEE 754 Single-Precision Multiplier (1-cycle pipelined)
///
/// Implements FMUL.S.  Also used internally by rv_fpu.sv to implement the
/// FMADD / FMSUB / FNMADD / FNMSUB family (non-fused: multiply then add).
///
/// Algorithm:
///   1. Classify inputs
///   2. Handle special cases (NaN, Inf, Zero)
///   3. Multiply 24-bit significands -> 48-bit product
///   4. Normalize (product may have leading 1 in bit 47 or 46)
///   5. Round
///   6. Assemble result, set fflags
///
/// fflags: {NV, DZ, OF, UF, NX}
///
/// C-2c third step: 1-cycle PIPELINED multiplier (mirrors rv_fpu_mul_d.sv).
/// A pipeline register at the post-product boundary splits stage 0 (extract/
/// classify, 24x24 product, exponent sum) from stage 1 (normalize/round/assemble).
/// `result`/`fflags` are valid 1 cycle after stable inputs; rv_fpu's
/// combinational-op handshake budgets for it.  Pure latency change, bit-identical.
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_fpu_mul (
    input  wire         clk,
    input  wire         rst_n,
    input  wire  [31:0] a,        // Operand A (multiplicand)
    input  wire  [31:0] b,        // Operand B (multiplier)
    input  wire  [2:0]  rm,       // Rounding mode (resolved)
    output logic [31:0] result,
    output logic [4:0]  fflags
);

    localparam logic [31:0] CANONICAL_NAN = 32'h7FC00000;

    // -------------------------------------------------------------------------
    // Field extraction
    // -------------------------------------------------------------------------
    logic        sa, sb, sr;
    logic [7:0]  ea, eb;
    logic [22:0] fra, frb;

    assign sa  = a[31];
    assign ea  = a[30:23];
    assign fra = a[22:0];
    assign sb  = b[31];
    assign eb  = b[30:23];
    assign frb = b[22:0];
    assign sr  = sa ^ sb;   // result sign

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

    // 24-bit mantissas
    logic [23:0] ma, mb;
    assign ma = {!a_sub && !a_zero, fra};
    assign mb = {!b_sub && !b_zero, frb};

    // -------------------------------------------------------------------------
    // Multiply significands: 24x24 -> 48-bit product
    // -------------------------------------------------------------------------
    logic [47:0] prod;
    assign prod = ma * mb;

    // -------------------------------------------------------------------------
    // Exponent sum (unbiased): (ea - 127) + (eb - 127) + 127 = ea + eb - 127
    // Handle subnormals: effective exp = 1 when ea=0
    // -------------------------------------------------------------------------
    logic [9:0] ea_eff, eb_eff;  // 10-bit to handle overflow
    assign ea_eff = a_sub ? 10'd1 : {2'b00, ea};
    assign eb_eff = b_sub ? 10'd1 : {2'b00, eb};

    logic signed [10:0] exp_sum;
    assign exp_sum = {1'b0, ea_eff} + {1'b0, eb_eff} - 11'd127;

    // =========================================================================
    // Pipeline register (stage 0 -> stage 1).  Free-running; rv_fpu's handshake
    // captures the stage-1 result on the correct cycle (stale fills uncaptured).
    // Registers the 24x24 product plus the light exponent sum / sign / special-
    // case flags so stage 1 is pure normalize/round/assemble.
    // =========================================================================
    logic [47:0]        prod_q;
    logic signed [10:0] exp_sum_q;
    logic               sr_q;
    logic               a_nan_q, b_nan_q, a_snan_q, b_snan_q;
    logic               a_inf_q, b_inf_q, a_zero_q, b_zero_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_q  <= '0; exp_sum_q <= '0; sr_q <= 1'b0;
            a_nan_q <= 1'b0; b_nan_q <= 1'b0; a_snan_q <= 1'b0; b_snan_q <= 1'b0;
            a_inf_q <= 1'b0; b_inf_q <= 1'b0; a_zero_q <= 1'b0; b_zero_q <= 1'b0;
        end else begin
            prod_q  <= prod; exp_sum_q <= exp_sum; sr_q <= sr;
            a_nan_q <= a_nan; b_nan_q <= b_nan; a_snan_q <= a_snan; b_snan_q <= b_snan;
            a_inf_q <= a_inf; b_inf_q <= b_inf; a_zero_q <= a_zero; b_zero_q <= b_zero;
        end
    end

    // -------------------------------------------------------------------------
    // Stage 1: normalize / round / assemble (reads registered *_q).
    // Normalize: locate the leading 1 of the 48-bit product and left-align it
    // to bit 47.  For two normalized inputs the leading 1 sits at bit 47 or 46
    // (1-bit shift), but a subnormal operand has no implicit leading 1, so its
    // 24-bit significand carries leading zeros and the product's leading 1 can
    // fall well below bit 46.  That demands a multi-bit left shift.
    //
    // The leading-zero count is a loop-based priority encoder (scan LSB->MSB so
    // the last/highest set bit wins).  After shifting, the leading 1 is at bit 47:
    //   prod_norm[47]   = hidden leading 1
    //   prod_norm[46:24]= fraction[22:0]
    //   prod_norm[23]   = G, [22] = R, [21:0] = sticky
    // Exponent: leading 1 originally at bit (47 - prod_lzc), so relative to the
    // bit-46 reference used by exp_sum the bias is +1 - prod_lzc.
    // -------------------------------------------------------------------------
    logic [5:0] prod_lzc;   // leading-zero count of prod_q[47:0] (0..47)
    always_comb begin
        prod_lzc = 6'd47;
        for (int i = 0; i <= 47; i++)
            if (prod_q[i]) prod_lzc = 6'(47 - i);   // prod_q[47]->0 ... prod_q[0]->47
    end

    logic [47:0] prod_norm;
    assign prod_norm = prod_q << prod_lzc;   // leading 1 left-aligned to bit 47

    logic [22:0] norm_frac;
    logic        G, R, S_bit;
    logic [10:0] norm_exp;

    always_comb begin
        norm_frac = prod_norm[46:24];
        G         = prod_norm[23];
        R         = prod_norm[22];
        S_bit     = |prod_norm[21:0];
        // exp_sum references the bit-46 leading position; shift moves it to 47
        norm_exp  = exp_sum_q[10:0] + 11'd1 - {5'd0, prod_lzc};
    end

    // -------------------------------------------------------------------------
    // Round
    // -------------------------------------------------------------------------
    logic round_up;
    always_comb begin
        case (rm)
            3'b000: round_up = G & (R | S_bit | norm_frac[0]);  // RNE
            3'b001: round_up = 1'b0;                              // RTZ
            3'b010: round_up = (G | R | S_bit) & sr_q;           // RDN
            3'b011: round_up = (G | R | S_bit) & !sr_q;          // RUP
            3'b100: round_up = G;                                  // RMM
            default: round_up = 1'b0;
        endcase
    end

    logic [23:0] mant_rounded;
    assign mant_rounded = {1'b0, norm_frac} + {23'h0, round_up};

    logic [10:0] final_exp;
    logic [22:0] final_frac;
    always_comb begin
        if (mant_rounded[23]) begin
            final_exp  = norm_exp + 11'd1;
            final_frac = mant_rounded[23:1];
        end else begin
            final_exp  = norm_exp;
            final_frac = mant_rounded[22:0];
        end
    end

    // =========================================================================
    // Output
    // =========================================================================
    always_comb begin
        result = 32'h0;
        fflags = 5'h0;

        if (a_nan_q || b_nan_q) begin
            result    = CANONICAL_NAN;
            fflags[4] = a_snan_q | b_snan_q;
        end else if ((a_inf_q && (b_zero_q)) || (b_inf_q && (a_zero_q))) begin
            // inf * 0 = NaN
            result    = CANONICAL_NAN;
            fflags[4] = 1'b1;
        end else if (a_inf_q || b_inf_q) begin
            result = {sr_q, 8'hFF, 23'h0};
        end else if (a_zero_q || b_zero_q) begin
            result = {sr_q, 31'h0};
        end else begin
            // Normal multiplication
            if ($signed(final_exp) >= 11'sd255) begin
                // Overflow
                fflags[2] = 1'b1;
                fflags[0] = 1'b1;
                case (rm)
                    3'b001: result = {sr_q, 8'hFE, 23'h7FFFFF};
                    3'b010: result = sr_q ? {1'b1,8'hFF,23'h0} : {1'b0,8'hFE,23'h7FFFFF};
                    3'b011: result = sr_q ? {1'b1,8'hFE,23'h7FFFFF} : {1'b0,8'hFF,23'h0};
                    default: result = {sr_q, 8'hFF, 23'h0};
                endcase
            end else if ($signed(final_exp) <= 11'sd0) begin
                // Underflow -> zero (simplified: flush to zero)
                result    = {sr_q, 31'h0};
                fflags[1] = 1'b1;
                fflags[0] = 1'b1;
            end else begin
                result    = {sr_q, final_exp[7:0], final_frac};
                fflags[0] = G | R | S_bit;
            end
        end
    end

endmodule

`default_nettype wire
