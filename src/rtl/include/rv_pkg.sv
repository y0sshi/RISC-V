// =============================================================================
/// @file rv_pkg.sv
/// @brief Central RISC-V Core Package with Type Definitions and Parameters
///
/// Defines all types, parameters, enumerations, and opcodes for the RISC-V processor.
///
/// **Key Definitions:**
/// - **XLEN**: Data path width (32 or 64 bits) set via +define+RV_XLEN_64
/// - **Types**: xlen_t, inst_t, reg_addr_t, addr_t for hardware modeling
/// - **Opcodes**: Major opcodes (OP_IMM, OP_REG, OP_LOAD, OP_STORE, etc.)
/// - **Control Signals**: ctrl_signals_t struct for pipeline control
/// - **CSR Definitions**: M-mode and S-mode CSRs (mstatus, mie, mepc, etc.)
/// - **Enumerations**: ALU operations, branch conditions, privilege levels
///
/// **Compilation Options:**
/// - Default: RV32I (32-bit)
/// - RV64I: `iverilog -DRV_XLEN_64 ...`
///
/// @author Naofumi Yoshinaga
/// @date 2025-05-22
/// @version 1.0
/// =============================================================================

`ifndef RV_PKG_SV
`define RV_PKG_SV

`timescale 1ns / 1ps

package rv_pkg;

    // =========================================================================
    // Global Parameters
    // =========================================================================

    // Base integer register width (32 or 64)
    // Override at compile time: +define+RV_XLEN=64
`ifdef RV_XLEN_64
    parameter int XLEN = 64;
`else
    parameter int XLEN = 32;
`endif

    parameter int ILEN = 32;               // Instruction length (base)
    parameter int NUM_REGS = 32;            // Number of integer registers
    localparam int REG_ADDR_W = 5;          // Register address width ($clog2(NUM_REGS))

    // =========================================================================
    // Base Types
    // =========================================================================
    typedef logic [XLEN-1:0]      xlen_t;       // XLEN-width data
    typedef logic [ILEN-1:0]      inst_t;        // Instruction word
    typedef logic [4:0]           reg_addr_t;   // Register address (5 bits for 32 registers)
    typedef logic [XLEN-1:0]      addr_t;        // Memory address

    // =========================================================================
    // Opcodes (inst[6:0]) - RV32I/RV64I Base
    // =========================================================================
    typedef enum logic [6:0] {
        OP_LUI      = 7'b0110111,   // Load Upper Immediate
        OP_AUIPC    = 7'b0010111,   // Add Upper Immediate to PC
        OP_JAL      = 7'b1101111,   // Jump and Link
        OP_JALR     = 7'b1100111,   // Jump and Link Register
        OP_BRANCH   = 7'b1100011,   // Branch (BEQ, BNE, BLT, BGE, BLTU, BGEU)
        OP_LOAD     = 7'b0000011,   // Load (LB, LH, LW, LBU, LHU, [LWU, LD])
        OP_STORE    = 7'b0100011,   // Store (SB, SH, SW, [SD])
        OP_IMM      = 7'b0010011,   // Integer Register-Immediate
        OP_REG      = 7'b0110011,   // Integer Register-Register
        OP_FENCE    = 7'b0001111,   // Fence
        OP_SYSTEM   = 7'b1110011,   // System (ECALL, EBREAK, CSR*)
        OP_IMM_W    = 7'b0011011,   // RV64I: Word-width Register-Immediate
        OP_REG_W    = 7'b0111011,   // RV64I: Word-width Register-Register
        OP_AMO      = 7'b0101111    // A extension: Atomic Memory Operations
    } opcode_t;

    // =========================================================================
    // M-Extension (Multiply-Divide) Operations
    // =========================================================================
    typedef enum logic [3:0] {
        MDU_MUL    = 4'd0,   // MUL    lower XLEN bits of rs1×rs2 (signed×signed)
        MDU_MULH   = 4'd1,   // MULH   upper XLEN bits (signed×signed)
        MDU_MULHSU = 4'd2,   // MULHSU upper XLEN bits (signed×unsigned)
        MDU_MULHU  = 4'd3,   // MULHU  upper XLEN bits (unsigned×unsigned)
        MDU_DIV    = 4'd4,   // DIV    signed division
        MDU_DIVU   = 4'd5,   // DIVU   unsigned division
        MDU_REM    = 4'd6,   // REM    signed remainder
        MDU_REMU   = 4'd7,   // REMU   unsigned remainder
        // RV64M W-type: 32-bit op, result sign-extended to XLEN
        MDU_MULW   = 4'd8,   // MULW
        MDU_DIVW   = 4'd9,   // DIVW
        MDU_DIVUW  = 4'd10,  // DIVUW
        MDU_REMW   = 4'd11,  // REMW
        MDU_REMUW  = 4'd12   // REMUW
    } muldiv_op_t;

    // =========================================================================
    // A-Extension (Atomic Memory Operations) — AMO op codes
    // =========================================================================
    typedef enum logic [3:0] {
        AMO_LR    = 4'd0,   // LR.W / LR.D  (Load-Reserved)
        AMO_SC    = 4'd1,   // SC.W / SC.D  (Store-Conditional)
        AMO_SWAP  = 4'd2,   // AMOSWAP
        AMO_ADD   = 4'd3,   // AMOADD
        AMO_XOR   = 4'd4,   // AMOXOR
        AMO_AND   = 4'd5,   // AMOAND
        AMO_OR    = 4'd6,   // AMOOR
        AMO_MIN   = 4'd7,   // AMOMIN  (signed)
        AMO_MAX   = 4'd8,   // AMOMAX  (signed)
        AMO_MINU  = 4'd9,   // AMOMINU (unsigned)
        AMO_MAXU  = 4'd10   // AMOMAXU (unsigned)
    } amo_op_t;

    // =========================================================================
    // ALU Operations
    // =========================================================================
    typedef enum logic [3:0] {
        ALU_ADD     = 4'b0000,
        ALU_SUB     = 4'b0001,
        ALU_SLL     = 4'b0010,
        ALU_SLT     = 4'b0011,
        ALU_SLTU    = 4'b0100,
        ALU_XOR     = 4'b0101,
        ALU_SRL     = 4'b0110,
        ALU_SRA     = 4'b0111,
        ALU_OR      = 4'b1000,
        ALU_AND     = 4'b1001,
        ALU_PASS_B  = 4'b1010,     // Pass operand B (for LUI, AUIPC)
        // RV64I: Word-width ops (32-bit operation, result sign-extended to XLEN)
        ALU_ADDW    = 4'b1011,     // ADDW / ADDIW
        ALU_SUBW    = 4'b1100,     // SUBW
        ALU_SLLW    = 4'b1101,     // SLLW / SLLIW
        ALU_SRLW    = 4'b1110,     // SRLW / SRLIW
        ALU_SRAW    = 4'b1111      // SRAW / SRAIW
    } alu_op_t;

    // =========================================================================
    // funct3 Encodings
    // =========================================================================

    // Branch funct3
    typedef enum logic [2:0] {
        F3_BEQ  = 3'b000,
        F3_BNE  = 3'b001,
        F3_BLT  = 3'b100,
        F3_BGE  = 3'b101,
        F3_BLTU = 3'b110,
        F3_BGEU = 3'b111
    } branch_funct3_t;

    // Load/Store funct3
    typedef enum logic [2:0] {
        F3_BYTE     = 3'b000,   // LB / SB
        F3_HALF     = 3'b001,   // LH / SH
        F3_WORD     = 3'b010,   // LW / SW
        F3_DOUBLE   = 3'b011,   // LD / SD (RV64)
        F3_BYTE_U   = 3'b100,   // LBU
        F3_HALF_U   = 3'b101,   // LHU
        F3_WORD_U   = 3'b110    // LWU (RV64)
    } mem_funct3_t;

    // ALU funct3 (for OP_IMM and OP_REG)
    typedef enum logic [2:0] {
        F3_ADD_SUB = 3'b000,
        F3_SLL     = 3'b001,
        F3_SLT     = 3'b010,
        F3_SLTU    = 3'b011,
        F3_XOR     = 3'b100,
        F3_SRL_SRA = 3'b101,
        F3_OR      = 3'b110,
        F3_AND     = 3'b111
    } alu_funct3_t;

    // System/CSR funct3
    typedef enum logic [2:0] {
        F3_PRIV    = 3'b000,    // ECALL, EBREAK, MRET, SRET, WFI
        F3_CSRRW   = 3'b001,
        F3_CSRRS   = 3'b010,
        F3_CSRRC   = 3'b011,
        F3_CSRRWI  = 3'b101,
        F3_CSRRSI  = 3'b110,
        F3_CSRRCI  = 3'b111
    } sys_funct3_t;

    // =========================================================================
    // Instruction Formats (for immediate extraction)
    // =========================================================================
    typedef enum logic [2:0] {
        FMT_R = 3'b000,
        FMT_I = 3'b001,
        FMT_S = 3'b010,
        FMT_B = 3'b011,
        FMT_U = 3'b100,
        FMT_J = 3'b101
    } inst_fmt_t;

    // =========================================================================
    // ALU Source Selection
    // =========================================================================
    typedef enum logic [1:0] {
        ALU_SRC1_RS1  = 2'b00,  // Register rs1
        ALU_SRC1_PC   = 2'b01,  // Program counter
        ALU_SRC1_ZERO = 2'b10   // Zero (for CSR operations)
    } alu_src1_t;

    typedef enum logic [1:0] {
        ALU_SRC2_RS2  = 2'b00,  // Register rs2
        ALU_SRC2_IMM  = 2'b01,  // Immediate value
        ALU_SRC2_FOUR = 2'b10   // Constant 4 (for JAL/JALR)
    } alu_src2_t;

    // =========================================================================
    // Writeback Source Selection
    // =========================================================================
    typedef enum logic [1:0] {
        WB_SRC_ALU  = 2'b00,   // ALU result
        WB_SRC_MEM  = 2'b01,   // Memory read data
        WB_SRC_PC4  = 2'b10,   // PC + 4 (for JAL/JALR)
        WB_SRC_CSR  = 2'b11    // CSR read data
    } wb_src_t;

    // =========================================================================
    // Control Signals Bundle
    // =========================================================================
    typedef struct packed {
        logic       reg_write;      // Write to register file
        logic       mem_read;       // Read from data memory
        logic       mem_write;      // Write to data memory
        logic       branch;         // Branch instruction
        logic       jump;           // Jump instruction (JAL/JALR)
        logic       jalr;           // JALR (register-indirect jump, target = (rs1+imm)&~1)
        alu_op_t    alu_op;         // ALU operation
        alu_src1_t  alu_src1;       // ALU source 1 selection
        alu_src2_t  alu_src2;       // ALU source 2 selection
        wb_src_t    wb_src;         // Writeback source selection
        logic       csr_write;      // CSR write enable
        logic       is_system;      // System instruction (ECALL/EBREAK/MRET/SRET)
        logic       is_ecall;       // ECALL
        logic       is_ebreak;      // EBREAK
        logic       is_mret;        // MRET (machine trap return)
        logic       is_sret;        // SRET (supervisor trap return, reserved for S-mode)
        // M extension
        logic       is_muldiv;      // Multiply/divide instruction (M extension)
        muldiv_op_t muldiv_op;      // M-extension operation selector
        // A extension
        logic       is_amo;         // Atomic memory operation (A extension)
        logic       is_lr;          // Load-Reserved  (LR.W / LR.D)
        logic       is_sc;          // Store-Conditional (SC.W / SC.D)
        amo_op_t    amo_op;         // AMO operation selector
        // Zicsr / privileged
        logic       is_sfence_vma;  // SFENCE.VMA — flush TLB
    } ctrl_signals_t;

    // =========================================================================
    // Privilege Levels
    // =========================================================================
    typedef enum logic [1:0] {
        PRIV_U = 2'b00,    // User
        PRIV_S = 2'b01,    // Supervisor
        PRIV_M = 2'b11     // Machine
    } priv_level_t;

    // =========================================================================
    // CSR Addresses (subset of commonly used ones)
    // =========================================================================
    // Machine-level CSRs
    parameter logic [11:0] CSR_MSTATUS    = 12'h300;
    parameter logic [11:0] CSR_MISA       = 12'h301;
    parameter logic [11:0] CSR_MEDELEG    = 12'h302;
    parameter logic [11:0] CSR_MIDELEG    = 12'h303;
    parameter logic [11:0] CSR_MIE        = 12'h304;
    parameter logic [11:0] CSR_MTVEC      = 12'h305;
    parameter logic [11:0] CSR_MSCRATCH   = 12'h340;
    parameter logic [11:0] CSR_MEPC       = 12'h341;
    parameter logic [11:0] CSR_MCAUSE     = 12'h342;
    parameter logic [11:0] CSR_MTVAL      = 12'h343;
    parameter logic [11:0] CSR_MIP        = 12'h344;
    parameter logic [11:0] CSR_MCYCLE     = 12'hB00;
    parameter logic [11:0] CSR_MINSTRET   = 12'hB02;
    parameter logic [11:0] CSR_MHARTID    = 12'hF14;

    // Supervisor-level CSRs (for Linux support)
    parameter logic [11:0] CSR_SSTATUS    = 12'h100;
    parameter logic [11:0] CSR_SIE        = 12'h104;
    parameter logic [11:0] CSR_STVEC      = 12'h105;
    parameter logic [11:0] CSR_SSCRATCH   = 12'h140;
    parameter logic [11:0] CSR_SEPC       = 12'h141;
    parameter logic [11:0] CSR_SCAUSE     = 12'h142;
    parameter logic [11:0] CSR_STVAL      = 12'h143;
    parameter logic [11:0] CSR_SIP        = 12'h144;
    parameter logic [11:0] CSR_SATP       = 12'h180;

    // =========================================================================
    // Exception Codes (mcause / scause)
    // =========================================================================
    parameter logic [3:0] EXC_INST_MISALIGN   = 4'd0;
    parameter logic [3:0] EXC_INST_FAULT      = 4'd1;
    parameter logic [3:0] EXC_ILLEGAL_INST    = 4'd2;
    parameter logic [3:0] EXC_BREAKPOINT      = 4'd3;
    parameter logic [3:0] EXC_LOAD_MISALIGN   = 4'd4;
    parameter logic [3:0] EXC_LOAD_FAULT      = 4'd5;
    parameter logic [3:0] EXC_STORE_MISALIGN  = 4'd6;
    parameter logic [3:0] EXC_STORE_FAULT     = 4'd7;
    parameter logic [3:0] EXC_ECALL_U         = 4'd8;
    parameter logic [3:0] EXC_ECALL_S         = 4'd9;
    parameter logic [3:0] EXC_ECALL_M         = 4'd11;
    parameter logic [3:0] EXC_INST_PAGE_FAULT = 4'd12;
    parameter logic [3:0] EXC_LOAD_PAGE_FAULT = 4'd13;
    parameter logic [3:0] EXC_STORE_PAGE_FAULT= 4'd15;

    // =========================================================================
    // Interrupt Codes (mcause / scause, MSB=1)
    // =========================================================================
    parameter logic [3:0] INT_S_SOFTWARE = 4'd1;
    parameter logic [3:0] INT_M_SOFTWARE = 4'd3;
    parameter logic [3:0] INT_S_TIMER    = 4'd5;
    parameter logic [3:0] INT_M_TIMER    = 4'd7;
    parameter logic [3:0] INT_S_EXTERNAL = 4'd9;
    parameter logic [3:0] INT_M_EXTERNAL = 4'd11;

    // =========================================================================
    // Helper Functions
    // =========================================================================

endpackage

`endif // RV_PKG_SV
