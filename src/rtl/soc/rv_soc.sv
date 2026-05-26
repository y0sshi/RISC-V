// =============================================================================
// rv_soc.sv - RISC-V System on Chip Top Module
// =============================================================================
// Integrates CPU core, MMU (TLB+PTW), instruction memory, and data memory.
//
// Memory arbitration:
//   Normal operation : core dmem VA → MMU → dmem PA
//   PTW in progress  : MMU PTW port → dmem (core dmem stalled via mmu_stall)
//
// Author: Naofumi Yoshinaga
// =============================================================================

`default_nettype none

module rv_soc
    import rv_pkg::*;
#(
    parameter int          XLEN        = rv_pkg::XLEN,
    parameter int          IMEM_DEPTH  = 4096,
    parameter int          DMEM_DEPTH  = 4096,
    parameter logic [63:0] RST_ADDR    = 64'h0,
    parameter              IMEM_FILE   = "",
    parameter              DMEM_FILE   = "",
    parameter int          CLK_FREQ    = 125_000_000,   // Hz (Zybo Z7-20 default)
    parameter int          BAUD_RATE   = 115_200        // bps
) (
    input  wire              clk,
    input  wire              rst_n,

    input  wire  [3:0]       gpio_in,
    output logic [3:0]       gpio_out,

    input  wire              uart_rx,
    output logic             uart_tx
);
    // =========================================================================
    // Forward declaration
    // ========================================================================
    logic       timer_irq_sig;
    logic [1:0] plic_ext_irq;
    logic       gpio_irq;

    // =========================================================================
    // Core → MMU buses (virtual addresses)
    // =========================================================================
    logic [XLEN-1:0] core_imem_va;
    logic            core_imem_req;

    logic [XLEN-1:0] core_dmem_va;
    logic [XLEN-1:0] core_dmem_wdata;
    logic [XLEN/8-1:0] core_dmem_wstrb;
    logic            core_dmem_req;
    logic            core_dmem_we;

    // =========================================================================
    // MMU → memory buses (physical addresses)
    // =========================================================================
    logic [XLEN-1:0] mmu_imem_pa;
    logic            mmu_imem_req;

    logic [XLEN-1:0] mmu_dmem_pa;
    logic            mmu_dmem_req;
    logic            mmu_dmem_we;

    // PTW port
    logic [XLEN-1:0] ptw_paddr;
    logic            ptw_req;
    logic [XLEN-1:0] ptw_rdata;
    logic            ptw_ready;

    // =========================================================================
    // Memory interfaces (physical)
    // =========================================================================
    logic [31:0]      imem_rdata;
    logic             imem_ready;

    logic [XLEN-1:0] dmem_rdata;
    logic            dmem_ready;

    // =========================================================================
    // MMU state from core
    // =========================================================================
    logic [XLEN-1:0] satp_out;
    priv_level_t     priv_out;
    logic            mstatus_sum_out;
    logic            mstatus_mxr_out;
    logic            tlb_flush_out;
    logic            mmu_stall;

    // Fault signals (for future trap injection — wired to core later)
    logic            if_fault_mmu;
    logic            mem_fault_mmu;

    // =========================================================================
    // CPU Core
    // =========================================================================
    rv_core #(
        .XLEN     (XLEN),
        .RST_ADDR (RST_ADDR)
    ) u_core (
        .clk             (clk),
        .rst_n           (rst_n),
        // Instruction memory (virtual)
        .imem_addr       (core_imem_va),
        .imem_req        (core_imem_req),
        .imem_rdata      (imem_rdata),
        .imem_ready      (imem_ready),
        // Data memory (virtual)
        .dmem_addr       (core_dmem_va),
        .dmem_wdata      (core_dmem_wdata),
        .dmem_wstrb      (core_dmem_wstrb),
        .dmem_req        (core_dmem_req),
        .dmem_we         (core_dmem_we),
        .dmem_rdata      (dmem_rdata),
        .dmem_ready      (dmem_ready),
        // MMU state
        .satp_out        (satp_out),
        .priv_out        (priv_out),
        .mstatus_sum_out (mstatus_sum_out),
        .mstatus_mxr_out (mstatus_mxr_out),
        .tlb_flush_out   (tlb_flush_out),
        .mmu_stall       (mmu_stall),
        // Interrupts (from integrated peripherals)
        .timer_irq       (timer_irq_sig),
        .sw_irq          (1'b0),                // Software interrupt not yet implemented
        .ext_irq         (plic_ext_irq[0])      // Machine-mode external IRQ from PLIC
    );

    // =========================================================================
    // MMU
    // =========================================================================
    rv_mmu #(
        .XLEN        (XLEN),
        .TLB_ENTRIES (16)
    ) u_mmu (
        .clk          (clk),
        .rst_n        (rst_n),
        // Control
        .satp         (satp_out),
        .priv_level   (priv_out),
        .mstatus_sum  (mstatus_sum_out),
        .mstatus_mxr  (mstatus_mxr_out),
        .tlb_flush    (tlb_flush_out),
        // IF port
        .if_va        (core_imem_va),
        .if_req       (core_imem_req),
        .if_pa        (mmu_imem_pa),
        .if_req_out   (mmu_imem_req),
        .if_fault     (if_fault_mmu),
        // MEM port
        .mem_va       (core_dmem_va),
        .mem_req      (core_dmem_req),
        .mem_we       (core_dmem_we),
        .mem_pa       (mmu_dmem_pa),
        .mem_req_out  (mmu_dmem_req),
        .mem_we_out   (mmu_dmem_we),
        .mem_fault    (mem_fault_mmu),
        // Stall
        .mmu_stall    (mmu_stall),
        // PTW
        .ptw_paddr    (ptw_paddr),
        .ptw_req      (ptw_req),
        .ptw_rdata    (ptw_rdata),
        .ptw_ready    (ptw_ready)
    );

    // =========================================================================
    // Instruction Memory
    // =========================================================================
    rv_imem #(
        .XLEN      (XLEN),
        .DEPTH     (IMEM_DEPTH),
        .INIT_FILE (IMEM_FILE)
    ) u_imem (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (mmu_imem_pa),
        .req   (mmu_imem_req),
        .rdata (imem_rdata),
        .ready (imem_ready)
    );

    // =========================================================================
    // Memory-mapped I/O address decoding & peripheral access muxing
    // Physical address map:
    //   0x0000_0000 - 0x7FFF_FFFF : Instruction memory (IMEM)
    //   0x8000_0000 - 0xBFFF_FFFF : Data memory (DMEM)
    //   0xC000_0000 - 0xC000_000F : Timer (CLINT)  [addr[31:16]=0xC000]
    //   0xC001_0000 - 0xC001_000F : UART           [addr[31:16]=0xC001]
    //   0xC002_0000 - 0xC002_000F : GPIO           [addr[31:16]=0xC002]
    //   0xC010_0000 - 0xC010_0FFF : PLIC           [addr[31:16]=0xC010]
    // =========================================================================
    logic [XLEN-1:0]   dmem_addr_arb;
    logic [XLEN-1:0]   dmem_wdata_arb;
    logic [XLEN/8-1:0] dmem_wstrb_arb;
    logic              dmem_req_arb;
    logic              dmem_we_arb;

    logic              is_timer_access;
    logic              is_uart_access;
    logic              is_plic_access;
    logic              is_dmem_access;

    logic [31:0]       timer_rdata;
    logic [31:0]       uart_rdata;
    logic [31:0]       plic_rdata;
    logic [XLEN-1:0]   dmem_rdata_mem;
    logic              dmem_ready_mem;

    logic              is_gpio_access;
    logic [31:0]       gpio_rdata;

    // Address decode based on physical address bits [31:16]
    always_comb begin
        is_timer_access = (mmu_dmem_pa[31:16] == 16'hC000);
        is_uart_access  = (mmu_dmem_pa[31:16] == 16'hC001);
        is_gpio_access  = (mmu_dmem_pa[31:16] == 16'hC002);
        is_plic_access  = (mmu_dmem_pa[31:16] == 16'hC010);
        is_dmem_access  = ~is_timer_access & ~is_uart_access
                        & ~is_gpio_access  & ~is_plic_access;
    end

    // Data memory arbitration (PTW has priority over core access)
    always_comb begin
        if (ptw_req) begin
            // PTW access: read page-table entry (always goes to DMEM)
            dmem_addr_arb  = ptw_paddr;
            dmem_wdata_arb = '0;
            dmem_wstrb_arb = '0;
            dmem_req_arb   = 1'b1;
            dmem_we_arb    = 1'b0;
        end else begin
            // Normal core data memory access to DMEM (not peripherals)
            dmem_addr_arb  = mmu_dmem_pa;
            dmem_wdata_arb = core_dmem_wdata;
            dmem_wstrb_arb = core_dmem_wstrb;
            dmem_req_arb   = mmu_dmem_req & is_dmem_access;
            dmem_we_arb    = mmu_dmem_we & is_dmem_access;
        end
    end

    // PTW ready/rdata only active when PTW is driving bus
    assign ptw_rdata = dmem_rdata_mem;
    assign ptw_ready = ptw_req ? dmem_ready_mem : 1'b0;

    // =========================================================================
    // Peripheral read data register
    // =========================================================================
    // Problem: the core's WB stage reads dmem_rdata COMBINATIONALLY one cycle
    // AFTER the MEM access.  rv_dmem provides naturally-delayed data because its
    // read port is synchronous (registered BRAM output).  Peripheral read data
    // is combinational, so if we drove dmem_rdata directly from uart_rdata etc.,
    // WB would see the CURRENT MEM access's data - not the PREVIOUS one.
    //
    // Fix: register the peripheral read data.  In cycle N (MEM), we latch the
    // combinational peripheral output.  In cycle N+1 (WB), we return the latched
    // value, giving the same 1-cycle read latency as DMEM.
    // =========================================================================
    logic [XLEN-1:0] periph_rdata_reg;   // registered peripheral read data
    logic            prev_periph_read;   // previous MEM cycle was a peripheral read

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            periph_rdata_reg <= '0;
            prev_periph_read <= 1'b0;
        end else begin
            // Latch the combinational peripheral data on every clock edge
            // (only the relevant register will be used - see mux below)
            if (is_timer_access)
                periph_rdata_reg <= {{(XLEN-32){1'b0}}, timer_rdata};
            else if (is_uart_access)
                periph_rdata_reg <= {{(XLEN-32){1'b0}}, uart_rdata};
            else if (is_gpio_access)
                periph_rdata_reg <= {{(XLEN-32){1'b0}}, gpio_rdata};
            else if (is_plic_access)
                periph_rdata_reg <= {{(XLEN-32){1'b0}}, plic_rdata};

            // Record whether the MEM stage issued a peripheral READ
            // (writes don't produce read data, so exclude them)
            prev_periph_read <= mmu_dmem_req & ~mmu_dmem_we
                              & (is_timer_access | is_uart_access
                               | is_gpio_access  | is_plic_access);
        end
    end

    // Mux read data and ready: registered peripheral data has 1-cycle latency
    // (matching DMEM), so WB always sees data from the correct MEM cycle.
    always_comb begin
        if (prev_periph_read) begin
            // Return the registered peripheral data from the previous MEM cycle
            dmem_rdata = periph_rdata_reg;
            dmem_ready = 1'b1;
        end else begin
            // DMEM (synchronous, 1-cycle latency) or no access
            dmem_rdata = dmem_rdata_mem;
            dmem_ready = dmem_ready_mem;
        end
    end

    rv_dmem #(
        .XLEN      (XLEN),
        .DEPTH     (DMEM_DEPTH),
        .INIT_FILE (DMEM_FILE)
    ) u_dmem (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (dmem_addr_arb),
        .wdata (dmem_wdata_arb),
        .wstrb (dmem_wstrb_arb),
        .req   (dmem_req_arb),
        .we    (dmem_we_arb),
        .rdata (dmem_rdata_mem),
        .ready (dmem_ready_mem)
    );

    // =========================================================================
    // Timer (CLINT) - at 0xC000_0000
    // =========================================================================
    rv_timer u_timer (
        .clk       (clk),
        .rst_n     (rst_n),
        .addr      (mmu_dmem_pa[3:0]),
        .req       (mmu_dmem_req & is_timer_access),
        .we        (mmu_dmem_we & is_timer_access),
        .wdata     (core_dmem_wdata[31:0]),
        .rdata     (timer_rdata),
        .timer_irq (timer_irq_sig)
    );

    // =========================================================================
    // UART - at 0xC001_0000
    // =========================================================================
    logic        uart_tx_sig;
    logic        uart_tx_irq;
    logic        uart_rx_irq;

    rv_uart #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_uart (
        .clk      (clk),
        .rst_n    (rst_n),
        .addr     (mmu_dmem_pa[3:0]),
        .req      (mmu_dmem_req & is_uart_access),
        .we       (mmu_dmem_we & is_uart_access),
        .wdata    (core_dmem_wdata[31:0]),
        .rdata    (uart_rdata),
        .uart_tx  (uart_tx_sig),
        .uart_rx  (uart_rx),
        .tx_irq   (uart_tx_irq),
        .rx_irq   (uart_rx_irq)
    );

    // =========================================================================
    // PLIC - at 0xC010_0000 (4 KB window, 12-bit internal offset)
    // Source map:
    //   src[1] = UART RX interrupt (uart_rx_irq / rx_irq)
    //   src[2] = UART TX interrupt (uart_tx_irq / tx_irq)
    //   src[3..8] = reserved for future peripherals
    // Context map:
    //   ext_irq[0] = Machine-mode external interrupt -> rv_core.ext_irq
    //   ext_irq[1] = Supervisor-mode external interrupt (future use)
    // =========================================================================
    rv_plic #(
        .NSRC      (8),
        .NCTX      (2),
        .PRIO_BITS (3)
    ) u_plic (
        .clk      (clk),
        .rst_n    (rst_n),
        .addr     (mmu_dmem_pa[11:0]),
        .req      (mmu_dmem_req & is_plic_access),
        .we       (mmu_dmem_we  & is_plic_access),
        .wdata    (core_dmem_wdata[31:0]),
        .rdata    (plic_rdata),
        .src_irq  ({5'b0, gpio_irq, uart_tx_irq, uart_rx_irq}), // [8:1], src1=RX, src2=TX, src3=GPIO
        .ext_irq  (plic_ext_irq)
    );

    // =========================================================================
    // GPIO - at 0xC002_0000 (16-byte window)
    // OUT(0x00) / IN(0x04) / DIR(0x08) / IRQ_EN(0x0C)
    // Zybo Z7-20: gpio_out[3:0]=led[3:0], gpio_in[3:0]=sw[3:0]
    // IRQ -> PLIC src[3]
    // =========================================================================
    rv_gpio #(.WIDTH(4)) u_gpio (
        .clk      (clk),
        .rst_n    (rst_n),
        .addr     (mmu_dmem_pa[3:0]),
        .req      (mmu_dmem_req & is_gpio_access),
        .we       (mmu_dmem_we  & is_gpio_access),
        .wdata    (core_dmem_wdata[31:0]),
        .rdata    (gpio_rdata),
        .gpio_in  (gpio_in),
        .gpio_out (gpio_out),
        .irq      (gpio_irq)
    );

    // =========================================================================
    // UART output connection
    // =========================================================================
    assign uart_tx = uart_tx_sig;

endmodule

`default_nettype wire
