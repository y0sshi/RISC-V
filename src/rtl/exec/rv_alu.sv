// =============================================================================
// rv_alu.sv - Arithmetic Logic Unit
// =============================================================================
// Performs arithmetic and logic operations for the RISC-V processor.
// Supports RV32I / RV64I base operations.
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module rv_alu
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    input  wire  [XLEN-1:0]  op_a,
    input  wire  [XLEN-1:0]  op_b,
    input  alu_op_t           alu_op,

    output logic [XLEN-1:0]  result,
    output logic              zero
);

    // Shift amount width: 5 bits for RV32, 6 bits for RV64
    localparam int SHAMT_W = (XLEN == 64) ? 6 : 5;

    logic [SHAMT_W-1:0] shamt;
    assign shamt = op_b[SHAMT_W-1:0];

    // W-type uses 5-bit shift amount regardless of XLEN
    logic [4:0] shamt_w;
    assign shamt_w = op_b[4:0];

    // Intermediate 32-bit results for W-type operations (RV64 only)
    logic [31:0] w_result_32;

    always_comb begin
        w_result_32 = 32'h0;
        case (alu_op)
            ALU_ADDW: w_result_32 = op_a[31:0] + op_b[31:0];
            ALU_SUBW: w_result_32 = op_a[31:0] - op_b[31:0];
            ALU_SLLW: w_result_32 = op_a[31:0] << shamt_w;
            ALU_SRLW: w_result_32 = op_a[31:0] >> shamt_w;
            ALU_SRAW: w_result_32 = 32'($signed(op_a[31:0]) >>> shamt_w);
            default:  w_result_32 = 32'h0;
        endcase
    end

    always_comb begin
        case (alu_op)
            ALU_ADD:    result = op_a + op_b;
            ALU_SUB:    result = op_a - op_b;
            ALU_SLL:    result = op_a << shamt;
            ALU_SLT:    result = {{(XLEN-1){1'b0}}, $signed(op_a) < $signed(op_b)};
            ALU_SLTU:   result = {{(XLEN-1){1'b0}}, op_a < op_b};
            ALU_XOR:    result = op_a ^ op_b;
            ALU_SRL:    result = op_a >> shamt;
            ALU_SRA:    result = $signed(op_a) >>> shamt;
            ALU_OR:     result = op_a | op_b;
            ALU_AND:    result = op_a & op_b;
            ALU_PASS_B: result = op_b;
            // RV64I W-type: 32-bit op, sign-extended to XLEN
            ALU_ADDW,
            ALU_SUBW,
            ALU_SLLW,
            ALU_SRLW,
            ALU_SRAW:   result = XLEN'($signed(w_result_32));
            default:    result = '0;
        endcase
    end

    assign zero = (result == '0);

endmodule

`default_nettype wire
