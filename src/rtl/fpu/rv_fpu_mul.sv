// =============================================================================
/// @file rv_fpu_mul.sv
/// @brief IEEE 754 Single-Precision Multiplier (combinational)
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
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_fpu_mul (
    input  logic [31:0] a,        // Operand A (multiplicand)
    input  logic [31:0] b,        // Operand B (multiplier)
    input  logic [2:0]  rm,       // Rounding mode (resolved)
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

    // -------------------------------------------------------------------------
    // Normalize: product is in range [1.0, 4.0) -> bit47 or bit46 is leading 1
    // -------------------------------------------------------------------------
    // If prod[47]=1: result = 1.prod[46:0] -> shift=0, exp_sum+1
    // If prod[46]=1: result = 1.prod[45:0] -> shift=1, exp_sum
    // We need 23 fraction bits + GRS for rounding
    //
    // Representation after normalization:
    //   mantissa[23:0] = {1, frac[22:0]}
    //   GRS = prod bits below the chosen fraction

    logic [22:0] norm_frac;
    logic        G, R, S_bit;
    logic [10:0] norm_exp;

    always_comb begin
        norm_exp  = 11'h0;
        norm_frac = 23'h0;
        G         = 1'b0;
        R         = 1'b0;
        S_bit     = 1'b0;

        if (prod[47]) begin
            // Leading 1 in bit 47: product = 1.prod[46:24] with GRS=prod[23:21]|...
            norm_frac = prod[46:24];
            G         = prod[23];
            R         = prod[22];
            S_bit     = |prod[21:0];
            norm_exp  = exp_sum[10:0] + 11'd1;
        end else begin
            // Leading 1 in bit 46 (normal case for normalized inputs)
            norm_frac = prod[45:23];
            G         = prod[22];
            R         = prod[21];
            S_bit     = |prod[20:0];
            norm_exp  = exp_sum[10:0];
        end
    end

    // -------------------------------------------------------------------------
    // Round
    // -------------------------------------------------------------------------
    logic round_up;
    always_comb begin
        case (rm)
            3'b000: round_up = G & (R | S_bit | norm_frac[0]);  // RNE
            3'b001: round_up = 1'b0;                              // RTZ
            3'b010: round_up = (G | R | S_bit) & sr;             // RDN
            3'b011: round_up = (G | R | S_bit) & !sr;            // RUP
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

        if (a_nan || b_nan) begin
            result    = CANONICAL_NAN;
            fflags[4] = a_snan | b_snan;
        end else if ((a_inf && (b_zero)) || (b_inf && (a_zero))) begin
            // inf * 0 = NaN
            result    = CANONICAL_NAN;
            fflags[4] = 1'b1;
        end else if (a_inf || b_inf) begin
            result = {sr, 8'hFF, 23'h0};
        end else if (a_zero || b_zero) begin
            result = {sr, 31'h0};
        end else begin
            // Normal multiplication
            if ($signed(final_exp) >= 11'sd255) begin
                // Overflow
                fflags[2] = 1'b1;
                fflags[0] = 1'b1;
                case (rm)
                    3'b001: result = {sr, 8'hFE, 23'h7FFFFF};
                    3'b010: result = sr ? {1'b1,8'hFF,23'h0} : {1'b0,8'hFE,23'h7FFFFF};
                    3'b011: result = sr ? {1'b1,8'hFE,23'h7FFFFF} : {1'b0,8'hFF,23'h0};
                    default: result = {sr, 8'hFF, 23'h0};
                endcase
            end else if ($signed(final_exp) <= 11'sd0) begin
                // Underflow -> zero (simplified: flush to zero)
                result    = {sr, 31'h0};
                fflags[1] = 1'b1;
                fflags[0] = 1'b1;
            end else begin
                result    = {sr, final_exp[7:0], final_frac};
                fflags[0] = G | R | S_bit;
            end
        end
    end

endmodule

`default_nettype wire
