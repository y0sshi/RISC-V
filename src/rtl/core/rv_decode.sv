// =============================================================================
/// @file rv_decode.sv
/// @brief Combinational Instruction Decoder
///
/// Decodes 32-bit RISC-V instructions and generates:
/// - **ctrl**: Control signals (ALU operation, memory access type, jump flags)
/// - **imm**: Sign-extended immediate value (12-20 bits depending on format)
/// - **rs1_addr, rs2_addr, rd_addr**: Register addresses
/// - **rs1_used, rs2_used**: Flags indicating which operands are actually used
///
/// **Supported Instructions:**
/// - RV32I / RV64I: All base integer instructions
/// - RV32M / RV64M: Multiply/Divide (via ctrl.alu_op)
/// - RV32A / RV64A: Atomic operations (via ctrl.is_amo)
/// - Zicsr: CSR read/write operations
/// - ECALL, EBREAK, MRET, SRET: Privilege instructions
///
/// **Immediate Encoding (I/S/B/U/J types):**
/// - I-type: imm = inst[31:20] sign-extended (12 bits)
/// - S-type: imm = {inst[31:25], inst[11:7]} sign-extended (12 bits)
/// - B-type: imm = {inst[31], inst[7], inst[30:25], inst[11:8]} << 1 (13 bits)
/// - U-type: imm = inst[31:12] << 12 (20 bits)
/// - J-type: imm = {inst[31], inst[19:12], inst[20], inst[30:21]} << 1 (21 bits)
///
/// @param XLEN Data path width (32 or 64)
/// @author Naofumi Yoshinaga
/// @date 2025-05-22
/// @version 1.0
/// =============================================================================

`default_nettype none

module rv_decode
    import rv_pkg::*;
#(
    parameter int XLEN = rv_pkg::XLEN
) (
    input  wire  [31:0]       inst,

    output ctrl_signals_t     ctrl,
    output logic [XLEN-1:0]   imm,
    output reg_addr_t         rs1_addr,
    output reg_addr_t         rs2_addr,
    output reg_addr_t         rd_addr,
    output logic              rs1_used,   // instruction actually reads rs1
    output logic              rs2_used    // instruction actually reads rs2
);

    // =========================================================================
    // Instruction field extraction
    // =========================================================================
    wire [6:0] opcode = inst[6:0];
    wire [2:0] funct3 = inst[14:12];
    wire [6:0] funct7 = inst[31:25];

    assign rs1_addr = inst[19:15];
    assign rs2_addr = inst[24:20];
    assign rd_addr  = inst[11:7];

    // =========================================================================
    // Immediate Generation
    // =========================================================================
    always_comb begin
        case (opcode)
            // I-type
            OP_IMM, OP_LOAD, OP_JALR, OP_IMM_W: begin
                imm = {{(XLEN-12){inst[31]}}, inst[31:20]};
            end
            // S-type
            OP_STORE: begin
                imm = {{(XLEN-12){inst[31]}}, inst[31:25], inst[11:7]};
            end
            // B-type
            OP_BRANCH: begin
                imm = {{(XLEN-13){inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
            end
            // U-type
            OP_LUI, OP_AUIPC: begin
                imm = {{(XLEN-32){inst[31]}}, inst[31:12], 12'b0};
            end
            // J-type
            OP_JAL: begin
                imm = {{(XLEN-21){inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};
            end
            // System (CSR immediate in rs1 field, zero-extended)
            OP_SYSTEM: begin
                imm = {{(XLEN-5){1'b0}}, inst[19:15]};
            end
            default: begin
                imm = '0;
            end
        endcase
    end

    // =========================================================================
    // Control Signal Generation
    // =========================================================================
    always_comb begin
        // Default: NOP-like (no side effects)
        ctrl     = '0;
        rs1_used = 1'b0;
        rs2_used = 1'b0;

        case (opcode)
            OP_LUI: begin
                ctrl.reg_write = 1'b1;
                ctrl.alu_op    = ALU_PASS_B;
                ctrl.alu_src2  = ALU_SRC2_IMM;
                ctrl.wb_src    = WB_SRC_ALU;
            end

            OP_AUIPC: begin
                ctrl.reg_write = 1'b1;
                ctrl.alu_op    = ALU_ADD;
                ctrl.alu_src1  = ALU_SRC1_PC;
                ctrl.alu_src2  = ALU_SRC2_IMM;
                ctrl.wb_src    = WB_SRC_ALU;
            end

            OP_JAL: begin
                ctrl.reg_write = 1'b1;
                ctrl.jump      = 1'b1;
                ctrl.wb_src    = WB_SRC_PC4;
            end

            OP_JALR: begin
                ctrl.reg_write = 1'b1;
                ctrl.jump      = 1'b1;
                ctrl.jalr      = 1'b1;   // Distinguish JALR from JAL (target = alu_result)
                ctrl.alu_op    = ALU_ADD;
                ctrl.alu_src2  = ALU_SRC2_IMM;
                ctrl.wb_src    = WB_SRC_PC4;
                rs1_used       = 1'b1;
            end

            OP_BRANCH: begin
                ctrl.branch    = 1'b1;
                ctrl.alu_op    = ALU_SUB;
                rs1_used       = 1'b1;
                rs2_used       = 1'b1;
            end

            OP_LOAD: begin
                ctrl.reg_write = 1'b1;
                ctrl.mem_read  = 1'b1;
                ctrl.alu_op    = ALU_ADD;
                ctrl.alu_src2  = ALU_SRC2_IMM;
                ctrl.wb_src    = WB_SRC_MEM;
                rs1_used       = 1'b1;
            end

            OP_STORE: begin
                ctrl.mem_write = 1'b1;
                ctrl.alu_op    = ALU_ADD;
                ctrl.alu_src2  = ALU_SRC2_IMM;
                rs1_used       = 1'b1;
                rs2_used       = 1'b1;
            end

            OP_IMM: begin
                ctrl.reg_write = 1'b1;
                ctrl.alu_src2  = ALU_SRC2_IMM;
                ctrl.wb_src    = WB_SRC_ALU;
                rs1_used       = 1'b1;
                // Decode ALU operation from funct3 + funct7
                case (funct3)
                    F3_ADD_SUB: ctrl.alu_op = ALU_ADD;   // ADDI (no SUB for immediate)
                    F3_SLL:     ctrl.alu_op = ALU_SLL;
                    F3_SLT:     ctrl.alu_op = ALU_SLT;
                    F3_SLTU:    ctrl.alu_op = ALU_SLTU;
                    F3_XOR:     ctrl.alu_op = ALU_XOR;
                    F3_SRL_SRA: ctrl.alu_op = inst[30] ? ALU_SRA : ALU_SRL;
                    F3_OR:      ctrl.alu_op = ALU_OR;
                    F3_AND:     ctrl.alu_op = ALU_AND;
                    default:    ctrl.alu_op = ALU_ADD;
                endcase
            end

            OP_REG: begin
                ctrl.reg_write = 1'b1;
                ctrl.wb_src    = WB_SRC_ALU;
                rs1_used       = 1'b1;
                rs2_used       = 1'b1;
                if (funct7 == 7'b0000001) begin
                    // RV32M / RV64M: Multiply-Divide (funct7 = 0000001)
                    ctrl.is_muldiv = 1'b1;
                    unique case (funct3)
                        3'b000: ctrl.muldiv_op = MDU_MUL;
                        3'b001: ctrl.muldiv_op = MDU_MULH;
                        3'b010: ctrl.muldiv_op = MDU_MULHSU;
                        3'b011: ctrl.muldiv_op = MDU_MULHU;
                        3'b100: ctrl.muldiv_op = MDU_DIV;
                        3'b101: ctrl.muldiv_op = MDU_DIVU;
                        3'b110: ctrl.muldiv_op = MDU_REM;
                        3'b111: ctrl.muldiv_op = MDU_REMU;
                    endcase
                end else begin
                    // RV32I / RV64I base integer R-type
                    case (funct3)
                        F3_ADD_SUB: ctrl.alu_op = inst[30] ? ALU_SUB : ALU_ADD;
                        F3_SLL:     ctrl.alu_op = ALU_SLL;
                        F3_SLT:     ctrl.alu_op = ALU_SLT;
                        F3_SLTU:    ctrl.alu_op = ALU_SLTU;
                        F3_XOR:     ctrl.alu_op = ALU_XOR;
                        F3_SRL_SRA: ctrl.alu_op = inst[30] ? ALU_SRA : ALU_SRL;
                        F3_OR:      ctrl.alu_op = ALU_OR;
                        F3_AND:     ctrl.alu_op = ALU_AND;
                        default:    ctrl.alu_op = ALU_ADD;
                    endcase
                end
            end

            // -----------------------------------------------------------------
            // RV64I: Word-width register-immediate (ADDIW, SLLIW, SRLIW, SRAIW)
            // -----------------------------------------------------------------
            OP_IMM_W: begin
                ctrl.reg_write = 1'b1;
                ctrl.alu_src2  = ALU_SRC2_IMM;
                ctrl.wb_src    = WB_SRC_ALU;
                rs1_used       = 1'b1;
                case (funct3)
                    F3_ADD_SUB: ctrl.alu_op = ALU_ADDW;               // ADDIW
                    F3_SLL:     ctrl.alu_op = ALU_SLLW;               // SLLIW
                    F3_SRL_SRA: ctrl.alu_op = inst[30] ? ALU_SRAW     // SRAIW
                                                       : ALU_SRLW;    // SRLIW
                    default:    ctrl.alu_op = ALU_ADDW;
                endcase
            end

            // -----------------------------------------------------------------
            // RV64I: Word-width register-register (ADDW, SUBW, SLLW, SRLW, SRAW)
            // -----------------------------------------------------------------
            OP_REG_W: begin
                ctrl.reg_write = 1'b1;
                ctrl.wb_src    = WB_SRC_ALU;
                rs1_used       = 1'b1;
                rs2_used       = 1'b1;
                if (funct7 == 7'b0000001) begin
                    // RV64M: W-type multiply-divide
                    ctrl.is_muldiv = 1'b1;
                    unique case (funct3)
                        3'b000: ctrl.muldiv_op = MDU_MULW;
                        3'b100: ctrl.muldiv_op = MDU_DIVW;
                        3'b101: ctrl.muldiv_op = MDU_DIVUW;
                        3'b110: ctrl.muldiv_op = MDU_REMW;
                        3'b111: ctrl.muldiv_op = MDU_REMUW;
                        default: ctrl.muldiv_op = MDU_MULW;
                    endcase
                end else begin
                    // RV64I base W-type
                    case (funct3)
                        F3_ADD_SUB: ctrl.alu_op = inst[30] ? ALU_SUBW : ALU_ADDW;
                        F3_SLL:     ctrl.alu_op = ALU_SLLW;
                        F3_SRL_SRA: ctrl.alu_op = inst[30] ? ALU_SRAW : ALU_SRLW;
                        default:    ctrl.alu_op = ALU_ADDW;
                    endcase
                end
            end

            // -----------------------------------------------------------------
            // A extension: Atomic Memory Operations
            //   inst[31:27] = funct5  (operation)
            //   inst[26]    = aq      (acquire ordering — ignored for now)
            //   inst[25]    = rl      (release ordering — ignored for now)
            //   inst[14:12] = funct3  (010=W, 011=D)
            //   inst[24:20] = rs2     (operand / store data; 00000 for LR)
            //   inst[19:15] = rs1     (base address)
            //   inst[11:7]  = rd      (destination)
            // -----------------------------------------------------------------
            OP_AMO: begin
                ctrl.reg_write = 1'b1;
                ctrl.is_amo    = 1'b1;
                ctrl.wb_src    = WB_SRC_MEM;   // default: return old memory value
                rs1_used       = 1'b1;          // rs1 = address
                unique case (inst[31:27])
                    5'b00010: begin   // LR.W / LR.D
                        ctrl.is_lr  = 1'b1;
                        ctrl.amo_op = AMO_LR;
                        // rs2 = x0 per spec; we don't mark rs2_used
                    end
                    5'b00011: begin   // SC.W / SC.D
                        ctrl.is_sc  = 1'b1;
                        ctrl.amo_op = AMO_SC;
                        ctrl.wb_src = WB_SRC_ALU;   // returns 0 (success) or 1 (failure)
                        rs2_used    = 1'b1;
                    end
                    5'b00001: begin ctrl.amo_op = AMO_SWAP; rs2_used = 1'b1; end  // AMOSWAP
                    5'b00000: begin ctrl.amo_op = AMO_ADD;  rs2_used = 1'b1; end  // AMOADD
                    5'b00100: begin ctrl.amo_op = AMO_XOR;  rs2_used = 1'b1; end  // AMOXOR
                    5'b01100: begin ctrl.amo_op = AMO_AND;  rs2_used = 1'b1; end  // AMOAND
                    5'b01000: begin ctrl.amo_op = AMO_OR;   rs2_used = 1'b1; end  // AMOOR
                    5'b10000: begin ctrl.amo_op = AMO_MIN;  rs2_used = 1'b1; end  // AMOMIN
                    5'b10100: begin ctrl.amo_op = AMO_MAX;  rs2_used = 1'b1; end  // AMOMAX
                    5'b11000: begin ctrl.amo_op = AMO_MINU; rs2_used = 1'b1; end  // AMOMINU
                    5'b11100: begin ctrl.amo_op = AMO_MAXU; rs2_used = 1'b1; end  // AMOMAXU
                    default: ;
                endcase
            end

            OP_FENCE: begin
                // NOP for now; fence is a hint in simple implementations
            end

            OP_SYSTEM: begin
                if (funct3 != F3_PRIV) begin
                    // CSR instructions (CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI)
                    ctrl.reg_write = 1'b1;
                    ctrl.csr_write = 1'b1;
                    ctrl.wb_src    = WB_SRC_CSR;
                    // Immediate forms (funct3[2]=1): write data is zimm in inst[19:15]
                    if (funct3[2]) begin
                        ctrl.alu_src1 = ALU_SRC1_ZERO;
                    end else begin
                        rs1_used = 1'b1;
                    end
                end else begin
                    // PRIV instructions: decode by inst[31:20]
                    ctrl.is_system = 1'b1;
                    case (inst[31:20])
                        12'h000: ctrl.is_ecall  = 1'b1;  // ECALL
                        12'h001: ctrl.is_ebreak = 1'b1;  // EBREAK
                        12'h302: ctrl.is_mret   = 1'b1;  // MRET  (0011_0000_0010)
                        12'h102: ctrl.is_sret   = 1'b1;  // SRET  (0001_0000_0010)
                        default: begin
                            // SFENCE.VMA: funct7=0001001, rs2=any, rs1=any, funct3=000, rd=0
                            if (inst[31:25] == 7'b0001001)
                                ctrl.is_sfence_vma = 1'b1;
                        end
                    endcase
                end
            end

            default: begin
                // Illegal instruction - keep default (NOP)
            end
        endcase
    end

endmodule

`default_nettype wire
