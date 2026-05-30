// =============================================================================
/// @file rv_fpu_mul_d.sv
/// @brief IEEE 754 Double-Precision Multiplier (combinational)
///
/// Implements FMUL.D.  Also used internally by rv_fpu.sv for FMADD.D family.
///
/// Format: s(1) | e(11) | f(52), bias=1023
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_fpu_mul_d (
    input  logic [63:0] a,
    input  logic [63:0] b,
    input  logic [2:0]  rm,
    output logic [63:0] result,
    output logic [4:0]  fflags
);

    localparam logic [63:0] CANONICAL_NAN = 64'h7FF8000000000000;

    logic         sa, sb, sr;
    logic [10:0]  ea, eb;
    logic [51:0]  fra, frb;

    assign sa  = a[63];
    assign ea  = a[62:52];
    assign fra = a[51:0];
    assign sb  = b[63];
    assign eb  = b[62:52];
    assign frb = b[51:0];
    assign sr  = sa ^ sb;

    logic a_nan, b_nan, a_snan, b_snan;
    logic a_inf, b_inf, a_zero, b_zero, a_sub, b_sub;

    assign a_nan  = (ea == 11'h7FF) && (fra != 0);
    assign b_nan  = (eb == 11'h7FF) && (frb != 0);
    assign a_snan = a_nan && !fra[51];
    assign b_snan = b_nan && !frb[51];
    assign a_inf  = (ea == 11'h7FF) && (fra == 0);
    assign b_inf  = (eb == 11'h7FF) && (frb == 0);
    assign a_zero = (ea == 0) && (fra == 0);
    assign b_zero = (eb == 0) && (frb == 0);
    assign a_sub  = (ea == 0) && (fra != 0);
    assign b_sub  = (eb == 0) && (frb != 0);

    // 53-bit mantissas
    logic [52:0] ma, mb;
    assign ma = {!a_sub && !a_zero, fra};
    assign mb = {!b_sub && !b_zero, frb};

    // Multiply: 53x53 -> 106-bit product
    logic [105:0] prod;
    assign prod = ma * mb;

    // Exponent sum: (ea-1023) + (eb-1023) + 1023 = ea + eb - 1023
    logic [12:0] ea_eff, eb_eff;
    assign ea_eff = a_sub ? 13'd1 : {2'b00, ea};
    assign eb_eff = b_sub ? 13'd1 : {2'b00, eb};

    logic signed [13:0] exp_sum;
    assign exp_sum = {1'b0, ea_eff} + {1'b0, eb_eff} - 14'sd1023;

    // Normalize: product in [1.0, 4.0)
    // If prod[105]=1: leading 1 at bit 105 -> fraction = prod[104:53], GRS = prod[52:50]|...
    // If prod[104]=1: leading 1 at bit 104 -> fraction = prod[103:52], GRS = prod[51:49]|...
    logic [51:0] norm_frac;
    logic        G, R, S_bit;
    logic [13:0] norm_exp;

    always @(*) begin
        norm_exp  = 14'h0;
        norm_frac = 52'h0;
        G         = 1'b0;
        R         = 1'b0;
        S_bit     = 1'b0;

        if (prod[105]) begin
            norm_frac = prod[104:53];
            G         = prod[52];
            R         = prod[51];
            S_bit     = |prod[50:0];
            norm_exp  = exp_sum[13:0] + 14'd1;
        end else begin
            norm_frac = prod[103:52];
            G         = prod[51];
            R         = prod[50];
            S_bit     = |prod[49:0];
            norm_exp  = exp_sum[13:0];
        end
    end

    // Round
    logic round_up;
    always @(*) begin
        case (rm)
            3'b000: round_up = G & (R | S_bit | norm_frac[0]);
            3'b001: round_up = 1'b0;
            3'b010: round_up = (G | R | S_bit) & sr;
            3'b011: round_up = (G | R | S_bit) & !sr;
            3'b100: round_up = G;
            default: round_up = 1'b0;
        endcase
    end

    logic [52:0] mant_rounded;
    assign mant_rounded = {1'b0, norm_frac} + {52'h0, round_up};

    logic [13:0] final_exp;
    logic [51:0] final_frac;
    always @(*) begin
        if (mant_rounded[52]) begin
            final_exp  = norm_exp + 14'd1;
            final_frac = mant_rounded[52:1];
        end else begin
            final_exp  = norm_exp;
            final_frac = mant_rounded[51:0];
        end
    end

    always @(*) begin
        result = 64'h0;
        fflags = 5'h0;

        if (a_nan || b_nan) begin
            result    = CANONICAL_NAN;
            fflags[4] = a_snan | b_snan;
        end else if ((a_inf && b_zero) || (b_inf && a_zero)) begin
            result    = CANONICAL_NAN;
            fflags[4] = 1'b1;
        end else if (a_inf || b_inf) begin
            result = {sr, 11'h7FF, 52'h0};
        end else if (a_zero || b_zero) begin
            result = {sr, 63'h0};
        end else begin
            if ($signed(final_exp) >= 14'sd2047) begin
                fflags[2] = 1'b1;
                fflags[0] = 1'b1;
                case (rm)
                    3'b001: result = {sr, 11'h7FE, 52'hFFFFFFFFFFFFF};
                    3'b010: result = sr ? {1'b1,11'h7FF,52'h0} : {1'b0,11'h7FE,52'hFFFFFFFFFFFFF};
                    3'b011: result = sr ? {1'b1,11'h7FE,52'hFFFFFFFFFFFFF} : {1'b0,11'h7FF,52'h0};
                    default: result = {sr, 11'h7FF, 52'h0};
                endcase
            end else if ($signed(final_exp) <= 14'sd0) begin
                result    = {sr, 63'h0};
                fflags[1] = 1'b1;
                fflags[0] = 1'b1;
            end else begin
                result    = {sr, final_exp[10:0], final_frac};
                fflags[0] = G | R | S_bit;
            end
        end
    end

endmodule

`default_nettype wire
