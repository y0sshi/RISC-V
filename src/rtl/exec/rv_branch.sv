// =============================================================================
// rv_branch.sv - Branch / Jump Resolution Unit
// =============================================================================
// Evaluates branch conditions and computes branch/jump target addresses.
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_branch
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    input  wire ctrl_signals_t ctrl,
    input  wire  [2:0]       funct3,
    input  wire  [XLEN-1:0]  rs1_data,
    input  wire  [XLEN-1:0]  rs2_data,
    input  wire  [XLEN-1:0]  pc,
    input  wire  [XLEN-1:0]  imm,
    input  wire  [XLEN-1:0]  alu_result,

    output logic              branch_taken,
    output logic [XLEN-1:0]  branch_target
);

    // Branch condition evaluation
    logic cond_met;

    always_comb begin
        cond_met = 1'b0;
        if (ctrl.branch) begin
            case (funct3)
                F3_BEQ:  cond_met = (rs1_data == rs2_data);
                F3_BNE:  cond_met = (rs1_data != rs2_data);
                F3_BLT:  cond_met = ($signed(rs1_data) < $signed(rs2_data));
                F3_BGE:  cond_met = ($signed(rs1_data) >= $signed(rs2_data));
                F3_BLTU: cond_met = (rs1_data < rs2_data);
                F3_BGEU: cond_met = (rs1_data >= rs2_data);
                default: cond_met = 1'b0;
            endcase
        end
    end

    // Branch taken signal
    assign branch_taken = (ctrl.branch & cond_met) | ctrl.jump;

    // Target address computation
    always_comb begin
        if (ctrl.jalr) begin
            // JALR: target = (rs1 + imm) & ~1  (alu_result = rs1 + imm)
            branch_target = (alu_result) & ~(XLEN'(1));
        end else begin
            // JAL / Branch: target = PC + imm  (PC-relative)
            branch_target = pc + imm;
        end
    end

endmodule

`default_nettype wire
