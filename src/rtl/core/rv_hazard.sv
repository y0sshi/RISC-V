// =============================================================================
/// @file rv_hazard.sv
/// @brief Hazard Detection Unit
///
/// Detects load-use hazards that cannot be resolved by forwarding alone.
///
/// An integer load-use hazard occurs when a LOAD (or AMO) instruction in EX
/// writes to a register that the following instruction in ID needs to read.
/// The loaded data is not available until WB, one cycle too late for EX even
/// with MEM/WB forwarding.
///
/// An FP load-use hazard occurs when FLW is in EX and the following FP
/// instruction (in ID) reads from the same FP register.
///
/// Resolution: stall IF+ID for 1 cycle, insert a bubble into ID/EX.
///
/// @author Naofumi Yoshinaga
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
    input  reg_addr_t     id_rs3_addr,   // FP rs3 for FMADD family
    input  ctrl_signals_t id_ctrl,       // ID decoded control (for FP hazard)
    input  logic          id_rs1_used,   // ID instruction actually reads int rs1
    input  logic          id_rs2_used,   // ID instruction actually reads int rs2

    // Hazard output
    output logic          load_use_hazard
);

    // Determine whether ID instruction reads FP registers
    // (conservative: most FP ops read frs1; fp_store reads frs2; FMADD reads frs3)
    wire id_fp_reads_rs1 = id_ctrl.is_fp && !id_ctrl.int_to_fp && !id_ctrl.fp_load;
    wire id_fp_reads_rs2 = (id_ctrl.is_fp && !id_ctrl.int_to_fp && !id_ctrl.fp_load) ||
                            id_ctrl.fp_store;
    wire id_fp_reads_rs3 = id_ctrl.fp_use_rs3;

    always_comb begin
        load_use_hazard = 1'b0;

        // ---- Integer load-use: LOAD or AMO in EX, consumer in ID ----
        // AMO (including LR/SC) writes rd one cycle after MEM (like a load).
        if (id_ex_valid && (id_ex_ctrl.mem_read || id_ex_ctrl.is_amo)
                        && (id_ex_rd_addr != '0)) begin
            if (id_rs1_used && (id_ex_rd_addr == id_rs1_addr))
                load_use_hazard = 1'b1;
            if (id_rs2_used && (id_ex_rd_addr == id_rs2_addr))
                load_use_hazard = 1'b1;
        end

        // ---- FP load-use: FLW in EX, FP consumer in ID ----
        // FLW result arrives in WB (one cycle after MEM), so ID cannot proceed.
        if (id_ex_valid && id_ex_ctrl.fp_load && (id_ex_rd_addr != '0)) begin
            if (id_fp_reads_rs1 && (id_ex_rd_addr == id_rs1_addr))
                load_use_hazard = 1'b1;
            if (id_fp_reads_rs2 && (id_ex_rd_addr == id_rs2_addr))
                load_use_hazard = 1'b1;
            if (id_fp_reads_rs3 && (id_ex_rd_addr == id_rs3_addr))
                load_use_hazard = 1'b1;
        end
    end

endmodule

`default_nettype wire
