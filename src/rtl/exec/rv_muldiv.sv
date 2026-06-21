// =============================================================================
// rv_muldiv.sv - M-Extension Multiply/Divide Unit
// =============================================================================
// Implements RV32M / RV64M operations.
//
//   * Multiply (MUL/MULH/MULHSU/MULHU/MULW) : single-cycle COMBINATIONAL.
//     Synthesis maps these to DSP blocks.  (Pipelining is future work C-2c.)
//
//   * Divide  (DIV/DIVU/REM/REMU + W-types) : MULTI-CYCLE radix-2 restoring
//     divider.  A single-cycle combinational 64-bit divider was the #1 FPGA
//     timing bottleneck (WNS = -226 ns on xc7z020-1; the DIV/REM ripple-carry
//     chain dominated all top critical paths, capping Fmax at ~4 MHz).  The
//     sequential divider trades latency for a short logic path.
//
// All RISC-V M-extension corner cases are handled (same results as before):
//   div/rem by zero  : result per spec (-1 / dividend)
//   signed overflow  : DIV(INT_MIN,-1)=INT_MIN, REM(INT_MIN,-1)=0
//
// Divider handshake (mirrors rv_fpu's FDIV/FSQRT busy protocol):
//   valid_in : 1 when a DIVIDE op is in EX and may start (the caller gates this
//              with !div_busy && !div_was_busy and a one-cycle start stall so the
//              instruction is held in ID/EX).  Asserted only for divide ops.
//   div_busy : high while the iteration is in progress.  The EX-stage pipeline
//              register captures `result` on the cycle div_busy DROPS.
// For multiply ops valid_in stays 0, div_busy stays 0, and `result` is the
// purely combinational product (1-cycle, as before).
//
// Interface note: a divide held in EX past completion by an UNRELATED stall may
// re-trigger (caller's div_was_busy only masks one cycle).  A restart recomputes
// the SAME quotient from the same (frozen) operands, so it is idempotent.
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_muldiv
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire  [XLEN-1:0]  rs1_data,
    input  wire  [XLEN-1:0]  rs2_data,
    input  wire  muldiv_op_t op,
    input  wire              valid_in,   // start a DIVIDE op (caller-gated)
    output logic [XLEN-1:0]  result,
    output logic             div_busy    // iteration in progress
);

    localparam int WBITS = 32;                 // W-type operand width
    localparam int CW    = $clog2(XLEN + 1);   // iteration counter width

    // =========================================================================
    // Op classification (combinational; `op` is stable while the instruction
    // is held in EX, so these are also valid during the finalize cycle).
    // =========================================================================
    logic is_div_op, is_w_op, is_signed_op, is_rem_op;
    always_comb begin
        is_div_op    = 1'b0;
        is_w_op      = 1'b0;
        is_signed_op = 1'b0;
        is_rem_op    = 1'b0;
        unique case (op)
            MDU_DIV:    begin is_div_op=1; is_signed_op=1;                  end
            MDU_DIVU:   begin is_div_op=1;                                  end
            MDU_REM:    begin is_div_op=1; is_signed_op=1; is_rem_op=1;     end
            MDU_REMU:   begin is_div_op=1;                 is_rem_op=1;     end
            MDU_DIVW:   begin is_div_op=1; is_signed_op=1; is_w_op=1;       end
            MDU_DIVUW:  begin is_div_op=1;                 is_w_op=1;       end
            MDU_REMW:   begin is_div_op=1; is_signed_op=1; is_rem_op=1; is_w_op=1; end
            MDU_REMUW:  begin is_div_op=1;                 is_rem_op=1; is_w_op=1; end
            default:    ; // multiply ops: all flags 0
        endcase
    end

    // =========================================================================
    // Multiply (pipelined: input + output registers; 50MHz step 6)
    //
    // The single-cycle DSP multiply on a load-forwarded operand
    //   D$ load -> EX forward -> rsN_data -> 64x64 multiply (+ MULH summation)
    //   -> result -> ex_mem_alu_result
    // was the post-step5 FPGA critical path (~33.5 ns).  Pipeline it like the FPU
    // combinational ops: register the operands (stage A) and the products
    // (stage B) so the DSP sits behind an input AND an output register (the
    // canonical high-Fmax DSP48E1 config), and run the multiply through the same
    // busy / start-stall handshake as the divider (MUL_LAT busy cycles; the
    // EX/MEM register captures `result` when busy drops).  Free-running capture
    // is safe and adds the fixed latency only: the operands are held stable in
    // ID/EX across the stall (rv_core refreshes id_ex_*_data with the resolved
    // forward each stall cycle), so both stages settle by the capture cycle --
    // exactly how the FPU misc operand/result stages settle within COMB_LAT.
    // This is a LATENCY change for MUL (it now occupies EX for MUL_LAT+ cycles
    // like a short divide), validated by result equivalence, not structural no-op.
    // =========================================================================
    localparam int unsigned MUL_LAT = 2;   // multiply busy cycles

    // Stage A: registered operands feeding the multipliers (DSP input register).
    logic [XLEN-1:0]   rs1_q, rs2_q;
    logic [2*XLEN-1:0] rs1_sx, rs2_sx;  // sign-extended (from registered operands)
    logic [2*XLEN-1:0] rs1_ux, rs2_ux;  // zero-extended

    assign rs1_sx = {{XLEN{rs1_q[XLEN-1]}}, rs1_q};
    assign rs2_sx = {{XLEN{rs2_q[XLEN-1]}}, rs2_q};
    assign rs1_ux = {{XLEN{1'b0}},           rs1_q};
    assign rs2_ux = {{XLEN{1'b0}},           rs2_q};

    logic [2*XLEN-1:0] prod_ss;   // signed   x signed   (combinational)
    logic [2*XLEN-1:0] prod_su;   // signed   x unsigned (MULHSU)
    logic [2*XLEN-1:0] prod_uu;   // unsigned x unsigned

    assign prod_ss = $signed(rs1_sx) * $signed(rs2_sx);
    assign prod_su = $signed(rs1_sx) * $signed(rs2_ux);  // rs2_ux MSB=0 -> non-neg
    assign prod_uu = rs1_ux * rs2_ux;

    // Stage B: registered products feeding the result select (DSP output register).
    logic [2*XLEN-1:0] prod_ss_q, prod_su_q, prod_uu_q;

    // Result select from the REGISTERED products.  The low half of a product is
    // independent of operand sign / upper bits, so MUL/MULW read prod_uu_q.
    logic [XLEN-1:0] mul_result;
    always_comb begin
        mul_result = '0;
        unique case (op)
            MDU_MUL:    mul_result = prod_uu_q[XLEN-1:0];
            MDU_MULH:   mul_result = prod_ss_q[2*XLEN-1:XLEN];
            MDU_MULHSU: mul_result = prod_su_q[2*XLEN-1:XLEN];
            MDU_MULHU:  mul_result = prod_uu_q[2*XLEN-1:XLEN];
            MDU_MULW:   mul_result = XLEN'($signed(prod_uu_q[WBITS-1:0]));
            default:    mul_result = '0;  // divide ops use div_result mux below
        endcase
    end

    // Multiply busy window (mirrors the divider handshake; MUL_LAT cycles).  Free-
    // running operand/product registers below; counter starts on a multiply
    // valid_in and counts down to the capture cycle (busy falling).
    logic [1:0] mul_cnt;
    logic       mul_busy;
    assign mul_busy = (mul_cnt != 2'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rs1_q     <= '0;
            rs2_q     <= '0;
            prod_ss_q <= '0;
            prod_su_q <= '0;
            prod_uu_q <= '0;
            mul_cnt   <= 2'd0;
        end else begin
            // Free-running stage A (operands) and stage B (products).
            rs1_q     <= rs1_data;
            rs2_q     <= rs2_data;
            prod_ss_q <= prod_ss;
            prod_su_q <= prod_su;
            prod_uu_q <= prod_uu;
            // Busy counter: a multiply spans MUL_LAT busy cycles (busy is still 0
            // on the start cycle, rising next edge -- like the divider's D_RUN).
            if (valid_in && !is_div_op && mul_cnt == 2'd0)
                mul_cnt <= MUL_LAT[1:0];
            else if (mul_cnt != 2'd0)
                mul_cnt <= mul_cnt - 2'd1;
        end
    end

    // =========================================================================
    // Sequential radix-2 restoring divider
    // =========================================================================
    typedef enum logic [1:0] { D_IDLE, D_RUN, D_CORR, D_DONE } div_state_t;
    div_state_t      state;

    logic [XLEN-1:0] rem_q;    // partial remainder (always < divisor magnitude)
    logic [XLEN-1:0] quot_q;   // quotient bits accumulate from LSB
    logic [XLEN-1:0] divd_q;   // dividend magnitude, left-justified, shifts left
    logic [XLEN-1:0] dvsr_q;   // divisor magnitude
    logic [CW-1:0]   count_q;  // remaining iterations
    logic [XLEN-1:0] div_result;

    // Latched op/operand attributes captured at start (operands are frozen while
    // the instruction is held in EX, but latching makes the finalize independent).
    logic            a_sign_q, b_sign_q, is_rem_q, is_w_q, special_q;
    logic [XLEN-1:0] special_res_q;

    // Output busy = divider iteration OR multiply pipeline in flight.  rv_core
    // ties this to muldiv_busy_int (stalls EX while a MUL or DIV is in flight).
    assign div_busy = (state == D_RUN) || (state == D_CORR) || mul_busy;

    // ---- Start-cycle operand/special preparation (combinational) ----
    logic [XLEN-1:0] a_ext, b_ext, a_mag, b_mag, divd_init, dvsr_init;
    logic            a_sgn, b_sgn, dz, ov;
    logic [XLEN-1:0] special_res;
    always_comb begin
        // Width-appropriate sign/zero extension to XLEN.
        a_ext = is_w_op ? (is_signed_op ? XLEN'($signed (rs1_data[WBITS-1:0]))
                                        : XLEN'($unsigned(rs1_data[WBITS-1:0])))
                        : rs1_data;
        b_ext = is_w_op ? (is_signed_op ? XLEN'($signed (rs2_data[WBITS-1:0]))
                                        : XLEN'($unsigned(rs2_data[WBITS-1:0])))
                        : rs2_data;
        a_sgn = is_signed_op & a_ext[XLEN-1];
        b_sgn = is_signed_op & b_ext[XLEN-1];
        a_mag = a_sgn ? (~a_ext + 1'b1) : a_ext;
        b_mag = b_sgn ? (~b_ext + 1'b1) : b_ext;
        // For W-type, process the high 32 bits: left-justify the 32-bit magnitude
        // so divd[XLEN-1] is its MSB and a 32-iteration run consumes it MSB-first.
        divd_init = is_w_op ? (a_mag << (XLEN - WBITS)) : a_mag;
        dvsr_init = b_mag;

        // Special cases (override the iterated result; match spec / prior logic).
        dz = is_w_op ? (rs2_data[WBITS-1:0] == '0) : (rs2_data == '0);
        ov = is_signed_op &&
             (is_w_op ? (rs1_data[WBITS-1:0] == 32'h8000_0000 &&
                         rs2_data[WBITS-1:0] == 32'hFFFF_FFFF)
                      : (rs1_data == {1'b1, {(XLEN-1){1'b0}}} && rs2_data == '1));
        if (dz)
            special_res = is_rem_op ? (is_w_op ? XLEN'($signed(rs1_data[WBITS-1:0]))
                                               : rs1_data)
                                    : {XLEN{1'b1}};                 // DIV x/0 = -1
        else // ov (signed overflow)
            special_res = is_rem_op ? '0
                                    : (is_w_op ? XLEN'($signed(32'h8000_0000))
                                               : {1'b1, {(XLEN-1){1'b0}}}); // INT_MIN
    end

    // ---- Iteration step (combinational) ----
    logic [XLEN:0]   rem_sh;   // {rem, next dividend bit}  (XLEN+1 bits)
    logic            q_bit;
    logic [XLEN-1:0] rem_nx;
    always_comb begin
        rem_sh = {rem_q, divd_q[XLEN-1]};
        q_bit  = (rem_sh >= {1'b0, dvsr_q});
        rem_nx = q_bit ? (rem_sh - {1'b0, dvsr_q}) : rem_sh; // < divisor, fits XLEN
    end

    // ---- Finalize (combinational): sign-correct magnitudes / apply special ----
    logic [XLEN-1:0] q_fixed, r_fixed, mag, fin_res;
    always_comb begin
        q_fixed = (a_sign_q ^ b_sign_q) ? (~quot_q + 1'b1) : quot_q;
        r_fixed =  a_sign_q             ? (~rem_q  + 1'b1) : rem_q;
        mag     = is_rem_q ? r_fixed : q_fixed;
        if (special_q)      fin_res = special_res_q;
        else if (is_w_q)    fin_res = XLEN'($signed(mag[WBITS-1:0]));
        else                fin_res = mag;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= D_IDLE;
            rem_q         <= '0;
            quot_q        <= '0;
            divd_q        <= '0;
            dvsr_q        <= '0;
            count_q       <= '0;
            div_result    <= '0;
            a_sign_q      <= 1'b0;
            b_sign_q      <= 1'b0;
            is_rem_q      <= 1'b0;
            is_w_q        <= 1'b0;
            special_q     <= 1'b0;
            special_res_q <= '0;
        end else begin
            unique case (state)
                D_IDLE: begin
                    if (valid_in && is_div_op) begin
                        // Latch operands/attributes and start iterating.
                        // (Multiply valid_in is handled by the mul busy counter.)
                        rem_q         <= '0;
                        quot_q        <= '0;
                        divd_q        <= divd_init;
                        dvsr_q        <= dvsr_init;
                        count_q       <= is_w_op ? CW'(WBITS) : CW'(XLEN);
                        a_sign_q      <= a_sgn;
                        b_sign_q      <= b_sgn;
                        is_rem_q      <= is_rem_op;
                        is_w_q        <= is_w_op;
                        special_q     <= dz | ov;
                        special_res_q <= special_res;
                        state         <= D_RUN;
                    end
                end

                D_RUN: begin
                    // One restoring step per cycle.  (For special cases the
                    // iteration runs harmlessly; the result is overridden.)
                    rem_q   <= rem_nx;
                    quot_q  <= {quot_q[XLEN-2:0], q_bit};
                    divd_q  <= {divd_q[XLEN-2:0], 1'b0};
                    count_q <= count_q - 1'b1;
                    if (count_q == CW'(1))
                        state <= D_CORR;  // last iteration done -> finalize
                end

                D_CORR: begin
                    // Registers now hold final magnitudes; latch corrected result.
                    div_result <= fin_res;
                    state      <= D_DONE;
                end

                D_DONE: begin
                    // div_busy is low here; the EX/MEM register captures `result`.
                    state <= D_IDLE;
                end

                default: state <= D_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Output mux: divide ops return the registered quotient/remainder (valid on
    // the D_DONE cycle); multiply ops return the combinational product.
    // =========================================================================
    assign result = is_div_op ? div_result : mul_result;

endmodule

`default_nettype wire
