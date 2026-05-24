// =============================================================================
/// @file rv_csr.sv
/// @brief Control and Status Register (CSR) Unit - Zicsr + Machine + Supervisor Mode
///
/// Implements RISC-V CSR instructions and state management for:
/// - **Machine-mode (M)**: Full privilege level with trap handling
/// - **Supervisor-mode (S)**: Virtual memory, interrupts via delegation
/// - **User-mode (U)**: Limited execution, no CSR access
///
/// **Trap Handling & Delegation:**
/// - Exception/interrupt delegation via `medeleg` (exceptions) and `mideleg` (interrupts)
/// - **M-mode trap**: Updates mepc/mcause/mtval, PC ← mtvec, priv ← M
/// - **S-mode trap**: Updates sepc/scause/stval, PC ← stvec, priv ← S (if delegated)
/// - **Interrupt priority**: MEIP > MSIP > MTIP > SEIP > SSIP > STIP
/// - **Masking**: Interrupts only delivered if corresponding bit in mie/sie is set
///
/// **Privilege Transitions:**
/// - **MRET**: Restore priv from mstatus.MPP, restore MIE from mstatus.MPIE
/// - **SRET**: Restore priv from mstatus.SPP (0=U, 1=S), restore SIE from mstatus.SPIE
/// - **Trap entry**: Saves PC to mepc/sepc, sets priv level, disables interrupts
///
/// **Implemented CSRs:**
/// - **M-mode**: mstatus, misa, medeleg, mideleg, mie, mtvec, mscratch, mepc,
///   mcause, mtval, mip, mcycle, minstret, mhartid, satp
/// - **S-mode**: sstatus (restricted mstatus), sie, stvec, sscratch, sepc,
///   scause, stval, sip (restricted mip)
///
/// **CSR Operations (Zicsr):**
/// - CSRRW: Atomic read-modify-write (write value from rd)
/// - CSRRS: Set bits (set those bits that are 1 in rs1)
/// - CSRRC: Clear bits (clear those bits that are 1 in rs1)
/// - CSRRWI/CSRRSI/CSRRCI: Immediate versions (zero-extend 5-bit uimm)
///
/// @param XLEN Data path width (32 or 64)
/// @param HARTID Hart ID for mhartid CSR (hardware thread ID)
/// @author Naofumi Yoshinaga
/// @date 2025-05-22
/// @version 1.0
/// =============================================================================

`default_nettype none

module rv_csr
    import rv_pkg::*;
#(
    parameter int XLEN   = rv_pkg::XLEN,
    parameter int HARTID = 0
) (
    input  wire              clk,
    input  wire              rst_n,

    // ---- CSR read/write from EX stage ----------------------------------------
    input  wire  [11:0]      csr_addr,   // CSR address (inst[31:20])
    input  wire  [XLEN-1:0]  csr_wdata,  // Write data
    input  wire  [2:0]       csr_op,     // funct3
    input  wire              csr_we,     // CSR write enable
    output logic [XLEN-1:0]  csr_rdata,  // Old CSR value (combinational)

    // ---- Exception trap entry ------------------------------------------------
    input  wire              trap_enter,
    input  wire  [XLEN-1:0]  trap_cause,
    input  wire  [XLEN-1:0]  trap_val,
    input  wire  [XLEN-1:0]  trap_epc,

    // ---- Trap returns --------------------------------------------------------
    input  wire              mret_en,    // MRET in EX
    input  wire              sret_en,    // SRET in EX

    // ---- Trap destinations (to rv_core PC mux) --------------------------------
    output logic [XLEN-1:0]  trap_vector, // mtvec or stvec (delegation-aware)
    output logic [XLEN-1:0]  mepc_out,    // mepc  (for MRET)
    output logic [XLEN-1:0]  sepc_out,    // sepc  (for SRET)

    // ---- Privilege / interrupt status ----------------------------------------
    output priv_level_t      priv_level,
    output logic             irq_pending,
    output logic [XLEN-1:0]  irq_cause,    // highest-priority pending interrupt cause (MSB=1)

    // ---- Retire pulse (for minstret) -----------------------------------------
    input  wire              retire_en,

    // ---- External interrupt inputs -------------------------------------------
    input  wire  [63:0]      timer_val,
    input  wire              timer_irq,
    input  wire              sw_irq,
    input  wire              ext_irq,

    // ---- MMU state outputs ---------------------------------------------------
    output logic [XLEN-1:0]  satp_val,
    output logic              mstatus_sum,
    output logic              mstatus_mxr,

    // ---- F-extension fcsr ----------------------------------------------------
    input  wire  [4:0]       fpu_fflags,    // FPU exception flags to OR into fflags
    input  wire              fpu_fflags_we, // 1 = FPU produced result this cycle
    output logic [2:0]       frm_out        // fcsr.frm -> FPU rounding mode (DYN)
);

    // =========================================================================
    // CSR storage
    // =========================================================================

    // mstatus — Machine fields
    logic           mstatus_mie;    // [3]  Machine Interrupt Enable
    logic           mstatus_mpie;   // [7]  Machine Previous IE
    logic [1:0]     mstatus_mpp;    // [12:11] Machine Previous Privilege
    logic           mstatus_sum_r;  // [18] Supervisor User Memory access
    logic           mstatus_mxr_r;  // [19] Make eXecutable Readable

    // mstatus — Supervisor fields
    logic           mstatus_sie;    // [1]  Supervisor Interrupt Enable
    logic           mstatus_spie;   // [5]  Supervisor Previous IE
    logic           mstatus_spp;    // [8]  Supervisor Previous Privilege (0=U,1=S)

    // Delegation registers
    xlen_t          medeleg_reg;    // Machine Exception Delegation
    xlen_t          mideleg_reg;    // Machine Interrupt Delegation

    // Machine CSRs
    xlen_t          satp_reg;
    xlen_t          mie_reg;
    xlen_t          mtvec_reg;
    xlen_t          mscratch_reg;
    xlen_t          mepc_reg;
    xlen_t          mcause_reg;
    xlen_t          mtval_reg;

    // Supervisor CSRs
    xlen_t          stvec_reg;
    xlen_t          sscratch_reg;
    xlen_t          sepc_reg;
    xlen_t          scause_reg;
    xlen_t          stval_reg;

    logic [63:0]    mcycle_cnt;
    logic [63:0]    minstret_cnt;

    // F-extension CSRs
    logic [4:0]     fflags_reg;  // fcsr[4:0] : NV|DZ|OF|UF|NX (accumulated)
    logic [2:0]     frm_reg;     // fcsr[7:5] : rounding mode

    assign frm_out = frm_reg;

    priv_level_t    cur_priv;
    assign priv_level = cur_priv;

    // =========================================================================
    // Bit masks
    // =========================================================================
    // sstatus writable bits: SIE[1], SPIE[5], SPP[8], SUM[18], MXR[19]
    localparam [XLEN-1:0] SSTATUS_WMASK = XLEN'((64'h1 << 1) | (64'h1 << 5) |
                                                  (64'h1 << 8) | (64'h1 << 18) |
                                                  (64'h1 << 19));
    // S-mode IRQ bits in mie/mip: SSIP[1], STIP[5], SEIP[9]
    localparam [XLEN-1:0] S_IRQ_MASK = XLEN'((64'h1 << 1) | (64'h1 << 5) |
                                               (64'h1 << 9));

    // =========================================================================
    // mip — read-only (driven by external interrupt inputs)
    // Use 64-bit intermediates and wire assigns to avoid constant-select
    // warnings in always_* with parametric-width signals.
    // =========================================================================
    wire [63:0] mip64 = ({63'b0, sw_irq   & mideleg_reg[1]} << 1)   // SSIP
                      | ({63'b0, sw_irq}                     << 3)   // MSIP
                      | ({63'b0, timer_irq & mideleg_reg[5]} << 5)   // STIP
                      | ({63'b0, timer_irq}                  << 7)   // MTIP
                      | ({63'b0, ext_irq  & mideleg_reg[9]}  << 9)   // SEIP
                      | ({63'b0, ext_irq}                    << 11); // MEIP
    wire [XLEN-1:0] mip_val = mip64[XLEN-1:0];

    // Masked views for S-mode
    wire [XLEN-1:0] sie_val = mie_reg  & S_IRQ_MASK;
    wire [XLEN-1:0] sip_val = mip_val  & S_IRQ_MASK;

    // =========================================================================
    // Interrupt pending
    // =========================================================================
    // M-mode interrupts: non-delegated (or not in mideleg)
    wire [XLEN-1:0] m_irq_bits;
    assign m_irq_bits = mip_val & mie_reg & ~mideleg_reg;  // M-mode only

    // S-mode interrupts: delegated
    wire [XLEN-1:0] s_irq_bits;
    assign s_irq_bits = sip_val & sie_val;

    // irq_pending: use assign so wire signals (m_irq_bits, s_irq_bits) are in sensitivity.
    // M-mode interrupts only taken in M-mode when mstatus.MIE=1
    wire m_irq_en = (cur_priv == PRIV_M) && mstatus_mie;
    // S-mode interrupts: taken in U/S-mode when mstatus.SIE=1
    wire s_irq_en = (cur_priv == PRIV_U) || (cur_priv == PRIV_S && mstatus_sie);
    assign irq_pending = (m_irq_en && |m_irq_bits) || (s_irq_en && |s_irq_bits);

    // =========================================================================
    // misa — read-only constant
    // =========================================================================
    xlen_t misa_val;
    always_comb begin
        misa_val = '0;
        if (XLEN == 64) misa_val[XLEN-1:XLEN-2] = 2'd2;
        else            misa_val[XLEN-1:XLEN-2] = 2'd1;
        misa_val[8]  = 1'b1;   // 'I'
        misa_val[18] = 1'b1;   // 'S' supervisor mode
        misa_val[20] = 1'b1;   // 'U' user mode
    end

    // =========================================================================
    // MMU state outputs
    // =========================================================================
    assign satp_val    = satp_reg;
    assign mstatus_sum = mstatus_sum_r;
    assign mstatus_mxr = mstatus_mxr_r;

    // =========================================================================
    // mstatus reconstruction (full M-mode view)
    // Wire-based to avoid constant-select warnings in always_*.
    // =========================================================================
    wire [63:0] mstatus64 = ({63'b0, mstatus_sie}   << 1)
                          | ({63'b0, mstatus_mie}   << 3)
                          | ({63'b0, mstatus_spie}  << 5)
                          | ({63'b0, mstatus_mpie}  << 7)
                          | ({63'b0, mstatus_spp}   << 8)
                          | ({62'b0, mstatus_mpp}   << 11)
                          | ({63'b0, mstatus_sum_r} << 18)
                          | ({63'b0, mstatus_mxr_r} << 19);
    wire [XLEN-1:0] mstatus_rval = mstatus64[XLEN-1:0];

    // sstatus: restricted view of mstatus (S-mode accessible bits only)
    wire [XLEN-1:0] sstatus_rval = mstatus_rval & SSTATUS_WMASK;

    // =========================================================================
    // Trap delegation check (combinational)
    // Exceptions (cause MSB=0): medeleg[cause_code[3:0]] decides delegation.
    // Interrupts (cause MSB=1): mideleg[cause_code[3:0]] decides delegation.
    //   M-mode interrupts (MTIP=7, MSIP=3, MEIP=11) are never in mideleg,
    //   so they always remain M-mode traps.
    // cur_priv != PRIV_M : delegation only when current privilege is below M.
    //
    // Detecting cause MSB without triggering iverilog's "all-bits-included"
    // warning: build a per-XLEN interrupt-flag mask via 64-bit shift, then OR
    // with trap_cause and compare to the mask itself (non-zero ↔ MSB is set).
    // =========================================================================
    wire [63:0] int_flag64    = 64'h1 << (XLEN-1);   // bit (XLEN-1) set; 0 elsewhere
    wire [XLEN-1:0] INT_FLAG  = int_flag64[XLEN-1:0]; // XLEN-wide mask
    wire is_irq_trap  = |(trap_cause & INT_FLAG);      // 1 when interrupt cause
    wire is_exc_trap  = ~is_irq_trap;                  // 1 when exception cause

    // Per-type delegation check (only one fires for any given trap_cause)
    wire trap_deleg_exc = is_exc_trap & medeleg_reg[trap_cause[3:0]];
    wire trap_deleg_irq = is_irq_trap & mideleg_reg[trap_cause[3:0]];

    wire trap_delegated_comb = trap_enter
                               && (cur_priv != PRIV_M)
                               && (trap_deleg_exc | trap_deleg_irq);

    // =========================================================================
    // Interrupt cause priority encoder
    // Priority: M-mode > S-mode; within each class: EIP > SIP > TIP
    // Cause codes use the 64-bit trick to set the MSB (interrupt flag) without
    // triggering iverilog's "constant-select in always_*" warning.
    // =========================================================================
    // Interrupt-cause constants: bit (XLEN-1) = 1 (interrupt flag per spec),
    // lower bits = cause code.  Use (XLEN-1) as the shift so the flag lands at
    // bit 31 for RV32 and bit 63 for RV64 after the [XLEN-1:0] truncation.
    wire [63:0] meip_cause64 = (64'h1 << (XLEN-1)) | 64'd11;
    wire [63:0] msip_cause64 = (64'h1 << (XLEN-1)) | 64'd3;
    wire [63:0] mtip_cause64 = (64'h1 << (XLEN-1)) | 64'd7;
    wire [63:0] seip_cause64 = (64'h1 << (XLEN-1)) | 64'd9;
    wire [63:0] ssip_cause64 = (64'h1 << (XLEN-1)) | 64'd1;
    wire [63:0] stip_cause64 = (64'h1 << (XLEN-1)) | 64'd5;
    wire [XLEN-1:0] MEIP_CAUSE = meip_cause64[XLEN-1:0];
    wire [XLEN-1:0] MSIP_CAUSE = msip_cause64[XLEN-1:0];
    wire [XLEN-1:0] MTIP_CAUSE = mtip_cause64[XLEN-1:0];
    wire [XLEN-1:0] SEIP_CAUSE = seip_cause64[XLEN-1:0];
    wire [XLEN-1:0] SSIP_CAUSE = ssip_cause64[XLEN-1:0];
    wire [XLEN-1:0] STIP_CAUSE = stip_cause64[XLEN-1:0];

    // Priority select wires (pure combinational, no always_* needed)
    wire take_meip = m_irq_en & m_irq_bits[11];
    wire take_msip = m_irq_en & m_irq_bits[3]  & ~take_meip;
    wire take_mtip = m_irq_en & m_irq_bits[7]  & ~take_meip & ~take_msip;
    wire take_seip = s_irq_en & s_irq_bits[9]  & ~take_meip & ~take_msip & ~take_mtip;
    wire take_ssip = s_irq_en & s_irq_bits[1]  & ~take_meip & ~take_msip & ~take_mtip & ~take_seip;
    wire take_stip = s_irq_en & s_irq_bits[5]  & ~take_meip & ~take_msip & ~take_mtip & ~take_seip & ~take_ssip;

    assign irq_cause = take_meip ? MEIP_CAUSE :
                       take_msip ? MSIP_CAUSE :
                       take_mtip ? MTIP_CAUSE :
                       take_seip ? SEIP_CAUSE :
                       take_ssip ? SSIP_CAUSE :
                       take_stip ? STIP_CAUSE :
                                   '0;

    // =========================================================================
    // Trap vector calculation
    // =========================================================================
    wire [XLEN-1:0] mtvec_base = {mtvec_reg[XLEN-1:2], 2'b00};
    wire [XLEN-1:0] stvec_base = {stvec_reg[XLEN-1:2], 2'b00};

    // Use assign (not always_comb) so iverilog picks up wire sensitivities correctly.
    assign trap_vector = trap_delegated_comb ? stvec_base : mtvec_base;

    // Return addresses (LSB always 0 per spec)
    assign mepc_out = {mepc_reg[XLEN-1:1], 1'b0};
    assign sepc_out = {sepc_reg[XLEN-1:1], 1'b0};

    // =========================================================================
    // CSR Read (combinational — returns old value before write)
    // =========================================================================
    always_comb begin
        csr_rdata = '0;
        case (csr_addr)
            // F-extension
            CSR_FFLAGS:   csr_rdata = {{(XLEN-5){1'b0}}, fflags_reg};
            CSR_FRM:      csr_rdata = {{(XLEN-3){1'b0}}, frm_reg};
            CSR_FCSR:     csr_rdata = {{(XLEN-8){1'b0}}, frm_reg, fflags_reg};
            // Supervisor-level
            CSR_SSTATUS:  csr_rdata = sstatus_rval;
            CSR_SIE:      csr_rdata = sie_val;
            CSR_STVEC:    csr_rdata = stvec_reg;
            CSR_SSCRATCH: csr_rdata = sscratch_reg;
            CSR_SEPC:     csr_rdata = sepc_reg;
            CSR_SCAUSE:   csr_rdata = scause_reg;
            CSR_STVAL:    csr_rdata = stval_reg;
            CSR_SIP:      csr_rdata = sip_val;
            CSR_SATP:     csr_rdata = satp_reg;
            // Machine-level
            CSR_MSTATUS:  csr_rdata = mstatus_rval;
            CSR_MISA:     csr_rdata = misa_val;
            CSR_MEDELEG:  csr_rdata = medeleg_reg;
            CSR_MIDELEG:  csr_rdata = mideleg_reg;
            CSR_MIE:      csr_rdata = mie_reg;
            CSR_MTVEC:    csr_rdata = mtvec_reg;
            CSR_MSCRATCH: csr_rdata = mscratch_reg;
            CSR_MEPC:     csr_rdata = mepc_reg;
            CSR_MCAUSE:   csr_rdata = mcause_reg;
            CSR_MTVAL:    csr_rdata = mtval_reg;
            CSR_MIP:      csr_rdata = mip_val;
            CSR_MCYCLE:   csr_rdata = xlen_t'(mcycle_cnt[XLEN-1:0]);
            CSR_MINSTRET: csr_rdata = xlen_t'(minstret_cnt[XLEN-1:0]);
            CSR_MHARTID:  csr_rdata = xlen_t'(HARTID[XLEN-1:0]);
            // RV32 upper-half counters
            12'hB80:      csr_rdata = (XLEN == 32) ? xlen_t'(mcycle_cnt[63:32])   : '0;
            12'hB82:      csr_rdata = (XLEN == 32) ? xlen_t'(minstret_cnt[63:32]) : '0;
            default:      csr_rdata = '0;
        endcase
    end

    // =========================================================================
    // Write data mux (CSRRW/CSRRS/CSRRC and immediate variants)
    // =========================================================================
    xlen_t csr_new_val;
    always_comb begin
        case (csr_op[1:0])
            2'b01:   csr_new_val = csr_wdata;
            2'b10:   csr_new_val = csr_rdata | csr_wdata;
            2'b11:   csr_new_val = csr_rdata & ~csr_wdata;
            default: csr_new_val = csr_rdata;
        endcase
    end

    // =========================================================================
    // Sequential CSR updates
    // Priority: trap_enter > sret_en > mret_en > csr_we
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_priv      <= PRIV_M;
            // M-mode mstatus fields
            mstatus_mie   <= 1'b0;
            mstatus_mpie  <= 1'b1;
            mstatus_mpp   <= 2'b11;  // MPP reset: M-mode
            mstatus_sum_r <= 1'b0;
            mstatus_mxr_r <= 1'b0;
            // S-mode mstatus fields
            mstatus_sie   <= 1'b0;
            mstatus_spie  <= 1'b1;
            mstatus_spp   <= 1'b0;
            // Delegation
            medeleg_reg   <= '0;
            mideleg_reg   <= '0;
            // Machine CSRs
            mie_reg       <= '0;
            mtvec_reg     <= '0;
            mscratch_reg  <= '0;
            mepc_reg      <= '0;
            mcause_reg    <= '0;
            mtval_reg     <= '0;
            satp_reg      <= '0;
            // Supervisor CSRs
            stvec_reg     <= '0;
            sscratch_reg  <= '0;
            sepc_reg      <= '0;
            scause_reg    <= '0;
            stval_reg     <= '0;
            // Counters
            mcycle_cnt    <= '0;
            minstret_cnt  <= '0;
            // F-extension CSRs
            fflags_reg    <= 5'h0;
            frm_reg       <= 3'h0;

        end else begin
            // Free-running cycle counter
            mcycle_cnt <= mcycle_cnt + 1;

            // Instruction retire counter
            if (retire_en)
                minstret_cnt <= minstret_cnt + 1;

            // FPU fflags accumulation (OR on every FPU result).
            // CSR write takes priority if both happen on the same cycle.
            if (fpu_fflags_we && !(csr_we && (csr_addr == CSR_FFLAGS ||
                                               csr_addr == CSR_FCSR)))
                fflags_reg <= fflags_reg | fpu_fflags;

            if (trap_enter) begin
                // ---- Trap entry (delegation-aware) ---------------------------
                if (trap_delegated_comb) begin
                    // Delegated to S-mode
                    sepc_reg     <= {trap_epc[XLEN-1:1], 1'b0};
                    scause_reg   <= trap_cause;
                    stval_reg    <= trap_val;
                    mstatus_spie <= mstatus_sie;
                    mstatus_sie  <= 1'b0;
                    mstatus_spp  <= (cur_priv == PRIV_S) ? 1'b1 : 1'b0;
                    cur_priv     <= PRIV_S;
                end else begin
                    // M-mode trap
                    mepc_reg     <= {trap_epc[XLEN-1:1], 1'b0};
                    mcause_reg   <= trap_cause;
                    mtval_reg    <= trap_val;
                    mstatus_mpie <= mstatus_mie;
                    mstatus_mie  <= 1'b0;
                    mstatus_mpp  <= cur_priv;
                    cur_priv     <= PRIV_M;
                end

            end else if (sret_en) begin
                // ---- Supervisor trap return ----------------------------------
                mstatus_sie  <= mstatus_spie;
                mstatus_spie <= 1'b1;
                cur_priv     <= mstatus_spp ? PRIV_S : PRIV_U;
                mstatus_spp  <= 1'b0;  // SPP ← U after SRET

            end else if (mret_en) begin
                // ---- Machine trap return -------------------------------------
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
                cur_priv     <= priv_level_t'(mstatus_mpp);
                mstatus_mpp  <= 2'b00;  // MPP ← U after MRET

            end else if (csr_we) begin
                // ---- Normal CSR write ----------------------------------------
                case (csr_addr)
                    // F-extension CSRs
                    CSR_FFLAGS: fflags_reg <= csr_new_val[4:0];
                    CSR_FRM:    frm_reg    <= csr_new_val[2:0];
                    CSR_FCSR: begin
                        fflags_reg <= csr_new_val[4:0];
                        frm_reg    <= csr_new_val[7:5];
                    end
                    // Supervisor CSRs
                    CSR_SSTATUS: begin
                        // Only update S-mode bits of mstatus
                        mstatus_sie   <= csr_new_val[1];
                        mstatus_spie  <= csr_new_val[5];
                        mstatus_spp   <= csr_new_val[8];
                        mstatus_sum_r <= csr_new_val[18];
                        mstatus_mxr_r <= csr_new_val[19];
                    end
                    CSR_SIE: begin
                        // Update only S-mode IE bits in mie_reg
                        mie_reg <= (mie_reg & ~S_IRQ_MASK) | (csr_new_val & S_IRQ_MASK);
                    end
                    CSR_STVEC:    stvec_reg    <= {csr_new_val[XLEN-1:2], 1'b0, csr_new_val[0]};
                    CSR_SSCRATCH: sscratch_reg <= csr_new_val;
                    CSR_SEPC:     sepc_reg     <= {csr_new_val[XLEN-1:1], 1'b0};
                    CSR_SCAUSE:   scause_reg   <= csr_new_val;
                    CSR_STVAL:    stval_reg    <= csr_new_val;
                    // SATP: also accessible from S/U mode (handled by privilege check elsewhere)
                    CSR_SATP:     satp_reg     <= csr_new_val;
                    // Machine CSRs
                    CSR_MSTATUS: begin
                        mstatus_sie   <= csr_new_val[1];
                        mstatus_mie   <= csr_new_val[3];
                        mstatus_spie  <= csr_new_val[5];
                        mstatus_mpie  <= csr_new_val[7];
                        mstatus_spp   <= csr_new_val[8];
                        mstatus_mpp   <= csr_new_val[12:11];
                        mstatus_sum_r <= csr_new_val[18];
                        mstatus_mxr_r <= csr_new_val[19];
                    end
                    CSR_MEDELEG:  medeleg_reg  <= csr_new_val;
                    CSR_MIDELEG:  mideleg_reg  <= csr_new_val;
                    CSR_MIE:      mie_reg      <= csr_new_val;
                    CSR_MTVEC:    mtvec_reg    <= {csr_new_val[XLEN-1:2], 1'b0, csr_new_val[0]};
                    CSR_MSCRATCH: mscratch_reg <= csr_new_val;
                    CSR_MEPC:     mepc_reg     <= {csr_new_val[XLEN-1:1], 1'b0};
                    CSR_MCAUSE:   mcause_reg   <= csr_new_val;
                    CSR_MTVAL:    mtval_reg    <= csr_new_val;
                    // misa, mip, mcycle, minstret, mhartid: read-only
                    default: ;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
