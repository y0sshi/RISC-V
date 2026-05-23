// =============================================================================
// rv_hazard.sv - Hazard Detection Unit
// =============================================================================
// Detects load-use hazards that cannot be resolved by forwarding alone.
//
// A load-use hazard occurs when a LOAD instruction in the EX stage writes to
// a register that the immediately following instruction (in ID) needs to read.
// The loaded data is not available until the WB stage, one cycle too late for
// the consumer instruction's EX stage even with MEM/WB forwarding.
//
// Resolution: stall IF and ID for 1 cycle, insert a bubble into ID/EX.
// After the stall, MEM/WB forwarding provides the loaded data to EX.
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_hazard
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    // ID/EX register: instruction currently in EX stage
    input  logic          id_ex_valid,
    input  ctrl_signals_t id_ex_ctrl,
    input  reg_addr_t     id_ex_rd_addr,

    // Decoded fields of instruction currently in ID stage (from IF/ID)
    input  reg_addr_t     id_rs1_addr,
    input  reg_addr_t     id_rs2_addr,
    input  logic          id_rs1_used,   // ID instruction actually reads rs1
    input  logic          id_rs2_used,   // ID instruction actually reads rs2

    // Hazard output
    output logic          load_use_hazard
);

    always_comb begin
        load_use_hazard = 1'b0;
        // Load-use hazard: LOAD or AMO in EX whose result consumer is in ID.
        // AMO (including LR/SC) writes rd one cycle after MEM (like a load).
        if (id_ex_valid && (id_ex_ctrl.mem_read || id_ex_ctrl.is_amo)
                        && (id_ex_rd_addr != '0)) begin
            if (id_rs1_used && (id_ex_rd_addr == id_rs1_addr))
                load_use_hazard = 1'b1;
            if (id_rs2_used && (id_ex_rd_addr == id_rs2_addr))
                load_use_hazard = 1'b1;
        end
    end

endmodule

`default_nettype wire
