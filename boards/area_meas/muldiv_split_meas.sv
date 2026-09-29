// =============================================================================
// muldiv_split_meas.sv - MEASUREMENT-ONLY split of rv_muldiv into MUL vs DIV
// =============================================================================
// rv_muldiv keeps the single-cycle multiplier and the multi-cycle radix-2
// divider in ONE module, selected by `op`.  The whole-SoC and standalone OOC
// reports therefore lump integer MUL+DIV together.  Constant-tying `op` to split
// them would collapse the multiplier/divider to a single variant and under-count.
//
// These two modules replicate ONLY the multiply block and ONLY the divider block
// from rv_muldiv.sv (verbatim), each keeping `op` as a free input so synthesis
// builds the FULL set of MUL (resp. DIV) variants.  They exist solely to measure
// per-operator area via boards/report_exec_area.tcl and are NOT part of any
// build or simulation.  Keep in sync with rv_muldiv.sv if that changes.
// =============================================================================

`default_nettype none

// ---- Integer MULTIPLY only (combinational, single-cycle; maps to DSP) -------
module mul_meas
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    input  wire  [XLEN-1:0]  rs1_data,
    input  wire  [XLEN-1:0]  rs2_data,
    input  wire  muldiv_op_t op,
    output logic [XLEN-1:0]  result
);
    logic [2*XLEN-1:0] rs1_sx, rs2_sx, rs1_ux, rs2_ux;
    assign rs1_sx = {{XLEN{rs1_data[XLEN-1]}}, rs1_data};
    assign rs2_sx = {{XLEN{rs2_data[XLEN-1]}}, rs2_data};
    assign rs1_ux = {{XLEN{1'b0}},              rs1_data};
    assign rs2_ux = {{XLEN{1'b0}},              rs2_data};

    logic [2*XLEN-1:0] prod_ss, prod_su, prod_uu;
    assign prod_ss = $signed(rs1_sx) * $signed(rs2_sx);
    assign prod_su = $signed(rs1_sx) * $signed(rs2_ux);
    assign prod_uu = rs1_ux * rs2_ux;

    logic [XLEN-1:0] mul_result;
    always_comb begin
        mul_result = '0;
        unique case (op)
            MDU_MUL:    mul_result = rs1_data * rs2_data;
            MDU_MULH:   mul_result = prod_ss[2*XLEN-1:XLEN];
            MDU_MULHSU: mul_result = prod_su[2*XLEN-1:XLEN];
            MDU_MULHU:  mul_result = prod_uu[2*XLEN-1:XLEN];
            MDU_MULW:   mul_result = XLEN'($signed(rs1_data[31:0] * rs2_data[31:0]));
            default:    mul_result = '0;
        endcase
    end
    assign result = mul_result;
endmodule

// ---- Integer DIVIDE only (multi-cycle radix-2 restoring divider) ------------
module div_meas
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire  [XLEN-1:0]  rs1_data,
    input  wire  [XLEN-1:0]  rs2_data,
    input  wire  muldiv_op_t op,
    input  wire              valid_in,
    output logic [XLEN-1:0]  result,
    output logic             div_busy
);
    localparam int WBITS = 32;
    localparam int CW    = $clog2(XLEN + 1);

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
            default:    ;
        endcase
    end

    typedef enum logic [1:0] { D_IDLE, D_RUN, D_CORR, D_DONE } div_state_t;
    div_state_t      state;
    logic [XLEN-1:0] rem_q, quot_q, divd_q, dvsr_q, div_result;
    logic [CW-1:0]   count_q;
    logic            a_sign_q, b_sign_q, is_rem_q, is_w_q, special_q;
    logic [XLEN-1:0] special_res_q;

    assign div_busy = (state == D_RUN) || (state == D_CORR);

    logic [XLEN-1:0] a_ext, b_ext, a_mag, b_mag, divd_init, dvsr_init;
    logic            a_sgn, b_sgn, dz, ov;
    logic [XLEN-1:0] special_res;
    always_comb begin
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
        divd_init = is_w_op ? (a_mag << (XLEN - WBITS)) : a_mag;
        dvsr_init = b_mag;
        dz = is_w_op ? (rs2_data[WBITS-1:0] == '0) : (rs2_data == '0);
        ov = is_signed_op &&
             (is_w_op ? (rs1_data[WBITS-1:0] == 32'h8000_0000 &&
                         rs2_data[WBITS-1:0] == 32'hFFFF_FFFF)
                      : (rs1_data == {1'b1, {(XLEN-1){1'b0}}} && rs2_data == '1));
        if (dz)
            special_res = is_rem_op ? (is_w_op ? XLEN'($signed(rs1_data[WBITS-1:0]))
                                               : rs1_data)
                                    : {XLEN{1'b1}};
        else
            special_res = is_rem_op ? '0
                                    : (is_w_op ? XLEN'($signed(32'h8000_0000))
                                               : {1'b1, {(XLEN-1){1'b0}}});
    end

    logic [XLEN:0]   rem_sh;
    logic            q_bit;
    logic [XLEN-1:0] rem_nx;
    always_comb begin
        rem_sh = {rem_q, divd_q[XLEN-1]};
        q_bit  = (rem_sh >= {1'b0, dvsr_q});
        rem_nx = q_bit ? (rem_sh - {1'b0, dvsr_q}) : rem_sh;
    end

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
            state <= D_IDLE; rem_q <= '0; quot_q <= '0; divd_q <= '0; dvsr_q <= '0;
            count_q <= '0; div_result <= '0; a_sign_q <= 1'b0; b_sign_q <= 1'b0;
            is_rem_q <= 1'b0; is_w_q <= 1'b0; special_q <= 1'b0; special_res_q <= '0;
        end else begin
            unique case (state)
                D_IDLE: if (valid_in) begin
                    rem_q <= '0; quot_q <= '0; divd_q <= divd_init; dvsr_q <= dvsr_init;
                    count_q <= is_w_op ? CW'(WBITS) : CW'(XLEN);
                    a_sign_q <= a_sgn; b_sign_q <= b_sgn; is_rem_q <= is_rem_op;
                    is_w_q <= is_w_op; special_q <= dz | ov; special_res_q <= special_res;
                    state <= D_RUN;
                end
                D_RUN: begin
                    rem_q <= rem_nx; quot_q <= {quot_q[XLEN-2:0], q_bit};
                    divd_q <= {divd_q[XLEN-2:0], 1'b0}; count_q <= count_q - 1'b1;
                    if (count_q == CW'(1)) state <= D_CORR;
                end
                D_CORR: begin div_result <= fin_res; state <= D_DONE; end
                D_DONE: state <= D_IDLE;
                default: state <= D_IDLE;
            endcase
        end
    end
    assign result = div_result;
endmodule

`default_nettype wire
