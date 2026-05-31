// =============================================================================
// @file rv_fpu_sqrt.sv
// @brief IEEE 754 Single-Precision Square Root (iterative, 27 cycles)
//
// Implements FSQRT.S using a digit-recurrence (restoring) algorithm.
// Each cycle extracts 2 bits of the radicand and produces 1 bit of root.
//
// Latency: 27 cycles from valid_in to result_valid (normal path).
//           1 cycle for special cases.
//
// fflags: {NV, DZ, OF, UF, NX}
//
// @author Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_fpu_sqrt (
    input  wire        clk,
    input  wire        rst_n,

    input  logic [31:0] a,
    input  logic [2:0]  rm,
    input  logic        valid_in,

    output logic [31:0] result,
    output logic [4:0]  fflags,
    output logic        result_valid,
    output logic        fpu_busy
);

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int          ITER          = 27;
    localparam logic [31:0] CANONICAL_NAN = 32'h7FC00000;
    localparam logic [31:0] POS_INF       = 32'h7F800000;
    localparam logic [31:0] NEG_ZERO      = 32'h80000000;

    // -------------------------------------------------------------------------
    // Field extraction
    // -------------------------------------------------------------------------
    logic        sa;
    logic [7:0]  ea;
    logic [22:0] fra;
    assign sa  = a[31];
    assign ea  = a[30:23];
    assign fra = a[22:0];

    logic a_nan, a_snan, a_inf, a_zero, a_sub;
    assign a_nan  = (ea == 8'hFF) && (fra != 23'h0);
    assign a_snan = a_nan && !fra[22];
    assign a_inf  = (ea == 8'hFF) && (fra == 23'h0);
    assign a_zero = (ea == 8'h00) && (fra == 23'h0);
    assign a_sub  = (ea == 8'h00) && (fra != 23'h0);

    // -------------------------------------------------------------------------
    // Special case detection
    // -------------------------------------------------------------------------
    logic        is_special;
    logic [31:0] special_result;
    logic [4:0]  special_fflags;

    always_comb begin
        is_special     = 1'b0;
        special_result = 32'h0;
        special_fflags = 5'h0;

        if (a_snan) begin
            is_special        = 1'b1;
            special_result    = CANONICAL_NAN;
            special_fflags[4] = 1'b1;        // NV
        end else if (a_nan) begin
            is_special        = 1'b1;
            special_result    = CANONICAL_NAN;
        end else if (sa && !a_zero) begin
            is_special        = 1'b1;
            special_result    = CANONICAL_NAN;
            special_fflags[4] = 1'b1;        // NV
        end else if (a_zero) begin
            is_special        = 1'b1;
            special_result    = sa ? NEG_ZERO : 32'h0;
        end else if (a_inf) begin
            is_special        = 1'b1;
            special_result    = POS_INF;
        end
    end

    // -------------------------------------------------------------------------
    // Subnormal pre-normalization (LZC by casez, then shift)
    // -------------------------------------------------------------------------
    logic [22:0] sub_mant_norm;
    logic [4:0]  sub_shift;
    logic [4:0]  lz;

    always_comb begin
        // Loop-based priority encoder: scan LSB->MSB, last (highest) set bit wins.
        lz = 5'd23;
        for (int i = 0; i <= 22; i++)
            if (fra[i]) lz = 5'(22 - i);   // fra[22]->0 ... fra[0]->22

        sub_shift      = lz + 5'd1;
        sub_mant_norm  = fra << sub_shift;
    end

    // -------------------------------------------------------------------------
    // FSM state registers
    // -------------------------------------------------------------------------
    logic [4:0]        iter_cnt;
    logic              computing;
    // special_pending: route special cases (NaN/negative/zero/inf) through a
    // single busy cycle so they mirror the multi-cycle path timing
    // (busy=1 for one cycle, then result_valid).  Without this the pipeline's
    // fpu_start_stall would hang waiting for a fpu_busy pulse that never came.
    logic              special_pending;
    logic [2:0]        rm_reg;
    logic signed [9:0] exp_r_reg;
    logic [53:0]       rad_reg;
    logic [26:0]       root_reg;
    logic [27:0]       rem_reg;

    // -------------------------------------------------------------------------
    // Pre-compute initial values for normal path
    // -------------------------------------------------------------------------
    logic [23:0]       t_mant_in;
    logic signed [9:0] t_e_unb;
    logic              t_odd;
    logic [53:0]       t_rad_init;
    logic signed [9:0] t_e_res;

    always_comb begin
        // Mantissa with hidden 1
        if (a_sub) begin
            t_mant_in = {1'b1, sub_mant_norm};
            t_e_unb   = -10'sd126 - $signed({5'd0, sub_shift});
        end else begin
            t_mant_in = {1'b1, fra};
            t_e_unb   = $signed({2'b00, ea}) - 10'sd127;
        end

        t_odd = t_e_unb[0];

        // Explicit part-select assignment to avoid iverilog concat-width bugs
        t_rad_init = 54'h0;
        if (t_odd) begin
            t_rad_init[53:29] = {t_mant_in, 1'b0}; // 25 bits, leading 1 at bit53
            t_e_res           = (t_e_unb - 10'sd1) >>> 1;
        end else begin
            t_rad_init[52:29] = t_mant_in;         // 24 bits, leading 1 at bit52
            t_e_res           = t_e_unb >>> 1;
        end
    end

    // -------------------------------------------------------------------------
    // Iteration logic (combinational)
    // rem' = (rem << 2) | rad[53:52]
    // trial = rem' - {root, 01}
    // if trial >= 0: qbit=1, rem<=trial, root<={root,1}
    // else         : qbit=0, rem<=rem',   root<={root,0}
    // rad <= 2
    // -------------------------------------------------------------------------
    logic [27:0] t_rem_ext;
    logic [27:0] t_sub_val;
    logic [28:0] t_trial_ext;
    logic [27:0] t_trial;
    logic        t_qbit;
    logic [26:0] root_next;
    logic [27:0] rem_next;

    always_comb begin
        // Explicit part-select for rem_ext
        t_rem_ext        = 28'h0;
        t_rem_ext[27:2]  = rem_reg[25:0];
        t_rem_ext[1:0]   = rad_reg[53:52];

        // Subtraction value: {root_reg[25:0], 2'b01}
        t_sub_val        = 28'h0;
        t_sub_val[27:2]  = root_reg[25:0];
        t_sub_val[1:0]   = 2'b01;

        t_trial_ext      = {1'b0, t_rem_ext} - {1'b0, t_sub_val};
        t_trial          = t_trial_ext[27:0];
        t_qbit           = ~t_trial_ext[28];

        // root_next = {root_reg[25:0], t_qbit} (27 bits)
        root_next        = 27'h0;
        root_next[26:1]  = root_reg[25:0];
        root_next[0]     = t_qbit;

        rem_next         = t_qbit ? t_trial : t_rem_ext;
    end

    assign fpu_busy = computing | special_pending;

    // -------------------------------------------------------------------------
    // Rounding & packing (uses root_next / rem_next at final cycle)
    // root_next[26]   = leading 1
    // root_next[25:3] = 23-bit fraction
    // root_next[2]   = guard
    // root_next[1]   = round
    // root_next[0]   = sticky base
    // rem_next != 0  => additional sticky
    // -------------------------------------------------------------------------
    logic [22:0]       t_frac;
    logic              t_g, t_r, t_s;
    logic              t_rup;
    logic [24:0]       t_mant_round; // 25 bits to detect overflow
    logic signed [9:0] t_exp_final;
    logic              t_inexact;
    logic [22:0]       t_frac_final;

    always_comb begin
        t_frac = root_next[25:3];
        t_g    = root_next[2];
        t_r    = root_next[1];
        t_s    = root_next[0] | (|rem_next);

        case (rm_reg)
            3'b000:  t_rup = t_g & (t_r | t_s | t_frac[0]); // RNE
            3'b001:  t_rup = 1'b0;                          // RTZ
            3'b010:  t_rup = 1'b0;                          // RDN (>=0)
            3'b011:  t_rup = t_g | t_r | t_s;               // RUP
            3'b100:  t_rup = t_g;                           // RMM
            default: t_rup = 1'b0;
        endcase

        // {hidden 1, fraction} + rup
        // Use part-select to be safe
        t_mant_round        = 25'h0;
        t_mant_round[23]    = 1'b1; // hidden 1
        t_mant_round[22:0]  = t_frac;
        t_mant_round        = t_mant_round + {24'h0, t_rup};

        if (t_mant_round[24]) begin
            // Rounding overflow: 1.111...1 + 1 = 10.000...0
            t_exp_final  = exp_r_reg + 10'sd1;
            t_frac_final = 23'h0;
        end else begin
            t_exp_final  = exp_r_reg;
            t_frac_final = t_mant_round[22:0];
        end

        t_inexact = t_g | t_r | t_s;
    end

    // -------------------------------------------------------------------------
    // Sequential
    // -------------------------------------------------------------------------
    logic [9:0] t_exp_biased;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            computing       <= 1'b0;
            special_pending <= 1'b0;
            result_valid    <= 1'b0;
            result          <= 32'h0;
            fflags          <= 5'h0;
            iter_cnt        <= 5'd0;
            rad_reg         <= 54'h0;
            root_reg        <= 27'h0;
            rem_reg         <= 28'h0;
            exp_r_reg       <= 10'sd0;
            rm_reg          <= 3'b000;
        end else begin
            result_valid <= 1'b0;

            if (special_pending) begin
                // Second cycle of a special case: emit the latched result.
                special_pending <= 1'b0;
                result_valid    <= 1'b1;

            end else if (!computing && valid_in && is_special) begin
                // First cycle of a special case: latch result, raise busy
                // (special_pending) for one cycle so timing matches the
                // multi-cycle iteration path.
                special_pending <= 1'b1;
                result          <= special_result;
                fflags          <= special_fflags;

            end else if (!computing && valid_in && !is_special) begin
                // Start iteration
                computing    <= 1'b1;
                iter_cnt     <= 5'd0;
                rm_reg       <= rm;
                exp_r_reg    <= t_e_res;
                rad_reg      <= t_rad_init;
                root_reg     <= 27'h0;
                rem_reg      <= 28'h0;

            end else if (computing) begin
                // Iteration step
                rem_reg   <= rem_next;
                root_reg  <= root_next;
                // Explicit shift via part-select concat
                rad_reg   <= {rad_reg[51:0], 2'b00};
                iter_cnt  <= iter_cnt + 5'd1;

                // Final cycle: round & emit
                if (iter_cnt == 5'(ITER - 1)) begin
                    computing    <= 1'b0;
                    result_valid <= 1'b1;

                    // Compute biased exponent: t_exp_final + 127
                    // t_exp_final is signed 10-bit, biased fits in 8 bits for normal results
                    t_exp_biased = $unsigned(t_exp_final + 10'sd127);

                    result <= {1'b0, t_exp_biased[7:0], t_frac_final};
                    fflags <= {4'h0, t_inexact};

                    // $display("FINAL DEBUG: iter=%d", iter_cnt);
                    // $display("  root_reg=0x%h root_next=0x%h", root_reg, root_next);
                    // $display("  rem_reg=0x%h rem_next=0x%h", rem_reg, rem_next);
                    // $display("  rem_ext=0x%h sub_val=0x%h", t_rem_ext, t_sub_val);
                    // $display("  t_qbit=%b t_trial=0x%h", t_qbit, t_trial);
                    // $display("  t_frac=0x%h g=%b r=%b s_base=%b s=%b", t_frac, t_g, t_r, root_next[0], t_s);
                    // $display("  t_rup=%b t_mant_round=0x%h", t_rup, t_mant_round);
                end
            end
        end
    end

endmodule

`default_nettype wire

