// =============================================================================
/// @file rv_fpu_div.sv
/// @brief IEEE 754 Single-Precision Divider (iterative, 27 cycles)
///
/// Implements FDIV.S using a non-restoring radix-2 digit recurrence algorithm.
/// The pipeline stalls (fpu_busy=1) while division is in progress.
///
/// Latency: 27 cycles from valid_in to result_valid.
///
/// fflags: {NV, DZ, OF, UF, NX}
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_fpu_div (
    input  wire        clk,
    input  wire        rst_n,

    input  logic [31:0] a,           // Dividend
    input  logic [31:0] b,           // Divisor
    input  logic [2:0]  rm,          // Rounding mode
    input  logic        valid_in,     // Start division (1 cycle pulse)

    output logic [31:0] result,
    output logic [4:0]  fflags,
    output logic        result_valid, // Result ready (1 cycle pulse)
    output logic        fpu_busy      // Stall pipeline while computing
);

    localparam int ITER = 27;          // Iterations for 24-bit quotient + 3 GRS bits
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
    assign sr  = sa ^ sb;

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

    // Special case detection
    logic is_special;
    logic [31:0] special_result;
    logic [4:0]  special_fflags;

    always_comb begin
        is_special     = 1'b0;
        special_result = 32'h0;
        special_fflags = 5'h0;

        if (a_nan || b_nan) begin
            is_special        = 1'b1;
            special_result    = CANONICAL_NAN;
            special_fflags[4] = a_snan | b_snan;
        end else if (a_inf && b_inf) begin
            is_special        = 1'b1;
            special_result    = CANONICAL_NAN;
            special_fflags[4] = 1'b1;
        end else if (a_zero && b_zero) begin
            is_special        = 1'b1;
            special_result    = CANONICAL_NAN;
            special_fflags[4] = 1'b1;
        end else if (b_zero) begin
            is_special        = 1'b1;
            special_result    = {sr, 8'hFF, 23'h0};
            special_fflags[3] = 1'b1;  // DZ
        end else if (a_zero || b_inf) begin
            is_special     = 1'b1;
            special_result = {sr, 31'h0};
        end else if (a_inf) begin
            is_special     = 1'b1;
            special_result = {sr, 8'hFF, 23'h0};
        end
    end

    // -------------------------------------------------------------------------
    // FSM for iterative division
    // -------------------------------------------------------------------------
    logic [4:0]  iter_cnt;
    logic        computing;
    // special_pending: route special cases (NaN/Inf/zero/div-by-zero) through a
    // single busy cycle so they mirror the multi-cycle path timing
    // (busy=1 for one cycle, then result_valid).  Without this the pipeline's
    // fpu_start_stall would hang waiting for a fpu_busy pulse that never came.
    logic        special_pending;

    logic [24:0] dividend_reg;  // unused after init but kept for clarity
    logic [24:0] divisor_reg;
    logic [26:0] quotient_reg;
    logic [25:0] remainder_reg;
    logic [2:0]  rm_reg;
    logic        sr_reg;
    logic [9:0]  exp_result_reg;

    // Temporaries (module-level to avoid iverilog local-decl restrictions)
    logic [9:0]  t_ea_e, t_eb_e;
    logic [10:0] t_er;
    logic [25:0] t_trial;
    logic        t_qbit;
    logic [9:0]  t_adj_exp;
    logic [22:0] t_frac_out;
    logic        t_gbit, t_rbit, t_sbit;
    logic        t_rup;
    logic [23:0] t_mant_r;

    assign fpu_busy = computing | special_pending;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            computing       <= 1'b0;
            special_pending <= 1'b0;
            result_valid    <= 1'b0;
            iter_cnt        <= 5'd0;
            result          <= 32'h0;
            fflags          <= 5'h0;
        end else begin
            result_valid <= 1'b0;

            if (valid_in && !is_special && !computing) begin
                computing <= 1'b1;
                iter_cnt  <= 5'd0;
                rm_reg    <= rm;
                sr_reg    <= sr;

                // Effective exponents for subnormals
                t_ea_e = a_sub ? 10'd1 : {2'b00, ea};
                t_eb_e = b_sub ? 10'd1 : {2'b00, eb};

                // Result exponent: ea - eb + 127
                t_er = {1'b0, t_ea_e} + (~{1'b0, t_eb_e} + 11'd1) + 11'd127;
                exp_result_reg <= t_er[9:0];

                dividend_reg  <= {1'b0, !a_sub, fra};
                divisor_reg   <= {1'b0, !b_sub, frb};
                // Work in the doubled-remainder (R = 2*rem) domain so the
                // initial value R_0 = N is an exact integer.  The previous
                // N/2 init ({3'b000,!a_sub,fra[22:1]}) dropped fra[0], which
                // introduced a 1-ULP error and spuriously set NX for exact
                // divisions (e.g. pi / 1.0).
                remainder_reg <= {2'b00, !a_sub, fra};
                quotient_reg  <= 27'h0;

            end else if (computing) begin
                // Restoring step in the doubled-remainder (R = 2*rem) domain.
                // Compare BEFORE shifting:  q = (R >= D),
                //   R_next = q ? 2*(R - D) : 2*R
                // This is algebraically identical to the old "2*rem - D" form
                // (same quotient-bit sequence) but keeps full precision because
                // R_0 = N is exact (no fra[0] truncation).
                t_trial = remainder_reg - {1'b0, divisor_reg};
                t_qbit  = !t_trial[25];  // 1 if R >= D (no borrow)

                if (t_qbit) begin
                    remainder_reg <= t_trial << 1;
                end else begin
                    remainder_reg <= remainder_reg << 1;
                end

                quotient_reg <= {quotient_reg[25:0], t_qbit};
                iter_cnt     <= iter_cnt + 5'd1;

                if (iter_cnt == ITER - 1) begin
                    computing    <= 1'b0;
                    result_valid <= 1'b1;

                    // After 27 iterations, the full 27-bit quotient is
                    // {quotient_reg[25:0], t_qbit}.  The OLD quotient_reg only
                    // has bits 0..25 populated (q0 at bit 25, not bit 26).
                    // Use the updated value for extraction.
                    //   updated[26] = quotient_reg[25]  (leading 1 for normalized)
                    //   updated[25:3] = quotient_reg[24:2]  (23-bit fraction)
                    //   updated[2:0] = {quotient_reg[1], quotient_reg[0], t_qbit}
                    if (quotient_reg[25]) begin
                        // Normalized: leading 1 at bit 26 of updated quotient
                        t_adj_exp  = exp_result_reg;
                        t_frac_out = quotient_reg[24:2];
                        t_gbit     = quotient_reg[1];
                        t_rbit     = quotient_reg[0];
                        t_sbit     = t_qbit | (|remainder_reg);
                    end else begin
                        // Unnormalized: shift up by 1, exp-1
                        t_adj_exp  = exp_result_reg - 10'd1;
                        t_frac_out = quotient_reg[23:1];
                        t_gbit     = quotient_reg[0];
                        t_rbit     = t_qbit;
                        t_sbit     = |remainder_reg;
                    end

                    // Round
                    case (rm_reg)
                        3'b000: t_rup = t_gbit & (t_rbit | t_sbit | t_frac_out[0]);
                        3'b001: t_rup = 1'b0;
                        3'b010: t_rup = (t_gbit | t_rbit | t_sbit) & sr_reg;
                        3'b011: t_rup = (t_gbit | t_rbit | t_sbit) & !sr_reg;
                        3'b100: t_rup = t_gbit;
                        default: t_rup = 1'b0;
                    endcase

                    t_mant_r = {1'b0, t_frac_out} + {23'h0, t_rup};
                    if (t_mant_r[23]) begin
                        t_adj_exp  = t_adj_exp + 10'd1;
                        t_frac_out = t_mant_r[22:0];  // = 0 on overflow
                    end else begin
                        t_frac_out = t_mant_r[22:0];
                    end

                    // Overflow / underflow
                    if ($signed(t_adj_exp) >= 10'sd255) begin
                        fflags <= 5'b00101;  // OF+NX
                        result <= {sr_reg, 8'hFF, 23'h0};
                    end else if ($signed(t_adj_exp) <= 10'sd0) begin
                        fflags <= 5'b00011;  // UF+NX
                        result <= {sr_reg, 31'h0};
                    end else begin
                        fflags <= {4'h0, (t_gbit | t_rbit | t_sbit)};
                        result <= {sr_reg, t_adj_exp[7:0], t_frac_out};
                    end
                end

            end else if (special_pending) begin
                // Second cycle of a special case: emit the latched result.
                special_pending <= 1'b0;
                result_valid    <= 1'b1;
            end else if (valid_in && is_special) begin
                // First cycle of a special case: latch result, raise busy
                // (special_pending) for one cycle so timing matches the
                // multi-cycle iteration path.
                special_pending <= 1'b1;
                result          <= special_result;
                fflags          <= special_fflags;
            end
        end
    end

endmodule

`default_nettype wire
