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
    // imem_gnt: the fetch request was FORWARDED downstream (MMU did not block it on
    // a TLB miss / PTW / fault).  In bare mode (no VM) this is the request itself (=1
    // whenever imem_req=1), so it is a structural no-op.  Under VM it gates the FTQ
    // head advance so the head does not run past an address whose translation is
    // still being walked (the MMU, unlike the I$, follows imem_addr and does not hold
    // a missed address -- advancing the head would fetch the next word and mis-tag it
    // with the held VA).  Tie to 1'b1 for direct (no-MMU) instantiations.
    input  wire              imem_gnt,

    // Data memory interface
    output logic [XLEN-1:0]  dmem_addr,
    output logic [XLEN-1:0]    dmem_wdata,
    output logic [XLEN/8-1:0]  dmem_wstrb,   // 4b(RV32) or 8b(RV64)
    output logic             dmem_req,
    output logic             dmem_we,
    output logic             dmem_acc_new,   // 1-cycle STROBE: first cycle of a NEW data access
    input  wire  [XLEN-1:0]  dmem_rdata,
    input  wire              dmem_ready,

    // MMU state outputs (to rv_mmu)
    output logic [XLEN-1:0]  satp_out,        // SATP CSR value
    output priv_level_t      priv_out,         // current privilege level
    output logic             mstatus_sum_out,  // mstatus.SUM
    output logic             mstatus_mxr_out,  // mstatus.MXR
    output logic             mstatus_mprv_out, // mstatus.MPRV
    output logic [1:0]       mstatus_mpp_out,  // mstatus.MPP
    output logic             tlb_flush_out,    // SFENCE.VMA pulse
    output logic             fence_i_out,      // FENCE.I pulse (flush I-cache)

    // MMU stall inputs (from rv_mmu)
    input  wire              mmu_stall,   // IF/ID stall (any translation pending)
    input  wire              mem_stall,   // EX/MEM stall (MEM-port translation pending)

    // Data-memory wait input (from an external variable-latency memory, e.g. the
    // AXI4 bridge to DDR).  High while a MEM-stage load/store/AMO/PTW-independent
    // data access is still in flight; drops on the cycle the access completes.
    // Tie to 1'b0 for the zero-latency BRAM path -- then every term below that
    // references it reduces to its original form (provably a no-op).
    input  wire              dmem_wait,

    // MMU fault inputs (from rv_mmu, when TLB hit but permission denied)
    input  wire              if_fault,    // instruction page fault
    input  wire              mem_fault,   // load/store page fault

    // External interrupt inputs
    input  wire              timer_irq,   // machine timer interrupt (MTIP/STIP via mideleg)
    input  wire              sw_irq,      // software interrupt
    input  wire              ext_irq,     // external interrupt

    // CLINT mtime value -> 'time' CSR (rdtime).  Tie to 0 if no timer present.
    input  wire  [63:0]      time_val
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
    // MEM stage page fault (load/store page fault from MMU, TLB-hit permission fail)
    logic        mem_trap_enter;
    // Instruction page fault (from rv_mmu if_fault) and the SATP-write fetch
    // barrier.  Declared here (before any_redirect / the redir mux use them);
    // driven further below.  All are 0 unless the MMU is active and a fetch
    // translation faults / SATP is written, so every path here is a structural
    // no-op for bare-mode (M-mode boot, all unit/compliance tests) where if_fault
    // never fires and SATP is only written in M-mode (which cannot fault on fetch).
    logic            ifpf_take;          // 1 = take an instruction page fault trap this cycle
    logic [XLEN-1:0] ifpf_pc;            // faulting instruction VA (-> mepc / mtval)
    // fetch_dead_q (bug #17): the COMMITTED instruction fetch has PAGE-FAULTED, so
    // imem_ready will NEVER rise for it -- the ~imem_ready full-pipeline freeze must
    // be released so the OLDER in-flight instructions (notably the very JAL/branch
    // whose redirect targeted the faulting page) can drain and RETIRE, after which
    // the latched fault is taken precisely.  Without this the freeze and the fault
    // deadlock each other: a demand-paged call target (Linux userspace) faults ->
    // imem_ready stays 0 -> stall_ex holds the JAL in EX -> branch_taken_ex keeps
    // redir_eff high -> the fault can neither latch nor be taken -> the MMU re-walks
    // the dead VA forever (observed: musl memset() call spinning in an IF-PTW
    // walk/fault loop at ~3 reads/17 cycles with zero retires).  Set on if_fault
    // (the walked VA is the committed imem_addr -- imem_gnt pins the FTQ head);
    // cleared when the fetch is alive again (imem_ready: a redirect moved fetch to
    // a mapped page) or the fault trap is taken (ifpf_take).  STRUCTURAL NO-OP
    // whenever instruction fetch never page-faults (bare mode / M-mode / all
    // compliance and unit suites): fetch_dead_q is then constant 0 and every
    // masked term reduces to the original expression.
    logic            fetch_dead_q;
    // Forward declarations (read by the ifpf take gate below their normal home):
    logic            if_id_valid;    // IF/ID pipeline register valid
    logic            id_ex_valid;    // ID/EX pipeline register valid
    logic            ex_mem_valid;   // EX/MEM pipeline register valid
    logic            satp_write_redir;   // SATP write committed -> refetch next insn under new satp
    logic [XLEN-1:0] satp_redir_tgt;     // = PC of the instruction after the SATP write
    logic        trap_or_mret;    // Combined: causes PC redirect + pipeline flush
    assign trap_or_mret = ex_trap_enter | ex_mret_en | ex_sret_en | mem_trap_enter;

    // redirect_settle: hold IF/ID for 2 cycles after ANY PC redirect.
    //
    // With the variable-length fetch, the next sequential PC is derived from
    // imem_rdata (the instruction currently being fetched).  Immediately after a
    // redirect the in-flight imem_rdata is wrong-path data and, worse, may have
    // been fetched under a stale translation regime (e.g. an SRET/MRET that
    // changes privilege one cycle later, so the target virtual address was briefly
    // fetched as a physical address and returned X from an unmapped region).
    // Feeding that into seq_pc would corrupt fetch_pc.
    //
    // Holding the fetch (re-presenting fetch_pc) for two cycles after a redirect
    // lets the privilege/SATP change settle and gives the MMU a cycle to evaluate
    // the target address and assert mmu_stall on a TLB miss before we ever advance
    // the PC from the (possibly invalid) fetched instruction.  In bare mode this
    // simply adds a couple of fetch bubbles after a branch/jump/trap.
    logic [1:0]  redirect_settle;
    wire         any_redirect = branch_taken_ex | trap_or_mret | satp_write_redir | ifpf_take;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) redirect_settle <= 2'b00;
        else        redirect_settle <= {redirect_settle[0], any_redirect};
    end
    wire redirect_stall = |redirect_settle;

    // Trap destinations from rv_csr
    logic [XLEN-1:0] trap_vector; // mtvec — used on trap_enter
    logic [XLEN-1:0] mepc_out;    // mepc  — used on mret_en

    // stall_if/stall_id fan out to the whole front-end (~200 loads each) and sit
    // mid-way on the worst timing path (dmem_wait -> stall_if -> imem_addr mux ->
    // I-side translation -> I$ read-enable).  max_fanout lets synthesis replicate
    // the driver to bound each copy's load; pure physical hint, functional no-op.
    (* max_fanout = 64 *) logic stall_if;      // freeze PC and IF/ID register
    (* max_fanout = 64 *) logic stall_id;      // freeze IF/ID register
    logic stall_ex;      // freeze EX/MEM register (AMO 2-phase stall)
    // Decoupled-fetch (approach B / 50 MHz step 4): the FETCH hold is fetch-domain
    // ONLY (redirect settle + FIFO backpressure), NEVER the data stall dmem_wait, so
    // the ex_mem_alu_result -> dc_c_wait -> stall -> imem_addr -> I$ worst path is cut.
    logic fetch_hold;    // hold (re-present) the in-flight fetch PC
    logic fetch_full;    // fetch FIFO backpressure (registered occupancy)
    logic flush_id;      // clear IF/ID   -> insert bubble into ID
    logic flush_ex;      // clear ID/EX   -> insert bubble into EX
    logic flush_ex_mem;  // clear EX/MEM  -> discard trap-interrupted instruction
    logic redir_eff;     // effective redirect (immediate|pending); driven in IF stage

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

    // fpu_done: an FP op produced its result but could not retire on its
    // completion cycle because stall_ex was held by an UNRELATED source (e.g.
    // ~imem_ready from an in-flight IF fetch).  Exactly mirrors muldiv_done
    // (see below): fpu_was_busy masks only ONE cycle, so without this a
    // completed FP op would RE-FIRE fpu_valid_in the next cycle and restart.
    // Idempotent (same operands -> same result), but a deterministically
    // recurring stall at completion would restart forever = LIVELOCK.  Now that
    // ALL FP compute ops are multi-cycle (C-2c), not just the rare FDIV/FSQRT,
    // this guard is load-bearing.  Strict no-op when an FP op always completes
    // with stall_ex=0 (BRAM: ~imem_ready never asserts).
    logic fpu_done;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fpu_done <= 1'b0;
        else if (fpu_was_busy && !fpu_busy_int && stall_ex)
            fpu_done <= 1'b1;   // completed this cycle but held in EX
        else if (!stall_ex)
            fpu_done <= 1'b0;   // EX advances -> the FP op retires/leaves
    end

    // fpu_start_stall: stall IF/ID for the one cycle when FDIV/FSQRT first enters EX.
    // Declared here (before stall assigns); driven after fpu_valid_in assignment below.
    // Without this, the instruction after FDIV advances into ID/EX on the same cycle
    // that fpu_busy_int goes high (NBA), so FDIV is lost from ID/EX before WB.
    logic fpu_valid_in;    // forward-declared; driven below
    logic fpu_start_stall; // forward-declared; driven below

    // muldiv_busy_int: multi-cycle integer divide (DIV/REM, sequential radix-2) in
    // progress.  Exactly mirrors the FPU FDIV/FSQRT busy protocol above so the EX
    // stage holds the divide instruction until its result is ready.  Multiply ops
    // (DSP, single-cycle) never assert these signals (no-op path).
    logic muldiv_busy_int;     // forward-declared; driven by rv_muldiv below
    logic muldiv_valid_in;     // forward-declared; driven below (divide start)
    logic muldiv_start_stall;  // forward-declared; driven below
    // muldiv_was_busy: 1-cycle delayed muldiv_busy_int, prevents re-triggering the
    // divider on the cycle busy falls (before ID/EX advances past the divide).
    logic muldiv_was_busy;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) muldiv_was_busy <= 1'b0;
        else        muldiv_was_busy <= muldiv_busy_int;
    end

    // muldiv_done: a divide produced its result but could not retire on its
    // completion cycle because stall_ex was held by an UNRELATED source (e.g.
    // ~imem_ready -- an in-flight IF fetch).  muldiv_was_busy masks only ONE
    // cycle, so without this the completed divide would RE-FIRE muldiv_valid_in
    // the next cycle and restart from scratch.  Recomputing is idempotent (same
    // operands -> same result), but if that stall recurs deterministically at
    // every completion the divide restarts forever and never retires -- a
    // LIVELOCK (observed: a trap-handler divide under a periodic I$ not-ready
    // pattern hung Linux boot / div_irq_test).  muldiv_done latches "computed,
    // waiting to retire": it suppresses the restart and holds the registered
    // result until the divide advances out of EX (~stall_ex).  Strict no-op when
    // a divide always completes with stall_ex=0 (BRAM: ~imem_ready never asserts).
    logic muldiv_done;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            muldiv_done <= 1'b0;
        else if (muldiv_was_busy && !muldiv_busy_int && stall_ex)
            muldiv_done <= 1'b1;   // completed this cycle but held in EX
        else if (!stall_ex)
            muldiv_done <= 1'b0;   // EX advances -> the divide retires/leaves
    end

    // Number of address bits that select a byte lane within one DMEM data word.
    // RV32: 2 bits (addr[1:0]) -> 4-byte word, wstrb is 4 bits
    // RV64: 3 bits (addr[2:0]) -> 8-byte logical word (two 32-bit BRAM halves), wstrb is 8 bits
    // Using [2:0] for RV32 causes overflow: SW to addr[2]=1 gives wstrb=0 (no write).
    localparam int BYTE_LANE_W = $clog2(XLEN/8);

    // redirect_stall holds IF/ID only (not EX) so the redirecting branch/trap can
    // still complete; it must NOT be added to stall_ex.
    // (~imem_ready & ~fetch_dead_q): the IF freeze is released while the committed
    // fetch is DEAD (page-faulted, bug #17) so older instructions drain and retire;
    // the aligner then starves and feeds bubbles.  ~fetch_dead_q is 1 (no-op)
    // whenever instruction fetch cannot page-fault.
    assign stall_if = load_use_hazard | (~imem_ready & ~fetch_dead_q) | amo_stall | mmu_stall | fpu_busy_int | fpu_start_stall | muldiv_busy_int | muldiv_start_stall | mal_stall | redirect_stall | dmem_wait;
    assign stall_id = load_use_hazard | (~imem_ready & ~fetch_dead_q) | amo_stall | mmu_stall | fpu_busy_int | fpu_start_stall | muldiv_busy_int | muldiv_start_stall | mal_stall | redirect_stall | dmem_wait;
    // mem_stall freezes EX/MEM: a load/store in MEM whose data translation is
    // still pending must remain in MEM (re-issuing its access) until the TLB is
    // filled.  Without this the access leaves MEM unwritten.  Note: IF-port PTW
    // (mmu_stall) must NOT freeze EX/MEM, or it would stall a branch/MRET/trap
    // resolving in EX and corrupt control flow.
    //
    // ~imem_ready (a multi-cycle IF fetch in progress) FREEZES the whole pipeline:
    // EX/MEM and MEM/WB (below) hold, so a held instruction is not re-committed
    // (no duplication) and forwarding state is preserved across the fetch.  The
    // EX-stage redirect is latched (redir_pend) and applied when the fetch
    // completes.  Unlike mmu_stall, the IF fetch uses its OWN AXI master, so
    // freezing EX/MEM does not conflict with the data port.  NO-OP for a 1-cycle
    // IF (imem_ready=1 every cycle): ~imem_ready=0.
    assign stall_ex = amo_stall | fpu_busy_int | muldiv_busy_int | mal_stall | mem_stall | dmem_wait | (~imem_ready & ~fetch_dead_q);
    // Traps/MRET flush the same stages as branch (instructions after the trap insn).
    // With the variable-length fetch (see IF stage), the redirect target address is
    // presented to IMEM combinationally on the cycle the redirect resolves, so the
    // very next cycle already delivers the correct target instruction.  Only the
    // single in-flight (wrong-path) fetch needs to be discarded, hence a 1-cycle
    // flush_id (no redirect_q needed as in the old fixed-+4 / late-PC design).
    // flush_id = effective redirect (immediate OR latched-pending).  Pending keeps
    // IF/ID flushed so a wrong-path fetch that completes during the pending window
    // is discarded.  Equals (branch_taken_ex | trap_or_mret) when no pending
    // (1-cycle IF).  redir_eff is declared in the IF stage below (module-scope
    // wire forward reference).
    // Flushes only take effect on a cycle the pipeline actually advances
    // (imem_ready); during a multi-cycle IF fetch everything is frozen and the
    // resolution (branch/trap commit + wrong-path kill) is deferred to the
    // completion cycle.  NO-OP for a 1-cycle IF (imem_ready=1 -> & 1).
    assign flush_id    = redir_eff & imem_ready;
    // flush_ex bubbles ID/EX (which holds the EX-stage instruction) the cycle a
    // resolving branch/JAL/JALR or a load-use hazard ADVANCES out of EX, so the
    // wrong-path / load-shadow instruction behind it does not execute.  It must be
    // gated by ~stall_ex (the exact condition under which the EX instruction
    // advances to EX/MEM), NOT merely by imem_ready: if a redirect resolves while
    // stall_ex holds the EX instruction for a reason OTHER than ~imem_ready (e.g.
    // dmem_wait from a prior store still completing, amo_stall, mal_stall,
    // mem_stall, fpu_busy), then imem_ready=1 would let flush_ex CLEAR the branch
    // from ID/EX while stall_ex prevents EX/MEM from capturing it -- losing the
    // instruction.  Conditional branches survive this (no writeback), but a JAL/JALR
    // would lose its link-register write: the redirect still fires (PC jumps to the
    // target) yet `ra` is never updated, so the matching `ret` returns to a stale
    // address (found via real OpenSBI: `jal` right after `sd s6,off(sp)`).  Gating
    // by ~stall_ex holds the branch/JAL in EX until it can advance and capture its
    // result; the redirect is applied throughout via redir_eff (independent of
    // flush_ex), and the wrong path stays bubbled in IF/ID by flush_id.  ~stall_ex
    // implies imem_ready, so this is a strict refinement / no-op whenever the only
    // stall source is ~imem_ready or there is no stall (the common BRAM case).
    // (fetch_dead_q & stall_id & ...): bug #17 drain-duplication guard.  Releasing
    // the ~imem_ready freeze creates the NEW combination "EX advances (stall_ex=0)
    // while ID cannot refill (stall_id=1, e.g. mmu_stall from the looping walk of
    // the dead page)": ID/EX would HOLD the instruction EX/MEM just captured and
    // EX/MEM would capture it AGAIN next cycle (double execution / CSR re-fire).
    // Bubble ID/EX on such an advance -- the instruction has executed.  The
    // *_start_stall exclusions keep a multi-cycle FPU/divide op held in ID/EX on
    // its start cycle (EX/MEM captured a deliberate bubble for it, not the op).
    // Today mmu_stall implies ~imem_ready (the I$ starves during a walk), so this
    // term can only fire under fetch_dead_q -> structural no-op without a fault.
    assign flush_ex    = (load_use_hazard | redir_eff
                          | (fetch_dead_q & stall_id
                             & ~fpu_start_stall & ~muldiv_start_stall)) & ~stall_ex;
    // EX/MEM must NOT be flushed for branch or load-use:
    //   - branch in EX: EX/MEM holds the instruction before the branch (already
    //     committed to EX; it must reach MEM/WB).  JAL's rd writeback also lives
    //     here and must not be discarded.
    //   - load-use in EX: the load itself must proceed to MEM so dmem is accessed.
    // Only flush EX/MEM for traps/MRET to prevent the interrupted instruction
    // from spuriously writing its destination register.  Gate by ~stall_ex (the
    // EX-advance cycle), NOT imem_ready: the trap/MRET now commits on ~stall_ex
    // (csr_commit_ex), so the flush must fire on the same cycle.  Were it left on
    // imem_ready it could bubble EX/MEM while EX is held by a non-IF stall
    // (dmem_wait/amo/mal/mem_stall) -- discarding the held MEM-stage instruction
    // (e.g. the very store whose dmem_wait caused the stall).  ~stall_ex implies
    // imem_ready, so this is a no-op for the common BRAM case (stall_ex=0).
    assign flush_ex_mem = trap_or_mret & ~stall_ex;

    // =========================================================================
    // Stage 1: Instruction Fetch (IF) — variable-length (C-extension capable)
    // =========================================================================
    // 50 MHz step 8: BLOCK-ALIGNED FETCH (FTQ) + HALFWORD ALIGNER.
    // ------------------------------------------------------------------------
    // The old variable-length engine derived the next fetch address as
    //   seq_pc     = fetch_pc + len(imem_rdata)   // depends on imem_rdata (data)
    //   imem_addr  = ~imem_ready ? fetch_pc : seq_pc  // depends on imem_ready
    // so imem_addr -> MMU -> I$ sat on a recursive loop
    //   I$ addr_q -> hit -> imem_ready/imem_rdata -> seq_pc/fetch_hold -> imem_addr
    //   -> MMU -> I$ addr_q
    // that bound the 50 MHz timing (docs/freq_50mhz.md sec 18-20).  Block fetch
    // breaks BOTH dependences:
    //   (a) imem_rdata: addresses advance by a FIXED word (+4), not by the decoded
    //       instruction length.  2/4-byte RVC boundaries (incl. word-straddling
    //       4-byte instructions) are recovered downstream by an in-core ALIGNER
    //       fed from a HALFWORD BUFFER, so decode/EX are unchanged.
    //   (b) imem_ready: the next address is PRE-GENERATED into a Fetch Target Queue
    //       (FTQ).  imem_addr = ftq[head] is a pure register-array read; the I$
    //       ready only advances the head POINTER (a flop enable), never imem_addr
    //       combinationally.  Crucially the head advances PAST an address as soon as
    //       the I$ accepts it, so during a miss fill imem_addr already presents the
    //       NEXT address while the I$ holds (and re-looks-up) the missed address in
    //       its own addr_q (rv_icache EXTRA-2 removed) -- no re-presentation by the
    //       core, no duplicate fetch, full 1-instruction/cycle throughput.
    //
    // A simple registered "present address" that advances on imem_ready does NOT
    // work: on a miss it would hold the missed address and the I$ would re-accept it
    // (duplicate) -> half throughput.  The FTQ (pre-generation) is what keeps the
    // presented address one ahead of the served address.  (docs/freq_50mhz.md 17.8.)
    //
    // bfpc : the WORD address whose 32-bit window is on imem_rdata this cycle
    //        (= the old fetch_pc role: the SERVED address, advances at a fetch
    //        boundary).  Used to tag pushed halfwords with their byte PC.
    logic [XLEN-1:0] bfpc;

    // ---- Redirect request (this cycle), priority order ----------------------
    logic            redir_req;
    logic [XLEN-1:0] redir_tgt;
    // MRET/SRET REDIRECT must be GATED by the commit condition (~stall_ex), exactly
    // like the privilege change they carry (rv_csr mret_en/sret_en = ex_*_en &
    // csr_commit_ex).  Otherwise the redirect to mepc/sepc fires while the xRET is
    // still HELD in EX (stall_ex=1), so fetch jumps to the target (e.g. a U-page on
    // SRET-to-userspace) BEFORE priv actually changes (still S-mode).  Fetching a
    // U-page in S-mode faults / is not forwarded -> imem_ready=0 -> stall_ex=1 ->
    // the xRET can NEVER commit (csr_commit_ex=~stall_ex) -> priv stays S -> the
    // fetch keeps faulting = a self-sustaining DEADLOCK at the S->U handoff.  Found
    // when a +1-cycle D$ access latency shifted an xRET's commit cycle onto a
    // ~imem_ready stall (docs/freq_50mhz.md; #14/#15/#16-class variable-latency
    // exposure).  Gating defers the redirect until the xRET commits, so the fetch
    // stays on the (fetchable) sequential path, ~imem_ready clears, stall_ex drops,
    // the xRET commits with priv AND redirect atomic.  STRICT no-op for the common
    // case (xRET commits at stall_ex=0: the gate is then 1, same as before).
    always_comb begin
        redir_req = 1'b1;
        if      (ifpf_take)                       redir_tgt = trap_vector;  // instruction page fault (ungated; the faulting fetch holds imem_ready low)
        else if (ex_trap_enter || mem_trap_enter) begin
            // A trap changes privilege; its REDIRECT must be ATOMIC with the priv
            // commit (csr_commit_ex = ~stall_ex), exactly like MRET/SRET below.  If a
            // trap is detected while EX is HELD (stall_ex=1) -- e.g. the +1-cycle
            // registered MEM-port fault lands while mem_stall holds the bubble, or an
            // older store's dmem_wait still stalls EX -- redirecting to trap_vector NOW
            // fetches the handler in the OLD privilege (an M-mode mtvec handler fetched
            // in S-mode), which faults -> imem_ready=0 -> stall_ex stays 1 -> the trap
            // can NEVER commit (csr_commit_ex=0) -> priv is stuck -> a self-sustaining
            // DEADLOCK (the same commit-gate class as the SRET S->U handoff;
            // docs/freq_50mhz.md #3, exposed by the registered data-TLB lookup).  Defer
            // (hold, no redirect) until stall_ex drops: the held instruction keeps the
            // fetch on a fetchable path so ~imem_ready clears, then the trap commits with
            // privilege AND redirect atomic.  The explicit hold also stops a YOUNGER
            // EX-stage branch from stealing redirect priority over an older held MEM
            // fault.  STRICT no-op for the common case (trap taken at stall_ex=0: the
            // gate is 1, immediate redirect exactly as before).
            if (~stall_ex)                        redir_tgt = trap_vector;
            else begin redir_req = 1'b0;          redir_tgt = '0; end
        end
        else if (ex_mret_en && ~stall_ex)         redir_tgt = mepc_out;
        else if (ex_sret_en && ~stall_ex)         redir_tgt = sepc_out;
        else if (branch_taken_ex)                 redir_tgt = branch_target_ex;
        else if (satp_write_redir)                redir_tgt = satp_redir_tgt; // SATP fetch barrier
        else begin redir_req = 1'b0; redir_tgt = '0; end
    end

    // ---- Latched pending redirect -------------------------------------------
    // A redirect resolved in EX must change the fetch stream, but with a
    // multi-cycle IF (AXI/DDR) the fetch slot may be busy (~imem_ready) on the
    // cycle the branch/trap resolves -- and the branch is flushed out of EX the
    // next edge (flush_ex), so its redirect would be lost.  Latch the target and
    // apply it at the next fetch boundary (imem_ready).  For a 1-cycle IF
    // (imem_ready every cycle) the pending bit never sets, so behaviour is
    // unchanged: the redirect is applied immediately, exactly as before.
    logic            redir_pend_q;
    logic [XLEN-1:0] redir_pend_tgt_q;
    // redir_eff = "a redirect is in progress" -- drives only the SQUASH machinery
    // (flush_id / flush_ex / FIFO flush+push gate / redirect_settle is separate) so
    // wrong-path instructions are discarded both the cycle the redirect RESOLVES
    // (redir_req) AND the extra cycle the registered steer below is still applying
    // (redir_pend_q).  It is NO LONGER used to drive imem_addr: the fetch address is
    // steered ONLY by the registered redir_pend_q / redir_pend_tgt_q (step 4), so the
    // data-dependent combinational redir_req never reaches imem_addr -> IF-TLB -> I$.
    assign           redir_eff     = redir_req | redir_pend_q;  // (declared above)

    // 50 MHz step 4 (approach B step 2): the redirect is ALWAYS latched one fetch
    // boundary before it steers imem_addr.  Previously redir_eff (which contains the
    // combinational, data-dependent redir_req) selected imem_addr directly; that put
    // ex_mem_alu_result -> dmem_wait -> stall_if -> irq inject -> ex_trap_enter ->
    // redir_req -> imem_addr -> IF-TLB -> I$ on the critical path.  By driving
    // imem_addr from the REGISTER redir_pend_q/_tgt_q only, redir_req ends at a flop
    // (this latch) and no longer fans out to the fetch address.  Cost: a taken
    // redirect resolved on a fetch-boundary cycle (imem_ready=1) applies +1 cycle
    // later; the decoupled fetch FIFO absorbs the fetch and redirect_settle/redir_eff
    // keep the wrong path squashed across the extra cycle.  STRICT no-op when the
    // redirect resolves while ~imem_ready (the I$-miss case already deferred it).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            redir_pend_q     <= 1'b0;
            redir_pend_tgt_q <= '0;
        end else begin
            if (redir_req) redir_pend_tgt_q <= redir_tgt;          // capture newest target
            // Apply (and clear) on the fetch boundary the registered target is
            // presented; re-arm iff a fresh redir_req coincides with that cycle.
            if (redir_pend_q && imem_ready) redir_pend_q <= redir_req; // applied; re-arm iff new
            else if (redir_req)             redir_pend_q <= 1'b1;      // arm for next boundary
        end
    end

    // ---- Fetch Target Queue (FTQ): pre-generated WORD fetch addresses --------
    // gen_pc generates the next sequential word address (+4) every cycle and pushes
    // it into the FTQ (when there is room); imem_addr = ftq[ftq_head] is a registered
    // array read.  The head advances (pop) when the I$ ACCEPTS the presented address
    // (imem_ready) -- a flop ENABLE, never a combinational input to imem_addr -- so
    // the head is already ONE AHEAD of the served address during a miss fill: the
    // missed address is held and re-looked-up by the I$ itself (rv_icache EXTRA-2
    // removed), and imem_addr already presents the NEXT address.  A plain register
    // that advances on imem_ready cannot do this (it would re-present the missed
    // address and the I$ would re-accept it = duplicate / half throughput); the FTQ
    // pre-generation is what keeps the presented address ahead (docs/freq_50mhz.md
    // 17.8 / 20).  redir_pend_q presents the (registered) redirect target through the
    // mux; the FTQ is reloaded to continue sequential generation from target+4 the
    // moment the redirect is applied.
    localparam int FTQ_DEPTH = 4;
    localparam int FQ_AW     = $clog2(FTQ_DEPTH);
    logic [XLEN-1:0]  ftq [FTQ_DEPTH];
    logic [FQ_AW-1:0] ftq_head, ftq_tail;
    logic [FQ_AW:0]   ftq_count;
    logic [XLEN-1:0]  gen_pc;
    wire ftq_full  = (ftq_count == (FQ_AW+1)'(FTQ_DEPTH));
    wire ftq_empty = (ftq_count == '0);

    wire [XLEN-1:0] reload_addr = redir_pend_tgt_q & ~XLEN'(3); // word-aligned target
    wire            ftq_reload  = redir_pend_q & imem_ready;    // redirect applied this boundary

    // ---- Halfword buffer occupancy (declared here so hb_full can gate the fetch
    //      hold / FTQ pop below; the buffer storage + FF are defined further down).
    localparam int HB_DEPTH = 8;                  // 4 words = 8 halfwords
    localparam int HB_AW    = $clog2(HB_DEPTH);
    logic [15:0]      hb_hw [HB_DEPTH];
    logic [XLEN-1:0]  hb_pc [HB_DEPTH];
    logic [HB_AW-1:0] hb_head, hb_tail;
    logic [HB_AW:0]   hb_count;
    logic             skip_low_q;                 // skip leading halfword of first post-redirect word
    wire hb_full  = (hb_count >= (HB_AW+1)'(HB_DEPTH-1)); // keep room for a 2-halfword push
    wire hb_empty = (hb_count == '0);

    // Backpressure / settle HOLD: re-present the SERVED word (bfpc) so the held I$
    // window stays available to push, exactly like the old fetch_pc hold.  NOTE:
    // ~imem_ready is NOT a hold reason any more -- a miss is replayed by the I$
    // itself, and the FTQ head already presents the next address during the fill.
    assign fetch_full = hb_full;
    assign fetch_hold = redirect_stall | fetch_full;

    // imem_addr: registered redirect target while pending; else (backpressure/settle)
    // re-present the served word; else the pre-generated FTQ head.  EVERY operand is
    // a register (redir_pend_q / reload_addr / fetch_hold / bfpc / ftq[head]) -- no
    // imem_ready, no imem_rdata in the fetch-address cone -> the 50 MHz loop is cut.
    always_comb begin
        if      (redir_pend_q) imem_addr = reload_addr;     // present target while pending
        else if (fetch_hold)   imem_addr = bfpc;            // hold (backpressure / settle)
        else                   imem_addr = ftq[ftq_head];   // pre-generated sequential word
    end
    assign imem_req = 1'b1;

    // hb_dup: the served word repeats the last pushed word's byte-PC.  Two causes:
    //   (1) redirect-reload SETTLE -- the redirect target is presented for an extra
    //       cycle (redir_pend_q hold + the ftq[0] reload both drive imem_addr=target),
    //       so the I$ serves it once MORE than it is pushed.  Here the FTQ head has
    //       already advanced (imem_addr = head = target+4 != bfpc = target), so a pop
    //       on this dup runs the head one word ahead of the served/pushed stream; that
    //       stale lead later skips a served-but-unpushed word when a full-buffer hold
    //       releases -> the next word inherits the skipped word's bfpc tag = 4-byte
    //       fetch skid (the step-8 path_parentat crash; cache_soc uncached repro).
    //   (2) IF-PTW hold -- imem_gnt=0 pins the head ON the committed word (imem_addr =
    //       head = bfpc); when the walk finishes the head MUST advance even though the
    //       I$ is still re-serving that same word.  Gating the pop with plain ~hb_dup
    //       would stall the head forever here (livelock).
    // So suppress the pop ONLY for case (1): a dup where the head has run ahead
    // (imem_addr != bfpc).  Case (2) keeps imem_addr == bfpc and is unaffected.
    //
    // The compare is NARROWED to the low word-index bits [5:2] (not the full XLEN):
    // reload-settle over-serve is always imem_addr = bfpc+4 (the I$ re-serves the
    // previous word while the head presents the next), so bit[2] alone already
    // differs; [5:2] gives margin without aliasing in a dup (re-serve) context,
    // which requires bfpc == hb_last_pc and cannot stride 64 B.  Case (2) (IF-PTW
    // hold) keeps imem_addr == bfpc -> [5:2] equal -> dup_ahead=0 (unaffected).
    // The full-width compare disturbed the thin 50 MHz default-flow placement;
    // the 4-bit compare is functionally equivalent (all gates re-verified).
    logic [XLEN-1:0] hb_last_pc;
    logic            hb_last_vld;
    wire hb_dup    = hb_last_vld & (bfpc == hb_last_pc);
    wire dup_ahead = hb_dup & (imem_addr[5:2] != bfpc[5:2]);   // reload-settle over-serve only
    // FTQ head pops on accept (not while holding); gen_pc pushes when there is room.
    // imem_gnt gates the pop: if the MMU is blocking the presented address on a TLB
    // miss (imem_gnt=0 while imem_ready=1 from the PREVIOUS fetch), the head must NOT
    // advance -- it holds the committed address so it is re-presented (and re-walked /
    // re-fetched) instead of being skipped while the next word is fetched and
    // mis-tagged.  This also keeps if_fault non-speculative (the head holds the
    // committed faulting address rather than running ahead into speculative faults).
    wire ftq_pop  = imem_ready & imem_gnt & ~ftq_reload & ~redir_pend_q & ~fetch_hold & ~ftq_empty & ~dup_ahead;
    wire ftq_push = ~ftq_full  & ~ftq_reload & ~redir_pend_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ftq[0]    <= RST_ADDR[XLEN-1:0] & ~XLEN'(3);
            ftq_head  <= '0;
            ftq_tail  <= FQ_AW'(1);
            ftq_count <= (FQ_AW+1)'(1);
            gen_pc    <= (RST_ADDR[XLEN-1:0] & ~XLEN'(3)) + XLEN'(4);
        end else if (ftq_reload) begin
            // redirect applied: put the TARGET itself at the FTQ head so it stays
            // presented (the head holds while imem_ready=0) until it is actually
            // fetched -- critical when the target needs a multi-cycle MMU page-table
            // walk.  The registered redirect (redir_pend_q) clears on the PREVIOUS
            // fetch's imem_ready, one cycle after it is applied, but the target's own
            // fetch (PTW) is still in flight; if the FTQ head were target+4 the head
            // would advance off the target before it is fetched and the held target
            // VA (bfpc) would be mis-tagged with target+4's data.  Holding the target
            // at the head re-presents it until fetched; the duplicate presentation in
            // the fast (no-PTW) path is dropped by hb_dup.
            ftq[0]    <= reload_addr;
            ftq_head  <= '0;
            ftq_tail  <= FQ_AW'(1);
            ftq_count <= (FQ_AW+1)'(1);
            gen_pc    <= reload_addr + XLEN'(4);
        end else begin
            if (ftq_push) begin
                ftq[ftq_tail] <= gen_pc;
                ftq_tail      <= ftq_tail + FQ_AW'(1);
                gen_pc        <= gen_pc + XLEN'(4);
            end
            if (ftq_pop) ftq_head <= ftq_head + FQ_AW'(1);
            ftq_count <= ftq_count + (ftq_push ? (FQ_AW+1)'(1) : (FQ_AW+1)'(0))
                                   - (ftq_pop  ? (FQ_AW+1)'(1) : (FQ_AW+1)'(0));
        end
    end

    // bfpc = the SERVED word address (PC of the word currently on imem_rdata).  It
    // captures imem_addr at each fetch boundary, exactly like the old fetch_pc, and
    // HOLDS during a miss / backpressure so the delivered word is tagged with the
    // address it actually belongs to.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          bfpc <= RST_ADDR[XLEN-1:0] & ~XLEN'(3);
        else if (imem_ready) bfpc <= imem_addr;
    end

    // ---- Halfword buffer (skid FIFO of 16-bit halfwords) + ALIGNER -----------
    // Each fetched 32-bit word pushes its two halfwords (each tagged with its byte
    // PC).  The aligner extracts a 2-byte (RVC) or 4-byte instruction from the buffer
    // head, assembling a word-straddling 4-byte instruction from two adjacent
    // halfwords -- this is what lets imem_addr advance by a FIXED +4.  Decode is
    // unchanged: a compressed instruction is identified by inst[1:0] != 2'b11, and
    // the upper 16 bits are don't-care for it.  (Storage / occupancy declared above.)

    // Aligner (combinational) -> drives IF/ID directly.
    wire [15:0]      h0   = hb_hw[hb_head];
    wire [15:0]      h1   = hb_hw[(hb_head + HB_AW'(1))];
    wire [XLEN-1:0]  h0pc = hb_pc[hb_head];
    wire             h0_avail = (hb_count >= (HB_AW+1)'(1));
    wire             h1_avail = (hb_count >= (HB_AW+1)'(2));
    wire             align_is_comp = (h0[1:0] != 2'b11);
    wire             align_valid   = h0_avail & (align_is_comp | h1_avail);
    wire [31:0]      align_inst    = {h1, h0};
    wire [HB_AW:0]   align_consume = align_is_comp ? (HB_AW+1)'(1) : (HB_AW+1)'(2);

    // Push the delivered word (imem_ready) on the committed path with buffer room;
    // pop the consumed halfwords when decode accepts an aligned instruction.  Flush
    // (drop wrong-path halfwords) for the whole duration of a redirect (redir_eff),
    // so the buffer is empty when a faulting/redirect target is being resolved.
    //
    // hb_dup: a hold-less synchronous IMEM (rv_imem, used by rv_soc_bram) re-reads
    // mem[addr] on EVERY req cycle.  Because the FTQ head advances one cycle AFTER an
    // accept (a flop enable), the very first address is presented for two cycles
    // while imem_ready ramps 0->1 (the I$ instead HOLDS its addr_q and serves once,
    // so it never duplicates).  That makes the hold-less IMEM deliver the same word
    // twice with the same bfpc.  A sequential fetch never re-serves the same byte PC
    // (PC strictly advances), and a redirect flushes the buffer (hb_last_vld<=0), so
    // "skip a push whose bfpc equals the immediately preceding pushed PC" drops only
    // such duplicates -- a structural no-op on the I$ path (bfpc always advances).
    wire hb_flush = redir_eff;
    wire hb_push  = imem_ready & ~redir_eff & ~redirect_stall & ~hb_full & ~hb_dup;
    wire hb_pop   = ~stall_id & align_valid;
    wire [HB_AW:0] hb_push_n = hb_push ? (skip_low_q ? (HB_AW+1)'(1) : (HB_AW+1)'(2)) : (HB_AW+1)'(0);
    wire [HB_AW:0] hb_pop_n  = hb_pop  ? align_consume : (HB_AW+1)'(0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hb_head <= '0; hb_tail <= '0; hb_count <= '0; skip_low_q <= 1'b0;
            hb_last_pc <= '0; hb_last_vld <= 1'b0;
        end else if (hb_flush) begin
            // drop wrong-path halfwords; the first word after a mid-word redirect
            // target (target[1]==1) skips its low halfword to start at the target.
            hb_head    <= '0; hb_tail <= '0; hb_count <= '0;
            skip_low_q <= redir_pend_tgt_q[1];
            hb_last_vld <= 1'b0;                     // first post-redirect push is never a dup
        end else begin
            if (hb_push) begin
                hb_last_pc  <= bfpc;
                hb_last_vld <= 1'b1;
                if (skip_low_q) begin
                    hb_hw[hb_tail] <= imem_rdata[31:16];
                    hb_pc[hb_tail] <= bfpc + XLEN'(2);
                    hb_tail        <= hb_tail + HB_AW'(1);
                    skip_low_q     <= 1'b0;
                end else begin
                    hb_hw[hb_tail]              <= imem_rdata[15:0];
                    hb_pc[hb_tail]              <= bfpc;
                    hb_hw[(hb_tail + HB_AW'(1))] <= imem_rdata[31:16];
                    hb_pc[(hb_tail + HB_AW'(1))] <= bfpc + XLEN'(2);
                    hb_tail                    <= hb_tail + HB_AW'(2);
                end
            end
            if (hb_pop) hb_head <= hb_head + align_consume[HB_AW-1:0];
            hb_count <= hb_count + hb_push_n - hb_pop_n;
        end
    end

    // -------------------------------------------------------------------------
    // Instruction page fault (rv_mmu if_fault) -- latched, precise (block fetch)
    // -------------------------------------------------------------------------
    // imem_gnt holds the FTQ head on the COMMITTED fetch address while its
    // translation is walked, so if_fault is for the committed (non-speculative)
    // address: imem_addr == the faulting VA.  LATCH the fault (capturing the 1-cycle
    // PTW_FAULT transient) and TAKE it when the aligner is STARVED (the buffer has
    // drained everything older = the fault is the next thing to retire) -> precise.
    //
    // BOTH the latch and the take are gated by ~redir_eff (exactly like the original
    // immediate-take design).  This is load-bearing: when ifpf_take fires it drives a
    // redirect to trap_vector (redir_eff=1) while the FAULTING fetch's if_fault is
    // still asserted for one more cycle; without the ~redir_eff latch gate that stale
    // if_fault would RE-LATCH a pending fault that is then taken again on the handler
    // fetch (a spurious double instruction-page-fault on the -- mapped -- trap
    // handler).  redir_eff is NOT set while the (committed) faulting target is held by
    // the FTQ after the registered redirect has applied (redir_pend_q has cleared),
    // so the real redirect-target / page-boundary fault is still latched normally.
    // An OLDER redirect (branch/trap/MRET/SRET/SATP in EX -- fetch_redir_ext) squashes
    // a pending fault outright (the speculative fetch was wrong-path).
    wire fetch_redir_ext = branch_taken_ex | trap_or_mret | satp_write_redir;
    logic            ifpf_pend;
    logic [XLEN-1:0] ifpf_pc_pend;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ifpf_pend    <= 1'b0;
            ifpf_pc_pend <= '0;
            ifpf_take    <= 1'b0;
            ifpf_pc      <= '0;
        end else begin
            ifpf_take <= 1'b0;                          // default: single-cycle pulse
            if (fetch_redir_ext) begin
                ifpf_pend <= 1'b0;                      // older redirect squashed the speculative fetch
            end else if (ifpf_pend && ~align_valid && ~if_id_valid && ~id_ex_valid
                         && ~ex_mem_valid
                         && (~redir_eff | (redir_pend_q & ~redir_req))) begin
                // faulting word is the next instruction to retire -> take now.
                // ~if_id_valid && ~id_ex_valid && ~ex_mem_valid (bug #17): with
                // the fetch_dead_q drain, older in-flight instructions retire
                // while the fault is pending; the take must wait until IF/ID,
                // ID/EX AND EX/MEM are bubbles.  ID/EX: the take's redirect
                // asserts flush_ex on a released (~stall_ex) cycle and would
                // otherwise KILL a live older instruction in EX.  EX/MEM: an
                // older MEM-stage access can raise ITS OWN page fault
                // (mem_trap_enter) on the very take cycle; the CSR trap mux
                // prefers ifpf_take, and flush_ex_mem would squash the older
                // access with its fault LOST (sret then returns to the ifpf PC,
                // never re-executing the load/store = silent data corruption).
                // All three are already bubbles in the pre-existing paths
                // (redirect-target fault: flushed; the freeze never let them
                // change) -> no-op there.
                // (redir_pend_q & ~redir_req) (bug #17): the fault of the CURRENT
                // redirect TARGET is takeable while the registered redirect is
                // still presenting that very target (redir_pend_q can never clear
                // for a dead fetch -- clearing needs imem_ready).  ~redir_req
                // keeps the original behavior for a LIVE redirect resolving this
                // cycle (its fault, if any, is wrong-path / stale).
                ifpf_take <= 1'b1;
                ifpf_pc   <= (hb_count != '0) ? h0pc : ifpf_pc_pend;
                ifpf_pend <= 1'b0;
            end else if (if_fault && ~ifpf_pend
                         && (~redir_eff | (redir_pend_q & ~redir_req))) begin
                ifpf_pend    <= 1'b1;                   // capture (incl. PTW_FAULT transient)
                // The faulting INSTRUCTION's VA, not just its word: a mid-word
                // redirect target (skip_low_q=1, target[1]==1) faults on its
                // word-aligned first fetch (imem_addr = target & ~3), but the
                // architectural faulting PC is the target = imem_addr + 2.  Saving
                // the bare imem_addr made the trap handler return 2 bytes early and
                // execute the low halfword -- e.g. a userspace ELF entry at
                // mod4==2 (musl 0x101be) demand-page-faulted, then re-entered at
                // 0x101bc = c.ebreak -> SIGTRAP -> init killed.  skip_low_q is
                // still pending here (the faulting word never pushed), so it marks
                // exactly the mid-word-target-fault case.
                ifpf_pc_pend <= imem_addr | (skip_low_q ? XLEN'(2) : XLEN'(0));
            end
        end
    end

    // fetch_dead_q driver (bug #17; see declaration above).  Set UNGATED on any
    // committed-fetch page fault (even while redir_eff blocks the ifpf latch --
    // releasing the freeze is what lets the redirect source retire so the latch
    // gate can open on the NEXT walk-fault iteration).  Cleared the moment the
    // fetch is alive again (imem_ready: a redirect moved fetch onto a mapped
    // page) or the fault trap is taken (ifpf_take redirects to the handler).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                      fetch_dead_q <= 1'b0;
        else if (imem_ready | ifpf_take) fetch_dead_q <= 1'b0;
        else if (if_fault)               fetch_dead_q <= 1'b1;
    end


    // =========================================================================
    // IF/ID Pipeline Register  (between IF and ID) -- fed by the aligner
    // =========================================================================
    logic [31:0]     if_id_inst;
    logic [XLEN-1:0] if_id_pc;
    // (if_id_valid / id_ex_valid are declared with the fetch_dead_q forward
    // declarations above: the ifpf take gate reads them before this point.)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_id) begin
            if_id_inst  <= 32'h0000_0013;   // NOP (ADDI x0, x0, 0)
            if_id_pc    <= '0;
            if_id_valid <= 1'b0;
        end else if (!stall_id) begin
            // Block fetch: the aligner emits one instruction (a bubble when starved).
            if_id_inst  <= align_valid ? align_inst : 32'h0000_0013;
            if_id_pc    <= align_valid ? h0pc       : '0;
            if_id_valid <= align_valid;
        end
        // else: stall — hold current value
    end

    // =========================================================================
    // Stage 2: Instruction Decode (ID)
    // =========================================================================
    // C-extension: expand a 16-bit compressed instruction into its 32-bit base
    // equivalent, then feed the expanded word to rv_decode so the rest of the
    // pipeline (decode/execute/forwarding) is reused unchanged.  An instruction is
    // compressed when if_id_inst[1:0] != 2'b11 (only the lower 16 bits are valid;
    // the upper 16 belong to the next instruction).
    ctrl_signals_t   id_ctrl;
    ctrl_signals_t   id_ctrl_raw;     // rv_decode output before is_compressed tag
    logic [XLEN-1:0] id_imm;
    reg_addr_t       id_rs1_addr, id_rs2_addr, id_rs3_addr, id_rd_addr;
    logic            id_rs1_used, id_rs2_used;
    logic [XLEN-1:0] id_rs1_data, id_rs2_data;

    wire             id_is_compressed = (if_id_inst[1:0] != 2'b11);
    logic [31:0]     id_cexpanded;     // 32-bit expansion of a compressed insn
    logic            id_cillegal;      // reserved compressed encoding
    logic            id_decode_illegal;// rv_decode: undecodable 32-bit encoding
    logic [31:0]     decode_inst;      // instruction actually fed to rv_decode

    rv_cdecode #(.XLEN(XLEN)) u_cdecode (
        .cinst         (if_id_inst[15:0]),
        .inst_out      (id_cexpanded),
        .is_compressed (/* unused: derived from if_id_inst[1:0] above */),
        .illegal       (id_cillegal)
    );

    assign decode_inst = id_is_compressed ? id_cexpanded : if_id_inst;

    rv_decode #(.XLEN(XLEN)) u_decode (
        .inst       (decode_inst),
        .ctrl       (id_ctrl_raw),
        .imm        (id_imm),
        .rs1_addr   (id_rs1_addr),
        .rs2_addr   (id_rs2_addr),
        .rs3_addr   (id_rs3_addr),
        .rd_addr    (id_rd_addr),
        .rs1_used   (id_rs1_used),
        .rs2_used   (id_rs2_used),
        .illegal    (id_decode_illegal)
    );

    // Tag the control bundle with the compressed flag (used for PC+2 link / mepc)
    // and the illegal-instruction flag.  For compressed insns the illegality comes
    // from rv_cdecode (rv_decode sees the expanded/NOP form); otherwise from rv_decode.
    always_comb begin
        id_ctrl               = id_ctrl_raw;
        id_ctrl.is_compressed = id_is_compressed;
        id_ctrl.is_illegal    = id_is_compressed ? id_cillegal : id_decode_illegal;
    end

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
    // F/D-Extension: FP Register File (32 x 64-bit, 3 read ports + 1 write port)
    // F-extension values are NaN-boxed (upper 32 bits = 0xFFFFFFFF).
    // =========================================================================
    logic [63:0]  id_frs1_data, id_frs2_data, id_frs3_data;
    logic [63:0]  wb_freg_data;   // FP WB write data (combinational; FP-load value)

    // --- Delayed FP-load writeback registers (fpld) ---
    // The FP-load value (wb_freg_data on its FRESH WB cycle) is registered here at
    // the core boundary so the long D$-data -> FP-datapath route is split across a
    // pipeline stage.  Everything downstream of a FP load (the fregfile write and
    // all FP forwarding) is fed from these registers one cycle later, NOT from the
    // live D$ read data.  fpld_we_q is a one-cycle pulse (the FP load has already
    // committed, so it is intentionally NOT gated by any flush).
    // The rv_fregfile instantiation lives further down, after the MEM/WB pipeline
    // signals it now reads (mem_wb_*) are declared.
    logic         fpld_we_q;      // a valid FP load retired last cycle
    reg_addr_t    fpld_rd_q;      // its destination f-register
    logic [63:0]  fpld_data_q;    // its loaded value (NaN-boxed / assembled)

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
    logic [31:0]     id_ex_inst;       // raw fetched word (for illegal-instruction mtval)
    // FP operands registered from fregfile (64-bit for F+D extensions)
    logic [63:0]     id_ex_frs1_data, id_ex_frs2_data, id_ex_frs3_data;

    // Forwarded EX operands (declared here so the ID/EX register can latch them
    // while an instruction is held in EX; driven by the forwarding muxes below).
    logic [XLEN-1:0] fwd_rs1_data, fwd_rs2_data;
    logic [63:0]     fwd_frs1_data, fwd_frs2_data, fwd_frs3_data;

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
            id_ex_inst      <= '0;
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
            // Use the expanded instruction so funct3 / CSR address are correct for
            // compressed instructions too (decode_inst == if_id_inst when not RVC).
            id_ex_funct3    <= decode_inst[14:12];
            id_ex_csr_addr  <= decode_inst[31:20];
            id_ex_inst      <= if_id_inst;   // raw word for illegal-instruction mtval
            id_ex_valid     <= if_id_valid;
            id_ex_frs1_data <= id_frs1_data;
            id_ex_frs2_data <= id_frs2_data;
            id_ex_frs3_data <= id_frs3_data;
        end else begin
            // stall_id=1 && !flush_ex — hold this instruction in EX, but REFRESH the
            // operand data with the currently-forwarded value.  A consumer frozen in
            // EX would otherwise lose a forwarding source that advances or bubbles
            // out from under it while it waits — e.g. MEM/WB bubbling on
            // dmem_wait/amo_stall/mal_stall (a store stalling the pipeline) drops the
            // address-producing instruction's result, so a dependent store reverts to
            // its stale ID/EX operand and writes the wrong address.  By latching the
            // resolved forward each stall cycle the operand stays correct once the
            // source leaves the forward network (it has already retired to the
            // regfile).  When no forward is active fwd_*_data == id_ex_*_data, so this
            // reduces to a plain hold (a no-op for the unstalled steady state, which
            // never takes this branch).  All other ID/EX fields are held.
            id_ex_rs1_data  <= fwd_rs1_data;
            id_ex_rs2_data  <= fwd_rs2_data;
            id_ex_frs1_data <= fwd_frs1_data;
            id_ex_frs2_data <= fwd_frs2_data;
            id_ex_frs3_data <= fwd_frs3_data;
        end
    end

    // =========================================================================
    // Stage 3: Execute (EX)
    // =========================================================================

    // --- EX/MEM and MEM/WB registers (forward-declared for forwarding unit) ---
    ctrl_signals_t   ex_mem_ctrl;
    logic [XLEN-1:0] ex_mem_alu_result;
    logic [XLEN-1:0] ex_mem_rs2_data;
    // Full 64-bit FP store data (FSD).  On RV64 the normal XLEN-wide ex_mem_rs2_data
    // already carries the whole double; on RV32 the 32-bit bus cannot, so FSD uses
    // this to write the low word in phase 0 and the high word in phase 1.
    logic [63:0]     ex_mem_fp_sdata;
    reg_addr_t       ex_mem_rd_addr;
    logic [XLEN-1:0] ex_mem_pc;    // PC of instruction in MEM stage (for fault mepc)
    logic [XLEN-1:0] ex_mem_pc4;
    logic [2:0]      ex_mem_funct3;
    // (ex_mem_valid is declared with the fetch_dead_q forward declarations above.)
    logic [XLEN-1:0] ex_mem_csr_fwd;     // forward-decl: used in ex_mem_fwd_data mux before definition
    logic [XLEN-1:0] ex_mem_fpu_result_i_fwd;  // forward-decl: FPU int result for EX/MEM forwarding

    ctrl_signals_t   mem_wb_ctrl;
    logic [XLEN-1:0] mem_wb_alu_result;
    reg_addr_t       mem_wb_rd_addr;
    logic [XLEN-1:0] mem_wb_pc4;
    logic            mem_wb_valid;
    // Forward-declared here (their MEM/WB-register section is further down) so the
    // branch operand mux (br_rs*_data, below) can read them: iverilog requires
    // declaration before use, unlike the wb_data forward references.
    logic [XLEN-1:0] mem_wb_csr_rdata;
    logic [XLEN-1:0] mem_wb_fpu_result_i;

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
        .fpld_valid     (fpld_we_q),
        .fpld_rd_addr   (fpld_rd_q),
        .fwd_rs1_sel    (fwd_rs1_sel),
        .fwd_rs2_sel    (fwd_rs2_sel),
        .fwd_frs1_sel   (fwd_frs1_sel),
        .fwd_frs2_sel   (fwd_frs2_sel),
        .fwd_frs3_sel   (fwd_frs3_sel)
    );

    // --- Forwarded operands ---
    // wb_data (MEM/WB result) is defined after the MEM/WB register below.
    // SV always_comb allows this forward reference since there is no circular path.
    // fwd_rs1_data, fwd_rs2_data forward-declared above (latched by ID/EX hold).

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

    // --- Conditional-branch comparison operands (registered-only forward) ---
    // 50 MHz step 10 (docs/freq_50mhz.md sec 22/23): a conditional branch's
    // taken/not-taken (branch_taken_ex) drives the redirect/flush that gates the
    // ID/EX clock-enable in the SAME cycle.  Feeding the comparison a value
    // forwarded combinationally from an in-flight load (the live D$-read shaped
    // data on the MEM/WB path, wb_data for WB_SRC_MEM) is the binding path:
    //   D$ BRAM -> load shape -> MEM/WB forward -> branch compare -> flush ->
    //   ID/EX CE.
    // The rv_hazard integer load->branch interlock guarantees a conditional
    // branch is NEVER in EX while a load it depends on is still in EX/MEM/WB: it
    // is stalled until the load retires and its value is captured into
    // id_ex_rs*_data via the regfile write bypass.  So the branch's MEM/WB
    // forward tier can never legitimately source the live load-shaped data;
    // substitute the REGISTERED mem_wb_alu_result for the WB_SRC_MEM (load) case
    // to physically remove that combinational D$ route from the comparison.  For
    // every functionally-reachable branch case br_rs*_data == fwd_rs*_data (the
    // EX/MEM tier ex_mem_fwd_data is already a pure register mux, and the MEM/WB
    // tier differs only for the load case, which a branch can never select).  The
    // ALU / store / JALR-target datapaths still use the live fwd_rs*_data, so this
    // is confined to the branch comparison.
    //
    // wb_data_brn is the MEM/WB forward value for the branch, REBUILT from the
    // registered writeback sources ONLY -- it must NOT reference `wb_data`, whose
    // WB_SRC_MEM arm is the combinational dmem_shifted: referencing wb_data lets
    // synthesis share that net and the live D$ route leaks back into the branch
    // comparison (observed in routed timing: dmem -> ... -> wb_data -> br_rs2_data
    // -> u_branch).  The WB_SRC_MEM (load) case maps to the default
    // (mem_wb_alu_result, a register) and is never selected for a branch (the
    // rv_hazard interlock guarantees it), so this is functionally identical while
    // physically removing every dmem path from the branch.
    logic [XLEN-1:0] wb_data_brn;
    always_comb begin
        case (mem_wb_ctrl.wb_src)
            WB_SRC_PC4: wb_data_brn = mem_wb_pc4;
            WB_SRC_CSR: wb_data_brn = mem_wb_csr_rdata;
            WB_SRC_FPU: wb_data_brn = mem_wb_fpu_result_i;
            default:    wb_data_brn = mem_wb_alu_result;  // WB_SRC_ALU + WB_SRC_MEM(never selected)
        endcase
    end

    logic [XLEN-1:0] br_rs1_data, br_rs2_data;
    always_comb begin
        unique case (fwd_rs1_sel)
            2'b01:   br_rs1_data = ex_mem_fwd_data;
            2'b10:   br_rs1_data = wb_data_brn;
            default: br_rs1_data = id_ex_rs1_data;
        endcase
    end
    always_comb begin
        unique case (fwd_rs2_sel)
            2'b01:   br_rs2_data = ex_mem_fwd_data;
            2'b10:   br_rs2_data = wb_data_brn;
            default: br_rs2_data = id_ex_rs2_data;
        endcase
    end

    // --- FP forwarded operands (64-bit for F+D extensions) ---
    // Forward-declare pipeline register signals so the mux below can reference them
    // before their full declaration in the EX/MEM and MEM/WB register sections.
    logic [63:0] ex_mem_fpu_result_f;
    logic [63:0] mem_wb_fpu_result_f;
    // fwd_frs1_data, fwd_frs2_data, fwd_frs3_data forward-declared above.

    // FP forward mux.  sel: 01=EX/MEM, 10=MEM/WB (FP compute results only -- FP
    // loads excluded by rv_forward), 11=delayed FP-load (fpld_data_q), 00=regfile.
    // The FP-load path no longer drives the MEM/WB case, so no live D$-read data
    // enters the FP forward network combinationally.
    always_comb begin
        unique case (fwd_frs1_sel)
            2'b01:   fwd_frs1_data = ex_mem_fpu_result_f;
            2'b10:   fwd_frs1_data = mem_wb_fpu_result_f;
            2'b11:   fwd_frs1_data = fpld_data_q;
            default: fwd_frs1_data = id_ex_frs1_data;
        endcase
    end

    always_comb begin
        unique case (fwd_frs2_sel)
            2'b01:   fwd_frs2_data = ex_mem_fpu_result_f;
            2'b10:   fwd_frs2_data = mem_wb_fpu_result_f;
            2'b11:   fwd_frs2_data = fpld_data_q;
            default: fwd_frs2_data = id_ex_frs2_data;
        endcase
    end

    always_comb begin
        unique case (fwd_frs3_sel)
            2'b01:   fwd_frs3_data = ex_mem_fpu_result_f;
            2'b10:   fwd_frs3_data = mem_wb_fpu_result_f;
            2'b11:   fwd_frs3_data = fpld_data_q;
            default: fwd_frs3_data = id_ex_frs3_data;
        endcase
    end

    // --- FP register file (instantiated here, after the MEM/WB signals its write
    // ports read are declared) ---
    // Port A (on-time): FP compute results only -- driven by mem_wb_fpu_result_f
    // (a register) so no D$-read data reaches the fregfile write/write-through.
    // Port B (delayed): the late FP-load writeback from the fpld registers.
    logic fp_wr_a_we;
    always_comb fp_wr_a_we = mem_wb_valid && mem_wb_ctrl.freg_write
                             && !mem_wb_ctrl.fp_load;

    rv_fregfile u_fregfile (
        .clk      (clk),
        .rst_n    (rst_n),
        .rs1_addr (id_rs1_addr),
        .rs2_addr (id_rs2_addr),
        .rs3_addr (id_rs3_addr),
        .rs1_data (id_frs1_data),
        .rs2_data (id_frs2_data),
        .rs3_data (id_frs3_data),
        // Port A: on-time FP compute results
        .rd_addr  (mem_wb_rd_addr),
        .rd_data  (mem_wb_fpu_result_f),
        .rd_we    (fp_wr_a_we),
        // Port B: delayed FP-load writeback
        .rd2_addr (fpld_rd_q),
        .rd2_data (fpld_data_q),
        .rd2_we   (fpld_we_q)
    );

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
    // M-Extension: Multiply (combinational) / Divide (multi-cycle) unit
    // =========================================================================
    logic [XLEN-1:0] muldiv_result;

    // Both MULTIPLY and DIVIDE now stall (50MHz step 6: the single-cycle DSP
    // multiply was the critical path, so MUL/MULH/MULW are pipelined behind input
    // + output registers and run through the same busy handshake as the divider).
    // Mirrors the FPU FDIV protocol:
    //   muldiv_valid_in : an M-ext op entering EX that may start (gated by busy/was).
    //   muldiv_start_stall : holds IF/ID for the start cycle (busy is still low,
    //     it goes high on the next edge) so the op is not lost from ID/EX.
    // rv_muldiv routes valid_in to the divider FSM or the multiply counter by op.
    assign muldiv_valid_in    = id_ex_valid
                                && id_ex_ctrl.is_muldiv
                                && !muldiv_busy_int
                                && !muldiv_was_busy
                                && !muldiv_done;
    assign muldiv_start_stall = muldiv_valid_in;

    rv_muldiv #(.XLEN(XLEN)) u_muldiv (
        .clk      (clk),
        .rst_n    (rst_n),
        .rs1_data (fwd_rs1_data),
        .rs2_data (fwd_rs2_data),
        .op       (id_ex_ctrl.muldiv_op),
        .valid_in (muldiv_valid_in),
        .result   (muldiv_result),
        .div_busy (muldiv_busy_int)
    );

    // EX-stage result: muldiv overrides ALU for M-extension instructions
    logic [XLEN-1:0] ex_result;
    assign ex_result = id_ex_ctrl.is_muldiv ? muldiv_result : ex_alu_result;

    // =========================================================================
    // F-Extension: FPU instantiation (EX stage)
    // =========================================================================
    // fpu_busy_int declared earlier (before stall assigns)
    logic        fpu_result_valid;
    logic [63:0] fpu_result_f;       // FP result (64-bit: NaN-boxed SP or DP)
    logic [XLEN-1:0] fpu_result_i;
    logic [4:0]  fpu_fflags_ex;
    logic [2:0]  frm_csr;

    assign fpu_valid_in = id_ex_valid
                          && id_ex_ctrl.is_fp
                          && !id_ex_ctrl.fp_load
                          && !id_ex_ctrl.fp_store
                          && !fpu_busy_int
                          && !fpu_was_busy
                          && !fpu_done;

    // Every FP compute op is now multi-cycle (C-2c: FDIV/FSQRT plus the newly
    // pipelined combinational ops all assert fpu_busy), so the start-cycle stall
    // that holds the op in ID/EX (busy is still low this cycle, rising on the
    // next edge) applies to all of them -- no longer just FDIV/FSQRT.
    assign fpu_start_stall = fpu_valid_in;

    rv_fpu #(.XLEN(XLEN)) u_fpu (
        .clk         (clk),
        .rst_n       (rst_n),
        .fa          (fwd_frs1_data),
        .fb          (fwd_frs2_data),
        .fc          (fwd_frs3_data),
        .int_a       (fwd_rs1_data),
        .fpu_op      (id_ex_ctrl.fpu_op),
        .fp_double   (id_ex_ctrl.fp_double),
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

    // LR/SC reservation kill: any COMMITTED trap entry or xRET voids the
    // reservation (priv spec: xRET voids an outstanding reservation; an SC is
    // always allowed to fail).  Without this, an interrupt taken between LR
    // and SC whose handler performs an AMO to the SAME address let the resumed
    // SC succeed with the PRE-trap loaded value, silently losing the handler's
    // update (Linux: atomic_fetch_add in IRQ context vs a try_cmpxchg loop in
    // task context -> refcount saturate/underflow WARNs, 2026-06-10).
    // Repro/regression: src/software/boot/lrsc_irq_test.S.
    // Mirrors the commit-gated trap/mret/sret events rv_csr receives (assigned
    // below, after csr_commit_ex), so it fires exactly once per event and is a
    // strict no-op while no trap/xRET commits.
    logic lrsc_kill;

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
            // AMO 2-phase: advance read(0) -> write(1) ONCE when the read access
            // completes, and HOLD the write phase until the AMO actually leaves
            // the MEM stage (amo_active drops).  Previously amo_state toggled back
            // to 0 on the next !dmem_wait, so if the AMO was held in MEM by an
            // UNRELATED stall (e.g. ~imem_ready during an in-flight instruction
            // fetch under AXI/DDR), it re-entered the read phase and the whole AMO
            // executed twice (e.g. OpenSBI's lottery amoadd ran 0->1->2, so the
            // single hart lost the boot-hart lottery).  Re-issuing the WRITE while
            // held is harmless (idempotent: same address, same computed value);
            // re-issuing the READ was the bug.
            // !mem_stall: while the AMO's data translation is pending (TLB miss
            // -> PTW), the MMU suppresses mem_req_out, so NO read is issued and
            // dmem_wait stays 0 -- without this term amo_state advanced to the
            // WRITE phase having never read, and the write was computed from
            // the STALE previous load's dmem_rdata (Linux: get_user_ns/get_net
            // refcount inc on a kernel VA that TLB-missed wrote (0xFFFFFFFF+1)
            // = 0 over the counter -> refcount saturate/underflow WARNs).
            // Bare/M-mode: vm_data=0 -> mem_stall=0 -> strict no-op.
            if (!amo_active)
                amo_state <= 1'b0;                    // reset only when AMO leaves MEM
            else if (!dmem_wait && !mem_stall && !amo_state)
                amo_state <= 1'b1;                    // read complete -> write phase

            // Reservation update (in MEM stage), exactly when the LR/SC ADVANCES
            // out of MEM (same gate as the MEM/WB capture below).  Gating on
            // !dmem_wait alone re-fired the update on every cycle an LR/SC was
            // HELD in MEM by a non-data stall (~imem_ready during an I$ miss):
            // an SC whose write had already completed cleared the reservation
            // while still held, so the MEM/WB capture later recomputed
            // sc_success=0 -- the SC WROTE MEMORY but REPORTED FAILURE (rd=1).
            // Linux's cmpxchg loops then saw perpetual "failure", walking the
            // printk ringbuffer head through the whole ring (silent console) --
            // same stall-refire family as the EX-stage CSR-commit bug (#4).
            // Repro: src/software/boot/atomic_test.S with BOOT_NO_ICACHE=1.
            // No-op for bare BRAM (imem_ready=1 every cycle; amo_stall excludes
            // LR/SC by construction; aligned LR/SC never raise mal_stall).
            if (lrsc_kill) begin
                // Trap entry / xRET commit voids the reservation (see decl).
                // Takes priority over an LR advancing on the same edge: the
                // paired SC then fails and the constrained loop retries.
                reservation_valid <= 1'b0;
            end else if (!amo_stall && !mal_stall && !dmem_wait && !mem_stall
                         && (imem_ready | fetch_dead_q)) begin
                // (| fetch_dead_q, bug #17): same advance condition as the MEM/WB
                // capture -- an LR/SC draining past a dead fetch must update the
                // reservation exactly once on its advance cycle.
                // !mem_stall: same translation-pending hole as amo_state above
                // (the LR/SC has not actually accessed memory yet).
                if (ex_mem_ctrl.is_lr && ex_mem_valid) begin
                    reservation_valid <= 1'b1;
                    reservation_addr  <= ex_mem_alu_result;
                end else if (ex_mem_ctrl.is_sc && ex_mem_valid) begin
                    reservation_valid <= 1'b0;   // SC always clears reservation
                end
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

    // mal_phase1_start: first cycle of phase 1 (mal_state just went 0->1).  On
    // this cycle dmem_rdata holds the PHASE-0 (first word) read result -- for a
    // 1-cycle memory it is valid the cycle after the phase-0 issue (== now), and
    // for the AXI bridge rdata_q holds it until the phase-1 read completes.  The
    // phase-0 result is captured here, OUTSIDE the dmem_wait guard, so the AXI
    // case (dmem_wait high during the in-flight phase-1 read) still latches it.
    // NO-OP timing-equivalent for a 1-cycle memory (phase 1 is a single cycle).
    logic mal_state_prev;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) mal_state_prev <= 1'b0;
        else        mal_state_prev <= mal_state;
    end
    wire mal_phase1_start = mal_state && !mal_state_prev;

    // -------------------------------------------------------------------------
    // Per-access STROBE to the data cache / MMU (dmem_acc_new)
    // -------------------------------------------------------------------------
    // The D$ / MMU need to register their (slow) hit/translate result, but the
    // simple bus has no per-access strobe: c_req is level-high, so a downstream
    // FSM cannot tell a NEW access from a completed one HELD in MEM by an
    // unrelated stall (~imem_ready etc.).  A naive in-place 2-phase oscillated
    // c_wait every cycle on a held hit and corrupted atomics (see docs/freq_50mhz.md).
    // The core, which owns the pipeline, marks the FIRST cycle of each distinct
    // logical access UNAMBIGUOUSLY, derived only from REGISTERS (no combinational
    // path from c_wait back in -> no loop):
    //   - a new instruction's first MEM cycle  = ex_adv_q (last cycle EX advanced)
    //   - AMO read->write phase start          = amo_state rising edge
    //   - misaligned phase0->phase1 start       = mal_phase1_start
    // A held access never re-pulses (ex_adv_q drops after the entry cycle), so the
    // downstream FSM only (re)starts a lookup on this strobe.  STRICT no-op for
    // bram/act wrappers (no D$/MMU consumer).
    logic amo_state_prev;
    logic ex_adv_q;     // 1 = EX advanced into MEM last cycle (new instr now in MEM)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            amo_state_prev <= 1'b0;
            ex_adv_q       <= 1'b0;
        end else begin
            amo_state_prev <= amo_state;
            ex_adv_q       <= ~stall_ex;
        end
    end
    wire amo_started  = amo_state & ~amo_state_prev;
    assign dmem_acc_new = (ex_adv_q & dmem_req) | amo_started | mal_phase1_start;

    // mal_squash: the misaligned 2-phase access is ABANDONED (FSM reset) only when
    // the MEM-stage instruction ITSELF is squashed by its own MEM-stage fault.
    // It must NOT reset on a generic flush_ex_mem (bug #16): flush_ex_mem bubbles
    // the EX->MEM transition to squash a trap/MRET/SRET taken on the YOUNGER
    // instruction in EX (or an IF page fault) -- but the OLDER misaligned access
    // sitting in MEM is legitimately RETIRING that cycle and must keep its
    // mal_first_data (captured at mal_phase1_start) intact.  The old code zeroed
    // mal_first_data there, dropping the phase-0 word of a misaligned LOAD that a
    // timer interrupt landed on under a D$ miss (loaded value lost its low half).
    // mem_trap_enter is the load/store's OWN fault, so resetting then is correct
    // (identical to the old behavior for that case).  ~stall_ex matches the commit
    // timing of flush_ex_mem; flush_ex_mem can only fire at the phase-1 retire
    // cycle (stall_ex=0 implies dmem_wait=0), never mid-access.  STRICT no-op when
    // there is no MEM fault: the else-branch already drops mal_state to idle on the
    // retire cycle and captures mal_first_data, so the only behavioral change is
    // preserving (not zeroing) the phase-0 word across a younger-instruction trap.
    wire mal_squash = mem_trap_enter & ~stall_ex;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || mal_squash) begin
            mal_state      <= 1'b0;
            mal_first_data <= '0;
        end else begin
            // State advances only when the current phase's data access has
            // completed (held by dmem_wait under variable latency; no-op when 0).
            // NOTE: unlike amo_state (which is gated by is_amo in the dmem driver),
            // mal_state is consumed by ALL loads/stores, so it must drop the cycle
            // the access advances -- it cannot be held high into the next
            // instruction's MEM cycle (that mis-addresses the next access).
            // !mem_stall: while the data translation is pending no access has
            // been issued (same hole as amo_state; no-op when vm off).
            if (!dmem_wait && !mem_stall) begin
                if (mal_cross && !mal_state)
                    mal_state <= 1'b1;   // phase 0 -> phase 1
                else if (mal_state && stall_ex)
                    mal_state <= 1'b1;   // HOLD phase 1: the misaligned access has
                                         // finished both word accesses but the
                                         // instruction cannot RETIRE this cycle
                                         // because EX is held by an unrelated stall
                                         // (notably ~imem_ready from an in-flight I$
                                         // fill / straddle-bypass).  Resetting to 0
                                         // here would re-assert mal_stall next cycle
                                         // and RESTART phase 0 -> livelock (the same
                                         // restart class as muldiv_done bug #14).
                                         // mal_stall=0 in phase 1, so stall_ex here
                                         // reflects only the unrelated blocker; once
                                         // it clears the instruction retires and the
                                         // else-branch drops mal_state to idle.
                                         // Strict no-op when imem_ready=1 at retire
                                         // (every BRAM run): stall_ex=0 -> else.
                else
                    mal_state <= 1'b0;   // phase 1 -> idle (instruction retires)
            end
            // Capture the phase-0 word at the first cycle of phase 1 (ungated).
            if (mal_phase1_start && ex_mem_ctrl.mem_read)
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
    // RV32 has a 4-byte data bus, so addr[2] never selects an upper half there and
    // amo_shift must stay 0 (a 32-bit shift on a 32-bit value would zero the data).
    logic [5:0]        amo_shift;   // bit shift: 32 when .W and addr[2]=1 (RV64), else 0
    logic [XLEN-1:0]   amo_old_data;
    logic [XLEN-1:0]   amo_new_data;
    logic [XLEN-1:0]   amo_wdata;
    logic [XLEN/8-1:0] amo_wstrb;

    assign amo_shift    = ((XLEN == 64) && !ex_mem_funct3[0] && ex_mem_alu_result[2]) ? 6'd32 : 6'd0;
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
    logic            csr_access_ok;  // EX CSR address implemented + privilege OK
    priv_level_t     priv_level;
    logic            irq_pending;
    logic [XLEN-1:0] irq_cause;       // highest-priority interrupt cause (from rv_csr)
    logic [XLEN-1:0] satp_val_int;
    logic            mstatus_sum_int;
    logic            mstatus_mxr_int;
    logic            mstatus_mprv_int;
    logic [1:0]      mstatus_mpp_int;

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
            if (id_ex_ctrl.is_illegal
                || (id_ex_ctrl.csr_write && !csr_access_ok)) begin
                // Illegal-instruction exception (synchronous; highest priority here).
                // mtval = the faulting instruction (16-bit zero-extended if compressed).
                // The CSR term fires for accesses to unimplemented CSRs or CSRs
                // above the current privilege (csr_access_ok from rv_csr) --
                // required so OpenSBI's trap-and-detect feature probing
                // (stimecmp/menvcfg/mhpm*) correctly concludes "absent".
                ex_trap_enter = 1'b1;
                ex_trap_cause = xlen_t'(EXC_ILLEGAL_INST);
                ex_trap_val   = id_ex_ctrl.is_compressed ? xlen_t'(id_ex_inst[15:0])
                                                         : xlen_t'(id_ex_inst);
            end else if (id_ex_ctrl.is_ecall) begin
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

    // -------------------------------------------------------------------------
    // MEM stage page fault detection
    // -------------------------------------------------------------------------
    // Fires when a valid load/store in MEM has a TLB-hit permission failure.
    // Under VM, rv_mmu now presents mem_fault from its REGISTERED MEM-port lookup,
    // i.e. ONE cycle after the access enters MEM (the capture bubble); the trap
    // redirect is therefore gated by ~stall_ex (see redir_req) so the priv change
    // and redirect stay atomic despite that +1-cycle latency (docs/freq_50mhz.md #3).
    logic [XLEN-1:0] mem_trap_cause;
    logic [XLEN-1:0] mem_trap_val;

    always_comb begin
        mem_trap_enter = ex_mem_valid
                         && (ex_mem_ctrl.mem_read || ex_mem_ctrl.mem_write)
                         && mem_fault;
        mem_trap_cause = ex_mem_ctrl.mem_read ? xlen_t'(EXC_LOAD_PAGE_FAULT)
                                              : xlen_t'(EXC_STORE_PAGE_FAULT);
        mem_trap_val   = ex_mem_alu_result;  // faulting virtual address
    end

    // Combined trap signals: MEM fault takes priority over EX exceptions
    // (they're mutually exclusive in practice since EX traps flush before MEM)
    logic            csr_trap_enter;
    logic [XLEN-1:0] csr_trap_cause;
    logic [XLEN-1:0] csr_trap_val;
    logic [XLEN-1:0] csr_trap_epc;

    always_comb begin
        if (ifpf_take) begin
            // Instruction page fault (taken at IF; highest priority since the
            // pipeline is otherwise idle/flushed when it fires).
            csr_trap_enter = 1'b1;
            csr_trap_cause = xlen_t'(EXC_INST_PAGE_FAULT);
            csr_trap_val   = ifpf_pc;
            csr_trap_epc   = ifpf_pc;
        end else if (mem_trap_enter) begin
            csr_trap_enter = 1'b1;
            csr_trap_cause = mem_trap_cause;
            csr_trap_val   = mem_trap_val;
            csr_trap_epc   = ex_mem_pc;
        end else begin
            csr_trap_enter = ex_trap_enter;
            csr_trap_cause = ex_trap_cause;
            csr_trap_val   = ex_trap_val;
            csr_trap_epc   = id_ex_pc;
        end
    end

    // CSR state-update gate.  Under a multi-cycle IF fetch the EX/MEM/WB stages
    // are frozen (full pipeline freeze, ~imem_ready), so the combinational
    // trap/MRET/SRET/CSR-write/retire signals would stay asserted for several
    // cycles and update CSR state repeatedly (mstatus push/pop, mepc, minstret).
    // Gate the *state-changing* CSR inputs by imem_ready so each fires exactly
    // once -- on the advancing (commit) cycle.  NO-OP when imem_ready=1 every
    // cycle (all BRAM/unified-mem paths -> identical to before).  The redirect
    // itself is handled separately (latched, see IF stage), and fflags writes
    // are left ungated (multi-cycle FP's result_valid pulse need not coincide
    // with imem_ready, and fflags accumulation is idempotent).
    // | fetch_dead_q (bug #17): while the committed fetch is dead the pipeline
    // drains (advance semantics identical to imem_ready=1 with a starved aligner),
    // so WB-stage events (retire count) must fire for the draining instructions.
    // Each instruction spends exactly one cycle in WB during the drain (MEM/WB
    // advances every cycle), so nothing double-counts.  No-op when fetch_dead_q=0.
    wire csr_commit = imem_ready | fetch_dead_q;
    // EX-stage commit gate for state changes attributed to the instruction in EX
    // (CSR write, trap entry, MRET/SRET).  These must fire EXACTLY ONCE -- on the
    // cycle the EX instruction actually advances out of EX (~stall_ex) -- NOT merely
    // when imem_ready=1.  imem_ready alone is insufficient: when EX is held by a
    // non-IF stall (dmem_wait from a write-through store, amo/mal/mem_stall, FPU
    // busy) while imem_ready stays 1, the EX CSR write would re-fire every held
    // cycle.  For a CSR swap idiom this is catastrophic: a stalled
    // "csrrw tp, mscratch, tp" (OpenSBI/Linux trap entry/exit) re-executes while
    // held behind the preceding store, overwriting mscratch with its own (already
    // swapped) tp on the 2nd+ cycle, so the kernel's tp is lost and never restored
    // on trap return -> the early-boot exception storm.  ~stall_ex implies
    // imem_ready (see flush_ex), so this is a strict refinement / no-op for the
    // common BRAM case (stall_ex=0).  retire_en stays on csr_commit (it is a WB-
    // stage event; MEM/WB bubbles under amo/mal/dmem_wait and holds only under an IF
    // freeze, which imem_ready already gates -- so it never double-counts).
    wire csr_commit_ex = ~stall_ex;

    // LR/SC reservation kill (declared in the A-extension section above):
    // exactly the commit-gated trap-entry/MRET/SRET events rv_csr receives.
    // ifpf_take bypasses the gate like the rv_csr trap_enter input does (the
    // faulting fetch keeps imem_ready low, so stall_ex stays high).
    assign lrsc_kill = ((csr_trap_enter | ex_mret_en | ex_sret_en) & csr_commit_ex)
                     | ifpf_take;

    // -------------------------------------------------------------------------
    // SATP-write fetch barrier (assigned here: needs id_ex_* and csr_commit)
    // -------------------------------------------------------------------------
    // Writing satp changes the active address space, but instructions already
    // prefetched (under the OLD translation) sit in the pipeline and would run
    // before the new mapping takes effect.  Real hardware (and the RISC-V boot
    // sequence) require the next fetch to use the new satp: Linux's
    // relocate_enable_mmu deliberately faults the first post-satp fetch to vector
    // (via stvec) into the freshly-mapped virtual address space.  Force that by
    // redirecting to the instruction right after the satp write the cycle it
    // commits, flushing the stale prefetch and re-fetching under the new satp
    // (redirect_settle then lets the change settle before the PC advances).
    assign satp_write_redir = id_ex_valid && id_ex_ctrl.csr_write
                              && (id_ex_csr_addr == CSR_SATP) && csr_commit && ~stall_ex;
    assign satp_redir_tgt   = id_ex_pc + (id_ex_ctrl.is_compressed ? XLEN'(2) : XLEN'(4));

    rv_csr #(
        .XLEN   (XLEN),
        .HARTID (0)
    ) u_csr (
        .clk        (clk),
        .rst_n      (rst_n),
        .csr_addr   (id_ex_csr_addr),
        .csr_wdata  (ex_csr_wdata),
        .csr_op     (id_ex_funct3),
        .csr_we     (id_ex_ctrl.csr_write & id_ex_valid & csr_commit_ex & csr_access_ok),
        .csr_rdata  (csr_rdata_ex),
        .csr_access_ok (csr_access_ok),
        // ifpf_take is a clean one-cycle pulse that must commit even though the
        // faulting fetch keeps imem_ready (and thus csr_commit_ex) low.
        .trap_enter ((csr_trap_enter & csr_commit_ex) | ifpf_take),
        .trap_cause (csr_trap_cause),
        .trap_val   (csr_trap_val),
        .trap_epc   (csr_trap_epc),
        .mret_en    (ex_mret_en & csr_commit_ex),
        .sret_en    (ex_sret_en & csr_commit_ex),
        .trap_vector(trap_vector),
        .mepc_out   (mepc_out),
        .sepc_out   (sepc_out),
        .priv_level (priv_level),
        .irq_pending(irq_pending),
        .irq_cause  (irq_cause),
        .retire_en  (mem_wb_valid & csr_commit),
        .timer_val  (time_val),
        .timer_irq  (timer_irq),
        .sw_irq     (sw_irq),
        .ext_irq    (ext_irq),
        .satp_val        (satp_val_int),
        .mstatus_sum     (mstatus_sum_int),
        .mstatus_mxr     (mstatus_mxr_int),
        .mstatus_mprv    (mstatus_mprv_int),
        .mstatus_mpp_out (mstatus_mpp_int),
        // F-extension
        .fpu_fflags    (fpu_fflags_ex),
        .fpu_fflags_we (fpu_result_valid),
        .frm_out       (frm_csr)
    );

    // --- MMU state outputs ---
    assign satp_out         = satp_val_int;
    assign priv_out         = priv_level;
    assign mstatus_sum_out  = mstatus_sum_int;
    assign mstatus_mxr_out  = mstatus_mxr_int;
    assign mstatus_mprv_out = mstatus_mprv_int;
    assign mstatus_mpp_out  = mstatus_mpp_int;

    // SFENCE.VMA in EX stage → TLB flush pulse (1-cycle).  Gated by csr_commit_ex
    // (~stall_ex) so a frozen SFENCE flushes exactly once on the advance cycle, not
    // every held cycle (no-op when stall_ex=0; the flush is idempotent regardless).
    assign tlb_flush_out   = id_ex_valid && id_ex_ctrl.is_sfence_vma && csr_commit_ex;

    // FENCE.I in EX stage → instruction-cache flush pulse (1-cycle).  Gated by
    // csr_commit_ex like the TLB flush so it fires exactly once on the EX advance.
    assign fence_i_out     = id_ex_valid && id_ex_ctrl.is_fence_i && csr_commit_ex;

    // --- Branch / Jump resolution ---
    // Forwarded rs1/rs2 are used for branch comparisons.
    // For JALR the branch target comes from ex_alu_result (rs1 + imm with forwarding).
    rv_branch #(.XLEN(XLEN)) u_branch (
        .ctrl          (id_ex_ctrl),
        .funct3        (id_ex_funct3),
        // Branch comparison reads REGISTERED-only forwarded operands (see
        // br_rs*_data above): removes the combinational D$-load route from the
        // branch_taken -> flush path (50 MHz binding).  The JALR target still
        // uses the live alu_result (computed from fwd_rs*_data) -- unaffected.
        .rs1_data      (br_rs1_data),
        .rs2_data      (br_rs2_data),
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
    // ex_mem_fpu_result_f declared earlier (forward-decl for FP forwarding mux, 64-bit)
    // ex_mem_fpu_result_i_fwd declared earlier (forward-decl for ex_mem_fwd_data mux)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || flush_ex_mem) begin
            ex_mem_ctrl              <= '0;
            ex_mem_alu_result        <= '0;
            ex_mem_rs2_data          <= '0;
            ex_mem_fp_sdata          <= '0;
            ex_mem_rd_addr           <= '0;
            ex_mem_pc                <= '0;
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
            // FSD: full 64-bit value; FSW: replicate lower 32-bit to fill bus
            ex_mem_rs2_data   <= (id_ex_ctrl.fp_store && id_ex_ctrl.fp_double)
                                 ? fwd_frs2_data[XLEN-1:0]
                                 : id_ex_ctrl.fp_store
                                   ? {(XLEN/32){fwd_frs2_data[31:0]}}
                                   : fwd_rs2_data;
            // Full 64-bit FSD store data (used by the RV32 two-word store path)
            ex_mem_fp_sdata   <= fwd_frs2_data;
            ex_mem_rd_addr    <= id_ex_rd_addr;
            ex_mem_pc         <= id_ex_pc;
            // Link / return address: PC+2 for compressed (C.JAL/C.JALR), else PC+4.
            ex_mem_pc4        <= id_ex_pc + (id_ex_ctrl.is_compressed ? XLEN'(2) : XLEN'(4));
            ex_mem_funct3     <= id_ex_funct3;
            ex_mem_csr_fwd    <= csr_rdata_ex;
            // Insert a bubble on the start cycle of a multi-cycle op (any FP
            // compute op now -- C-2c -- or an integer divide): stall_ex is still 0
            // here (busy goes high next edge) and the result is not yet ready, so
            // EX/MEM must not capture a valid instruction.  The op is held in ID/EX
            // by *_start_stall and is captured for real on the cycle busy drops.
            ex_mem_valid      <= id_ex_valid && !fpu_start_stall
                                 && !muldiv_start_stall;
            // Only capture FPU result for actual compute ops (not FLW/FLD/FSW/FSD).
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
                    if ((XLEN == 32) && ex_mem_ctrl.fp_store && ex_mem_ctrl.fp_double) begin
                        // RV32 FSD: write the low 32-bit word of the double
                        dmem_wstrb = {(XLEN/8){1'b1}};
                        dmem_wdata = ex_mem_fp_sdata[XLEN-1:0];
                    end else begin
                        dmem_wstrb = mal_wstrb_wide[XLEN/8-1:0];
                        dmem_wdata = ex_mem_rs2_data << mal_shl;
                    end
                end
            end else begin
                // Phase 1: second aligned word
                dmem_addr = (ex_mem_alu_result & WORD_MASK) + (XLEN)'(XLEN/8);
                if (ex_mem_ctrl.mem_write) begin
                    if ((XLEN == 32) && ex_mem_ctrl.fp_store && ex_mem_ctrl.fp_double) begin
                        // RV32 FSD: write the high 32-bit word of the double
                        dmem_wstrb = {(XLEN/8){1'b1}};
                        dmem_wdata = ex_mem_fp_sdata[63:32];
                    end else begin
                        dmem_wstrb = {(XLEN/8)'(0), mal_wstrb_wide[2*(XLEN/8)-1:XLEN/8]};
                        dmem_wdata = ex_mem_rs2_data >> mal_shr;
                    end
                end
            end
        end
    end

    // =========================================================================
    // MEM/WB Pipeline Register  (between MEM and WB)
    // =========================================================================
    // mem_wb_csr_rdata declared earlier (forward-decl for the branch operand mux)
    logic [2:0]      mem_wb_funct3;
    logic [BYTE_LANE_W-1:0] mem_wb_byte_offset;  // addr[BYTE_LANE_W-1:0] — byte lane selector for sub-word loads
    // mem_wb_fpu_result_f declared earlier (forward-decl for FP forwarding mux, 64-bit)
    // mem_wb_fpu_result_i declared earlier (forward-decl for the branch operand mux)
    // mem_wb_fresh: 1 only on the cycle MEM/WB just advanced (the WB instruction's
    // FIRST cycle in WB).  A load's dmem_rdata is valid on this cycle; on later
    // (held) cycles the live dmem_rdata reflects a YOUNGER load re-issuing from MEM
    // during an IF freeze, so the WB load must use a latched copy (dmem_rdata_held).
    logic            mem_wb_fresh;
    logic [XLEN-1:0] dmem_rdata_held;

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
            mem_wb_fresh          <= 1'b0;
        end else if (amo_stall || mal_stall || dmem_wait || mem_stall) begin
            // AMO read phase / misaligned (incl. RV32 64-bit FLD/FSD) phase 0 /
            // data access in flight (dmem_wait) / data translation pending
            // (mem_stall: the access has not even been issued -- capturing here
            // would retire the instruction with stale dmem_rdata and re-capture
            // it again when the translation completes = double retire/garbage
            // rd write; no-op when vm off): insert a BUBBLE rather than
            // holding the previous WB instruction.  Holding would re-write the
            // just-retired instruction's destination a second time using the now-
            // stale live dmem_rdata, corrupting it — and double-count retire.  The
            // in-progress AMO/mal/data instruction is still held in EX/MEM and is
            // captured normally when the stall drops (phase 1 / write / data-ready).
            mem_wb_ctrl   <= '0;
            mem_wb_valid  <= 1'b0;
            mal_active_wb <= 1'b0;
            mem_wb_fresh  <= 1'b0;
        end else if (imem_ready | fetch_dead_q) begin
            // Normal advance.  This instruction is FRESH in WB next cycle.
            // fetch_dead_q (bug #17): the committed fetch has page-faulted and will
            // never raise imem_ready; the pipeline drains instead of freezing, so
            // MEM/WB must advance (capturing the draining instructions, then
            // bubbles) exactly as in the imem_ready=1 flow.
            mem_wb_fresh          <= 1'b1;
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
        end else begin
            // (~imem_ready, IF fetch in flight): HOLD MEM/WB.  The full pipeline
            // freezes during a multi-cycle IF fetch, so MEM/WB must hold (not bubble)
            // to preserve the MEM/WB forwarding source for a consumer in EX.  retire
            // is gated by imem_ready (rv_csr), so holding does not double-count.
            // No longer FRESH: a held load must use dmem_rdata_held (see below), as
            // the live dmem_rdata now belongs to a younger load re-issuing from MEM.
            // NO-OP for a 1-cycle IF (imem_ready=1: this branch is never taken).
            mem_wb_fresh <= 1'b0;
        end
    end

    // Latch the load result on its FRESH WB cycle so a load HELD in MEM/WB across an
    // IF freeze writes back / forwards its OWN data, not the live dmem_rdata of a
    // younger load re-issuing from the (frozen) MEM stage.  NO-OP when imem_ready=1
    // every cycle (every WB instruction is fresh for its single WB cycle).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)            dmem_rdata_held <= '0;
        else if (mem_wb_fresh) dmem_rdata_held <= dmem_rdata;
    end
    // Effective load data for WB: live on the fresh cycle, latched while held.
    wire [XLEN-1:0] dmem_eff = mem_wb_fresh ? dmem_rdata : dmem_rdata_held;

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
                        | ({(XLEN)'(0), dmem_eff}       << wb_shl);
    assign mal_combined = mal_wide[XLEN-1:0];

    // dmem_shifted: for normal (non-crossing) loads, shift by byte offset.
    // For misaligned crossing loads, use pre-combined data (already positioned).
    logic [XLEN-1:0] dmem_shifted;
    always_comb begin
        if (mal_active_wb)
            dmem_shifted = mal_combined;
        else
            // Shift by byte_offset*8: RV32 max shift=24, RV64 max shift=56
            dmem_shifted = dmem_eff >> ({3'b0, mem_wb_byte_offset} << 3);
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
    // FLW: NaN-box the 32-bit loaded value (upper 32 bits = 0xFFFFFFFF)
    // FLD: write full 64-bit loaded value
    // FPU: write fpu_result_f (64-bit; already NaN-boxed for SP by rv_fpu.sv)
    //
    // wb_freg_data is the FP-load value here (the only place D$-read data enters
    // the FP datapath).  FP compute results are written via fregfile port A
    // directly from mem_wb_fpu_result_f; FP loads are written via port B from the
    // registered fpld_* (captured below) one cycle later.  Keeping the dmem-fed
    // value confined to wb_freg_data -> fpld_data_q (a register) splits the long
    // D$-data -> FP route at the core boundary.
    always_comb begin
        if (mem_wb_ctrl.fp_load) begin
            if (mem_wb_ctrl.fp_double)
                // FLD: 64-bit.  RV64 gets the whole double in one access (dmem_shifted).
                // RV32 (and any boundary-crossing case) assembles it from the two
                // word reads combined in mal_wide[63:0] (phase-0 low | phase-1 high).
                wb_freg_data = mal_active_wb ? mal_wide[63:0] : dmem_shifted[63:0];
            else
                wb_freg_data = {32'hFFFFFFFF, dmem_shifted[31:0]};  // FLW: NaN-boxed
        end else begin
            wb_freg_data = mem_wb_fpu_result_f;
        end
    end

    // ---- Delayed FP-load writeback capture (fpld) ----
    // Capture the FP-load value on its single FRESH WB cycle (when wb_freg_data is
    // valid).  fpld_we_q is a one-cycle pulse driving fregfile port B and the
    // lowest-priority FP forward (sel 2'b11) on the next cycle.  Because the load
    // has already retired, the capture/commit is NOT cancelled by any flush.
    // NO-OP for non-FP code (fpld_we_q stays 0).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fpld_we_q   <= 1'b0;
            fpld_rd_q   <= '0;
            fpld_data_q <= '0;
        end else begin
            fpld_we_q   <= mem_wb_fresh && mem_wb_valid
                           && mem_wb_ctrl.freg_write && mem_wb_ctrl.fp_load;
            fpld_rd_q   <= mem_wb_rd_addr;
            fpld_data_q <= wb_freg_data;
        end
    end

    // =========================================================================
    // Hazard Detection Unit
    // =========================================================================
    rv_hazard #(.XLEN(XLEN)) u_hazard (
        .id_ex_valid     (id_ex_valid),
        .id_ex_ctrl      (id_ex_ctrl),
        .id_ex_rd_addr   (id_ex_rd_addr),
        .ex_mem_valid    (ex_mem_valid),
        .ex_mem_ctrl     (ex_mem_ctrl),
        .ex_mem_rd_addr  (ex_mem_rd_addr),
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
