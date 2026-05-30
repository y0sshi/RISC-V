// =============================================================================
/// @file rv_cdecode.sv
/// @brief RISC-V C-Extension (Compressed) to Base 32-bit Instruction Expander
///
/// Purely combinational logic that expands a 16-bit RVC instruction into its
/// equivalent 32-bit base RISC-V instruction.  The expanded instruction is then
/// fed to the existing rv_decode, so the decode / execute / forwarding logic is
/// reused unchanged.
///
/// **Encoding overview:**
/// - An instruction is compressed when inst[1:0] != 2'b11.
/// - quadrant = inst[1:0] (00 / 01 / 10), funct3 = inst[15:13].
///
/// **XLEN-dependent encodings (must branch on XLEN):**
/// - C.JAL  (Q1, funct3=001): RV32C only -> jal x1, imm.
///   In RV64C the same slot is C.ADDIW -> addiw rd, rd, imm.
/// - C.LD/C.SD/C.LDSP/C.SDSP: RV64C only (64-bit load/store).
///   In RV32C the same slots are C.FLW/C.FSW/C.FLWSP/C.FSWSP (single-precision FP).
/// - C.FLD/C.FSD/C.FLDSP/C.FSDSP: double-precision FP load/store (both RV32C/RV64C).
/// - C.SLLI/C.SRLI/C.SRAI shamt: RV32C requires shamt[5]=0 (5-bit), RV64C is 6-bit.
/// - C.ADDIW/C.SUBW/C.ADDW: W-form, RV64 only.  Reserved in RV32C.
///
/// Reserved / illegal compressed encodings are reported via `illegal` and are
/// expanded to a canonical NOP (addi x0, x0, 0) so they never corrupt state.
///
/// @param XLEN Data path width (32 or 64).  Selects RV32C vs RV64C semantics.
/// @author Naofumi Yoshinaga
/// @date 2026-05-31
/// @version 1.0
// =============================================================================

`default_nettype none

module rv_cdecode
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    input  wire  [15:0] cinst,        // lower 16 bits of the fetched word
    output logic [31:0] inst_out,     // expanded 32-bit instruction
    output logic        is_compressed,// 1 when cinst[1:0] != 2'b11
    output logic        illegal       // reserved / unsupported compressed encoding
);

    localparam bit IS_RV64 = (XLEN == 64);

    // -------------------------------------------------------------------------
    // Common field extraction
    // -------------------------------------------------------------------------
    wire [1:0] op     = cinst[1:0];
    wire [2:0] funct3 = cinst[15:13];

    // Full 5-bit register specifiers
    wire [4:0] rd_rs1 = cinst[11:7];   // C.ADDI / C.SLLI / CR-format rd or rs1
    wire [4:0] rs2_c  = cinst[6:2];    // CR / CSS-format rs2

    // 3-bit popular registers (x8..x15)
    wire [4:0] rs1_p  = {2'b01, cinst[9:7]};
    wire [4:0] rs2_p  = {2'b01, cinst[4:2]};
    wire [4:0] rd_p   = {2'b01, cinst[4:2]};   // CL/CIW destination

    // -------------------------------------------------------------------------
    // Immediate decoders (one per compressed immediate format)
    // -------------------------------------------------------------------------
    // C.ADDI4SPN: zero-extended scaled-by-4 10-bit immediate
    wire [9:0] ciw_imm = {cinst[10:7], cinst[12:11], cinst[5], cinst[6], 2'b00};

    // CL/CS word access (C.LW/C.SW/C.FLW/C.FSW): scaled-by-4
    wire [6:0] clw_imm = {cinst[5], cinst[12:10], cinst[6], 2'b00};
    // CL/CS double access (C.LD/C.SD/C.FLD/C.FSD): scaled-by-8
    wire [7:0] cld_imm = {cinst[6:5], cinst[12:10], 3'b000};

    // CI sign-extended 6-bit immediate (C.ADDI/C.ADDIW/C.LI/C.ANDI)
    wire [5:0] ci_imm  = {cinst[12], cinst[6:2]};
    // CI shift amount (C.SLLI/C.SRLI/C.SRAI): 6-bit
    wire [5:0] ci_shamt = {cinst[12], cinst[6:2]};

    // C.ADDI16SP scaled-by-16 sign-extended immediate (bit 9 is sign)
    wire [9:0] addi16sp_imm =
        {cinst[12], cinst[4:3], cinst[5], cinst[2], cinst[6], 4'b0000};

    // C.LUI sign-extended 6-bit value placed in bits [17:12]
    wire [5:0] lui_imm = {cinst[12], cinst[6:2]};

    // CJ jump offset (C.J / C.JAL): sign-extended 12-bit (LSB=0)
    wire [11:0] cj_imm =
        {cinst[12], cinst[8], cinst[10:9], cinst[6], cinst[7],
         cinst[2], cinst[11], cinst[5:3], 1'b0};

    // CB branch offset (C.BEQZ / C.BNEZ): sign-extended 9-bit (LSB=0)
    wire [8:0] cb_imm =
        {cinst[12], cinst[6:5], cinst[2], cinst[11:10], cinst[4:3], 1'b0};

    // CI stack-pointer relative load offsets (base = x2)
    wire [7:0] lwsp_imm = {cinst[3:2], cinst[12], cinst[6:4], 2'b00};       // C.LWSP/C.FLWSP
    wire [8:0] ldsp_imm = {cinst[4:2], cinst[12], cinst[6:5], 3'b000};      // C.LDSP/C.FLDSP

    // CSS stack-pointer relative store offsets (base = x2)
    wire [7:0] swsp_imm = {cinst[8:7], cinst[12:9], 2'b00};                 // C.SWSP/C.FSWSP
    wire [8:0] sdsp_imm = {cinst[9:7], cinst[12:10], 3'b000};               // C.SDSP/C.FSDSP

    // -------------------------------------------------------------------------
    // Builders for 32-bit base instructions (combinational helpers)
    // -------------------------------------------------------------------------
    localparam logic [31:0] NOP = 32'h0000_0013;   // addi x0, x0, 0

    // I-type: imm[11:0] | rs1 | funct3 | rd | opcode
    function automatic [31:0] enc_i(input [11:0] imm,
                                    input [4:0]  rs1,
                                    input [2:0]  f3,
                                    input [4:0]  rd,
                                    input [6:0]  opc);
        enc_i = {imm, rs1, f3, rd, opc};
    endfunction

    // S-type: imm[11:5] | rs2 | rs1 | funct3 | imm[4:0] | opcode
    function automatic [31:0] enc_s(input [11:0] imm,
                                    input [4:0]  rs2,
                                    input [4:0]  rs1,
                                    input [2:0]  f3,
                                    input [6:0]  opc);
        enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], opc};
    endfunction

    // R-type: funct7 | rs2 | rs1 | funct3 | rd | opcode
    function automatic [31:0] enc_r(input [6:0]  f7,
                                    input [4:0]  rs2,
                                    input [4:0]  rs1,
                                    input [2:0]  f3,
                                    input [4:0]  rd,
                                    input [6:0]  opc);
        enc_r = {f7, rs2, rs1, f3, rd, opc};
    endfunction

    // U-type: imm[31:12] | rd | opcode
    function automatic [31:0] enc_u(input [19:0] imm20,
                                    input [4:0]  rd,
                                    input [6:0]  opc);
        enc_u = {imm20, rd, opc};
    endfunction

    // J-type (JAL): build inst[31:12] from a 21-bit signed offset, then rd, opcode
    function automatic [31:0] enc_jal(input [20:0] off,   // off[0] ignored (=0)
                                      input [4:0]  rd);
        // inst[31]=off[20], inst[30:21]=off[10:1], inst[20]=off[11], inst[19:12]=off[19:12]
        enc_jal = {off[20], off[10:1], off[11], off[19:12], rd, 7'b1101111};
    endfunction

    // B-type (branch): 13-bit signed offset (off[0]=0)
    function automatic [31:0] enc_b(input [12:0] off,
                                    input [4:0]  rs2,
                                    input [4:0]  rs1,
                                    input [2:0]  f3);
        enc_b = {off[12], off[10:5], rs2, rs1, f3, off[4:1], off[11], 7'b1100011};
    endfunction

    // Opcodes for the shift-immediate group (uses the full 6-bit shamt; for RV32
    // the high shamt bit is forced to 0 by guards, so the upper bits are valid).
    // SLLI:  inst[31:26]=000000, funct3=001
    // SRLI:  inst[31:26]=000000, funct3=101
    // SRAI:  inst[31:26]=010000, funct3=101
    function automatic [31:0] enc_shift(input [5:0] shamt,
                                        input [4:0] rs1,
                                        input [4:0] rd,
                                        input [2:0] f3,
                                        input       arith);  // 1 = SRAI
        enc_shift = {1'b0, arith, 4'b0000, shamt, rs1, f3, rd, 7'b0010011};
    endfunction

    // -------------------------------------------------------------------------
    // Sign-extended immediates as 12-bit fields for I/S encodings
    // -------------------------------------------------------------------------
    wire [11:0] ci_imm_sx     = {{6{ci_imm[5]}}, ci_imm};
    wire [11:0] andi_imm_sx   = {{6{ci_imm[5]}}, ci_imm};
    wire [11:0] addi16_imm_sx = {{2{addi16sp_imm[9]}}, addi16sp_imm};
    wire [19:0] lui_imm_sx    = {{14{lui_imm[5]}}, lui_imm};   // placed at [17:12]+sext
    wire [20:0] cj_off_sx     = {{9{cj_imm[11]}}, cj_imm};
    wire [12:0] cb_off_sx     = {{4{cb_imm[8]}}, cb_imm};

    // -------------------------------------------------------------------------
    // Main expansion
    // -------------------------------------------------------------------------
    assign is_compressed = (op != 2'b11);

    always_comb begin
        inst_out = NOP;
        illegal  = 1'b0;

        unique case (op)
        // =====================================================================
        // Quadrant 0
        // =====================================================================
        2'b00: begin
            unique case (funct3)
                3'b000: begin
                    // C.ADDI4SPN -> addi rd', x2, zext(imm)
                    if (ciw_imm == 10'd0) illegal = 1'b1;   // reserved (also all-zero = illegal)
                    inst_out = enc_i({2'b00, ciw_imm}, 5'd2, 3'b000, rd_p, OP_IMM);
                end
                3'b001: begin
                    // C.FLD -> fld rd', off(rs1')  (D-extension, both RV32C/RV64C)
                    inst_out = enc_i({4'b0000, cld_imm}, rs1_p, 3'b011, rd_p, OP_LOAD_FP);
                end
                3'b010: begin
                    // C.LW -> lw rd', off(rs1')
                    inst_out = enc_i({5'b00000, clw_imm}, rs1_p, 3'b010, rd_p, OP_LOAD);
                end
                3'b011: begin
                    if (IS_RV64)
                        // C.LD -> ld rd', off(rs1')
                        inst_out = enc_i({4'b0000, cld_imm}, rs1_p, 3'b011, rd_p, OP_LOAD);
                    else
                        // C.FLW -> flw rd', off(rs1')
                        inst_out = enc_i({5'b00000, clw_imm}, rs1_p, 3'b010, rd_p, OP_LOAD_FP);
                end
                3'b100: begin
                    illegal  = 1'b1;   // reserved
                    inst_out = NOP;
                end
                3'b101: begin
                    // C.FSD -> fsd rs2', off(rs1')
                    inst_out = enc_s({4'b0000, cld_imm}, rs2_p, rs1_p, 3'b011, OP_STORE_FP);
                end
                3'b110: begin
                    // C.SW -> sw rs2', off(rs1')
                    inst_out = enc_s({5'b00000, clw_imm}, rs2_p, rs1_p, 3'b010, OP_STORE);
                end
                3'b111: begin
                    if (IS_RV64)
                        // C.SD -> sd rs2', off(rs1')
                        inst_out = enc_s({4'b0000, cld_imm}, rs2_p, rs1_p, 3'b011, OP_STORE);
                    else
                        // C.FSW -> fsw rs2', off(rs1')
                        inst_out = enc_s({5'b00000, clw_imm}, rs2_p, rs1_p, 3'b010, OP_STORE_FP);
                end
                default: illegal = 1'b1;
            endcase
        end

        // =====================================================================
        // Quadrant 1
        // =====================================================================
        2'b01: begin
            unique case (funct3)
                3'b000: begin
                    // C.NOP (rd=0) / C.ADDI -> addi rd, rd, sext(imm)
                    inst_out = enc_i(ci_imm_sx, rd_rs1, 3'b000, rd_rs1, OP_IMM);
                end
                3'b001: begin
                    if (IS_RV64) begin
                        // C.ADDIW -> addiw rd, rd, sext(imm)   (rd != 0)
                        if (rd_rs1 == 5'd0) illegal = 1'b1;
                        inst_out = enc_i(ci_imm_sx, rd_rs1, 3'b000, rd_rs1, OP_IMM_W);
                    end else begin
                        // C.JAL -> jal x1, off
                        inst_out = enc_jal(cj_off_sx, 5'd1);
                    end
                end
                3'b010: begin
                    // C.LI -> addi rd, x0, sext(imm)
                    inst_out = enc_i(ci_imm_sx, 5'd0, 3'b000, rd_rs1, OP_IMM);
                end
                3'b011: begin
                    if (rd_rs1 == 5'd2) begin
                        // C.ADDI16SP -> addi x2, x2, sext(imm*16)
                        if (addi16sp_imm == 10'd0) illegal = 1'b1;
                        inst_out = enc_i(addi16_imm_sx, 5'd2, 3'b000, 5'd2, OP_IMM);
                    end else begin
                        // C.LUI -> lui rd, sext(imm) << 12
                        if (lui_imm == 6'd0) illegal = 1'b1;
                        inst_out = enc_u(lui_imm_sx, rd_rs1, OP_LUI);
                    end
                end
                3'b100: begin
                    // CB/CA group: C.SRLI / C.SRAI / C.ANDI / register ALU
                    unique case (cinst[11:10])
                        2'b00: begin
                            // C.SRLI -> srli rd', rd', shamt
                            if (!IS_RV64 && ci_shamt[5]) illegal = 1'b1;
                            inst_out = enc_shift(ci_shamt, rs1_p, rs1_p, 3'b101, 1'b0);
                        end
                        2'b01: begin
                            // C.SRAI -> srai rd', rd', shamt
                            if (!IS_RV64 && ci_shamt[5]) illegal = 1'b1;
                            inst_out = enc_shift(ci_shamt, rs1_p, rs1_p, 3'b101, 1'b1);
                        end
                        2'b10: begin
                            // C.ANDI -> andi rd', rd', sext(imm)
                            inst_out = enc_i(andi_imm_sx, rs1_p, 3'b111, rs1_p, OP_IMM);
                        end
                        2'b11: begin
                            // Register-register ALU (C.SUB/XOR/OR/AND/SUBW/ADDW)
                            if (cinst[12] == 1'b0) begin
                                unique case (cinst[6:5])
                                    2'b00: inst_out = enc_r(7'b0100000, rs2_p, rs1_p, 3'b000, rs1_p, OP_REG); // C.SUB
                                    2'b01: inst_out = enc_r(7'b0000000, rs2_p, rs1_p, 3'b100, rs1_p, OP_REG); // C.XOR
                                    2'b10: inst_out = enc_r(7'b0000000, rs2_p, rs1_p, 3'b110, rs1_p, OP_REG); // C.OR
                                    2'b11: inst_out = enc_r(7'b0000000, rs2_p, rs1_p, 3'b111, rs1_p, OP_REG); // C.AND
                                endcase
                            end else begin
                                // W-form: RV64 only
                                if (!IS_RV64) begin
                                    illegal = 1'b1;
                                end else begin
                                    unique case (cinst[6:5])
                                        2'b00: inst_out = enc_r(7'b0100000, rs2_p, rs1_p, 3'b000, rs1_p, OP_REG_W); // C.SUBW
                                        2'b01: inst_out = enc_r(7'b0000000, rs2_p, rs1_p, 3'b000, rs1_p, OP_REG_W); // C.ADDW
                                        default: illegal = 1'b1;   // reserved
                                    endcase
                                end
                            end
                        end
                    endcase
                end
                3'b101: begin
                    // C.J -> jal x0, off
                    inst_out = enc_jal(cj_off_sx, 5'd0);
                end
                3'b110: begin
                    // C.BEQZ -> beq rs1', x0, off
                    inst_out = enc_b(cb_off_sx, 5'd0, rs1_p, 3'b000);
                end
                3'b111: begin
                    // C.BNEZ -> bne rs1', x0, off
                    inst_out = enc_b(cb_off_sx, 5'd0, rs1_p, 3'b001);
                end
                default: illegal = 1'b1;
            endcase
        end

        // =====================================================================
        // Quadrant 2
        // =====================================================================
        2'b10: begin
            unique case (funct3)
                3'b000: begin
                    // C.SLLI -> slli rd, rd, shamt
                    if (!IS_RV64 && ci_shamt[5]) illegal = 1'b1;
                    inst_out = enc_shift(ci_shamt, rd_rs1, rd_rs1, 3'b001, 1'b0);
                end
                3'b001: begin
                    // C.FLDSP -> fld rd, off(x2)  (D-extension)
                    inst_out = enc_i({3'b000, ldsp_imm}, 5'd2, 3'b011, rd_rs1, OP_LOAD_FP);
                end
                3'b010: begin
                    // C.LWSP -> lw rd, off(x2)   (rd != 0)
                    if (rd_rs1 == 5'd0) illegal = 1'b1;
                    inst_out = enc_i({4'b0000, lwsp_imm}, 5'd2, 3'b010, rd_rs1, OP_LOAD);
                end
                3'b011: begin
                    if (IS_RV64) begin
                        // C.LDSP -> ld rd, off(x2)  (rd != 0)
                        if (rd_rs1 == 5'd0) illegal = 1'b1;
                        inst_out = enc_i({3'b000, ldsp_imm}, 5'd2, 3'b011, rd_rs1, OP_LOAD);
                    end else begin
                        // C.FLWSP -> flw rd, off(x2)
                        inst_out = enc_i({4'b0000, lwsp_imm}, 5'd2, 3'b010, rd_rs1, OP_LOAD_FP);
                    end
                end
                3'b100: begin
                    if (cinst[12] == 1'b0) begin
                        if (rs2_c == 5'd0) begin
                            // C.JR -> jalr x0, 0(rs1)   (rs1 != 0)
                            if (rd_rs1 == 5'd0) illegal = 1'b1;
                            inst_out = enc_i(12'd0, rd_rs1, 3'b000, 5'd0, OP_JALR);
                        end else begin
                            // C.MV -> add rd, x0, rs2
                            inst_out = enc_r(7'b0000000, rs2_c, 5'd0, 3'b000, rd_rs1, OP_REG);
                        end
                    end else begin
                        if (rs2_c == 5'd0) begin
                            if (rd_rs1 == 5'd0) begin
                                // C.EBREAK -> ebreak
                                inst_out = 32'h0010_0073;
                            end else begin
                                // C.JALR -> jalr x1, 0(rs1)
                                inst_out = enc_i(12'd0, rd_rs1, 3'b000, 5'd1, OP_JALR);
                            end
                        end else begin
                            // C.ADD -> add rd, rd, rs2
                            inst_out = enc_r(7'b0000000, rs2_c, rd_rs1, 3'b000, rd_rs1, OP_REG);
                        end
                    end
                end
                3'b101: begin
                    // C.FSDSP -> fsd rs2, off(x2)  (D-extension)
                    inst_out = enc_s({3'b000, sdsp_imm}, rs2_c, 5'd2, 3'b011, OP_STORE_FP);
                end
                3'b110: begin
                    // C.SWSP -> sw rs2, off(x2)
                    inst_out = enc_s({4'b0000, swsp_imm}, rs2_c, 5'd2, 3'b010, OP_STORE);
                end
                3'b111: begin
                    if (IS_RV64)
                        // C.SDSP -> sd rs2, off(x2)
                        inst_out = enc_s({3'b000, sdsp_imm}, rs2_c, 5'd2, 3'b011, OP_STORE);
                    else
                        // C.FSWSP -> fsw rs2, off(x2)
                        inst_out = enc_s({4'b0000, swsp_imm}, rs2_c, 5'd2, 3'b010, OP_STORE_FP);
                end
                default: illegal = 1'b1;
            endcase
        end

        // =====================================================================
        // Quadrant 3 (= not compressed): pass-through handled by rv_core.
        // =====================================================================
        default: begin
            inst_out = NOP;
            illegal  = 1'b0;
        end
        endcase
    end

endmodule

`default_nettype wire
