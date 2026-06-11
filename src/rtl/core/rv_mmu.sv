// =============================================================================
/// @file rv_mmu.sv
/// @brief Memory Management Unit with TLB and Hardware Page Table Walker
///
/// Implements virtual-to-physical address translation for supervisor and user modes:
/// - **Sv32** (RV32): 2-level page table, 4 KB pages
/// - **Sv39** (RV64): 3-level page table, 4 KB pages
///
/// **TLB (Translation Lookaside Buffer):**
/// - **Size**: 16 fully-associative entries
/// - **Replacement**: Round-robin eviction policy
/// - **Flush**: SFENCE.VMA instruction invalidates all entries
/// - **Hit**: O(1) translation from virtual address (VA) to physical address (PA)
///
/// **Hardware Page Table Walker (PTW):**
/// - **FSM**: Walks 2 (Sv32) or 3 (Sv39) levels of page tables
/// - **Access mode**: Reads page table entries (PTEs) from memory via PTW port
/// - **Fault detection**: Generates page fault exceptions for invalid PTEs
/// - **Privilege checking**: Enforces U-mode/S-mode access restrictions
///
/// **Access Control (Privilege & Protection):**
/// - **PRIV+U/S bits**: Permission check per PTE
/// - **SUM (Supervisor User Memory)**: S-mode can read U-mode pages
/// - **MXR (Make eXecutable Readable)**: X bit satisfies R requirement
///
/// **Translation Requests:**
/// - **IF port**: Instruction fetch translation (page fault → EXC_INST_PAGE_FAULT)
/// - **MEM port**: Data load/store translation (page fault → EXC_LOAD/STORE_PAGE_FAULT)
///
/// **Stalling:**
/// - **mmu_stall = 1**: When PTW is in progress or a fault is pending
/// - **rv_core**: Must gate IF/ID pipeline stages with mmu_stall
///
/// @param XLEN Data path width: 32 (Sv32) or 64 (Sv39)
/// @param TLB_ENTRIES Number of TLB entries (default: 16)
/// @author Naofumi Yoshinaga
/// @date 2025-05-22
/// @version 1.0
/// =============================================================================

`default_nettype none

module rv_mmu
    import rv_pkg::*;
#(
    parameter int XLEN        = rv_pkg::XLEN,
    parameter int TLB_ENTRIES = 16
) (
    input  wire              clk,
    input  wire              rst_n,

    // ---- Translation control (from rv_core / rv_csr) ------------------------
    input  wire  [XLEN-1:0]  satp,           // SATP CSR
    input  wire priv_level_t priv_level,     // current privilege level (IF)
    input  wire              mstatus_sum,    // mstatus.SUM
    input  wire              mstatus_mxr,    // mstatus.MXR
    input  wire              mstatus_mprv,   // mstatus.MPRV
    input  wire  [1:0]       mstatus_mpp,    // mstatus.MPP (used with MPRV)
    input  wire              tlb_flush,      // SFENCE.VMA → invalidate all TLB

    // ---- IF port (instruction fetch) ----------------------------------------
    input  wire  [XLEN-1:0]  if_va,
    input  wire              if_req,
    output logic [XLEN-1:0]  if_pa,          // physical address → imem
    output logic             if_req_out,     // forwarded req → imem
    output logic             if_fault,       // instruction page fault

    // ---- MEM port (data memory) ---------------------------------------------
    input  wire  [XLEN-1:0]  mem_va,
    input  wire              mem_req,
    input  wire              mem_we,
    output logic [XLEN-1:0]  mem_pa,         // physical address → dmem
    output logic             mem_req_out,    // forwarded req → dmem
    output logic             mem_we_out,     // forwarded we → dmem
    output logic             mem_fault,      // load/store page fault

    // ---- Stall outputs ------------------------------------------------------
    output logic             mmu_stall,      // 1 = IF or MEM translation pending (stalls IF/ID)
    output logic             mem_stall,      // 1 = MEM-port translation pending (also stalls EX/MEM)

    // ---- PTW physical-memory port (rv_soc muxes with dmem) -----------------
    output logic [XLEN-1:0]  ptw_paddr,
    output logic             ptw_req,
    input  wire  [XLEN-1:0]  ptw_rdata,
    input  wire              ptw_ready
);

    // =========================================================================
    // Parameters derived from XLEN
    // =========================================================================
    // VPN total width:  Sv32=20,  Sv39=27
    // PPN total width:  Sv32=22,  Sv39=44
    // VPN bits/level:   Sv32=10,  Sv39=9
    // PTE size (bytes): Sv32=4,   Sv39=8
    // PTW levels:       Sv32=2,   Sv39=3

    localparam int VPN_W      = (XLEN == 32) ? 20 : 27;
    localparam int PPN_INT_W  = 44;   // fixed internal width (max of 22 and 44)
    localparam int PTE_SHIFT  = (XLEN == 32) ? 2 : 3;  // log2(PTE bytes)

    // =========================================================================
    // Translation-mode detection
    // =========================================================================
    // Sv32: SATP[31]=MODE, Sv39: SATP[63:60]=4'h8
    // M-mode always uses physical addresses for IF.
    // For data accesses: MPRV=1 uses MPP as effective privilege instead.
    wire [63:0] satp64      = {{(64-XLEN){1'b0}}, satp};
    wire        vm_active   = (XLEN == 32) ? satp64[31]
                                           : (satp64[63:60] == 4'h8);
    wire        vm_enabled  = vm_active && (priv_level != PRIV_M);
    // Effective privilege for data accesses (MPRV: use MPP when in M-mode)
    wire [1:0]  priv_data   = (mstatus_mprv && (priv_level == PRIV_M))
                              ? mstatus_mpp : priv_level;
    wire        vm_data     = vm_active && (priv_data != PRIV_M);

    // Root-page-table PPN from SATP (44-bit internal)
    wire [PPN_INT_W-1:0] satp_ppn44 = (XLEN == 32)
                                       ? {22'b0, satp64[21:0]}
                                       : satp64[43:0];

    // =========================================================================
    // VPN extraction from VA (safe: use 64-bit intermediates)
    // =========================================================================
    wire [63:0]      if_va64  = {{(64-XLEN){1'b0}}, if_va};
    wire [63:0]      mem_va64 = {{(64-XLEN){1'b0}}, mem_va};

    // VPN = VA[VPN_W+11 : 12]
    wire [VPN_W-1:0] if_vpn  = if_va64 [VPN_W+11:12];
    wire [VPN_W-1:0] mem_vpn = mem_va64[VPN_W+11:12];

    // =========================================================================
    // TLB storage (16 entries, fully associative)
    // =========================================================================
    logic [TLB_ENTRIES-1:0]         tlb_valid;
    logic [VPN_W-1:0]               tlb_vpn [0:TLB_ENTRIES-1];
    logic [PPN_INT_W-1:0]           tlb_ppn [0:TLB_ENTRIES-1];
    logic                           tlb_r   [0:TLB_ENTRIES-1];
    logic                           tlb_w   [0:TLB_ENTRIES-1];
    logic                           tlb_x   [0:TLB_ENTRIES-1];
    logic                           tlb_u   [0:TLB_ENTRIES-1];
    logic                           tlb_d   [0:TLB_ENTRIES-1];

    logic [$clog2(TLB_ENTRIES)-1:0] tlb_repl;   // round-robin pointer

    // =========================================================================
    // TLB lookup (combinational)
    // =========================================================================
    logic [PPN_INT_W-1:0] if_tlb_ppn, mem_tlb_ppn;
    logic                 if_tlb_hit,  mem_tlb_hit;
    logic                 if_tlb_r,  if_tlb_w,  if_tlb_x,  if_tlb_u,  if_tlb_d;
    logic                 mem_tlb_r, mem_tlb_w, mem_tlb_x, mem_tlb_u, mem_tlb_d;

    always_comb begin
        if_tlb_hit = 1'b0;
        if_tlb_ppn = '0;
        if_tlb_r = 0; if_tlb_w = 0; if_tlb_x = 0; if_tlb_u = 0; if_tlb_d = 0;
        for (int i = 0; i < TLB_ENTRIES; i++) begin
            if (tlb_valid[i] && (tlb_vpn[i] == if_vpn)) begin
                if_tlb_hit = 1'b1;
                if_tlb_ppn = tlb_ppn[i];
                if_tlb_r   = tlb_r[i]; if_tlb_w = tlb_w[i]; if_tlb_x = tlb_x[i];
                if_tlb_u   = tlb_u[i]; if_tlb_d = tlb_d[i];
            end
        end
    end

    always_comb begin
        mem_tlb_hit = 1'b0;
        mem_tlb_ppn = '0;
        mem_tlb_r = 0; mem_tlb_w = 0; mem_tlb_x = 0; mem_tlb_u = 0; mem_tlb_d = 0;
        for (int i = 0; i < TLB_ENTRIES; i++) begin
            if (tlb_valid[i] && (tlb_vpn[i] == mem_vpn)) begin
                mem_tlb_hit = 1'b1;
                mem_tlb_ppn = tlb_ppn[i];
                mem_tlb_r   = tlb_r[i]; mem_tlb_w = tlb_w[i]; mem_tlb_x = tlb_x[i];
                mem_tlb_u   = tlb_u[i]; mem_tlb_d = tlb_d[i];
            end
        end
    end

    // =========================================================================
    // Permission checks
    // =========================================================================
    logic if_perm_ok, mem_perm_ok;

    always_comb begin
        // Fetch: need X bit
        if_perm_ok = if_tlb_x;
        if (priv_level == PRIV_U)      if_perm_ok = if_tlb_x &&  if_tlb_u;
        else if (priv_level == PRIV_S) if_perm_ok = if_tlb_x && !if_tlb_u;
    end

    always_comb begin
        if (mem_we)
            // Store: need W + D (dirty bit must be set)
            mem_perm_ok = mem_tlb_w && mem_tlb_d;
        else
            // Load: need R, or (MXR && X)
            mem_perm_ok = mem_tlb_r || (mstatus_mxr && mem_tlb_x);

        // Use priv_data (MPRV-adjusted) for U/S privilege check on data accesses
        if      (priv_data == PRIV_U) mem_perm_ok = mem_perm_ok &&  mem_tlb_u;
        else if (priv_data == PRIV_S) mem_perm_ok = mem_perm_ok && (!mem_tlb_u || mstatus_sum);
    end

    // =========================================================================
    // Physical address construction from TLB hit
    // =========================================================================
    // PA = {ppn, page_offset}  — via 64-bit intermediate, then truncated to XLEN
    wire [63:0] if_pa64  = ({20'b0, if_tlb_ppn}  << 12) | {52'b0, if_va [11:0]};
    wire [63:0] mem_pa64 = ({20'b0, mem_tlb_ppn} << 12) | {52'b0, mem_va[11:0]};

    // =========================================================================
    // PTW state machine
    // =========================================================================
    typedef enum logic [2:0] {
        PTW_IDLE  = 3'd0,
        PTW_L2    = 3'd1,    // Sv39 only: walk root (VPN[2])
        PTW_L1    = 3'd2,    // Sv32 root (VPN[1]) / Sv39 mid (VPN[1])
        PTW_L0    = 3'd3,    // Leaf level (VPN[0])
        PTW_DONE  = 3'd4,
        PTW_FAULT = 3'd5
    } ptw_state_t;

    ptw_state_t      ptw_state;
    logic            ptw_wait;            // 1 = just entered new state, skip 1 cycle
    logic            ptw_for_if;          // 1 = walking for IF port
    logic [VPN_W-1:0] ptw_vpn;           // VPN of the VA being walked
    logic [PPN_INT_W-1:0] ptw_ppn_cur;   // PPN of the current page table

    // Results latched after successful leaf PTE
    logic [PPN_INT_W-1:0] ptw_res_ppn;
    logic ptw_res_r, ptw_res_w, ptw_res_x, ptw_res_u, ptw_res_d;
    logic ptw_fault_r;   // registered: fault was signalled

    // ---- PTE decoding (combinational, applies to ptw_rdata) -----------------
    wire [63:0] pte64    = {{(64-XLEN){1'b0}}, ptw_rdata};
    wire        pte_v    = pte64[0];
    wire        pte_r    = pte64[1];
    wire        pte_w    = pte64[2];
    wire        pte_x    = pte64[3];
    wire        pte_u    = pte64[4];
    wire        pte_a    = pte64[6];
    wire        pte_d    = pte64[7];
    wire        pte_leaf = pte_r | pte_x;
    // PPN from PTE: Sv32 pte[31:10]=22b, Sv39 pte[53:10]=44b
    wire [PPN_INT_W-1:0] pte_ppn44 = (XLEN == 32) ? {22'b0, pte64[31:10]}
                                                    : pte64[53:10];

    // ---- VPN sub-fields (10-bit containers for both modes) ------------------
    wire [63:0] ptw_vpn64 = {{(64-VPN_W){1'b0}}, ptw_vpn};

    // Sv39: VPN[2]=bits[26:18] (9-bit), VPN[1]=bits[17:9], VPN[0]=bits[8:0]
    // Sv32: VPN[1]=bits[19:10] (10-bit), VPN[0]=bits[9:0]
    wire [9:0] vpn_idx_l2 = (XLEN == 64) ? {1'b0, ptw_vpn64[26:18]} : 10'b0;
    wire [9:0] vpn_idx_l1 = (XLEN == 32) ? ptw_vpn64[19:10]
                                          : {1'b0, ptw_vpn64[17:9]};
    wire [9:0] vpn_idx_l0 = (XLEN == 32) ? ptw_vpn64[9:0]
                                          : {1'b0, ptw_vpn64[8:0]};

    // ---- PTW address calculation (64-bit intermediates) ---------------------
    wire [63:0] w_root_base = {20'b0, satp_ppn44}  << 12;
    wire [63:0] w_cur_base  = {20'b0, ptw_ppn_cur} << 12;

    wire [63:0] ptw_l2_addr = w_root_base + ({54'b0, vpn_idx_l2} << PTE_SHIFT);
    wire [63:0] ptw_l1_addr = ((XLEN == 32) ? w_root_base : w_cur_base)
                              + ({54'b0, vpn_idx_l1} << PTE_SHIFT);
    wire [63:0] ptw_l0_addr = w_cur_base + ({54'b0, vpn_idx_l0} << PTE_SHIFT);

    // PTW address mux (combinational)
    logic [63:0] ptw_paddr64;
    always_comb begin
        ptw_req      = 1'b0;
        ptw_paddr64  = '0;
        case (ptw_state)
            PTW_L2:  begin ptw_req = 1'b1; ptw_paddr64 = ptw_l2_addr; end
            PTW_L1:  begin ptw_req = 1'b1; ptw_paddr64 = ptw_l1_addr; end
            PTW_L0:  begin ptw_req = 1'b1; ptw_paddr64 = ptw_l0_addr; end
            default: ;
        endcase
    end
    assign ptw_paddr = ptw_paddr64[XLEN-1:0];

    // ---- PTW state transitions ----------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ptw_state   <= PTW_IDLE;
            ptw_wait    <= 1'b0;
            ptw_for_if  <= 1'b0;
            ptw_vpn     <= '0;
            ptw_ppn_cur <= '0;
            ptw_res_ppn <= '0;
            ptw_res_r   <= 1'b0; ptw_res_w <= 1'b0; ptw_res_x <= 1'b0;
            ptw_res_u   <= 1'b0; ptw_res_d <= 1'b0;
            ptw_fault_r <= 1'b0;
        end else begin
            case (ptw_state)

                PTW_IDLE: begin
                    ptw_fault_r <= 1'b0;
                    ptw_wait    <= 1'b0;
                    // IF miss has priority over MEM miss
                    // Note: no ptw_wait needed on IDLE→L* transition because
                    // ptw_req=0 in IDLE so the memory model returns ptw_ready=0
                    // on the first cycle after transition (natural 1-cycle gap).
                    if (vm_enabled && if_req && !if_tlb_hit) begin
                        ptw_for_if <= 1'b1;
                        ptw_vpn    <= if_vpn;
                        ptw_state  <= (XLEN == 64) ? PTW_L2 : PTW_L1;
                    end else if (vm_data && mem_req && !mem_tlb_hit) begin
                        ptw_for_if <= 1'b0;
                        ptw_vpn    <= mem_vpn;
                        ptw_state  <= (XLEN == 64) ? PTW_L2 : PTW_L1;
                    end
                end

                PTW_L2: begin   // Sv39 only
                    if (ptw_wait) begin
                        ptw_wait <= 1'b0;
                    end else if (ptw_ready) begin
                        if (!pte_v || (!pte_r && pte_w)) begin
                            ptw_fault_r <= 1'b1;
                            ptw_state   <= PTW_FAULT;
                        end else if (pte_leaf) begin
                            // Sv39 gigapage (1 GB): PPN[17:0] must be 0
                            if (pte_ppn44[17:0] != 18'b0 || !pte_a) begin
                                ptw_fault_r <= 1'b1;
                                ptw_state   <= PTW_FAULT;
                            end else begin
                                // Effective PPN: upper PPN bits + VPN[1:0] from VA
                                ptw_res_ppn <= {pte_ppn44[43:18], ptw_vpn[17:0]};
                                ptw_res_r   <= pte_r; ptw_res_w <= pte_w;
                                ptw_res_x   <= pte_x; ptw_res_u <= pte_u;
                                ptw_res_d   <= pte_d;
                                ptw_fault_r <= 1'b0;
                                ptw_state   <= PTW_DONE;
                            end
                        end else begin
                            // Non-leaf: proceed to L1
                            ptw_ppn_cur <= pte_ppn44;
                            ptw_state   <= PTW_L1;
                            ptw_wait    <= 1'b1;
                        end
                    end
                end

                PTW_L1: begin
                    if (ptw_wait) begin
                        ptw_wait <= 1'b0;
                    end else if (ptw_ready) begin
                        if (!pte_v || (!pte_r && pte_w)) begin
                            ptw_fault_r <= 1'b1;
                            ptw_state   <= PTW_FAULT;
                        end else if (pte_leaf) begin
                            // Sv39 megapage (2 MB): PPN[8:0] must be 0
                            // Sv32 megapage (4 MB): PPN[9:0] must be 0
                            logic [17:0] align_mask;
                            logic        misaligned;
                            align_mask  = (XLEN == 64) ? 18'h1ff : 18'h3ff;
                            misaligned  = |(pte_ppn44[17:0] & align_mask);
                            if (misaligned || !pte_a) begin
                                ptw_fault_r <= 1'b1;
                                ptw_state   <= PTW_FAULT;
                            end else begin
                                // Effective PPN: upper bits + VPN[0] from VA
                                ptw_res_ppn <= (XLEN == 64)
                                    ? {pte_ppn44[43:9], ptw_vpn[8:0]}
                                    : {pte_ppn44[43:10], ptw_vpn[9:0]};
                                ptw_res_r   <= pte_r; ptw_res_w <= pte_w;
                                ptw_res_x   <= pte_x; ptw_res_u <= pte_u;
                                ptw_res_d   <= pte_d;
                                ptw_fault_r <= 1'b0;
                                ptw_state   <= PTW_DONE;
                            end
                        end else begin
                            // Non-leaf: proceed to L0
                            ptw_ppn_cur <= pte_ppn44;
                            ptw_state   <= PTW_L0;
                            ptw_wait    <= 1'b1;
                        end
                    end
                end

                PTW_L0: begin   // Leaf PTE
                    if (ptw_wait) begin
                        ptw_wait <= 1'b0;
                    end else if (ptw_ready) begin
                        if (!pte_v || (!pte_r && pte_w) || !pte_a || !pte_leaf) begin
                            ptw_fault_r <= 1'b1;
                            ptw_state   <= PTW_FAULT;
                        end else begin
                            ptw_res_ppn <= pte_ppn44;
                            ptw_res_r   <= pte_r;  ptw_res_w <= pte_w;
                            ptw_res_x   <= pte_x;  ptw_res_u <= pte_u;
                            ptw_res_d   <= pte_d;
                            ptw_fault_r <= 1'b0;
                            ptw_state   <= PTW_DONE;
                        end
                    end
                end

                PTW_DONE:  ptw_state <= PTW_IDLE;
                PTW_FAULT: ptw_state <= PTW_IDLE;
                default:   ptw_state <= PTW_IDLE;

            endcase
        end
    end

    // =========================================================================
    // TLB fill and flush
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tlb_valid <= '0;
            tlb_repl  <= '0;
            for (int i = 0; i < TLB_ENTRIES; i++) begin
                tlb_vpn[i] <= '0; tlb_ppn[i] <= '0;
                tlb_r[i]   <= 0;  tlb_w[i]   <= 0;
                tlb_x[i]   <= 0;  tlb_u[i]   <= 0;
                tlb_d[i]   <= 0;
            end
        end else begin
            if (tlb_flush) begin
                tlb_valid <= '0;
            end else if (ptw_state == PTW_DONE && !ptw_fault_r) begin
                tlb_valid[tlb_repl]  <= 1'b1;
                tlb_vpn  [tlb_repl]  <= ptw_vpn;
                tlb_ppn  [tlb_repl]  <= ptw_res_ppn;
                tlb_r    [tlb_repl]  <= ptw_res_r;
                tlb_w    [tlb_repl]  <= ptw_res_w;
                tlb_x    [tlb_repl]  <= ptw_res_x;
                tlb_u    [tlb_repl]  <= ptw_res_u;
                tlb_d    [tlb_repl]  <= ptw_res_d;
                tlb_repl             <= tlb_repl + 1;
            end
        end
    end

    // =========================================================================
    // Stall outputs
    // =========================================================================
    // mem_stall: the MEM-stage load/store cannot complete because its data
    // translation is still pending (TLB miss being walked, or just-detected).
    // This is purely combinational so it covers the whole window from miss
    // detection through TLB fill, and drops as soon as the TLB hits (access
    // proceeds) or the access faults (trap is taken).  It freezes EX/MEM so the
    // access stays in MEM and re-issues once the translation is ready.
    wire mem_xlate_pending = vm_data && mem_req && !mem_tlb_hit && !mem_fault;
    assign mem_stall = mem_xlate_pending;

    // mmu_stall: stall IF/ID whenever any PTW is walking (IF or MEM) or a MEM
    // translation is pending.  PTW_FAULT does NOT stall (the fault is taken as
    // a trap immediately).  IF-port PTW does not freeze EX/MEM (that path keeps
    // running, matching the original pipeline behavior).
    wire ptw_walking = (ptw_state == PTW_L2)
                       || (ptw_state == PTW_L1)
                       || (ptw_state == PTW_L0);
    assign mmu_stall = ptw_walking || mem_xlate_pending;

    // Pre-truncated physical addresses (avoids parametric selects in always_comb)
    wire [XLEN-1:0] if_pa_xlat  = if_pa64 [XLEN-1:0];
    wire [XLEN-1:0] mem_pa_xlat = mem_pa64[XLEN-1:0];

    // =========================================================================
    // IF port output (combinational)
    // =========================================================================
    always_comb begin
        if (!vm_enabled) begin
            // Bare mode: pass-through
            if_pa      = if_va;
            if_req_out = if_req;
            if_fault   = 1'b0;
        end else if (!if_req) begin
            if_pa      = '0;
            if_req_out = 1'b0;
            if_fault   = 1'b0;
        end else if (if_tlb_hit) begin
            if_pa      = if_pa_xlat;
            if_req_out = if_perm_ok;
            if_fault   = !if_perm_ok;
        end else begin
            // TLB miss: block request, signal fault if PTW faulted
            if_pa      = '0;
            if_req_out = 1'b0;
            if_fault   = ptw_fault_r && ptw_for_if && (ptw_state == PTW_FAULT);
        end
    end

    // =========================================================================
    // MEM port output (combinational)
    // =========================================================================
    always_comb begin
        if (!vm_data) begin
            // VM disabled for data accesses (bare mode or MPRV→M-mode)
            mem_pa      = mem_va;
            mem_req_out = mem_req;
            mem_we_out  = mem_we;
            mem_fault   = 1'b0;
        end else if (!mem_req) begin
            mem_pa      = '0;
            mem_req_out = 1'b0;
            mem_we_out  = 1'b0;
            mem_fault   = 1'b0;
        end else if (mem_tlb_hit) begin
            mem_pa      = mem_pa_xlat;
            mem_req_out = mem_perm_ok;
            mem_we_out  = mem_we && mem_perm_ok;
            mem_fault   = !mem_perm_ok;
        end else begin
            mem_pa      = '0;
            mem_req_out = 1'b0;
            mem_we_out  = 1'b0;
            mem_fault   = ptw_fault_r && !ptw_for_if && (ptw_state == PTW_FAULT);
        end
    end

endmodule

`default_nettype wire
