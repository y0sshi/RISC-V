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
/// An FP load-use hazard occurs when an FP load (FLW/FLD) is in EX or MEM and a
/// following FP instruction (in ID) reads from the same FP register.  The FP-load
/// result is registered one cycle at the core boundary (fpld; see rv_core) to
/// break the long D$-data -> FP-datapath route, so it is forwardable one cycle
/// later than an ordinary value -- hence the consumer must be held until the load
/// reaches WB (FP load in EX -> 2 stall cycles, FP load in MEM -> 1 stall cycle;
/// thereafter the fpld forward / regfile supplies it).
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
    input  wire           id_ex_valid,
    input  wire ctrl_signals_t id_ex_ctrl,
    input  wire reg_addr_t id_ex_rd_addr,

    // EX/MEM register: instruction currently in MEM stage (FP-load only -- used to
    // extend the FP load-use stall by one cycle for the late fpld writeback).
    input  wire           ex_mem_valid,
    input  wire ctrl_signals_t ex_mem_ctrl,
    input  wire reg_addr_t ex_mem_rd_addr,

    // Decoded fields of instruction currently in ID stage (from IF/ID)
    input  wire reg_addr_t id_rs1_addr,
    input  wire reg_addr_t id_rs2_addr,
    input  wire reg_addr_t id_rs3_addr,   // FP rs3 for FMADD family
    input  wire ctrl_signals_t id_ctrl,       // ID decoded control (for FP hazard)
    input  wire           id_rs1_used,   // ID instruction actually reads int rs1
    input  wire           id_rs2_used,   // ID instruction actually reads int rs2

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

        // ---- FP load-use: FP load in EX, FP consumer in ID ----
        // The FP-load value is forwardable one cycle later than usual (it is
        // registered into fpld at the core boundary), so the consumer must wait
        // until the load reaches WB.  Stalling while the load is in EX *and* again
        // while it is in MEM yields the required 2-cycle hold for a back-to-back
        // dependent FP op; a 2-instruction-apart consumer (load already in MEM)
        // gets the single remaining stall.
        // Note: no `!= '0` guard here -- f0 is a real, writable FP register
        // (unlike integer x0), so a load targeting f0 must still stall.
        if (id_ex_valid && id_ex_ctrl.fp_load) begin
            if (id_fp_reads_rs1 && (id_ex_rd_addr == id_rs1_addr))
                load_use_hazard = 1'b1;
            if (id_fp_reads_rs2 && (id_ex_rd_addr == id_rs2_addr))
                load_use_hazard = 1'b1;
            if (id_fp_reads_rs3 && (id_ex_rd_addr == id_rs3_addr))
                load_use_hazard = 1'b1;
        end

        // ---- FP load-use: FP load in MEM, FP consumer in ID ----
        // Second stall cycle of the extended FP load-use hold (see above).
        if (ex_mem_valid && ex_mem_ctrl.fp_load) begin
            if (id_fp_reads_rs1 && (ex_mem_rd_addr == id_rs1_addr))
                load_use_hazard = 1'b1;
            if (id_fp_reads_rs2 && (ex_mem_rd_addr == id_rs2_addr))
                load_use_hazard = 1'b1;
            if (id_fp_reads_rs3 && (ex_mem_rd_addr == id_rs3_addr))
                load_use_hazard = 1'b1;
        end
    end

endmodule

`default_nettype wire
