// =============================================================================
// rv_muldiv.sv - M-Extension Multiply/Divide Unit
// =============================================================================
// Implements RV32M / RV64M operations as single-cycle combinational logic.
// For FPGA targets, synthesis tools map MUL to DSP blocks and DIV to LUT-based
// dividers (slow, large). A pipelined/multi-cycle variant can be substituted
// later without changing the interface.
//
// All RISC-V M-extension corner cases are handled:
//   div/rem by zero : result per spec (-1 / dividend)
//   signed overflow  : DIV(INT_MIN,-1)=INT_MIN, REM(INT_MIN,-1)=0
//
// Interface: purely combinational — no clock, no enables.
// The calling stage (rv_core EX) gates the output via ctrl.is_muldiv.
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_muldiv
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    input  wire  [XLEN-1:0]  rs1_data,
    input  wire  [XLEN-1:0]  rs2_data,
    input  muldiv_op_t        op,
    output logic [XLEN-1:0]  result
);

    // =========================================================================
    // Operand extension (2*XLEN bits) for MULH variants
    // Using wire assigns (not inside always_*) to avoid iverilog limitations
    // with parameterised types in procedural blocks.
    // =========================================================================
    logic [2*XLEN-1:0] rs1_sx, rs2_sx;  // sign-extended
    logic [2*XLEN-1:0] rs1_ux, rs2_ux;  // zero-extended

    assign rs1_sx = {{XLEN{rs1_data[XLEN-1]}}, rs1_data};
    assign rs2_sx = {{XLEN{rs2_data[XLEN-1]}}, rs2_data};
    assign rs1_ux = {{XLEN{1'b0}},              rs1_data};
    assign rs2_ux = {{XLEN{1'b0}},              rs2_data};

    // =========================================================================
    // Products (2*XLEN-bit combinational — captures the full exact product
    // because |A_signed × B_unsigned| < 2^(2*XLEN-1) for any XLEN-bit inputs)
    // =========================================================================
    logic [2*XLEN-1:0] prod_ss;   // signed   × signed
    logic [2*XLEN-1:0] prod_su;   // signed   × unsigned  (MULHSU)
    logic [2*XLEN-1:0] prod_uu;   // unsigned × unsigned

    assign prod_ss = $signed(rs1_sx) * $signed(rs2_sx);
    assign prod_su = $signed(rs1_sx) * $signed(rs2_ux);  // rs2_ux MSB=0 → non-neg
    assign prod_uu = rs1_ux * rs2_ux;

    // =========================================================================
    // Special-case flags
    // =========================================================================
    // Base-XLEN
    wire              div_by_zero     = (rs2_data == '0);
    wire              signed_overflow = (rs1_data == {1'b1, {(XLEN-1){1'b0}}}   // INT_MIN
                                         && rs2_data == '1);                      // -1
    // W-type (32-bit operands regardless of XLEN)
    wire              div_by_zero_w     = (rs2_data[31:0] == '0);
    wire              signed_overflow_w = (rs1_data[31:0] == 32'h8000_0000
                                           && rs2_data[31:0] == 32'hFFFF_FFFF);

    // =========================================================================
    // Result mux
    // =========================================================================
    always_comb begin
        result = '0;
        unique case (op)

            // ------------------------------------------------------------------
            // Multiply
            // ------------------------------------------------------------------
            // MUL: lower XLEN bits of signed×signed product
            // (same lower bits as unsigned×unsigned, so rs1*rs2 is sufficient)
            MDU_MUL:    result = rs1_data * rs2_data;

            // MULH: upper XLEN bits of signed×signed product
            MDU_MULH:   result = prod_ss[2*XLEN-1:XLEN];

            // MULHSU: upper XLEN bits of signed×unsigned product
            MDU_MULHSU: result = prod_su[2*XLEN-1:XLEN];

            // MULHU: upper XLEN bits of unsigned×unsigned product
            MDU_MULHU:  result = prod_uu[2*XLEN-1:XLEN];

            // ------------------------------------------------------------------
            // Divide (signed)
            //   div-by-zero  → all-ones (-1 signed)
            //   INT_MIN / -1 → INT_MIN  (overflow)
            // ------------------------------------------------------------------
            MDU_DIV: begin
                if (div_by_zero)
                    result = '1;
                else if (signed_overflow)
                    result = rs1_data;   // INT_MIN
                else
                    result = xlen_t'($signed(rs1_data) / $signed(rs2_data));
            end

            // Divide (unsigned)
            //   div-by-zero  → all-ones (2^XLEN - 1)
            MDU_DIVU: begin
                if (div_by_zero)
                    result = '1;
                else
                    result = rs1_data / rs2_data;
            end

            // ------------------------------------------------------------------
            // Remainder (signed)
            //   div-by-zero  → dividend unchanged
            //   INT_MIN % -1 → 0  (consistent with DIV overflow result)
            // ------------------------------------------------------------------
            MDU_REM: begin
                if (div_by_zero)
                    result = rs1_data;
                else if (signed_overflow)
                    result = '0;
                else
                    result = xlen_t'($signed(rs1_data) % $signed(rs2_data));
            end

            // Remainder (unsigned)
            //   div-by-zero  → dividend unchanged
            MDU_REMU: begin
                if (div_by_zero)
                    result = rs1_data;
                else
                    result = rs1_data % rs2_data;
            end

            // ------------------------------------------------------------------
            // W-type (RV64M): 32-bit operation, result sign-extended to XLEN
            // ------------------------------------------------------------------

            // MULW: lower 32 bits of rs1[31:0]×rs2[31:0], sign-extended
            MDU_MULW:
                result = XLEN'($signed(rs1_data[31:0] * rs2_data[31:0]));

            // DIVW: signed 32-bit division, sign-extended
            MDU_DIVW: begin
                if (div_by_zero_w)
                    result = '1;
                else if (signed_overflow_w)
                    result = XLEN'($signed(32'h8000_0000));  // INT32_MIN sign-ext
                else
                    result = XLEN'($signed($signed(rs1_data[31:0]) /
                                           $signed(rs2_data[31:0])));
            end

            // DIVUW: unsigned 32-bit division, result sign-extended
            MDU_DIVUW: begin
                if (div_by_zero_w)
                    result = '1;
                else
                    result = XLEN'($signed(rs1_data[31:0] / rs2_data[31:0]));
            end

            // REMW: signed 32-bit remainder, sign-extended
            MDU_REMW: begin
                if (div_by_zero_w)
                    result = XLEN'($signed(rs1_data[31:0]));
                else if (signed_overflow_w)
                    result = '0;
                else
                    result = XLEN'($signed($signed(rs1_data[31:0]) %
                                           $signed(rs2_data[31:0])));
            end

            // REMUW: unsigned 32-bit remainder, sign-extended
            MDU_REMUW: begin
                if (div_by_zero_w)
                    result = XLEN'($signed(rs1_data[31:0]));
                else
                    result = XLEN'($signed(rs1_data[31:0] % rs2_data[31:0]));
            end

            default: result = '0;
        endcase
    end

endmodule

`default_nettype wire
