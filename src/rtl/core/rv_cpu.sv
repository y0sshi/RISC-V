// =============================================================================
/// @file rv_cpu.sv
/// @brief CPU complex: rv_core + rv_mmu + the wiring between them.
///
/// Mode-independent building block shared by every SoC top-level wrapper
/// (rv_soc = AXI/DDR + peripherals, rv_soc_bram = Harvard BRAM + peripherals,
/// rv_soc_act = compliance unified memory).  It exposes a clean PHYSICAL-address
/// memory interface (instruction / data / page-table-walk ports) plus the data
/// virtual address for testbench monitoring; the wrappers attach the memory and
/// peripheral back-ends.  Translation, privilege, traps, stalls and faults are
/// fully internal.
///
/// @param XLEN     Data path width (32 or 64).
/// @param RST_ADDR Reset / entry PC.
// =============================================================================

`default_nettype none

module rv_cpu
    import rv_pkg::*;
#(
    parameter int          XLEN     = rv_pkg::XLEN,
    parameter logic [63:0] RST_ADDR = 64'h0000_0000_0000_0000
) (
    input  wire              clk,
    input  wire              rst_n,

    // ---- Instruction fetch port (physical address) -------------------------
    output logic [XLEN-1:0]  imem_addr,    // = MMU instruction physical address
    output logic             imem_req,
    input  wire  [31:0]      imem_rdata,
    input  wire              imem_ready,

    // ---- Data port (physical address) ---------------------------------------
    output logic [XLEN-1:0]  dmem_addr,    // = MMU data physical address
    output logic [XLEN-1:0]  dmem_wdata,
    output logic [XLEN/8-1:0] dmem_wstrb,
    output logic             dmem_req,
    output logic             dmem_we,
    input  wire  [XLEN-1:0]  dmem_rdata,
    input  wire              dmem_ready,
    input  wire              dmem_wait,    // variable-latency hold (AXI/DDR)

    // ---- Data virtual address (monitoring / tohost detection) ---------------
    output logic [XLEN-1:0]  dmem_va,

    // ---- Page-table-walk port (physical address) ----------------------------
    output logic [XLEN-1:0]  ptw_paddr,
    output logic             ptw_req,
    input  wire  [XLEN-1:0]  ptw_rdata,
    input  wire              ptw_ready,

    // ---- Interrupts ----------------------------------------------------------
    input  wire              timer_irq,
    input  wire              sw_irq,
    input  wire              ext_irq,

    // ---- CLINT mtime -> 'time' CSR (rdtime) ---------------------------------
    input  wire  [63:0]      time_val
);

    // ---- Core <-> MMU buses (internal) --------------------------------------
    logic [XLEN-1:0]   core_imem_va;
    logic              core_imem_req;
    logic [XLEN-1:0]   core_dmem_va;
    logic [XLEN-1:0]   core_dmem_wdata;
    logic [XLEN/8-1:0] core_dmem_wstrb;
    logic              core_dmem_req;
    logic              core_dmem_we;

    logic [XLEN-1:0]   mmu_imem_pa;
    logic              mmu_imem_req;
    logic [XLEN-1:0]   mmu_dmem_pa;
    logic              mmu_dmem_req;
    logic              mmu_dmem_we;

    logic [XLEN-1:0]   satp_out;
    priv_level_t       priv_out;
    logic              mstatus_sum_out;
    logic              mstatus_mxr_out;
    logic              mstatus_mprv_out;
    logic [1:0]        mstatus_mpp_out;
    logic              tlb_flush_out;
    logic              mmu_stall;
    logic              mem_stall;
    logic              if_fault_mmu;
    logic              mem_fault_mmu;

    rv_core #(
        .XLEN     (XLEN),
        .RST_ADDR (RST_ADDR)
    ) u_core (
        .clk (clk),
        .rst_n (rst_n),
        .imem_addr (core_imem_va),
        .imem_req (core_imem_req),
        .imem_rdata (imem_rdata),
        .imem_ready (imem_ready),
        .dmem_addr (core_dmem_va),
        .dmem_wdata (core_dmem_wdata),
        .dmem_wstrb (core_dmem_wstrb),
        .dmem_req (core_dmem_req),
        .dmem_we (core_dmem_we),
        .dmem_rdata (dmem_rdata),
        .dmem_ready (dmem_ready),
        .satp_out (satp_out),
        .priv_out (priv_out),
        .mstatus_sum_out  (mstatus_sum_out),
        .mstatus_mxr_out  (mstatus_mxr_out),
        .mstatus_mprv_out (mstatus_mprv_out),
        .mstatus_mpp_out  (mstatus_mpp_out),
        .tlb_flush_out (tlb_flush_out),
        .mmu_stall (mmu_stall),
        .mem_stall (mem_stall),
        .dmem_wait (dmem_wait),
        .if_fault  (if_fault_mmu),
        .mem_fault (mem_fault_mmu),
        .timer_irq (timer_irq),
        .sw_irq    (sw_irq),
        .ext_irq   (ext_irq),
        .time_val  (time_val)
    );

    rv_mmu #(
        .XLEN (XLEN),
        .TLB_ENTRIES (16)
    ) u_mmu (
        .clk (clk),
        .rst_n (rst_n),
        .satp (satp_out),
        .priv_level (priv_out),
        .mstatus_sum  (mstatus_sum_out),
        .mstatus_mxr  (mstatus_mxr_out),
        .mstatus_mprv (mstatus_mprv_out),
        .mstatus_mpp  (mstatus_mpp_out),
        .tlb_flush (tlb_flush_out),
        .if_va (core_imem_va),
        .if_req (core_imem_req),
        .if_pa (mmu_imem_pa),
        .if_req_out (mmu_imem_req),
        .if_fault (if_fault_mmu),
        .mem_va (core_dmem_va),
        .mem_req (core_dmem_req),
        .mem_we (core_dmem_we),
        .mem_pa (mmu_dmem_pa),
        .mem_req_out (mmu_dmem_req),
        .mem_we_out (mmu_dmem_we),
        .mem_fault (mem_fault_mmu),
        .mmu_stall (mmu_stall),
        .mem_stall (mem_stall),
        .ptw_paddr (ptw_paddr),
        .ptw_req (ptw_req),
        .ptw_rdata (ptw_rdata),
        .ptw_ready (ptw_ready)
    );

    // ---- Physical-address memory interface (to the wrapper's back-end) ------
    assign imem_addr  = mmu_imem_pa;
    assign imem_req   = mmu_imem_req;
    assign dmem_addr  = mmu_dmem_pa;
    assign dmem_req   = mmu_dmem_req;
    assign dmem_we    = mmu_dmem_we;
    assign dmem_wdata = core_dmem_wdata;   // write data / strobe are not translated
    assign dmem_wstrb = core_dmem_wstrb;
    assign dmem_va    = core_dmem_va;       // virtual address (monitoring)

endmodule

`default_nettype wire
