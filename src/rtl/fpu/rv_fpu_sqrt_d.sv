// =============================================================================
/// @file rv_fpu_sqrt_d.sv
/// @brief IEEE 754 Double-Precision Square Root (iterative, 56 cycles)
///
/// Implements FSQRT.D using a digit-recurrence (restoring) algorithm.
/// Latency: 56 cycles (normal path), 1 cycle (special cases).
///
/// Format: s(1) | e(11) | f(52), bias=1023
///
/// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_fpu_sqrt_d (
    input  wire        clk,
    input  wire        rst_n,

    input  wire  [63:0] a,
    input  wire  [2:0]  rm,
    input  wire         valid_in,

    output logic [63:0] result,
    output logic [4:0]  fflags,
    output logic        result_valid,
    output logic        fpu_busy
);

    localparam int          ITER          = 56;
    localparam logic [63:0] CANONICAL_NAN = 64'h7FF8000000000000;
    localparam logic [63:0] POS_INF       = 64'h7FF0000000000000;
    localparam logic [63:0] NEG_ZERO      = 64'h8000000000000000;

    logic         sa;
    logic [10:0]  ea;
    logic [51:0]  fra;
    assign sa  = a[63];
    assign ea  = a[62:52];
    assign fra = a[51:0];

    logic a_nan, a_snan, a_inf, a_zero, a_sub;
    assign a_nan  = (ea == 11'h7FF) && (fra != 0);
    assign a_snan = a_nan && !fra[51];
    assign a_inf  = (ea == 11'h7FF) && (fra == 0);
    assign a_zero = (ea == 0) && (fra == 0);
    assign a_sub  = (ea == 0) && (fra != 0);

    logic        is_special;
    logic [63:0] special_result;
    logic [4:0]  special_fflags;

    always_comb begin
        is_special     = 1'b0;
        special_result = 64'h0;
        special_fflags = 5'h0;

        if (a_snan) begin
            is_special        = 1'b1;
            special_result    = CANONICAL_NAN;
            special_fflags[4] = 1'b1;
        end else if (a_nan) begin
            is_special        = 1'b1;
            special_result    = CANONICAL_NAN;
        end else if (sa && !a_zero) begin
            is_special        = 1'b1;
            special_result    = CANONICAL_NAN;
            special_fflags[4] = 1'b1;
        end else if (a_zero) begin
            is_special     = 1'b1;
            special_result = sa ? NEG_ZERO : 64'h0;
        end else if (a_inf) begin
            is_special     = 1'b1;
            special_result = POS_INF;
        end
    end

    // Subnormal pre-normalization (LZC of 52-bit fraction)
    logic [51:0] sub_mant_norm;
    logic [5:0]  sub_shift;
    logic [5:0]  lz;

    always_comb begin
        // Loop-based priority encoder: scan LSB->MSB, last (highest) set bit wins.
        lz = 6'd52;
        for (int i = 0; i <= 51; i++)
            if (fra[i]) lz = 6'(51 - i);   // fra[51]->0 ... fra[0]->51

        sub_shift     = lz + 6'd1;
        sub_mant_norm = fra << sub_shift;
    end

    // FSM state registers
    logic [5:0]         iter_cnt;
    logic               computing;
    logic               special_pending;
    logic [2:0]         rm_reg;
    logic signed [11:0] exp_r_reg;    // result exp (unbiased)
    logic [111:0]       rad_reg;      // 2*ITER = 112-bit radicand
    logic [56:0]        root_reg;     // ITER+1 = 57-bit root
    logic [57:0]        rem_reg;      // ITER+2 = 58-bit remainder

    // Pre-compute initial values
    logic [52:0]        t_mant_in;
    logic signed [11:0] t_e_unb;
    logic               t_odd;
    logic [111:0]       t_rad_init;
    logic signed [11:0] t_e_res;

    always_comb begin
        if (a_sub) begin
            t_mant_in = {1'b1, sub_mant_norm};
            t_e_unb   = -12'sd1022 - $signed({6'd0, sub_shift});
        end else begin
            t_mant_in = {1'b1, fra};
            t_e_unb   = $signed({1'b0, ea}) - 12'sd1023;
        end

        t_odd = t_e_unb[0];

        t_rad_init = 112'h0;
        if (t_odd) begin
            // Odd exp: radicand = 2M, leading 1 at bit[111] → top 2 bits = {1,0}
            t_rad_init[111:58] = {t_mant_in, 1'b0};  // 54 bits
            t_e_res            = (t_e_unb - 12'sd1) >>> 1;
        end else begin
            // Even exp: radicand = M, leading 1 at bit[110] → top 2 bits = {0,1}
            t_rad_init[110:58] = t_mant_in;           // 53 bits (FIX: was [111:59])
            t_e_res            = t_e_unb >>> 1;
        end
    end

    // Iteration combinational logic
    logic [57:0] t_rem_ext;
    logic [57:0] t_sub_val;
    logic [58:0] t_trial_ext;
    logic [57:0] t_trial;
    logic        t_qbit;
    logic [56:0] root_next;
    logic [57:0] rem_next;

    always_comb begin
        t_rem_ext       = 58'h0;
        t_rem_ext[57:2] = rem_reg[55:0];
        t_rem_ext[1:0]  = rad_reg[111:110];

        t_sub_val       = 58'h0;
        t_sub_val[57:2] = root_reg[55:0];
        t_sub_val[1:0]  = 2'b01;

        t_trial_ext = {1'b0, t_rem_ext} - {1'b0, t_sub_val};
        t_trial     = t_trial_ext[57:0];
        t_qbit      = ~t_trial_ext[58];

        root_next       = 57'h0;
        root_next[56:1] = root_reg[55:0];
        root_next[0]    = t_qbit;

        rem_next = t_qbit ? t_trial : t_rem_ext;
    end

    assign fpu_busy = computing | special_pending;

    // Rounding & packing
    logic [51:0]        t_frac;
    logic               t_g, t_r, t_s;
    logic               t_rup;
    logic [53:0]        t_mant_round;
    logic signed [11:0] t_exp_final;
    logic               t_inexact;
    logic [51:0]        t_frac_final;
    logic [11:0]        t_exp_biased;

    // After ITER=56 iterations: root_next[55]=q0=leading 1 (hidden),
    // root_next[54:3]=q1..q52=fraction (52 bits), [2]=G, [1]=R, [0]=S_base.
    always_comb begin
        t_frac  = root_next[54:3];   // q1..q52 (was [55:4] - off by 1)
        t_g     = root_next[2];
        t_r     = root_next[1];
        t_s     = root_next[0] | (|rem_next);

        case (rm_reg)
            3'b000:  t_rup = t_g & (t_r | t_s | t_frac[0]);
            3'b001:  t_rup = 1'b0;
            3'b010:  t_rup = 1'b0;
            3'b011:  t_rup = t_g | t_r | t_s;
            3'b100:  t_rup = t_g;
            default: t_rup = 1'b0;
        endcase

        t_mant_round        = 54'h0;
        t_mant_round[52]    = 1'b1;
        t_mant_round[51:0]  = t_frac;
        t_mant_round        = t_mant_round + {53'h0, t_rup};

        if (t_mant_round[53]) begin
            t_exp_final  = exp_r_reg + 12'sd1;
            t_frac_final = 52'h0;
        end else begin
            t_exp_final  = exp_r_reg;
            t_frac_final = t_mant_round[51:0];
        end

        t_inexact    = t_g | t_r | t_s;
        t_exp_biased = $unsigned(t_exp_final + 12'sd1023);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            computing       <= 1'b0;
            special_pending <= 1'b0;
            result_valid    <= 1'b0;
            result          <= 64'h0;
            fflags          <= 5'h0;
            iter_cnt        <= 6'd0;
            rad_reg         <= 112'h0;
            root_reg        <= 57'h0;
            rem_reg         <= 58'h0;
            exp_r_reg       <= 12'sd0;
            rm_reg          <= 3'b000;
        end else begin
            result_valid <= 1'b0;

            if (special_pending) begin
                special_pending <= 1'b0;
                result_valid    <= 1'b1;
            end else if (!computing && valid_in && is_special) begin
                special_pending <= 1'b1;
                result          <= special_result;
                fflags          <= special_fflags;
            end else if (!computing && valid_in && !is_special) begin
                computing    <= 1'b1;
                iter_cnt     <= 6'd0;
                rm_reg       <= rm;
                exp_r_reg    <= t_e_res;
                rad_reg      <= t_rad_init;
                root_reg     <= 57'h0;
                rem_reg      <= 58'h0;
            end else if (computing) begin
                rem_reg   <= rem_next;
                root_reg  <= root_next;
                rad_reg   <= {rad_reg[109:0], 2'b00};
                iter_cnt  <= iter_cnt + 6'd1;

                if (iter_cnt == 6'(ITER - 1)) begin
                    computing    <= 1'b0;
                    result_valid <= 1'b1;
                    result       <= {1'b0, t_exp_biased[10:0], t_frac_final};
                    fflags       <= {4'h0, t_inexact};
                end
            end
        end
    end

endmodule

`default_nettype wire
