// =============================================================================
/// @file rv_core.sv
/// @brief RISC-V Processor Core with 5-Stage In-Order Pipeline
///
/// Implements a classic 5-stage in-order pipeline:
/// - **IF** (Instruction Fetch): Load instruction from IMEM (synchronous read)
/// - **ID** (Decode): Decode instruction, read registers, extract immediates
/// - **EX** (Execute): Execute ALU operations, evaluate branches, forward data
/// - **MEM** (Memory): Access data memory (DMEM) for load/store operations
/// - **WB** (Write Back): Write results back to register file
///
/// **Key Features:**
/// - Data forwarding: EX/MEM (1-cycle old) and MEM/WB (2-cycle old) results
/// - Load-use hazard: Stall insertion via rv_hazard module
/// - Branch/Jump resolution: 2-cycle pipeline flush (IF/ID + ID/EX bubble)
/// - Interrupt handling: Priority-based with mstatus.MIE masking
/// - Privilege levels: M-mode, S-mode, U-mode with delegation
/// - RV32I/RV64I base + M (multiply/divide) + A (atomics) + Zicsr
///
/// **Memory Timing:**
/// - IMEM: Synchronous read (1-cycle latency). fetch_pc tracks pending instruction.
/// - DMEM: Synchronous read, data available in WB stage.
///
/// @param XLEN Data path width: 32 (RV32I) or 64 (RV64I)
/// @param RST_ADDR Reset address (default 0x0000_0000)
///
/// @author Naofumi Yoshinaga
/// @date 2025-05-22
/// @version 1.0
/// =============================================================================

`default_nettype none

module rv_core
    import rv_pkg::*;
#(
    parameter int          XLEN     = rv_pkg::XLEN,
    parameter logic [63:0] RST_ADDR = 64'h0000_0000_0000_0000
) (
    input  wire              clk,
    input  wire              rst_n,

    // Instruction memory interface
    output logic [XLEN-1:0]  imem_addr,
    output logic             imem_req,
    input  wire  [31:0]      imem_rdata,
    input  wire              imem_ready,

    // Data memory interface
    output logic [XLEN-1:0]  dmem_addr,
    output logic [XLEN-1:0]    dmem_wdata,
    output logic [XLEN/8-1:0]  dmem_wstrb,   // 4b(RV32) or 8b(RV64)
    output logic             dmem_req,
    output logic             dmem_we,
    input  wire  [XLEN-1:0]  dmem_rdata,
    input  wire              dmem_ready,

    // MMU state outputs (to rv_mmu)
    output logic [XLEN-1:0]  satp_out,        // SATP CSR value
    output priv_level_t      priv_out,        // current privilege level
    output logic             mstatus_sum_out, // mstatus.SUM
    output logic             mstatus_mxr_out, // mstatus.MXR
    output logic             tlb_flush_out,   // SFENCE.VMA pulse

    // MMU stall input (from rv_mmu, when PTW in progress)
    input  wire              mmu_stall,

    // External interrupt inputs
    input  wire              timer_irq,   // machine timer interrupt (MTIP/STIP via mideleg)
    input  wire              sw_irq,      // software interrupt
    input  wire              ext_irq      // external interrupt
);

    // =========================================================================
    // Pipeline control
    // =========================================================================
    logic load_use_hazard;
    logic branch_taken_ex;
    logic [XLEN-1:0] branch_target_ex;

    // CSR module outputs
    logic [XLEN-1:0] sepc_out;        // sepc for SRET


    // Trap / MRET / SRET signals from EX stage (combinational, redirect PC next cycle)
    logic        ex_trap_enter;   // ECALL or EBREAK in EX
    logic        ex_mret_en;      // MRET in EX
    logic        ex_sret_en;      // SRET in EX
    logic        trap_or_mret;    // Combined: causes PC redirect + pipeline flush
    assign trap_or_mret = ex_trap_enter | ex_mret_en | ex_sret_en;

    // Trap destinations from rv_csr
    logic [XLEN-1:0] trap_vector; // mtvec — used on trap_enter
    logic [XLEN-1:0] mepc_out;    // mepc  — used on mret_en

    logic stall_if;      // freeze PC and IF/ID register
    logic stall_id;      // freeze IF/ID register
    logic stall_ex;      // freeze EX/MEM register (AMO 2-phase stall)
    logic flush_id;      // clear IF/ID   -> insert bubble into ID
    logic flush_ex;      // clear ID/EX   -> insert bubble into EX
    logic flush_ex_mem;  // clear EX/MEM  -> discard trap-interrupted instruction

    // amo_stall: holds the whole pipeline while AMO executes its read phase.
    // Declared here; driven after AMO state logic below.
    logic amo_stall;

    // mal_stall: holds the whole pipeline during misaligned access phase 0.
    // Declared here; driven after misaligned FSM below.
    logic mal_stall;
    logic mal_state;                 // 0 = phase 0 (first word), 1 = phase 1 (second word)
    logic [XLEN-1:0] mal_first_data; // first-read result saved during phase 1
    logic mal_active_wb;             // MEM/WB: this load crossed a word boundary

    // fpu_busy_int: multi-cycle FPU (FDIV/FSQRT) in progress.
    // Declared here (before stall assign); driven after FPU instantiation below.
    logic fpu_busy_int;
    // fpu_was_busy: 1-cycle delayed fpu_busy_int.
    // Prevents re-triggering the FPU on the cycle when fpu_busy_int falls (result
    // arrives), before ID/EX has advanced past the completed FDIV/FSQRT instruction.
    logic fpu_was_busy;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) fpu_was_busy <= 1'b0;
        else        fpu_was_busy <= fpu_busy_int;
    end

    // fpu_start_stall: stall IF/ID for the one cycle when FDIV/FSQRT first enters EX.
    // Declared here (before stall assigns); driven after fpu_valid_in assignment below.
    // Without this, the instruction after FDIV advances into ID/EX on the same cycle
    // that fpu_busy_int goes high (NBA), so FDIV is lost from ID/EX before WB.
    logic fpu_valid_in;    // forward-declared; driven below
    logic fpu_start_stall; // forward-declared; driven below

    // Number of address bits that select a byte lane within one DMEM data word.
    // RV32: 2 bits (addr[1:0]) -> 4-byte word, wstrb is 4 bits
    // RV64: 3 bits (addr[2:0]) -> 8-byte logical word (two 32-bit BRAM halves), wstrb is 8 bits
    // Using [2:0] for RV32 causes overflow: SW to addr[2]=1 gives wstrb=0 (no write).
    localparam int BYTE_LANE_W = $clog2(XLEN/8);

    // redirect_q: 1-cycle delayed version of any PC redirect (branch/trap/MRET).
    // Because IMEM is a synchronous BRAM (1-cycle read latency), the cycle after a
    // redirect the BRAM still outputs data fetched from the OLD PC.  We must flush
    // the IF/ID register for two consecutive cycles to discard both the in-flight
    // fetch that was already issued (flushed by flush_id cycle 0) and the stale
    // BRAM result that arrives one cycle later (flushed by redirect_q cycle 1).
    logic redirect_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) redirect_q <= 1'b0;
        else        redirect_q <= branch_taken_ex | trap_or_mret;
    end

    assign stall_if = load_use_hazard | ~imem_ready | amo_stall | mmu_stall | fpu_busy_int | fpu_start_stall | mal_stall;
    assign stall_id = load_use_hazard | ~imem_ready | amo_stall | mmu_stall | fpu_busy_int | fpu_start_stall | mal_stall;
    assign stall_ex = amo_stall | fpu_busy_int | mal_stall;
    // Traps/MRET flush the same stages as branch (instructions after the trap insn).
    // flush_id is asserted for 2 cycles: cycle 0 (branch_taken_ex | trap_or_mret)
    // discards the instruction that was fetched alongside the branch; cycle 1
    // (redirect_q) discards the stale BRAM result from the OLD pc_reg that arrives
    // one cycle after the redirect due to synchronous-BRAM read latency.
    assign flush_id    = branch_taken_ex | redirect_q | trap_or_mret;
    // Suppress load-use bubble injection when stall_ex=1: the load can't
    // advance to EX/MEM while the pipeline is frozen, so keep it in ID/EX
    // (stall_id holds it there) rather than flushing it.  The bubble will be
    // injected naturally on the cycle when stall_ex drops to 0.
    assign flush_ex    = (load_use_hazard && !stall_ex) | branch_taken_ex | trap_or_mret;
    // EX/MEM must NOT be flushed for branch or load-use:
    //   - branch in EX: EX/MEM holds the instruction before the branch (already
    //     committed to EX; it must reach MEM/WB).  JAL's rd writeback also lives
    //     here and must not be discarded.
    //   - load-use in EX: the load itself must proceed to MEM so dmem is accessed.
    // Only flush EX/MEM for traps/MRET to prevent the interrupted instruction
    // from spuriously writing its destination register.
    assign flush_ex_mem = trap_or_mret;

    // =========================================================================
    // Stage 1: Instruction Fetch (IF)
    // =========================================================================
    // pc_reg    : address sent to BRAM this cycle (BRAM latches it on posedge)
    // fetch_pc  : address that was sent last cycle = PC of the instruction
    //             that will appear on imem_rdata this cycle.
    //
    // Timeline with 1-cycle BRAM:
    //   cycle N  : pc_reg = X  → BRAM address registered
    //   cycle N+1: imem_rdata = mem[X], imem_ready = 1
    //              fetch_pc = X  ← captured from pc_reg of cycle N
    //
    // IF/ID captures (imem_rdata, fetch_pc) so the correct PC is associated
    // with each instruction.

    logic [XLEN-1:0] pc_reg;
    logic [XLEN-1:0] fetch_pc;  // delayed PC matching current imem_rdata

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          pc_reg <= RST_ADDR[XLEN-1:0];
        else if (!stall_if)  pc_reg <= ex_trap_enter    ? trap_vector       :
                                        ex_mret_en       ? mepc_out          :
                                        ex_sret_en       ? sepc_out          :
                                        branch_taken_ex  ? branch_target_ex  :
                                                           (pc_reg + XLEN'(4));
    end

    // fetch_pc follows pc_reg with 1-cycle delay (tracks BRAM input address)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)         fetch_pc <= RST_ADDR[XLEN-1:0];
        else if (!stall_if) fetch_pc <= pc_reg;
    end

    // During a stall (stall_if=1), re-issue the fetch for fetch_pc rather than
    // advancing to the stalled pc_reg.  Without this, the BRAM latches pc_reg
    // (already advanced past the pending instruction) during the stall cycle, so
    // the instruction arriving in imem_rdata this cycle is lost and the BRAM
    // skips ahead by one instruction when the stall resolves.
    // By re-feeding fetch_pc to the BRAM, it re-delivers mem[fetch_pc] in the
    // first cycle after the stall, which if_id then correctly captures.
    assign imem_addr = stall_if ? fetch_pc : pc_reg;
    assign imem_req  = 1'b1;

    // =========================================================================
    // IF/ID Pipeline Register  (between IF and ID)
    // =========================================================================
    logic [31:0]     if_id_inst;
    logic [XLEN-1:0] if_id_pc;
    logic            if_id_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_id) begin
            if_id_inst  <= 32'h0000_0013;   // NOP (ADDI x0, x0, 0)
            if_id_pc    <= '0;
            if_id_valid <= 1'b0;
        end else if (!stall_id) begin
            if_id_inst  <= imem_rdata;
            if_id_pc    <= fetch_pc;        // use fetch_pc (not pc_reg) for sync BRAM
            if_id_valid <= imem_ready;
        end
        // else: stall — hold current value
    end

    // =========================================================================
    // Stage 2: Instruction Decode (ID)
    // =========================================================================
    ctrl_signals_t   id_ctrl;
    logic [XLEN-1:0] id_imm;
    reg_addr_t       id_rs1_addr, id_rs2_addr, id_rs3_addr, id_rd_addr;
    logic            id_rs1_used, id_rs2_used;
    logic [XLEN-1:0] id_rs1_data, id_rs2_data;

    rv_decode #(.XLEN(XLEN)) u_decode (
        .inst       (if_id_inst),
        .ctrl       (id_ctrl),
        .imm        (id_imm),
        .rs1_addr   (id_rs1_addr),
        .rs2_addr   (id_rs2_addr),
        .rs3_addr   (id_rs3_addr),
        .rd_addr    (id_rd_addr),
        .rs1_used   (id_rs1_used),
        .rs2_used   (id_rs2_used)
    );

    // WB-stage signals (declared here; driven by always_comb after MEM/WB register).
    // Forward-referenced here because the register file and forwarding unit need them.
    logic [XLEN-1:0] wb_data;
    reg_addr_t       wb_rd_addr;
    logic            wb_reg_write;

    rv_regfile #(.XLEN(XLEN)) u_regfile (
        .clk      (clk),
        .rst_n    (rst_n),
        .rs1_addr (id_rs1_addr),
        .rs2_addr (id_rs2_addr),
        .rs1_data (id_rs1_data),
        .rs2_data (id_rs2_data),
        .rd_addr  (wb_rd_addr),
        .rd_data  (wb_data),
        .rd_we    (wb_reg_write)
    );

    // =========================================================================
    // F-Extension: FP Register File (32 x 32-bit, 3 read ports + 1 write port)
    // =========================================================================
    logic [31:0]  id_frs1_data, id_frs2_data, id_frs3_data;
    logic [31:0]  wb_freg_data;   // FP WB write data
    reg_addr_t    wb_frd_addr;    // FP WB write address
    logic         wb_freg_write;  // FP WB write enable

    rv_fregfile u_fregfile (
        .clk      (clk),
        .rst_n    (rst_n),
        .rs1_addr (id_rs1_addr),
        .rs2_addr (id_rs2_addr),
        .rs3_addr (id_rs3_addr),
        .rs1_data (id_frs1_data),
        .rs2_data (id_frs2_data),
        .rs3_data (id_frs3_data),
        .rd_addr  (wb_frd_addr),
        .rd_data  (wb_freg_data),
        .rd_we    (wb_freg_write)
    );

    // =========================================================================
    // ID/EX Pipeline Register  (between ID and EX)
    // =========================================================================
    ctrl_signals_t   id_ex_ctrl;
    logic [XLEN-1:0] id_ex_rs1_data, id_ex_rs2_data;
    logic [XLEN-1:0] id_ex_imm;
    reg_addr_t       id_ex_rs1_addr, id_ex_rs2_addr, id_ex_rs3_addr, id_ex_rd_addr;
    logic [XLEN-1:0] id_ex_pc;
    logic [2:0]      id_ex_funct3;
    logic [11:0]     id_ex_csr_addr;   // inst[31:20] — CSR address for Zicsr
    logic            id_ex_valid;
    // FP operands registered from fregfile
    logic [31:0]     id_ex_frs1_data, id_ex_frs2_data, id_ex_frs3_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_ex) begin
            id_ex_ctrl      <= '0;
            id_ex_rs1_data  <= '0;
            id_ex_rs2_data  <= '0;
            id_ex_imm       <= '0;
            id_ex_rs1_addr  <= '0;
            id_ex_rs2_addr  <= '0;
            id_ex_rs3_addr  <= '0;
            id_ex_rd_addr   <= '0;
            id_ex_pc        <= '0;
            id_ex_funct3    <= '0;
            id_ex_csr_addr  <= '0;
            id_ex_valid     <= 1'b0;
            id_ex_frs1_data <= '0;
            id_ex_frs2_data <= '0;
            id_ex_frs3_data <= '0;
        end else if (!stall_id) begin
            id_ex_ctrl      <= id_ctrl;
            id_ex_rs1_data  <= id_rs1_data;
            id_ex_rs2_data  <= id_rs2_data;
            id_ex_imm       <= id_imm;
            id_ex_rs1_addr  <= id_rs1_addr;
            id_ex_rs2_addr  <= id_rs2_addr;
            id_ex_rs3_addr  <= id_rs3_addr;
            id_ex_rd_addr   <= id_rd_addr;
            id_ex_pc        <= if_id_pc;
            id_ex_funct3    <= if_id_inst[14:12];
            id_ex_csr_addr  <= if_id_inst[31:20];
            id_ex_valid     <= if_id_valid;
            id_ex_frs1_data <= id_frs1_data;
            id_ex_frs2_data <= id_frs2_data;
            id_ex_frs3_data <= id_frs3_data;
        end
        // else: stall_id=1 && !flush_ex — hold current ID/EX value
    end

    // =========================================================================
    // Stage 3: Execute (EX)
    // =========================================================================

    // --- EX/MEM and MEM/WB registers (forward-declared for forwarding unit) ---
    ctrl_signals_t   ex_mem_ctrl;
    logic [XLEN-1:0] ex_mem_alu_result;
    logic [XLEN-1:0] ex_mem_rs2_data;
    reg_addr_t       ex_mem_rd_addr;
    logic [XLEN-1:0] ex_mem_pc4;
    logic [2:0]      ex_mem_funct3;
    logic            ex_mem_valid;
    logic [XLEN-1:0] ex_mem_csr_fwd;     // forward-decl: used in ex_mem_fwd_data mux before definition
    logic [XLEN-1:0] ex_mem_fpu_result_i_fwd;  // forward-decl: FPU int result for EX/MEM forwarding

    ctrl_signals_t   mem_wb_ctrl;
    logic [XLEN-1:0] mem_wb_alu_result;
    reg_addr_t       mem_wb_rd_addr;
    logic [XLEN-1:0] mem_wb_pc4;
    logic            mem_wb_valid;

    // --- Data to forward from EX/MEM ---
    // For loads in EX/MEM: alu_result is the load address, NOT the data.
    // The load-use stall prevents any consumer from reaching EX while the load
    // is in EX/MEM, so forwarding ex_mem_alu_result for loads is never exercised.
    logic [XLEN-1:0] ex_mem_fwd_data;
    always_comb begin
        case (ex_mem_ctrl.wb_src)
            WB_SRC_PC4:  ex_mem_fwd_data = ex_mem_pc4;
            WB_SRC_CSR:  ex_mem_fwd_data = ex_mem_csr_fwd;
            WB_SRC_FPU:  ex_mem_fwd_data = ex_mem_fpu_result_i_fwd;
            default:     ex_mem_fwd_data = ex_mem_alu_result;
        endcase
    end

    // --- Forwarding unit ---
    logic [1:0] fwd_rs1_sel, fwd_rs2_sel;
    logic [1:0] fwd_frs1_sel, fwd_frs2_sel, fwd_frs3_sel;

    rv_forward #(.XLEN(XLEN)) u_forward (
        .id_ex_rs1_addr (id_ex_rs1_addr),
        .id_ex_rs2_addr (id_ex_rs2_addr),
        .id_ex_rs3_addr (id_ex_rs3_addr),
        .ex_mem_valid   (ex_mem_valid),
        .ex_mem_ctrl    (ex_mem_ctrl),
        .ex_mem_rd_addr (ex_mem_rd_addr),
        .mem_wb_valid   (mem_wb_valid),
        .mem_wb_ctrl    (mem_wb_ctrl),
        .mem_wb_rd_addr (mem_wb_rd_addr),
        .fwd_rs1_sel    (fwd_rs1_sel),
        .fwd_rs2_sel    (fwd_rs2_sel),
        .fwd_frs1_sel   (fwd_frs1_sel),
        .fwd_frs2_sel   (fwd_frs2_sel),
        .fwd_frs3_sel   (fwd_frs3_sel)
    );

    // --- Forwarded operands ---
    // wb_data (MEM/WB result) is defined after the MEM/WB register below.
    // SV always_comb allows this forward reference since there is no circular path.
    logic [XLEN-1:0] fwd_rs1_data, fwd_rs2_data;

    always_comb begin
        unique case (fwd_rs1_sel)
            2'b01:   fwd_rs1_data = ex_mem_fwd_data;   // EX/MEM forward
            2'b10:   fwd_rs1_data = wb_data;            // MEM/WB forward
            default: fwd_rs1_data = id_ex_rs1_data;     // register file
        endcase
    end

    always_comb begin
        unique case (fwd_rs2_sel)
            2'b01:   fwd_rs2_data = ex_mem_fwd_data;   // EX/MEM forward
            2'b10:   fwd_rs2_data = wb_data;            // MEM/WB forward
            default: fwd_rs2_data = id_ex_rs2_data;     // register file
        endcase
    end

    // --- FP forwarded operands ---
    // Forward-declare pipeline register signals so the mux below can reference them
    // before their full declaration in the EX/MEM and MEM/WB register sections.
    logic [31:0] ex_mem_fpu_result_f;
    logic [31:0] mem_wb_fpu_result_f;
    logic [31:0] fwd_frs1_data, fwd_frs2_data, fwd_frs3_data;

    always_comb begin
        unique case (fwd_frs1_sel)
            2'b01:   fwd_frs1_data = ex_mem_fpu_result_f;   // EX/MEM forward
            2'b10:   fwd_frs1_data = wb_freg_data;          // MEM/WB: uses dmem_rdata for FLW, fpu_result for FPU ops
            default: fwd_frs1_data = id_ex_frs1_data;       // FP register file
        endcase
    end

    always_comb begin
        unique case (fwd_frs2_sel)
            2'b01:   fwd_frs2_data = ex_mem_fpu_result_f;
            2'b10:   fwd_frs2_data = wb_freg_data;
            default: fwd_frs2_data = id_ex_frs2_data;
        endcase
    end

    always_comb begin
        unique case (fwd_frs3_sel)
            2'b01:   fwd_frs3_data = ex_mem_fpu_result_f;
            2'b10:   fwd_frs3_data = wb_freg_data;
            default: fwd_frs3_data = id_ex_frs3_data;
        endcase
    end

    // --- ALU operand muxes ---
    logic [XLEN-1:0] alu_op_a, alu_op_b;

    always_comb begin
        case (id_ex_ctrl.alu_src1)
            ALU_SRC1_RS1:  alu_op_a = fwd_rs1_data;
            ALU_SRC1_PC:   alu_op_a = id_ex_pc;
            ALU_SRC1_ZERO: alu_op_a = '0;
            default:       alu_op_a = fwd_rs1_data;
        endcase
    end

    always_comb begin
        case (id_ex_ctrl.alu_src2)
            ALU_SRC2_RS2:  alu_op_b = fwd_rs2_data;
            ALU_SRC2_IMM:  alu_op_b = id_ex_imm;
            ALU_SRC2_FOUR: alu_op_b = XLEN'(4);
            default:       alu_op_b = fwd_rs2_data;
        endcase
    end

    logic [XLEN-1:0] ex_alu_result;
    logic            ex_alu_zero;

    rv_alu #(.XLEN(XLEN)) u_alu (
        .op_a    (alu_op_a),
        .op_b    (alu_op_b),
        .alu_op  (id_ex_ctrl.alu_op),
        .result  (ex_alu_result),
        .zero    (ex_alu_zero)
    );

    // =========================================================================
    // M-Extension: Multiply / Divide unit (combinational, single-cycle)
    // =========================================================================
    logic [XLEN-1:0] muldiv_result;

    rv_muldiv #(.XLEN(XLEN)) u_muldiv (
        .rs1_data (fwd_rs1_data),
        .rs2_data (fwd_rs2_data),
        .op       (id_ex_ctrl.muldiv_op),
        .result   (muldiv_result)
    );

    // EX-stage result: muldiv overrides ALU for M-extension instructions
    logic [XLEN-1:0] ex_result;
    assign ex_result = id_ex_ctrl.is_muldiv ? muldiv_result : ex_alu_result;

    // =========================================================================
    // F-Extension: FPU instantiation (EX stage)
    // =========================================================================
    // fpu_busy_int declared earlier (before stall assigns)
    logic        fpu_result_valid;   // 1-cycle pulse when FPU result is ready
    logic [31:0] fpu_result_f;       // FP result (to freg)
    logic [XLEN-1:0] fpu_result_i;  // int result (FMV.X.W, FCVT.W.S, CMP, FCLASS)
    logic [4:0]  fpu_fflags_ex;     // FPU exception flags
    logic [2:0]  frm_csr;           // fcsr.frm from CSR (for DYN rounding mode)

    // valid_in: pulse once on the first cycle a FP op enters EX.
    // Guard with !fpu_was_busy to prevent re-triggering FDIV/FSQRT on the cycle
    // fpu_busy_int falls (result arrives), before ID/EX has advanced past the op.
    // fpu_valid_in and fpu_start_stall are forward-declared near the stall signals.
    assign fpu_valid_in = id_ex_valid
                          && id_ex_ctrl.is_fp
                          && !id_ex_ctrl.fp_load
                          && !id_ex_ctrl.fp_store
                          && !fpu_busy_int
                          && !fpu_was_busy;

    assign fpu_start_stall = fpu_valid_in
                             && (id_ex_ctrl.fpu_op == FPU_DIV ||
                                 id_ex_ctrl.fpu_op == FPU_SQRT);

    rv_fpu #(.XLEN(XLEN)) u_fpu (
        .clk         (clk),
        .rst_n       (rst_n),
        .fa          (fwd_frs1_data),      // FP rs1 (with forwarding)
        .fb          (fwd_frs2_data),      // FP rs2 (with forwarding)
        .fc          (fwd_frs3_data),      // FP rs3 for FMADD family (with forwarding)
        .int_a       (fwd_rs1_data),       // integer rs1 for FCVT.S.W, FMV.W.X
        .fpu_op      (id_ex_ctrl.fpu_op),
        .fp_rm       (id_ex_ctrl.fp_rm),
        .frm_in      (frm_csr),
        .rs2_sel     (id_ex_ctrl.fp_rs2_sel),
        .valid_in    (fpu_valid_in),
        .result_f    (fpu_result_f),
        .result_i    (fpu_result_i),
        .fflags      (fpu_fflags_ex),
        .fpu_busy    (fpu_busy_int),
        .result_valid(fpu_result_valid)
    );

    // =========================================================================
    // A-Extension: Atomic Memory Operations
    // =========================================================================

    // --- Reservation register (for LR/SC) ---
    logic            reservation_valid;
    logic [XLEN-1:0] reservation_addr;

    // --- AMO 2-phase state (0 = read phase, 1 = write phase) ---
    // Only non-LR, non-SC AMOs require 2 phases.
    logic amo_state;

    // Asserted when a true AMO (not LR, not SC) is in MEM and in read phase
    wire  amo_active = ex_mem_valid
                       && ex_mem_ctrl.is_amo
                       && !ex_mem_ctrl.is_lr
                       && !ex_mem_ctrl.is_sc;

    assign amo_stall = amo_active && !amo_state;   // stall during read phase

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            amo_state         <= 1'b0;
            reservation_valid <= 1'b0;
            reservation_addr  <= '0;
        end else begin
            // AMO 2-phase: toggle state on active AMO
            if (amo_active && !amo_state)
                amo_state <= 1'b1;   // phase 0 → phase 1
            else
                amo_state <= 1'b0;   // phase 1 → idle, or no AMO

            // Reservation update (in MEM stage)
            if (ex_mem_ctrl.is_lr && ex_mem_valid) begin
                reservation_valid <= 1'b1;
                reservation_addr  <= ex_mem_alu_result;
            end else if (ex_mem_ctrl.is_sc && ex_mem_valid) begin
                reservation_valid <= 1'b0;   // SC always clears reservation
            end
        end
    end

    // SC success flag: reservation valid and address matches
    wire sc_success = ex_mem_ctrl.is_sc && ex_mem_valid
                      && reservation_valid
                      && (reservation_addr == ex_mem_alu_result);

    // =========================================================================
    // Misaligned access 2-phase FSM
    // =========================================================================
    // mal_cross: the current MEM-stage access spans two word-aligned regions.
    // Phase 0 (mal_state=0): issue read/write to first aligned word, stall pipeline.
    // Phase 1 (mal_state=1): issue read/write to second aligned word, advance pipeline.
    // WB stage: for loads, combine mal_first_data (phase-0 result) with dmem_rdata (phase-1).
    //
    // Access size = 1 << funct3[1:0]  (LB/SB=1, LH/SH=2, LW/SW=4, LD/SD=8)
    // Cross occurs when: addr[BYTE_LANE_W-1:0] + size - 1 >= XLEN/8

    logic [3:0] mal_size;
    logic [3:0] mal_last_byte;
    logic       mal_cross;

    assign mal_size      = 4'd1 << ex_mem_funct3[1:0];
    assign mal_last_byte = {1'b0, ex_mem_alu_result[BYTE_LANE_W-1:0]} + mal_size - 4'd1;
    assign mal_cross     = ex_mem_valid
                         && (ex_mem_ctrl.mem_read || ex_mem_ctrl.mem_write)
                         && !ex_mem_ctrl.is_amo
                         && (mal_last_byte >= 4'(XLEN/8));
    assign mal_stall = mal_cross && !mal_state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_ex_mem) begin
            mal_state      <= 1'b0;
            mal_first_data <= '0;
        end else begin
            if (mal_cross && !mal_state)
                mal_state <= 1'b1;   // phase 0 -> phase 1
            else
                mal_state <= 1'b0;   // phase 1 -> idle

            // Save first read result when advancing out of phase 1
            if (mal_cross && mal_state && ex_mem_ctrl.mem_read)
                mal_first_data <= dmem_rdata;
        end
    end

    // Misaligned store: full byte-enable shifted by byte offset.
    // Lower XLEN/8 bits -> phase-0 write strobe (first aligned word)
    // Upper XLEN/8 bits -> phase-1 write strobe (second aligned word)
    logic [XLEN/8-1:0]   mal_base_wstrb;
    logic [2*(XLEN/8)-1:0] mal_wstrb_wide;
    always_comb begin
        case (ex_mem_funct3[1:0])
            2'b00:   mal_base_wstrb = (XLEN/8)'(8'h01);
            2'b01:   mal_base_wstrb = (XLEN/8)'(8'h03);
            2'b10:   mal_base_wstrb = (XLEN/8)'(8'h0F);
            default: mal_base_wstrb = {(XLEN/8){1'b1}};
        endcase
        mal_wstrb_wide = {(XLEN/8)'(0), mal_base_wstrb}
                         << ex_mem_alu_result[BYTE_LANE_W-1:0];
    end

    // Misaligned address alignment mask (clears lower BYTE_LANE_W bits)
    localparam [XLEN-1:0] WORD_MASK = ~(XLEN)'(XLEN/8 - 1);

    // Shift amounts for misaligned store data (in bits)
    logic [5:0] mal_shl;   // byte_off * 8  (shift store data left for phase 0)
    logic [5:0] mal_shr;   // (XLEN/8 - byte_off) * 8  (shift store data right for phase 1)
    assign mal_shl = {3'b0, ex_mem_alu_result[BYTE_LANE_W-1:0]} << 3;
    assign mal_shr = {1'b0, 4'(XLEN/8) - {1'b0, ex_mem_alu_result[BYTE_LANE_W-1:0]}} << 3;

    // --- AMO compute unit ---
    // For .W AMO on a 64-bit BRAM, the 32-bit word may be in the upper half of the
    // 8-byte word when addr[2]=1.  amo_shift selects which half to read/write.
    logic [5:0]        amo_shift;   // bit shift: 32 when .W and addr[2]=1, else 0
    logic [XLEN-1:0]   amo_old_data;
    logic [XLEN-1:0]   amo_new_data;
    logic [XLEN-1:0]   amo_wdata;
    logic [XLEN/8-1:0] amo_wstrb;

    assign amo_shift    = (!ex_mem_funct3[0] && ex_mem_alu_result[2]) ? 6'd32 : 6'd0;
    assign amo_old_data = dmem_rdata >> amo_shift;   // extract correct 32-bit word
    assign amo_wdata    = amo_new_data << amo_shift;  // place result at correct position
    assign amo_wstrb    = ex_mem_funct3[0] ? {(XLEN/8){1'b1}}
                                           : ((XLEN/8)'(8'h0F) << amo_shift[5:3]);

    rv_amo #(.XLEN(XLEN)) u_amo (
        .old_data (amo_old_data),        // correct 32-bit word extracted from BRAM
        .rs2_data (ex_mem_rs2_data),
        .op       (ex_mem_ctrl.amo_op),
        .funct3   (ex_mem_funct3),
        .new_data (amo_new_data)
    );

    // =========================================================================
    // EX stage: CSR interface and trap/MRET detection
    // =========================================================================

    // CSR write data:
    //   Immediate forms (alu_src1=ZERO): zimm lives in id_ex_imm (zero-extended)
    //   Register forms               : rs1 after forwarding
    logic [XLEN-1:0] ex_csr_wdata;
    assign ex_csr_wdata = (id_ex_ctrl.alu_src1 == ALU_SRC1_ZERO) ? id_ex_imm
                                                                   : fwd_rs1_data;

    // CSR module outputs
    logic [XLEN-1:0] csr_rdata_ex;   // old CSR value (for rd writeback)
    priv_level_t     priv_level;
    logic            irq_pending;
    logic [XLEN-1:0] irq_cause;       // highest-priority interrupt cause (from rv_csr)
    logic [XLEN-1:0] satp_val_int;
    logic            mstatus_sum_int;
    logic            mstatus_mxr_int;

    // Trap cause: depends on privilege level for ECALL
    logic [XLEN-1:0] ex_trap_cause;
    logic [XLEN-1:0] ex_trap_val;

    always_comb begin
        ex_trap_enter = 1'b0;
        ex_mret_en    = 1'b0;
        ex_sret_en    = 1'b0;
        ex_trap_cause = '0;
        ex_trap_val   = '0;

        if (id_ex_valid) begin
            if (id_ex_ctrl.is_ecall) begin
                ex_trap_enter = 1'b1;
                // Cause depends on current privilege level
                unique case (priv_level)
                    PRIV_U:  ex_trap_cause = xlen_t'(EXC_ECALL_U);
                    PRIV_S:  ex_trap_cause = xlen_t'(EXC_ECALL_S);
                    default: ex_trap_cause = xlen_t'(EXC_ECALL_M);
                endcase
            end else if (id_ex_ctrl.is_ebreak) begin
                ex_trap_enter = 1'b1;
                ex_trap_cause = xlen_t'(EXC_BREAKPOINT);
                ex_trap_val   = id_ex_pc;   // tval = PC of EBREAK per spec
            end else if (id_ex_ctrl.is_mret) begin
                ex_mret_en = 1'b1;
            end else if (id_ex_ctrl.is_sret) begin
                ex_sret_en = 1'b1;
            end else if (irq_pending && !stall_if) begin
                // Asynchronous interrupt injection at instruction boundary.
                // Only when pipeline can advance (!stall_if) so the PC redirect
                // to trap_vector takes effect on the very next cycle.
                // trap_epc = id_ex_pc: the interrupted instruction's PC; MRET/SRET
                // returns here so execution resumes from the right point.
                ex_trap_enter = 1'b1;
                ex_trap_cause = irq_cause;
                // ex_trap_val stays '0 (no fault address for interrupts)
            end
        end
    end

    rv_csr #(
        .XLEN   (XLEN),
        .HARTID (0)
    ) u_csr (
        .clk        (clk),
        .rst_n      (rst_n),
        .csr_addr   (id_ex_csr_addr),
        .csr_wdata  (ex_csr_wdata),
        .csr_op     (id_ex_funct3),
        .csr_we     (id_ex_ctrl.csr_write & id_ex_valid),
        .csr_rdata  (csr_rdata_ex),
        .trap_enter (ex_trap_enter),
        .trap_cause (ex_trap_cause),
        .trap_val   (ex_trap_val),
        .trap_epc   (id_ex_pc),
        .mret_en    (ex_mret_en),
        .sret_en    (ex_sret_en),
        .trap_vector(trap_vector),
        .mepc_out   (mepc_out),
        .sepc_out   (sepc_out),
        .priv_level (priv_level),
        .irq_pending(irq_pending),
        .irq_cause  (irq_cause),
        .retire_en  (mem_wb_valid),
        .timer_val  (64'h0),
        .timer_irq  (timer_irq),
        .sw_irq     (sw_irq),
        .ext_irq    (ext_irq),
        .satp_val      (satp_val_int),
        .mstatus_sum   (mstatus_sum_int),
        .mstatus_mxr   (mstatus_mxr_int),
        // F-extension
        .fpu_fflags    (fpu_fflags_ex),
        .fpu_fflags_we (fpu_result_valid),
        .frm_out       (frm_csr)
    );

    // --- MMU state outputs ---
    assign satp_out        = satp_val_int;
    assign priv_out        = priv_level;
    assign mstatus_sum_out = mstatus_sum_int;
    assign mstatus_mxr_out = mstatus_mxr_int;

    // SFENCE.VMA in EX stage → TLB flush pulse (1-cycle)
    assign tlb_flush_out   = id_ex_valid && id_ex_ctrl.is_sfence_vma;

    // --- Branch / Jump resolution ---
    // Forwarded rs1/rs2 are used for branch comparisons.
    // For JALR the branch target comes from ex_alu_result (rs1 + imm with forwarding).
    rv_branch #(.XLEN(XLEN)) u_branch (
        .ctrl          (id_ex_ctrl),
        .funct3        (id_ex_funct3),
        .rs1_data      (fwd_rs1_data),
        .rs2_data      (fwd_rs2_data),
        .pc            (id_ex_pc),
        .imm           (id_ex_imm),
        .alu_result    (ex_alu_result),
        .branch_taken  (branch_taken_ex),
        .branch_target (branch_target_ex)
    );

    // =========================================================================
    // EX/MEM Pipeline Register  (between EX and MEM)
    // =========================================================================
    // ex_mem_csr_fwd declared earlier (forward-decl for ex_mem_fwd_data mux)
    // ex_mem_fpu_result_f declared earlier (forward-decl for FP forwarding mux)
    // ex_mem_fpu_result_i_fwd declared earlier (forward-decl for ex_mem_fwd_data mux)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_ex_mem) begin
            ex_mem_ctrl              <= '0;
            ex_mem_alu_result        <= '0;
            ex_mem_rs2_data          <= '0;
            ex_mem_rd_addr           <= '0;
            ex_mem_pc4               <= '0;
            ex_mem_funct3            <= '0;
            ex_mem_csr_fwd           <= '0;
            ex_mem_valid             <= 1'b0;
            ex_mem_fpu_result_f      <= '0;
            ex_mem_fpu_result_i_fwd  <= '0;
        end else if (!stall_ex) begin
            ex_mem_ctrl       <= id_ex_ctrl;
            ex_mem_alu_result <= ex_result;
            // FSW: store data comes from FP regfile (frs2), replicate to fill data bus
            ex_mem_rs2_data   <= id_ex_ctrl.fp_store
                                 ? {(XLEN/32){fwd_frs2_data}}
                                 : fwd_rs2_data;
            ex_mem_rd_addr    <= id_ex_rd_addr;
            ex_mem_pc4        <= id_ex_pc + XLEN'(4);
            ex_mem_funct3     <= id_ex_funct3;
            ex_mem_csr_fwd    <= csr_rdata_ex;
            ex_mem_valid      <= id_ex_valid && !(fpu_valid_in &&
                                     (id_ex_ctrl.fpu_op == FPU_DIV ||
                                      id_ex_ctrl.fpu_op == FPU_SQRT));
            // Only capture FPU result for actual FP compute ops; FLW/FSW don't
            // produce a meaningful fpu_result_f and may have X-bit operands from
            // uninitialized FP registers (e.g. the rs2 imm field decoded as f0).
            ex_mem_fpu_result_f     <= (id_ex_ctrl.is_fp && !id_ex_ctrl.fp_load
                                        && !id_ex_ctrl.fp_store)
                                       ? fpu_result_f : '0;
            ex_mem_fpu_result_i_fwd <= fpu_result_i;
        end
        // else: stall_ex — hold EX/MEM
    end


    // =========================================================================
    // Stage 4: Memory Access (MEM)
    // =========================================================================
    // AMO and SC override the normal load/store dmem signals.
    // All outputs are combinational; no pipeline register here.
    always_comb begin
        // Defaults (normal load / store)
        dmem_addr  = ex_mem_alu_result;
        dmem_wdata = ex_mem_rs2_data;
        dmem_req   = ex_mem_ctrl.mem_read | ex_mem_ctrl.mem_write;
        dmem_we    = ex_mem_ctrl.mem_write;
        dmem_wstrb = '0;

        // --- Normal store byte-enable (used when not AMO) ---
        // Shift mask by the byte offset within the DMEM data word.
        // BYTE_LANE_W selects the right number of address bits:
        //   RV32: addr[1:0] (2 bits) -> 4-bit wstrb, no overflow
        //   RV64: addr[2:0] (3 bits) -> 8-bit wstrb, covers both 32-bit halves
        case (ex_mem_funct3)
            3'b000:  dmem_wstrb = (XLEN/8)'(8'h01) << ex_mem_alu_result[BYTE_LANE_W-1:0]; // SB
            3'b001:  dmem_wstrb = (XLEN/8)'(8'h03) << ex_mem_alu_result[BYTE_LANE_W-1:0]; // SH
            3'b010:  dmem_wstrb = (XLEN/8)'(8'h0F) << ex_mem_alu_result[BYTE_LANE_W-1:0]; // SW
            3'b011:  dmem_wstrb = (XLEN/8)'(8'hFF);                            // SD (RV64)
            default: dmem_wstrb = '1;
        endcase

        // --- Store data pre-conditioning ---
        // Shift rs2 left by byte_off*8 so the data lands at the correct byte lanes.
        // wstrb (already shifted above) selects the correct bytes for write.
        if (ex_mem_ctrl.mem_write && !ex_mem_ctrl.is_amo)
            dmem_wdata = ex_mem_rs2_data << mal_shl;

        // --- AMO / SC override ---
        if (ex_mem_ctrl.is_amo && ex_mem_valid) begin
            dmem_addr = ex_mem_alu_result;    // base address = rs1

            if (ex_mem_ctrl.is_lr) begin
                // LR: simple read; no write
                dmem_req   = 1'b1;
                dmem_we    = 1'b0;
                dmem_wdata = '0;
                dmem_wstrb = '0;
            end else if (ex_mem_ctrl.is_sc) begin
                // SC: conditional write of rs2; read is not needed
                dmem_req   = sc_success;
                dmem_we    = sc_success;
                dmem_wdata = ex_mem_rs2_data << amo_shift;  // shift for .W addr[2]=1
                dmem_wstrb = sc_success ? amo_wstrb : '0;
            end else if (!amo_state) begin
                // AMO phase 0: issue read
                dmem_req   = 1'b1;
                dmem_we    = 1'b0;
                dmem_wdata = '0;
                dmem_wstrb = '0;
            end else begin
                // AMO phase 1: issue write of computed new value
                dmem_req   = 1'b1;
                dmem_we    = 1'b1;
                dmem_wdata = amo_wdata;   // shifted to correct byte position
                dmem_wstrb = amo_wstrb;
            end
        end

        // Misaligned access: override address and (for stores) wstrb/wdata.
        // AMO addresses are required to be aligned, so this block is never
        // entered for AMO operations.
        if (mal_cross) begin
            if (!mal_state) begin
                // Phase 0: first aligned word
                dmem_addr = ex_mem_alu_result & WORD_MASK;
                if (ex_mem_ctrl.mem_write) begin
                    dmem_wstrb = mal_wstrb_wide[XLEN/8-1:0];
                    dmem_wdata = ex_mem_rs2_data << mal_shl;
                end
            end else begin
                // Phase 1: second aligned word
                dmem_addr = (ex_mem_alu_result & WORD_MASK) + (XLEN)'(XLEN/8);
                if (ex_mem_ctrl.mem_write) begin
                    dmem_wstrb = {(XLEN/8)'(0), mal_wstrb_wide[2*(XLEN/8)-1:XLEN/8]};
                    dmem_wdata = ex_mem_rs2_data >> mal_shr;
                end
            end
        end
    end

    // =========================================================================
    // MEM/WB Pipeline Register  (between MEM and WB)
    // =========================================================================
    logic [XLEN-1:0] mem_wb_csr_rdata;
    logic [2:0]      mem_wb_funct3;
    logic [BYTE_LANE_W-1:0] mem_wb_byte_offset;  // addr[BYTE_LANE_W-1:0] — byte lane selector for sub-word loads
    // mem_wb_fpu_result_f declared earlier (forward-decl for FP forwarding mux)
    logic [XLEN-1:0] mem_wb_fpu_result_i;  // FPU int result -> int reg

    // SC result: 0 = success, 1 = failure (rd receives this value via WB_SRC_ALU)
    wire [XLEN-1:0] sc_result = {{(XLEN-1){1'b0}}, ~sc_success};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_wb_ctrl           <= '0;
            mem_wb_alu_result     <= '0;
            mem_wb_rd_addr        <= '0;
            mem_wb_pc4            <= '0;
            mem_wb_csr_rdata      <= '0;
            mem_wb_funct3         <= '0;
            mem_wb_byte_offset    <= '0;
            mem_wb_valid          <= 1'b0;
            mem_wb_fpu_result_f   <= '0;
            mem_wb_fpu_result_i   <= '0;
            mal_active_wb         <= 1'b0;
        end else if (!amo_stall && !mal_stall) begin
            // Hold MEM/WB during AMO read phase or misaligned phase 0
            mem_wb_ctrl           <= ex_mem_ctrl;
            mem_wb_alu_result     <= ex_mem_ctrl.is_sc ? sc_result : ex_mem_alu_result;
            mem_wb_rd_addr        <= ex_mem_rd_addr;
            mem_wb_pc4            <= ex_mem_pc4;
            mem_wb_csr_rdata      <= ex_mem_csr_fwd;
            mem_wb_funct3         <= ex_mem_funct3;
            mem_wb_byte_offset    <= ex_mem_alu_result[BYTE_LANE_W-1:0];
            mem_wb_valid          <= ex_mem_valid;
            mem_wb_fpu_result_f   <= ex_mem_fpu_result_f;
            mem_wb_fpu_result_i   <= ex_mem_fpu_result_i_fwd;
            mal_active_wb         <= mal_cross;
        end
        // else: amo_stall or mal_stall — hold MEM/WB
    end

    // =========================================================================
    // Stage 5: Writeback (WB)
    // =========================================================================
    // dmem_rdata is the synchronous DMEM output registered in the previous
    // (MEM) cycle, so it is valid here without any additional buffering.
    //
    // Sub-word loads (LB/LH/LBU/LHU) require right-shifting dmem_rdata by
    // addr[1:0] bytes to select the correct byte lane before sign/zero extension.
    // rv_dmem always returns data aligned to the 4-byte (word) boundary of the
    // address, so byte 0 of the word is always in rdata[7:0].
    //
    // Example: LB at address 0x05 (byte 1 of word 1)
    //   word_addr = 0x05 >> 2 = 1  →  rdata = mem[1] = bytes 4-7
    //   addr[1:0] = 1  →  shift right 8  →  rdata[15:8] in shifted[7:0]
    //   sign_extend(shifted[7:0]) = sign_extend(byte at 0x05) ✓

    // Misaligned load: combine two aligned reads into one value.
    // Phase-0 result (mal_first_data) holds bytes [0..XLEN/8-1-byte_off].
    // Phase-1 result (dmem_rdata) holds bytes [XLEN/8-byte_off..size-1].
    // Result = (first >> byte_off*8) | (second << (XLEN/8-byte_off)*8)
    logic [5:0] wb_shr;   // byte_off * 8
    logic [5:0] wb_shl;   // (XLEN/8 - byte_off) * 8
    assign wb_shr = {3'b0, mem_wb_byte_offset} << 3;
    assign wb_shl = {1'b0, 4'(XLEN/8) - {1'b0, mem_wb_byte_offset}} << 3;

    logic [2*XLEN-1:0] mal_wide;
    logic [XLEN-1:0]   mal_combined;
    assign mal_wide     = ({(XLEN)'(0), mal_first_data} >> wb_shr)
                        | ({(XLEN)'(0), dmem_rdata}     << wb_shl);
    assign mal_combined = mal_wide[XLEN-1:0];

    // dmem_shifted: for normal (non-crossing) loads, shift by byte offset.
    // For misaligned crossing loads, use pre-combined data (already positioned).
    logic [XLEN-1:0] dmem_shifted;
    always_comb begin
        if (mal_active_wb)
            dmem_shifted = mal_combined;
        else
            // Shift by byte_offset*8: RV32 max shift=24, RV64 max shift=56
            dmem_shifted = dmem_rdata >> ({3'b0, mem_wb_byte_offset} << 3);
    end

    always_comb begin
        case (mem_wb_ctrl.wb_src)
            WB_SRC_ALU: wb_data = mem_wb_alu_result;
            WB_SRC_MEM: begin
                // Sign/zero extension after byte-lane selection
                unique case (mem_wb_funct3)
                    3'b000: wb_data = xlen_t'($signed(dmem_shifted[ 7:0]));  // LB
                    3'b001: wb_data = xlen_t'($signed(dmem_shifted[15:0]));  // LH
                    3'b010: wb_data = xlen_t'($signed(dmem_shifted[31:0]));  // LW
                    3'b011: wb_data = dmem_shifted;                           // LD
                    3'b100: wb_data = xlen_t'(dmem_shifted[ 7:0]);            // LBU
                    3'b101: wb_data = xlen_t'(dmem_shifted[15:0]);            // LHU
                    3'b110: wb_data = xlen_t'(dmem_shifted[31:0]);            // LWU (RV64)
                    default: wb_data = dmem_shifted;
                endcase
            end
            WB_SRC_PC4: wb_data = mem_wb_pc4;
            WB_SRC_CSR: wb_data = mem_wb_csr_rdata;
            WB_SRC_FPU: wb_data = mem_wb_fpu_result_i;  // FMV.X.W, FCVT.W.S, FEQ, FCLASS
            default:    wb_data = mem_wb_alu_result;
        endcase
    end

    assign wb_rd_addr   = mem_wb_rd_addr;
    assign wb_reg_write = mem_wb_ctrl.reg_write & mem_wb_valid;

    // ---- FP register writeback ----
    // freg_write: FLW (fp_load) or any FPU op writing a float result (freg_write)
    // For FLW: write dmem_rdata[31:0] to freg
    // For FPU: write mem_wb_fpu_result_f to freg
    always_comb begin
        wb_freg_write = mem_wb_valid && mem_wb_ctrl.freg_write;
        wb_frd_addr   = mem_wb_rd_addr;
        if (mem_wb_ctrl.fp_load)
            wb_freg_data = dmem_shifted[31:0];   // FLW data from DMEM
        else
            wb_freg_data = mem_wb_fpu_result_f;  // FPU float result
    end

    // =========================================================================
    // Hazard Detection Unit
    // =========================================================================
    rv_hazard #(.XLEN(XLEN)) u_hazard (
        .id_ex_valid     (id_ex_valid),
        .id_ex_ctrl      (id_ex_ctrl),
        .id_ex_rd_addr   (id_ex_rd_addr),
        .id_rs1_addr     (id_rs1_addr),
        .id_rs2_addr     (id_rs2_addr),
        .id_rs3_addr     (id_rs3_addr),
        .id_ctrl         (id_ctrl),
        .id_rs1_used     (id_rs1_used),
        .id_rs2_used     (id_rs2_used),
        .load_use_hazard (load_use_hazard)
    );

endmodule

`default_nettype wire
