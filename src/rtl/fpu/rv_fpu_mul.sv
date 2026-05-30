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
    // Normalize: locate the leading 1 of the 48-bit product and left-align it
    // to bit 47.  For two normalized inputs the leading 1 sits at bit 47 or 46
    // (1-bit shift), but a subnormal operand has no implicit leading 1, so its
    // 24-bit significand carries leading zeros and the product's leading 1 can
    // fall well below bit 46.  That demands a multi-bit left shift.
    //
    // The leading-zero count is computed with an explicit if-else priority
    // encoder (NOT casez: iverilog mishandles casez on wide part-selects, see
    // rv_fpu_add_d.sv).  After shifting, the leading 1 is at bit 47:
    //   prod_norm[47]   = hidden leading 1
    //   prod_norm[46:24]= fraction[22:0]
    //   prod_norm[23]   = G, [22] = R, [21:0] = sticky
    // Exponent: leading 1 originally at bit (47 - prod_lzc), so relative to the
    // bit-46 reference used by exp_sum the bias is +1 - prod_lzc.
    // -------------------------------------------------------------------------
    logic [5:0] prod_lzc;   // leading-zero count of prod[47:0] (0..47)
    always_comb begin
        if      (prod[47]) prod_lzc = 6'd0;
        else if (prod[46]) prod_lzc = 6'd1;
        else if (prod[45]) prod_lzc = 6'd2;
        else if (prod[44]) prod_lzc = 6'd3;
        else if (prod[43]) prod_lzc = 6'd4;
        else if (prod[42]) prod_lzc = 6'd5;
        else if (prod[41]) prod_lzc = 6'd6;
        else if (prod[40]) prod_lzc = 6'd7;
        else if (prod[39]) prod_lzc = 6'd8;
        else if (prod[38]) prod_lzc = 6'd9;
        else if (prod[37]) prod_lzc = 6'd10;
        else if (prod[36]) prod_lzc = 6'd11;
        else if (prod[35]) prod_lzc = 6'd12;
        else if (prod[34]) prod_lzc = 6'd13;
        else if (prod[33]) prod_lzc = 6'd14;
        else if (prod[32]) prod_lzc = 6'd15;
        else if (prod[31]) prod_lzc = 6'd16;
        else if (prod[30]) prod_lzc = 6'd17;
        else if (prod[29]) prod_lzc = 6'd18;
        else if (prod[28]) prod_lzc = 6'd19;
        else if (prod[27]) prod_lzc = 6'd20;
        else if (prod[26]) prod_lzc = 6'd21;
        else if (prod[25]) prod_lzc = 6'd22;
        else if (prod[24]) prod_lzc = 6'd23;
        else if (prod[23]) prod_lzc = 6'd24;
        else if (prod[22]) prod_lzc = 6'd25;
        else if (prod[21]) prod_lzc = 6'd26;
        else if (prod[20]) prod_lzc = 6'd27;
        else if (prod[19]) prod_lzc = 6'd28;
        else if (prod[18]) prod_lzc = 6'd29;
        else if (prod[17]) prod_lzc = 6'd30;
        else if (prod[16]) prod_lzc = 6'd31;
        else if (prod[15]) prod_lzc = 6'd32;
        else if (prod[14]) prod_lzc = 6'd33;
        else if (prod[13]) prod_lzc = 6'd34;
        else if (prod[12]) prod_lzc = 6'd35;
        else if (prod[11]) prod_lzc = 6'd36;
        else if (prod[10]) prod_lzc = 6'd37;
        else if (prod[9])  prod_lzc = 6'd38;
        else if (prod[8])  prod_lzc = 6'd39;
        else if (prod[7])  prod_lzc = 6'd40;
        else if (prod[6])  prod_lzc = 6'd41;
        else if (prod[5])  prod_lzc = 6'd42;
        else if (prod[4])  prod_lzc = 6'd43;
        else if (prod[3])  prod_lzc = 6'd44;
        else if (prod[2])  prod_lzc = 6'd45;
        else if (prod[1])  prod_lzc = 6'd46;
        else               prod_lzc = 6'd47;  // prod[0] or prod==0 (unreachable here)
    end

    logic [47:0] prod_norm;
    assign prod_norm = prod << prod_lzc;   // leading 1 left-aligned to bit 47

    logic [22:0] norm_frac;
    logic        G, R, S_bit;
    logic [10:0] norm_exp;

    always_comb begin
        norm_frac = prod_norm[46:24];
        G         = prod_norm[23];
        R         = prod_norm[22];
        S_bit     = |prod_norm[21:0];
        // exp_sum references the bit-46 leading position; shift moves it to 47
        norm_exp  = exp_sum[10:0] + 11'd1 - {5'd0, prod_lzc};
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
