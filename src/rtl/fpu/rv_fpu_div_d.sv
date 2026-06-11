// =============================================================================
/// @file rv_fpu_div_d.sv
/// @brief IEEE 754 Double-Precision Divider (iterative, 56 cycles)
///
/// Implements FDIV.D using a non-restoring radix-2 digit recurrence algorithm.
/// Latency: 56 cycles from valid_in to result_valid.
///
/// Format: s(1) | e(11) | f(52), bias=1023
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_fpu_div_d (
    input  wire        clk,
    input  wire        rst_n,

    input  wire  [63:0] a,
    input  wire  [63:0] b,
    input  wire  [2:0]  rm,
    input  wire         valid_in,

    output logic [63:0] result,
    output logic [4:0]  fflags,
    output logic        result_valid,
    output logic        fpu_busy
);

    localparam int          ITER          = 56;
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

    logic        is_special;
    logic [63:0] special_result;
    logic [4:0]  special_fflags;

    always_comb begin
        is_special     = 1'b0;
        special_result = 64'h0;
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
            special_result    = {sr, 11'h7FF, 52'h0};
            special_fflags[3] = 1'b1;
        end else if (a_zero || b_inf) begin
            is_special     = 1'b1;
            special_result = {sr, 63'h0};
        end else if (a_inf) begin
            is_special     = 1'b1;
            special_result = {sr, 11'h7FF, 52'h0};
        end
    end

    // FSM
    logic [5:0]  iter_cnt;
    logic        computing;
    logic        special_pending;

    logic [53:0]  divisor_reg;
    logic [55:0]  remainder_reg;  // 2*rem domain, 54+2 bits
    logic [56:0]  quotient_reg;   // ITER+1 bits
    logic [2:0]   rm_reg;
    logic         sr_reg;
    logic [12:0]  exp_result_reg;

    // Temporaries
    logic [12:0]  t_ea_e, t_eb_e;
    logic [13:0]  t_er;
    logic [55:0]  t_trial;
    logic         t_qbit;
    logic [12:0]  t_adj_exp;
    logic [51:0]  t_frac_out;
    logic         t_gbit, t_rbit, t_sbit;
    logic         t_rup;
    logic [52:0]  t_mant_r;

    assign fpu_busy = computing | special_pending;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            computing       <= 1'b0;
            special_pending <= 1'b0;
            result_valid    <= 1'b0;
            iter_cnt        <= 6'd0;
            result          <= 64'h0;
            fflags          <= 5'h0;
        end else begin
            result_valid <= 1'b0;

            if (valid_in && !is_special && !computing) begin
                computing <= 1'b1;
                iter_cnt  <= 6'd0;
                rm_reg    <= rm;
                sr_reg    <= sr;

                t_ea_e = a_sub ? 13'd1 : {2'b00, ea};
                t_eb_e = b_sub ? 13'd1 : {2'b00, eb};

                // exp_a - exp_b + bias (1023)
                t_er = {1'b0, t_ea_e} + (~{1'b0, t_eb_e} + 14'd1) + 14'd1023;
                exp_result_reg <= t_er[12:0];

                divisor_reg   <= {1'b0, !b_sub, frb};
                remainder_reg <= {2'b00, !a_sub, fra};
                quotient_reg  <= 57'h0;

            end else if (computing) begin
                // Doubled-remainder domain
                t_trial = remainder_reg - {1'b0, divisor_reg};
                t_qbit  = !t_trial[55];

                if (t_qbit) begin
                    remainder_reg <= t_trial << 1;
                end else begin
                    remainder_reg <= remainder_reg << 1;
                end

                quotient_reg <= {quotient_reg[55:0], t_qbit};
                iter_cnt     <= iter_cnt + 6'd1;

                if (iter_cnt == 6'(ITER - 1)) begin
                    computing    <= 1'b0;
                    result_valid <= 1'b1;

                    // After ITER=56 cycles, quotient_reg[54]=q0 (leading 1 for normalized).
                    // q0 at bit[54], q1..q52 at [53:2], G=q53 at [1], R=q54 at [0], S=t_qbit|...
                    if (quotient_reg[54]) begin
                        t_adj_exp  = exp_result_reg;
                        t_frac_out = quotient_reg[53:2];
                        t_gbit     = quotient_reg[1];
                        t_rbit     = quotient_reg[0];
                        t_sbit     = t_qbit | (|remainder_reg);
                    end else begin
                        t_adj_exp  = exp_result_reg - 13'd1;
                        t_frac_out = quotient_reg[52:1];
                        t_gbit     = quotient_reg[0];
                        t_rbit     = t_qbit;
                        t_sbit     = |remainder_reg;
                    end

                    case (rm_reg)
                        3'b000: t_rup = t_gbit & (t_rbit | t_sbit | t_frac_out[0]);
                        3'b001: t_rup = 1'b0;
                        3'b010: t_rup = (t_gbit | t_rbit | t_sbit) & sr_reg;
                        3'b011: t_rup = (t_gbit | t_rbit | t_sbit) & !sr_reg;
                        3'b100: t_rup = t_gbit;
                        default: t_rup = 1'b0;
                    endcase

                    t_mant_r = {1'b0, t_frac_out} + {52'h0, t_rup};
                    if (t_mant_r[52]) begin
                        t_adj_exp  = t_adj_exp + 13'd1;
                        t_frac_out = t_mant_r[51:0];
                    end else begin
                        t_frac_out = t_mant_r[51:0];
                    end

                    if ($signed(t_adj_exp) >= 13'sd2047) begin
                        fflags <= 5'b00101;
                        result <= {sr_reg, 11'h7FF, 52'h0};
                    end else if ($signed(t_adj_exp) <= 13'sd0) begin
                        fflags <= 5'b00011;
                        result <= {sr_reg, 63'h0};
                    end else begin
                        fflags <= {4'h0, (t_gbit | t_rbit | t_sbit)};
                        result <= {sr_reg, t_adj_exp[10:0], t_frac_out};
                    end
                end

            end else if (special_pending) begin
                special_pending <= 1'b0;
                result_valid    <= 1'b1;
            end else if (valid_in && is_special) begin
                special_pending <= 1'b1;
                result          <= special_result;
                fflags          <= special_fflags;
            end
        end
    end

endmodule

`default_nettype wire
