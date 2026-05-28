// =============================================================================
/// @file rv_forward.sv
/// @brief Combinational Data Forwarding Unit for RAW Hazard Resolution
///
/// Resolves **RAW (Read-After-Write)** data hazards by forwarding ALU/memory results
/// from later pipeline stages back to the EX stage ALU inputs.
///
/// **Forwarding Paths:**
/// - **EX forwarding**: Forward from EX/MEM register (1-instruction-old result)
///   - Used when destination of instruction in MEM stage matches operand in EX stage
/// - **MEM forwarding**: Forward from MEM/WB register (2-instruction-old result)
///   - Used when destination of instruction in WB stage matches operand in EX stage
///
/// **Forwarding Priority** (highest to lowest):
/// 1. EX/MEM result (most recent)
/// 2. MEM/WB result (second most recent)
/// 3. Original operand from ID/EX register (no forward)
///
/// **Selection Encoding:**
/// - 2'b00: No forward (use ID/EX or register file value)
/// - 2'b01: Forward from EX/MEM
/// - 2'b10: Forward from MEM/WB
///
/// **Exception:** Destination register x0 never causes forwarding (read-only).
///
/// @param XLEN Data path width (32 or 64)
/// @author Naofumi Yoshinaga
/// @date 2025-05-22
/// @version 1.0
/// =============================================================================

`default_nettype none

module rv_forward
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    // ID/EX register: source register addresses of instruction in EX stage
    input  reg_addr_t     id_ex_rs1_addr,
    input  reg_addr_t     id_ex_rs2_addr,
    input  reg_addr_t     id_ex_rs3_addr,   // FP rs3 for FMADD family

    // EX/MEM register: destination and write-enable of instruction in MEM stage
    input  logic          ex_mem_valid,
    input  ctrl_signals_t ex_mem_ctrl,
    input  reg_addr_t     ex_mem_rd_addr,

    // MEM/WB register: destination and write-enable of instruction in WB stage
    input  logic          mem_wb_valid,
    input  ctrl_signals_t mem_wb_ctrl,
    input  reg_addr_t     mem_wb_rd_addr,

    // Integer forwarding mux select signals
    output logic [1:0]    fwd_rs1_sel,
    output logic [1:0]    fwd_rs2_sel,

    // FP forwarding mux select signals (2'b00=regfile, 2'b01=EX/MEM, 2'b10=MEM/WB)
    output logic [1:0]    fwd_frs1_sel,
    output logic [1:0]    fwd_frs2_sel,
    output logic [1:0]    fwd_frs3_sel
);

    always_comb begin
        fwd_rs1_sel  = 2'b00;
        fwd_rs2_sel  = 2'b00;
        fwd_frs1_sel = 2'b00;
        fwd_frs2_sel = 2'b00;
        fwd_frs3_sel = 2'b00;

        // ---- Integer forwarding ----

        // EX hazard: forward from EX/MEM (highest priority)
        if (ex_mem_valid && ex_mem_ctrl.reg_write &&
                (ex_mem_rd_addr != '0) && (ex_mem_rd_addr == id_ex_rs1_addr))
            fwd_rs1_sel = 2'b01;

        if (ex_mem_valid && ex_mem_ctrl.reg_write &&
                (ex_mem_rd_addr != '0) && (ex_mem_rd_addr == id_ex_rs2_addr))
            fwd_rs2_sel = 2'b01;

        // MEM hazard: forward from MEM/WB (only if no EX hazard for same reg)
        if (mem_wb_valid && mem_wb_ctrl.reg_write &&
                (mem_wb_rd_addr != '0) && (mem_wb_rd_addr == id_ex_rs1_addr) &&
                !(ex_mem_valid && ex_mem_ctrl.reg_write &&
                  (ex_mem_rd_addr != '0) && (ex_mem_rd_addr == id_ex_rs1_addr)))
            fwd_rs1_sel = 2'b10;

        if (mem_wb_valid && mem_wb_ctrl.reg_write &&
                (mem_wb_rd_addr != '0) && (mem_wb_rd_addr == id_ex_rs2_addr) &&
                !(ex_mem_valid && ex_mem_ctrl.reg_write &&
                  (ex_mem_rd_addr != '0) && (ex_mem_rd_addr == id_ex_rs2_addr)))
            fwd_rs2_sel = 2'b10;

        // ---- FP forwarding ----
        // f0 is writable (unlike x0), so no != '0 guard needed.

        // EX hazard: forward from EX/MEM
        if (ex_mem_valid && ex_mem_ctrl.freg_write &&
                (ex_mem_rd_addr == id_ex_rs1_addr))
            fwd_frs1_sel = 2'b01;

        if (ex_mem_valid && ex_mem_ctrl.freg_write &&
                (ex_mem_rd_addr == id_ex_rs2_addr))
            fwd_frs2_sel = 2'b01;

        if (ex_mem_valid && ex_mem_ctrl.freg_write &&
                (ex_mem_rd_addr == id_ex_rs3_addr))
            fwd_frs3_sel = 2'b01;

        // MEM hazard: forward from MEM/WB (only if no EX hazard for same reg)
        if (mem_wb_valid && mem_wb_ctrl.freg_write &&
                (mem_wb_rd_addr == id_ex_rs1_addr) &&
                !(ex_mem_valid && ex_mem_ctrl.freg_write &&
                  (ex_mem_rd_addr == id_ex_rs1_addr)))
            fwd_frs1_sel = 2'b10;

        if (mem_wb_valid && mem_wb_ctrl.freg_write &&
                (mem_wb_rd_addr == id_ex_rs2_addr) &&
                !(ex_mem_valid && ex_mem_ctrl.freg_write &&
                  (ex_mem_rd_addr == id_ex_rs2_addr)))
            fwd_frs2_sel = 2'b10;

        if (mem_wb_valid && mem_wb_ctrl.freg_write &&
                (mem_wb_rd_addr == id_ex_rs3_addr) &&
                !(ex_mem_valid && ex_mem_ctrl.freg_write &&
                  (ex_mem_rd_addr == id_ex_rs3_addr)))
            fwd_frs3_sel = 2'b10;
    end

endmodule

`default_nettype wire
