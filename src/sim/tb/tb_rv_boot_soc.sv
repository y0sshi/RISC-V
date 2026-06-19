// =============================================================================
// tb_rv_boot_soc.sv - OpenSBI-style boot harness over a SHARED DDR image
// =============================================================================
// Boots a firmware image (the mini-SBI stand-in, or a real OpenSBI fw_payload)
// on rv_soc with I/D caches enabled, where instructions, data and page tables
// all live in ONE shared DDR (rv_axi_dualport_mem_bfm) -- the sim analogue of
// the board's single PS DDR reached via an AXI SmartConnect.
//
// The firmware is loaded by the BFM via $readmemh from BOOT_HEX (objcopy -O
// verilog with --adjust-vma=-BASE so addresses are base-relative).  The UART TX
// line is deserialized (8N1) and echoed to the console; completion is detected
// by the firmware storing a sentinel word to TOHOST.
//
//   make sim_boot                       (default firmware: src/software/boot)
//   make sim_boot BOOT_HEX=path/to.hex  (e.g. a real OpenSBI fw_payload hex)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

`ifndef BOOT_HEX
  `define BOOT_HEX "../software/boot/sbi_boot.hex"
`endif

module tb_rv_boot_soc;

    import rv_pkg::*;
    localparam int XLEN = rv_pkg::XLEN;
    localparam int IDW  = 4;
    // Shared-DDR base = RST_ADDR = BFM BASE_ADDR.  Defaults to the sim base
    // 0x8000_0000; override with -DBOOT_MEM_BASE=<decimal> to mirror a re-linked
    // firmware (e.g. 2097152 = 0x0020_0000 for the Zybo PS-DDR boot sanity check).
    // Decimal avoids quoting a 64'h literal on the Verilator command line.
`ifdef BOOT_MEM_BASE
    localparam logic [63:0] MEM_BASE = `BOOT_MEM_BASE;
`else
    localparam logic [63:0] MEM_BASE = 64'h8000_0000;
`endif

    // NS16550 16x oversampling: bit period = 16 * divisor.  Pick CLK so the
    // default divisor = CLK/(16*BAUD) = 1 -> 16 clocks/bit (small, fast sim).
    localparam int CLKF   = 1_843_200;              // = 16 * 115200
    localparam int BAUD   = 115_200;
    localparam int BITCLK = CLKF / BAUD;            // clocks per bit (= 16)

    localparam int TOHOST_OFF = 32'h2000;           // TOHOST - MEM_BASE
    localparam logic [31:0] DONE_MAGIC = 32'h00C0_FFEE;
    localparam logic [31:0] FAIL_MAGIC = 32'h0BAD_BAD0;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---- data master <-> BFM data port ----
    logic [IDW-1:0]  awid;  logic [XLEN-1:0] awaddr; logic [7:0] awlen;
    logic [2:0] awsize; logic [1:0] awburst; logic awvalid,awready;
    logic [XLEN-1:0] wdata; logic [XLEN/8-1:0] wstrb; logic wlast,wvalid,wready;
    logic [IDW-1:0] bid; logic [1:0] bresp; logic bvalid,bready;
    logic [IDW-1:0] arid; logic [XLEN-1:0] araddr; logic [7:0] arlen;
    logic [2:0] arsize; logic [1:0] arburst; logic arvalid,arready;
    logic [IDW-1:0] rid; logic [XLEN-1:0] rdata; logic [1:0] rresp;
    logic rlast,rvalid,rready;
    // ---- IF master <-> BFM instruction port ----
    logic [IDW-1:0] i_awid; logic [XLEN-1:0] i_awaddr; logic [7:0] i_awlen;
    logic [2:0] i_awsize; logic [1:0] i_awburst; logic i_awvalid,i_awready;
    logic [31:0] i_wdata; logic [3:0] i_wstrb; logic i_wlast,i_wvalid,i_wready;
    logic [IDW-1:0] i_bid; logic [1:0] i_bresp; logic i_bvalid,i_bready;
    logic [IDW-1:0] i_arid; logic [XLEN-1:0] i_araddr; logic [7:0] i_arlen;
    logic [2:0] i_arsize; logic [1:0] i_arburst; logic i_arvalid,i_arready;
    logic [IDW-1:0] i_rid; logic [31:0] i_rdata; logic [1:0] i_rresp;
    logic i_rlast,i_rvalid,i_rready;

    logic uart_tx;
    logic [3:0] gpio_out_w;

`ifdef BOOT_NO_ICACHE
    localparam bit ICEN = 1'b0;
`else
    localparam bit ICEN = 1'b1;
`endif
`ifdef BOOT_NO_DCACHE
    localparam bit DCEN = 1'b0;
`else
    localparam bit DCEN = 1'b1;
`endif
// 16 KiB L1 caches (512 sets x 32 B) by default.  A real Linux-capable SoC has
// >= 16 KiB L1; the larger D$ cuts OpenSBI's DDR data reads ~4x (e.g. 1640 -> 411
// over the first 3M cycles) and lets a full OpenSBI boot complete in ~8M cycles.
// (Cache transparency is proven by sim_cache_soc.)  Override per-run if needed.
`ifndef BOOT_ICACHE_SETS
  `define BOOT_ICACHE_SETS 512
`endif
`ifndef BOOT_DCACHE_SETS
  `define BOOT_DCACHE_SETS 512
`endif
// CLINT mtime prescaler: 1 = mtime +1/cycle (a "1 MHz" CPU vs the 1 MHz DT
// timebase -- the 250 Hz Linux periodic tick then fires every 4000 cycles and
// its handler costs more than that, livelocking tick_handle_periodic catch-up).
// Linux boots should use BOOT_MTIME_DIV=64 (a 64 MHz core, tick every 256k cy).
`ifndef BOOT_MTIME_DIV
  `define BOOT_MTIME_DIV 1
`endif
    rv_soc #(.XLEN(XLEN), .RST_ADDR(MEM_BASE), .AXI_ID_WIDTH(IDW),
             .CLK_FREQ(CLKF), .BAUD_RATE(BAUD),
             .ICACHE_EN(ICEN), .DCACHE_EN(DCEN),
             .MTIME_DIV(`BOOT_MTIME_DIV),
             .ICACHE_SETS(`BOOT_ICACHE_SETS), .DCACHE_SETS(`BOOT_DCACHE_SETS)) u_soc (
        .clk(clk), .rst_n(rst_n), .gpio_in(4'b0), .gpio_out(gpio_out_w),
        .uart_rx(1'b1), .uart_tx(uart_tx),
        .m_axi_awid(awid),.m_axi_awaddr(awaddr),.m_axi_awlen(awlen),.m_axi_awsize(awsize),
        .m_axi_awburst(awburst),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wlast(wlast),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bid(bid),.m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
        .m_axi_arid(arid),.m_axi_araddr(araddr),.m_axi_arlen(arlen),.m_axi_arsize(arsize),
        .m_axi_arburst(arburst),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rid(rid),.m_axi_rdata(rdata),.m_axi_rresp(rresp),.m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready),
        .m_axi_if_awid(i_awid),.m_axi_if_awaddr(i_awaddr),.m_axi_if_awlen(i_awlen),.m_axi_if_awsize(i_awsize),
        .m_axi_if_awburst(i_awburst),.m_axi_if_awvalid(i_awvalid),.m_axi_if_awready(i_awready),
        .m_axi_if_wdata(i_wdata),.m_axi_if_wstrb(i_wstrb),.m_axi_if_wlast(i_wlast),.m_axi_if_wvalid(i_wvalid),.m_axi_if_wready(i_wready),
        .m_axi_if_bid(i_bid),.m_axi_if_bresp(i_bresp),.m_axi_if_bvalid(i_bvalid),.m_axi_if_bready(i_bready),
        .m_axi_if_arid(i_arid),.m_axi_if_araddr(i_araddr),.m_axi_if_arlen(i_arlen),.m_axi_if_arsize(i_arsize),
        .m_axi_if_arburst(i_arburst),.m_axi_if_arvalid(i_arvalid),.m_axi_if_arready(i_arready),
        .m_axi_if_rid(i_rid),.m_axi_if_rdata(i_rdata),.m_axi_if_rresp(i_rresp),.m_axi_if_rlast(i_rlast),.m_axi_if_rvalid(i_rvalid),.m_axi_if_rready(i_rready)
    );

    // AXI latency (cycles).  Low for the large OpenSBI image to keep sim time down.
    // Overridable at compile time to emulate real-HW DDR/SmartConnect latency:
    // -DBOOT_AR_DELAY=<n> (read addr->data lead), -DBOOT_R_DELAY=<n> (extra beat
    // latency), -DBOOT_AW/W/B_DELAY for writes.  Default 0 = strict no-op (the
    // proven baseline).  Used to widen the imem_ready/dmem_wait stall windows that
    // mask variable-latency atomic/LR-SC races on bare BRAM-like (0-delay) memory.
`ifndef BOOT_AR_DELAY
  `define BOOT_AR_DELAY 0
`endif
`ifndef BOOT_R_DELAY
  `define BOOT_R_DELAY 0
`endif
`ifndef BOOT_AW_DELAY
  `define BOOT_AW_DELAY 0
`endif
`ifndef BOOT_W_DELAY
  `define BOOT_W_DELAY 0
`endif
`ifndef BOOT_B_DELAY
  `define BOOT_B_DELAY 0
`endif
    logic [7:0] ard=8'd`BOOT_AR_DELAY, rd_=8'd`BOOT_R_DELAY, awd=8'd`BOOT_AW_DELAY,
                wd=8'd`BOOT_W_DELAY, bd=8'd`BOOT_B_DELAY;

    // 64 MiB shared DDR image.  Must cover OpenSBI firmware + payload (2 MiB
    // offset) AND the FDT relocation target (~0x8220_0000 = 34 MiB), which the
    // embedded DTB's 256 MiB /memory node lets OpenSBI pick.  8 MiB was too
    // small -> loads from the relocated FDT returned X (see docs/opensbi_sim.md).
    rv_axi_dualport_mem_bfm #(.ADDR_WIDTH(XLEN), .XLEN(XLEN), .ID_WIDTH(IDW),
                              .DEPTH(1<<26), .BASE_ADDR(MEM_BASE),
                              .INIT_FILE(`BOOT_HEX)) u_bfm (
        .clk(clk), .rst_n(rst_n),
        .ar_delay(ard), .r_delay(rd_), .aw_delay(awd), .w_delay(wd), .b_delay(bd),
        .d_awid(awid),.d_awaddr(awaddr),.d_awlen(awlen),.d_awsize(awsize),.d_awburst(awburst),
        .d_awvalid(awvalid),.d_awready(awready),
        .d_wdata(wdata),.d_wstrb(wstrb),.d_wlast(wlast),.d_wvalid(wvalid),.d_wready(wready),
        .d_bid(bid),.d_bresp(bresp),.d_bvalid(bvalid),.d_bready(bready),
        .d_arid(arid),.d_araddr(araddr),.d_arlen(arlen),.d_arsize(arsize),.d_arburst(arburst),
        .d_arvalid(arvalid),.d_arready(arready),
        .d_rid(rid),.d_rdata(rdata),.d_rresp(rresp),.d_rlast(rlast),.d_rvalid(rvalid),.d_rready(rready),
        .i_arid(i_arid),.i_araddr(i_araddr),.i_arlen(i_arlen),.i_arsize(i_arsize),.i_arburst(i_arburst),
        .i_arvalid(i_arvalid),.i_arready(i_arready),
        .i_rid(i_rid),.i_rdata(i_rdata),.i_rresp(i_rresp),.i_rlast(i_rlast),.i_rvalid(i_rvalid),.i_rready(i_rready)
    );

    // ---- 8N1 UART receiver: deserialize uart_tx, echo to console ----
    integer nchars = 0;
    logic [7:0] ch; integer bi;
    initial begin
        forever begin
            @(negedge uart_tx);                          // start bit
            repeat (BITCLK + BITCLK/2) @(posedge clk);   // -> middle of bit0
            ch = 8'd0;
            for (bi = 0; bi < 8; bi = bi + 1) begin
                ch[bi] = uart_tx;
                repeat (BITCLK) @(posedge clk);
            end
            $write("%c", ch);
            nchars = nchars + 1;
        end
    end

    function automatic logic [31:0] sentinel();
        return {u_bfm.mem_b[TOHOST_OFF+3], u_bfm.mem_b[TOHOST_OFF+2],
                u_bfm.mem_b[TOHOST_OFF+1], u_bfm.mem_b[TOHOST_OFF+0]};
    endfunction

    // Read a 32-bit word at a base-relative byte offset (always available, for
    // failure-context discriminators a focused test leaves near TOHOST).
    function automatic logic [31:0] peek(input int off);
        return {u_bfm.mem_b[off+3], u_bfm.mem_b[off+2],
                u_bfm.mem_b[off+1], u_bfm.mem_b[off+0]};
    endfunction

    // ---- In-context divide-result checker (C-2a regression hunt) -------------
    // At each integer-divide retire, recompute the golden result from the live
    // forwarded operands and compare to the multi-cycle divider output.  Catches
    // any divide whose result is wrong in the real Linux pipeline context
    // (operand mismatch, mis-capture, etc.) that the unit/random tests miss.
    import rv_pkg::*;
    localparam int CKW = 64;
    function automatic logic [CKW-1:0] dgolden(input muldiv_op_t o,
                                               input logic [CKW-1:0] a, b);
        logic dz, dzw, ov, ovw;
        dz = (b=='0); dzw = (b[31:0]=='0);
        ov  = (a=={1'b1,{(CKW-1){1'b0}}}) && (b=='1);
        ovw = (a[31:0]==32'h8000_0000) && (b[31:0]==32'hFFFF_FFFF);
        unique case (o)
          MDU_DIV:  dgolden = dz?'1 : ov?a : CKW'($signed(a)/$signed(b));
          MDU_DIVU: dgolden = dz?'1 : a/b;
          MDU_REM:  dgolden = dz?a  : ov?'0 : CKW'($signed(a)%$signed(b));
          MDU_REMU: dgolden = dz?a  : a%b;
          MDU_DIVW: dgolden = dzw?'1 : ovw?CKW'($signed(32'h8000_0000))
                            : CKW'($signed($signed(a[31:0])/$signed(b[31:0])));
          MDU_DIVUW:dgolden = dzw?'1 : CKW'($signed(a[31:0]/b[31:0]));
          MDU_REMW: dgolden = dzw?CKW'($signed(a[31:0])) : ovw?'0
                            : CKW'($signed($signed(a[31:0])%$signed(b[31:0])));
          MDU_REMUW:dgolden = dzw?CKW'($signed(a[31:0])) : CKW'($signed(a[31:0]%b[31:0]));
          default:  dgolden = 'x;
        endcase
    endfunction

`ifdef BOOT_DIVCHK
    integer div_check_fails = 0;
    always @(posedge clk) if (rst_n) begin : div_chk
        automatic logic is_d;
        is_d = u_soc.u_cpu.u_core.id_ex_ctrl.is_muldiv
               && u_soc.u_cpu.u_core.muldiv_is_divide
               && u_soc.u_cpu.u_core.id_ex_valid
               && !u_soc.u_cpu.u_core.muldiv_busy_int
               && !u_soc.u_cpu.u_core.muldiv_start_stall
               && !u_soc.u_cpu.u_core.stall_ex;   // divide retiring this cycle
        if (is_d) begin
            automatic logic [63:0] g, got;
            g   = dgolden(u_soc.u_cpu.u_core.id_ex_ctrl.muldiv_op,
                          u_soc.u_cpu.u_core.fwd_rs1_data,
                          u_soc.u_cpu.u_core.fwd_rs2_data);
            got = u_soc.u_cpu.u_core.muldiv_result;
            if (got !== g) begin
                div_check_fails = div_check_fails + 1;
                if (div_check_fails <= 30)
                    $display("[DIVCHK @%0t] MISMATCH pc=%h op=%0d a=%h b=%h got=%h exp=%h",
                        $time, u_soc.u_cpu.u_core.id_ex_pc,
                        u_soc.u_cpu.u_core.id_ex_ctrl.muldiv_op,
                        u_soc.u_cpu.u_core.fwd_rs1_data,
                        u_soc.u_cpu.u_core.fwd_rs2_data, got, g);
            end
        end
    end
`endif

    // diagnostics
    integer if_ar = 0, d_ar = 0;
    integer nvpe = 0;        // TEMP-DIAG vprintk_emit entry count (BOOT_TRACE only)
    always @(posedge clk) if (rst_n) begin
        if (i_arvalid & i_arready) if_ar = if_ar + 1;
        if (arvalid   & arready  ) d_ar  = d_ar  + 1;
    end

    // ---- P0-5 interrupt-delivery chain diagnostics (always-on, cheap) --------
    // Pinpoints where the 8250-TX / PLIC-S-context / SEIP chain breaks when a
    // userspace tty write() never flushes.  All sticky flags + edge counters,
    // reported at every 1M-cycle progress line and at the final summary.
    integer n_seip = 0, n_meip = 0, n_stip = 0;
    logic   ever_extirq1 = 0, ever_extirq0 = 0, ever_uirq = 0, ever_ier1 = 0;
    logic   ever_en1 = 0, ever_pend1 = 0;
    logic   itr_d = 0;
    // ---- PTW-mask hazard detector (netlink atomic_dec loss; rv_soc.sv:364) ----
    // core_dmem_wait = ptw_req ? 0 : dc_c_wait masks an IN-FLIGHT D$ access (load
    // miss fill / write-through) whenever ANY ptw_req is asserted -- including an
    // INSTRUCTION-fetch PTW (ptw_for_if) that is independent of the held data
    // access.  When an IF-PTW masks a real dc_c_wait, the held AMO/load/store can
    // advance before its D$ access completes -> lost AMO write (counter stuck at
    // the pre-decrement value) / stale load.  Pure observation (no DUT effect):
    // count cycles where an IF-PTW is actively masking a real D$ wait.
    longint unsigned ptwmask_cyc = 0;   // dc_c_wait & ptw_req (any: window hit)
    longint unsigned ptwmask_if  = 0;   // dc_c_wait & ptw_req & ptw_for_if
    longint unsigned ptwmask_adv = 0;   // dc_c_wait & !stall_ex (TRUE harm:
                                        // a data op leaves MEM while the D$ still
                                        // has its access in flight = lost/stale)
    // Smoking gun for the netlink AMO write-loss: amo_state==1 (WRITE phase)
    // while the D$ is still in S_FILL (the READ-miss line fill).  Only the
    // ptw_req dmem_wait mask (rv_soc.sv:364) can advance amo_state during the
    // fill; the AMO then retires at the S_RELOOKUP cycle (c_wait drops) BEFORE
    // S_LOOKUP latches the write -> the AMO write is lost.  Must be 0 post-fix.
    longint unsigned amo_prem = 0;
    always @(posedge clk) if (rst_n) begin
        if (u_soc.plic_ext_irq[1])            ever_extirq1 <= 1'b1;
        if (u_soc.plic_ext_irq[0])            ever_extirq0 <= 1'b1;
        if (u_soc.u_periph.u_uart.rx_irq)     ever_uirq    <= 1'b1;  // combined UART IRQ line
        if (u_soc.u_periph.u_uart.ier[1])     ever_ier1    <= 1'b1;  // THRI (TX int) enabled by driver
        if (|u_soc.u_periph.u_plic.enable1)   ever_en1     <= 1'b1;  // S-context source enabled
        if (|u_soc.u_periph.u_plic.pending)   ever_pend1   <= 1'b1;  // any PLIC source pended
        // Count interrupt traps on the committed-trap edge (cause MSB set).
        itr_d <= u_soc.u_cpu.u_core.csr_trap_enter & u_soc.u_cpu.u_core.csr_commit_ex;
        if ((u_soc.u_cpu.u_core.csr_trap_enter & u_soc.u_cpu.u_core.csr_commit_ex)
            && !itr_d && u_soc.u_cpu.u_core.csr_trap_cause[XLEN-1]) begin
            case (u_soc.u_cpu.u_core.csr_trap_cause[3:0])
                4'd9:  n_seip <= n_seip + 1;
                4'd11: n_meip <= n_meip + 1;
                4'd5:  n_stip <= n_stip + 1;
                default: ;
            endcase
        end
`ifndef BOOT_NO_DCACHE
        if (u_soc.gen_dcache.u_dc.c_wait && u_soc.ptw_req) begin
            ptwmask_cyc <= ptwmask_cyc + 1;
            if (u_soc.u_cpu.u_mmu.ptw_for_if) ptwmask_if <= ptwmask_if + 1;
        end
        // TRUE harm: the D$ still has an access in flight (c_wait) yet the core
        // is NOT stalling EX -> the held data op (AMO/load/store) is retiring
        // before its D$ access completes.  Only reachable because core_dmem_wait
        // was masked to 0 by ptw_req (rv_soc.sv:364).
        if (u_soc.gen_dcache.u_dc.c_wait && !u_soc.u_cpu.u_core.stall_ex)
            ptwmask_adv <= ptwmask_adv + 1;
        // amo_state in WRITE phase while the D$ is still in S_FILL = premature
        // advance (the write will be lost when the AMO retires at S_RELOOKUP).
        if (u_soc.u_cpu.u_core.amo_state && (u_soc.gen_dcache.u_dc.state == 3'd2))
            amo_prem <= amo_prem + 1;
`endif
    end

`ifdef MTIME_INSTR
    // ===== Entropy-determinism harness (HW-bug vs RNG-roulette discriminator) =====
    // Override the CLINT mtime with a RETIRED-INSTRUCTION counter (>> 6, i.e. an
    // instruction-based 1/64 prescaler) so rdtime (kernel get_cycles entropy) AND
    // timer-interrupt instants become a function of ARCHITECTURAL progress, not
    // cycles.  A baseline (single-cycle divide) and a C-2a (multi-cycle divide)
    // run then see IDENTICAL mtime at the same retired instruction, so they must
    // execute identically unless a real (cycle-level) HW bug perturbs data.
    // retire_en = mem_wb_valid & csr_commit (the exact minstret increment).
    longint unsigned arch_clk = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) arch_clk <= 0;
        else if (u_soc.u_cpu.u_core.mem_wb_valid && u_soc.u_cpu.u_core.csr_commit)
            arch_clk <= arch_clk + 1;
    end
    // Re-drive the override every cycle (force holds until re-evaluated).
    always @(posedge clk)
        force u_soc.u_periph.u_timer.gen_bus64.mtime = (arch_clk >> 6);
    // Also neutralize rdcycle (CSR_CYCLE returns mcycle_cnt, +1/cycle): pin it to
    // the retired-instruction count so ANY cycle-based entropy the kernel might
    // read becomes instruction-based & identical across baseline/C-2a too.
    always @(posedge clk)
        force u_soc.u_cpu.u_core.u_csr.mcycle_cnt = u_soc.u_cpu.u_core.u_csr.minstret_cnt;
`endif

`ifdef BOOT_TRACE
    // --- divergence trace: ring buffer of distinct fetch_pc, dumped on first X ---
    integer tcyc = 0, rh = 0, rwh = 0, i;
    logic seen_x = 0;
    logic seen_hang = 0;
    logic seen_run = 0;
    logic [XLEN-1:0] prev_pc = 64'hFFFF_FFFF_FFFF_FFFF;
    logic [XLEN-1:0] ring_pc [0:63];
    integer          ring_cy [0:63];
    logic [4:0]      ring_rd [0:63];
    logic [XLEN-1:0] ring_rdat [0:63];
    integer          ring_rcy [0:63];
    // data-access ring (completion cycle), 256 deep, with load result + mal flag
    integer          dh = 0;
    logic [XLEN-1:0] ring_da [0:255];
    logic [XLEN-1:0] ring_dw [0:255];   // store wdata, or (for loads) the rdata result
    logic            ring_dwe [0:255];
    logic            ring_dmal [0:255];
    integer          ring_dcy [0:255];
    logic            pend_ld = 0;
    integer          pend_idx = 0;
    integer          nlot = 0;
    logic            lpend = 0;
    // duplicate EX->MEM capture detector
    integer          ndup = 0;
    logic [XLEN-1:0] last_exmem_pc = 64'hFFFF_FFFF_FFFF_FFFF;
    integer nmis = 0;
    integer nipa = 0;
    integer npw  = 0;
    integer ncsr = 0;        // sscratch/satp/stvec CSR-write monitor cap
    integer ntp  = 0;        // tp (x4) writeback monitor cap
    integer nud  = 0;        // udelay-entry probe cap
    integer ntm  = 0;        // timer-path probe cap
    integer nrc  = 0;        // refcount_warn_saturate probe cap
`ifndef BOOT_PTWLO
  `define BOOT_PTWLO 0
`endif
`ifndef BOOT_WATCH_PA
  `define BOOT_WATCH_PA 64'h0
`endif
    function automatic logic [31:0] mem_win(input [XLEN-1:0] pa);
        logic [63:0] o; o = pa - MEM_BASE;
        return {u_bfm.mem_b[o+3], u_bfm.mem_b[o+2], u_bfm.mem_b[o+1], u_bfm.mem_b[o+0]};
    endfunction
    // 64-bit aligned DDR window (the 8-byte word containing pa), for D-load checks.
    function automatic logic [63:0] mem_win64(input [XLEN-1:0] pa);
        logic [63:0] o; o = (pa - MEM_BASE) & ~64'h7;
        return {u_bfm.mem_b[o+7], u_bfm.mem_b[o+6], u_bfm.mem_b[o+5], u_bfm.mem_b[o+4],
                u_bfm.mem_b[o+3], u_bfm.mem_b[o+2], u_bfm.mem_b[o+1], u_bfm.mem_b[o+0]};
    endfunction
    // Software Sv39 page-table walk over the shared DDR (diagnostic): prints each
    // level's PTE + permission bits for a VA, to see why a fault was raised.
    task automatic ptwalk(input [63:0] va);
        logic [63:0] satp_v, base, pte; integer i; logic [8:0] vpn;
        begin
            satp_v = u_soc.u_cpu.satp_out;
            base   = (satp_v & 64'hFFF_FFFF_FFFF) << 12;
            $display("  [ptwalk va=%h satp=%h]", va, satp_v);
            for (i = 2; i >= 0; i = i - 1) begin
                vpn = va[12 + i*9 +: 9];
                pte = mem_win64(base + vpn*8);
                $display("    L%0d idx=%0d @%h pte=%h V=%b R=%b W=%b X=%b U=%b A=%b D=%b",
                         i, vpn, base + vpn*8, pte, pte[0], pte[1], pte[2], pte[3],
                         pte[4], pte[6], pte[7]);
                if (!pte[0]) begin $display("    -> NOT VALID"); i = -1; end
                else if (pte[1] || pte[3]) begin $display("    -> LEAF"); i = -1; end
                else base = (pte[53:10]) << 12;
            end
        end
    endtask
    // --- D-load-vs-DDR correctness check (decisive: catches a load whose data the
    // core actually USES (dmem_eff) diverges from the shared-DDR word). Valid only
    // while satp=0 (VA==PA, early M-mode boot) and for cacheable DDR (>= MEM_BASE).
    // ld_chk pends a compare to the load's FRESH WB cycle. ---
    integer ndld = 0;
    logic            ld_chk   = 1'b0;
    logic [XLEN-1:0] ld_addr  = '0;
    logic [XLEN-1:0] ld_pc    = '0;
    // --- forwarded-operand-vs-regfile check (catches fix#1-family forward bug):
    // when a load/store commits (advances EX->MEM), its forwarded base (rs1) / store
    // data (rs2) must equal the architectural regfile value WHENEVER that source reg
    // is "stable" (not being written by the in-flight EX/MEM or MEM/WB instr).  A
    // mismatch means forwarding fed a wrong value while the regfile holds the right
    // one -- the exact store-addr/store-data corruption we hunt. ---
    integer nfwd = 0;
    // callee-saved + sp/ra: the regs spilled/restored in prologues (stable).
    function automatic logic stable_reg(input [4:0] r);
        // x1(ra),x2(sp),x8(s0),x9(s1),x18..x27(s2..s11)
        return (r==5'd1)||(r==5'd2)||(r==5'd8)||(r==5'd9)||(r>=5'd18 && r<=5'd27);
    endfunction
    always @(posedge clk) if (rst_n) begin
        tcyc <= tcyc + 1;
`ifdef BOOT_CTRPROBE
        // Focused probe: every D$ access (and AMO state) touching the watched
        // line (BOOT_WATCH_PA), to localize a stale amoadd read.
`ifndef BOOT_NO_DCACHE
        if (u_soc.gen_dcache.u_dc.c_req
            && (u_soc.gen_dcache.u_dc.c_addr[31:5] == (`BOOT_WATCH_PA >> 5)))
            $display("[CTR c%0d] dcst=%0d we=%b hit=%b cwait=%b mdone=%b mrv=%b rdq=%016h cwd=%016h | amo_st=%b amo_sl=%b exmpc=%h imrdy=%b sex=%b",
                tcyc, u_soc.gen_dcache.u_dc.state, u_soc.gen_dcache.u_dc.c_we,
                u_soc.gen_dcache.u_dc.hit, u_soc.gen_dcache.u_dc.c_wait,
                u_soc.gen_dcache.u_dc.m_done, u_soc.gen_dcache.u_dc.m_rvalid,
                u_soc.gen_dcache.u_dc.rdata_q, u_soc.gen_dcache.u_dc.c_wdata,
                u_soc.u_cpu.u_core.amo_state, u_soc.u_cpu.u_core.amo_stall,
                u_soc.u_cpu.u_core.ex_mem_pc, u_soc.imem_ready,
                u_soc.u_cpu.u_core.stall_ex);
`endif
`endif
`ifdef BOOT_DCWIN
        // IF AXI channel state in the wedge window (why does a fill never finish?).
        if (tcyc >= `BOOT_DCWIN && tcyc <= `BOOT_DCWIN + 160)
            $display("   [IFAXI c%0d] brst=%0d arv=%b arr=%b araddr=%h arlen=%0d rv=%b rr=%b rlast=%b s_req=%b s_done=%b s_busy=%b",
                tcyc, u_soc.gen_icache.u_axi_if.state,
                i_arvalid, i_arready, i_araddr, i_arlen,
                i_rvalid, i_rready, i_rlast,
                u_soc.gen_icache.ic_m_req, u_soc.gen_icache.ic_m_done,
                u_soc.gen_icache.ic_m_busy);
        // All pipeline stall sources per cycle (wedge/livelock dissection).
        if (tcyc >= `BOOT_DCWIN && tcyc <= `BOOT_DCWIN + 160)
            $display("[STALL c%0d] sif=%b sid=%b sex=%b | imrdy=%b dwait=%b amo=%b mal=%b mems=%b mmus=%b fpub=%b fpus=%b mdb=%b mds=%b luh=%b rds=%b | idexpc=%h idexv=%b mret=%b fpc=%h iaddr=%h | ic_st=%0d c_req=%b c_rdy=%b aq=%h mreq=%b mdone=%b ifpa=%h ifreq=%b priv=%0d",
                tcyc, u_soc.u_cpu.u_core.stall_if, u_soc.u_cpu.u_core.stall_id,
                u_soc.u_cpu.u_core.stall_ex,
                u_soc.imem_ready, u_soc.core_dmem_wait,
                u_soc.u_cpu.u_core.amo_stall, u_soc.u_cpu.u_core.mal_stall,
                u_soc.u_cpu.u_core.mem_stall, u_soc.u_cpu.u_core.mmu_stall,
                u_soc.u_cpu.u_core.fpu_busy_int, u_soc.u_cpu.u_core.fpu_start_stall,
                u_soc.u_cpu.u_core.muldiv_busy_int, u_soc.u_cpu.u_core.muldiv_start_stall,
                u_soc.u_cpu.u_core.load_use_hazard, u_soc.u_cpu.u_core.redirect_stall,
                u_soc.u_cpu.u_core.id_ex_pc, u_soc.u_cpu.u_core.id_ex_valid,
                u_soc.u_cpu.u_core.ex_mret_en,
                u_soc.u_cpu.u_core.fetch_pc, u_soc.u_cpu.u_core.imem_addr,
                u_soc.gen_icache.u_ic.state, u_soc.gen_icache.u_ic.c_req,
                u_soc.gen_icache.u_ic.c_ready, u_soc.gen_icache.u_ic.addr_q,
                u_soc.gen_icache.u_ic.m_req, u_soc.gen_icache.u_ic.m_done,
                u_soc.u_cpu.mmu_imem_pa, u_soc.u_cpu.mmu_imem_req,
                u_soc.u_cpu.priv_out);
        // Cycle-by-cycle D-cache + core MEM/WB state around a target cycle, to see
        // why a load's rdata_q goes stale / byte_offset desyncs under IF latency.
        if (tcyc >= `BOOT_DCWIN && tcyc <= `BOOT_DCWIN + 160)
            $display("[dc c%0d] st=%0d creq=%b cwe=%b caddr=%h hit=%b cwait=%b mdone=%b mrv=%b rdq=%h cwd=%h | imrdy=%b sex=%b dwait=%b memrd=%b exmpc=%h exmpa=%h va=%h exmv=%b mwv=%b fresh=%b ddr@a=%h",
                tcyc, u_soc.gen_dcache.u_dc.state, u_soc.gen_dcache.u_dc.c_req,
                u_soc.gen_dcache.u_dc.c_we, u_soc.gen_dcache.u_dc.c_addr,
                u_soc.gen_dcache.u_dc.hit, u_soc.gen_dcache.u_dc.c_wait,
                u_soc.gen_dcache.u_dc.m_done, u_soc.gen_dcache.u_dc.m_rvalid,
                u_soc.gen_dcache.u_dc.rdata_q, u_soc.gen_dcache.u_dc.c_wdata,
                u_soc.imem_ready, u_soc.u_cpu.u_core.stall_ex, u_soc.core_dmem_wait,
                u_soc.u_cpu.u_core.ex_mem_ctrl.mem_read, u_soc.u_cpu.u_core.ex_mem_pc,
                u_soc.mmu_dmem_pa, u_soc.u_cpu.u_core.ex_mem_alu_result,
                u_soc.u_cpu.u_core.ex_mem_valid, u_soc.u_cpu.u_core.mem_wb_valid,
                u_soc.u_cpu.u_core.mem_wb_fresh,
                ((^u_soc.mmu_dmem_pa !== 1'bx && u_soc.mmu_dmem_pa >= MEM_BASE)
                    ? mem_win64(u_soc.mmu_dmem_pa) : 64'hX));
        // CSR internals in-window: catch a csrrw to mscratch whose CSR-write may be
        // dropped by a concurrent trap/mret (else-if priority) or IF-freeze gate.
        if (tcyc >= `BOOT_DCWIN && tcyc <= `BOOT_DCWIN + 100
            && u_soc.u_cpu.u_core.id_ex_valid
            && u_soc.u_cpu.u_core.id_ex_ctrl.csr_write
            && u_soc.u_cpu.u_core.id_ex_csr_addr == 12'h340)
            $display("   [MSCR c%0d] pc=%h op=%b wdata=%h rdata_ex=%h | imrdy=%b sex=%b te=%b mte=%b mret=%b sret=%b ifpf=%b csr_we=%b mscr_reg=%h",
                tcyc, u_soc.u_cpu.u_core.id_ex_pc, u_soc.u_cpu.u_core.id_ex_funct3,
                u_soc.u_cpu.u_core.ex_csr_wdata, u_soc.u_cpu.u_core.csr_rdata_ex,
                u_soc.imem_ready, u_soc.u_cpu.u_core.stall_ex,
                u_soc.u_cpu.u_core.ex_trap_enter, u_soc.u_cpu.u_core.mem_trap_enter,
                u_soc.u_cpu.u_core.ex_mret_en, u_soc.u_cpu.u_core.ex_sret_en,
                u_soc.u_cpu.u_core.ifpf_take, u_soc.u_cpu.u_core.u_csr.csr_we,
                u_soc.u_cpu.u_core.u_csr.mscratch_reg);
        // Per-cycle mscratch_reg value (to see when/whether the 1st csrrw's write
        // lands and whether it is later clobbered).
        if (tcyc >= `BOOT_DCWIN && tcyc <= `BOOT_DCWIN + 100)
            $display("   [MSREG c%0d] mscratch_reg=%h exmpc=%h", tcyc,
                u_soc.u_cpu.u_core.u_csr.mscratch_reg, u_soc.u_cpu.u_core.ex_mem_pc);
`endif
`ifdef BOOT_CYCTRACE
        if (tcyc < 50)
            $display("[c%0d] fpc=%h ir=%b ird=%08h memwin=%08h sid=%b sex=%b idxpc=%h idxv=%b",
                tcyc, u_soc.u_cpu.u_core.fetch_pc, u_soc.imem_ready, u_soc.imem_rdata,
                (^u_soc.u_cpu.u_core.fetch_pc !== 1'bx && u_soc.u_cpu.u_core.fetch_pc >= MEM_BASE)
                    ? mem_win(u_soc.u_cpu.u_core.fetch_pc) : 32'hDEADDEAD,
                u_soc.u_cpu.u_core.stall_id, u_soc.u_cpu.u_core.stall_ex,
                u_soc.u_cpu.u_core.id_ex_pc, u_soc.u_cpu.u_core.id_ex_valid);
`endif
`ifdef BOOT_EXEC
`ifndef BOOT_EXEC_LO
  `define BOOT_EXEC_LO 0
`endif
`ifdef BOOT_IPROBE
      if (tcyc >= `BOOT_EXEC_LO && tcyc <= `BOOT_EXEC_LO + 40)
        $display("c%0d fpc=%h ifhit=%b iffault=%b | PTW st=%0d forif=%b faultr=%b | idexv=%b idexpc=%h exmemv=%b memwbv=%b sif=%b sid=%b sex=%b",
          tcyc, u_soc.u_cpu.u_core.fetch_pc,
          u_soc.u_cpu.u_mmu.if_tlb_hit, u_soc.u_cpu.u_mmu.if_fault,
          u_soc.u_cpu.u_mmu.ptw_state, u_soc.u_cpu.u_mmu.ptw_for_if,
          u_soc.u_cpu.u_mmu.ptw_fault_r,
          u_soc.u_cpu.u_core.id_ex_valid, u_soc.u_cpu.u_core.id_ex_pc,
          u_soc.u_cpu.u_core.ex_mem_valid, u_soc.u_cpu.u_core.mem_wb_valid,
          u_soc.u_cpu.u_core.stall_if, u_soc.u_cpu.u_core.stall_id,
          u_soc.u_cpu.u_core.stall_ex);
      if (tcyc == `BOOT_EXEC_LO) begin
        $display("[PTMEM] tramp[2]@81725010=%h tramp[511]@81725ff8=%h",
          mem_win64(64'h0000000081725010), mem_win64(64'h0000000081725ff8));
        $display("[PTMEM] early[2]@80e05010=%h early[511]@80e05ff8=%h",
          mem_win64(64'h0000000080e05010), mem_win64(64'h0000000080e05ff8));
        $display("[PTMEM] tramp0=%h tramp8=%h early0=%h early8=%h",
          mem_win64(64'h0000000081725000), mem_win64(64'h0000000081725008),
          mem_win64(64'h0000000080e05000), mem_win64(64'h0000000080e05008));
      end
`endif
      if (tcyc >= `BOOT_EXEC_LO) begin
        // Committed-instruction stream: every cycle EX/MEM advances capturing a
        // valid instruction (each architecturally-executed insn passes here once).
        if (!u_soc.u_cpu.u_core.flush_ex_mem && !u_soc.u_cpu.u_core.stall_ex
            && u_soc.u_cpu.u_core.id_ex_valid)
            $display("EXEC cy=%0d pc=%h inst=%08h", tcyc,
                u_soc.u_cpu.u_core.id_ex_pc, u_soc.u_cpu.u_core.id_ex_inst);
`ifdef BOOT_WIN
        if (tcyc >= `BOOT_WIN && tcyc <= `BOOT_WIN + 30)
            $display("c%0d fpc=%h rdy=%b sid=%b sex=%b fexm=%b fex=%b | EX pc=%h v=%b rs1=%0d rs1sel=%b rs1d=%h | EXMEM pc=%h rd=%0d v=%b fwd=%h | MEMWB rd=%0d v=%b wb=%h",
                tcyc, u_soc.u_cpu.u_core.fetch_pc, u_soc.imem_ready,
                u_soc.u_cpu.u_core.stall_id, u_soc.u_cpu.u_core.stall_ex,
                u_soc.u_cpu.u_core.flush_ex_mem, u_soc.u_cpu.u_core.flush_ex,
                u_soc.u_cpu.u_core.id_ex_pc, u_soc.u_cpu.u_core.id_ex_valid,
                u_soc.u_cpu.u_core.id_ex_rs1_addr, u_soc.u_cpu.u_core.fwd_rs1_sel,
                u_soc.u_cpu.u_core.fwd_rs1_data,
                u_soc.u_cpu.u_core.ex_mem_pc, u_soc.u_cpu.u_core.ex_mem_rd_addr,
                u_soc.u_cpu.u_core.ex_mem_valid, u_soc.u_cpu.u_core.ex_mem_fwd_data,
                u_soc.u_cpu.u_core.mem_wb_rd_addr, u_soc.u_cpu.u_core.mem_wb_valid,
                u_soc.u_cpu.u_core.wb_data);
`endif
        // Architectural register writeback (rd != x0).
        if (u_soc.u_cpu.u_core.wb_reg_write && u_soc.u_cpu.u_core.wb_rd_addr != 0)
            $display("   WB cy=%0d x%0d <= %h", tcyc,
                u_soc.u_cpu.u_core.wb_rd_addr, u_soc.u_cpu.u_core.wb_data);
        // Data memory access at completion (store: wdata; load: addr now, data next).
        if (u_soc.mmu_dmem_req && !u_soc.periph_is_periph && !u_soc.core_dmem_wait)
            $display("   MEM cy=%0d %s addr=%h wdata=%h", tcyc,
                u_soc.core_dmem_we ? "ST" : "LD", u_soc.mmu_dmem_pa,
                u_soc.core_dmem_wdata);
      end
`endif
        // Detect EX->MEM capturing the SAME instruction twice in a row (duplicate
        // execution): EX/MEM advances (!stall_ex, !flush_ex_mem) capturing id_ex,
        // but id_ex was HELD (stall_id) without a bubble (flush_ex) -> re-captured.
        if (!u_soc.u_cpu.u_core.flush_ex_mem && !u_soc.u_cpu.u_core.stall_ex) begin
            if (u_soc.u_cpu.u_core.id_ex_valid
                && (u_soc.u_cpu.u_core.id_ex_pc === last_exmem_pc) && ndup < 20) begin
                ndup <= ndup + 1;
                $display("[DUP @%0d] EX->MEM re-captured pc=%h  stall_id=%b stall_ex=%b flush_ex=%b",
                    tcyc, u_soc.u_cpu.u_core.id_ex_pc, u_soc.u_cpu.u_core.stall_id,
                    u_soc.u_cpu.u_core.stall_ex, u_soc.u_cpu.u_core.flush_ex);
            end
            if (u_soc.u_cpu.u_core.id_ex_valid)
                last_exmem_pc <= u_soc.u_cpu.u_core.id_ex_pc;
            else
                last_exmem_pc <= 64'hFFFF_FFFF_FFFF_FFFF;
        end
`ifndef BOOT_NO_ICACHE
        // Verify the instruction the I$ delivers matches the shared-DDR window at
        // fetch_pc (only valid while satp=0 / VA==PA, i.e. early M-mode boot).
        if (u_soc.imem_ready && (^u_soc.u_cpu.u_core.fetch_pc !== 1'bx)
            && (u_soc.u_cpu.u_core.fetch_pc >= MEM_BASE)
            && (u_soc.imem_rdata !== mem_win(u_soc.u_cpu.u_core.fetch_pc)) && nmis < 20) begin
            nmis <= nmis + 1;
            $display("[IMIS @%0d] pc=%h I$=%h mem=%h",
                     tcyc, u_soc.u_cpu.u_core.fetch_pc, u_soc.imem_rdata,
                     mem_win(u_soc.u_cpu.u_core.fetch_pc));
        end
        // PTE-store watch: any DRAM store whose low byte has the valid bit set
        // (a plausible page-table entry).  Localizes where (if anywhere) the
        // kernel installs page tables.
        if (u_soc.mmu_dmem_req && u_soc.core_dmem_we && !u_soc.periph_is_periph
            && !u_soc.core_dmem_wait
            && (u_soc.core_dmem_wdata != 0)
            && (((u_soc.mmu_dmem_pa >= 64'h80e05000) && (u_soc.mmu_dmem_pa < 64'h80e06000))
             || ((u_soc.mmu_dmem_pa >= 64'h81725000) && (u_soc.mmu_dmem_pa < 64'h81726000)))
            && nipa < 40) begin
            nipa <= nipa + 1;
            $display("[PTST @%0d] pa=%h wdata=%h pc=%h",
                     tcyc, u_soc.mmu_dmem_pa, u_soc.core_dmem_wdata,
                     u_soc.u_cpu.u_core.ex_mem_pc);
        end
        // Physical-address I$ content check (valid under MMU too: addr_q is the
        // PHYSICAL line address the I$ believes it is serving).  If the delivered
        // window diverges from the shared DDR at addr_q, the I$ line content (or
        // its part-select) is wrong; if this stays silent while the core still
        // commits garbage, addr_q itself is the wrong physical address.
        if (u_soc.imem_ready
            && (^u_soc.gen_icache.u_ic.addr_q !== 1'bx)
            && (u_soc.gen_icache.u_ic.addr_q >= MEM_BASE)
            && (u_soc.imem_rdata !== mem_win(u_soc.gen_icache.u_ic.addr_q))
            && nipa < 40) begin
            nipa <= nipa + 1;
            $display("[IPA @%0d] addr_q=%h pa=%h I$=%h mem@addr_q=%h",
                     tcyc, u_soc.gen_icache.u_ic.addr_q, u_soc.mmu_imem_pa,
                     u_soc.imem_rdata, mem_win(u_soc.gen_icache.u_ic.addr_q));
        end
`endif
        // PTW state tracer for DATA walks around the first store-fault window.
        if (`BOOT_PTWLO != 0 && tcyc >= `BOOT_PTWLO && tcyc <= `BOOT_PTWLO + 400
            && !u_soc.u_cpu.u_mmu.ptw_for_if
            && u_soc.u_cpu.u_mmu.ptw_state != 0)
            $display("[PTW @%0d] st=%0d wait=%b rdy=%b paddr=%h rdata=%h vpn=%h ppncur=%h | ddr@paddr=%h owptw=%b brbusy=%b brdone=%b brrv=%b",
                tcyc, u_soc.u_cpu.u_mmu.ptw_state, u_soc.u_cpu.u_mmu.ptw_wait,
                u_soc.u_cpu.ptw_ready, u_soc.u_cpu.u_mmu.ptw_paddr,
                u_soc.u_cpu.u_mmu.ptw_rdata, u_soc.u_cpu.u_mmu.ptw_vpn,
                u_soc.u_cpu.u_mmu.ptw_ppn_cur,
                ((^u_soc.u_cpu.u_mmu.ptw_paddr !== 1'bx
                  && u_soc.u_cpu.u_mmu.ptw_paddr >= MEM_BASE)
                    ? mem_win64(u_soc.u_cpu.u_mmu.ptw_paddr) : 64'hX),
                u_soc.owner_ptw, u_soc.br_busy, u_soc.br_done, u_soc.br_rvalid);
        // ---- Lost-store hunt: trace the lifecycle of `sw zero, dev_boot_phase`
        // (PC 0xffffffff80a35fba in net_dev_init).  Fires while the store is in EX
        // (ID/EX) or MEM (EX/MEM), printing every signal that could drop it.
        if (u_soc.u_cpu.u_core.id_ex_valid
            && u_soc.u_cpu.u_core.id_ex_pc == 64'hffffffff80a35fba)
            $display("[STEX @%0d] id_ex(store) sif=%b sid=%b sex=%b | imrdy=%b dwait=%b mems=%b mmus=%b luh=%b rds=%b flushex=%b trapen=%b sret=%b",
                tcyc, u_soc.u_cpu.u_core.stall_if, u_soc.u_cpu.u_core.stall_id,
                u_soc.u_cpu.u_core.stall_ex, u_soc.imem_ready, u_soc.core_dmem_wait,
                u_soc.u_cpu.u_core.mem_stall, u_soc.u_cpu.u_core.mmu_stall,
                u_soc.u_cpu.u_core.load_use_hazard, u_soc.u_cpu.u_core.redirect_stall,
                u_soc.u_cpu.u_core.flush_ex_mem, u_soc.u_cpu.u_core.ex_trap_enter,
                u_soc.u_cpu.u_core.ex_sret_en);
        if (u_soc.u_cpu.u_core.ex_mem_valid
            && u_soc.u_cpu.u_core.ex_mem_pc == 64'hffffffff80a35fba)
            $display("[STMEM @%0d] ex_mem(store) we=%b mem_w=%b dmem_pa=%h dmem_req=%b dmem_we=%b | sex=%b dwait=%b mems=%b mmus=%b flushex=%b | dc_st=%0d dc_creq=%b dc_cwe=%b dc_caddr=%h dc_cwait=%b dc_mreq=%b dc_mdone=%b | word=%h",
                tcyc, u_soc.u_cpu.u_core.ex_mem_ctrl.mem_write,
                u_soc.u_cpu.u_core.ex_mem_ctrl.mem_write,
                u_soc.mmu_dmem_pa, u_soc.mmu_dmem_req, u_soc.mmu_dmem_we,
                u_soc.u_cpu.u_core.stall_ex, u_soc.core_dmem_wait,
                u_soc.u_cpu.u_core.mem_stall, u_soc.u_cpu.u_core.mmu_stall,
                u_soc.u_cpu.u_core.flush_ex_mem,
                u_soc.gen_dcache.u_dc.state, u_soc.gen_dcache.u_dc.c_req,
                u_soc.gen_dcache.u_dc.c_we, u_soc.gen_dcache.u_dc.c_addr,
                u_soc.gen_dcache.u_dc.c_wait, u_soc.gen_dcache.u_dc.m_req,
                u_soc.gen_dcache.u_dc.m_done, mem_win64(64'h0000000081719ae0));
        // Catch the first divergent store (init_thread_union slot 0x81603a40,
        // C-2a value 0xecb5a897) -> reveals the producing PC + cycle for provenance.
        if (u_soc.mmu_dmem_req && u_soc.core_dmem_we && !u_soc.periph_is_periph
            && (u_soc.mmu_dmem_pa[31:3] == 29'(64'h81603a40 >> 3))
            && (u_soc.core_dmem_wdata[31:0] == 32'hecb5a897 ||
                u_soc.core_dmem_wdata[31:0] == 32'ha38c3727))
            $display("[DIVST @%0d] pa=%h wdata=%h wstrb=%h ex_mem_pc=%h id_ex_pc=%h",
                tcyc, u_soc.mmu_dmem_pa, u_soc.core_dmem_wdata, u_soc.core_dmem_wstrb,
                u_soc.u_cpu.u_core.ex_mem_pc, u_soc.u_cpu.u_core.id_ex_pc);
        if (u_soc.u_cpu.u_core.trap_or_mret || u_soc.u_cpu.u_core.ifpf_take)
            $display("[trap @%0d] tgt=%h te=%b mte=%b ifpf=%b mret=%b sret=%b | LIVE cause=%h epc=%h tval=%h priv=%0d a7=%h a6=%h a0=%h",
                tcyc, u_soc.u_cpu.u_core.redir_tgt,
                u_soc.u_cpu.u_core.ex_trap_enter, u_soc.u_cpu.u_core.mem_trap_enter,
                u_soc.u_cpu.u_core.ifpf_take,
                u_soc.u_cpu.u_core.ex_mret_en, u_soc.u_cpu.u_core.ex_sret_en,
                u_soc.u_cpu.u_core.csr_trap_cause, u_soc.u_cpu.u_core.csr_trap_epc,
                u_soc.u_cpu.u_core.csr_trap_val, u_soc.u_cpu.priv_out,
                u_soc.u_cpu.u_core.u_regfile.regs[17],
                u_soc.u_cpu.u_core.u_regfile.regs[16],
                u_soc.u_cpu.u_core.u_regfile.regs[10]);
        // CSR-write monitor (sscratch/satp/stvec): the kernel storm uses
        // tp == sscratch == 0x8003e000 (an OpenSBI-firmware PHYSICAL address) as a
        // pointer.  Trace where that value gets installed -- whether the kernel
        // COMPUTED it (DTB/per-CPU/memory-map bug) or a LOAD returned wrong data
        // (residual cache/data-path corruption).  Capped to avoid log flooding.
        if (u_soc.u_cpu.u_core.id_ex_valid && !u_soc.u_cpu.u_core.stall_ex
            && u_soc.u_cpu.u_core.id_ex_ctrl.csr_write && u_soc.imem_ready
            && (u_soc.u_cpu.u_core.id_ex_csr_addr == 12'h140    // sscratch
             || u_soc.u_cpu.u_core.id_ex_csr_addr == 12'h180    // satp
             || u_soc.u_cpu.u_core.id_ex_csr_addr == 12'h105)   // stvec
            && ncsr < 80) begin
            ncsr <= ncsr + 1;
            $display("[CSRW @%0d] pc=%h csr=%h wdata=%h", tcyc,
                u_soc.u_cpu.u_core.id_ex_pc, u_soc.u_cpu.u_core.id_ex_csr_addr,
                u_soc.u_cpu.u_core.ex_csr_wdata);
        end
        // tp (x4) architectural writeback -- catches the moment tp becomes the bad
        // firmware-physical pointer.
        if (u_soc.u_cpu.u_core.wb_reg_write && u_soc.u_cpu.u_core.wb_rd_addr == 5'd4
            && ntp < 80) begin
            ntp <= ntp + 1;
            $display("[TPWB @%0d] tp <= %h (pc-ish wb)", tcyc,
                u_soc.u_cpu.u_core.wb_data);
        end
        // udelay entry probe: caller (ra), argument (a0), computed target (a4) and
        // the live time CSR.  Characterizes why a udelay spins for tens of millions
        // of cycles (large target vs stuck rdtime).  The udelay entry PC moves with
        // each vmlinux layout: override with -DBOOT_UDELAY_PC=64'h... (default =
        // the 2026-06-10 V01 build; old pre-V01 build was ...8094f380).
`ifndef BOOT_UDELAY_PC
  `define BOOT_UDELAY_PC 64'hffffffff8094f5b4
`endif
        if (u_soc.u_cpu.u_core.id_ex_valid && !u_soc.u_cpu.u_core.stall_ex
            && u_soc.imem_ready
            && u_soc.u_cpu.u_core.id_ex_pc == `BOOT_UDELAY_PC
            && nud < 40) begin
            nud <= nud + 1;
            $display("[UDELAY @%0d] ra=%h a0=%h a4(target)=%h time=%0d",
                tcyc, u_soc.u_cpu.u_core.u_regfile.regs[1],
                u_soc.u_cpu.u_core.u_regfile.regs[10],
                u_soc.u_cpu.u_core.u_regfile.regs[14],
                u_soc.u_cpu.u_core.time_val);
        end
        // TEMP-DIAG: earlycon registration chain PC probes (2026-06-10 vmlinux)
        if (u_soc.u_cpu.u_core.id_ex_valid && !u_soc.u_cpu.u_core.stall_ex
            && u_soc.imem_ready && nud < 40) begin
            case (u_soc.u_cpu.u_core.id_ex_pc)
                64'hffffffff80a00678: $display("[ECPROBE @%0d] parse_early_param", tcyc);
                64'hffffffff80a000ba: $display("[ECPROBE @%0d] do_early_param a0=%h", tcyc,
                                               u_soc.u_cpu.u_core.u_regfile.regs[10]);
                64'hffffffff80a28bd4: $display("[ECPROBE @%0d] setup_earlycon a0=%h", tcyc,
                                               u_soc.u_cpu.u_core.u_regfile.regs[10]);
                64'hffffffff80a28e48: $display("[ECPROBE @%0d] param_setup_earlycon a0=%h", tcyc,
                                               u_soc.u_cpu.u_core.u_regfile.regs[10]);
                64'hffffffff80a2914c: $display("[ECPROBE @%0d] early_sbi_setup", tcyc);
                64'hffffffff8004ed7a: $display("[ECPROBE @%0d] register_console a0=%h", tcyc,
                                               u_soc.u_cpu.u_core.u_regfile.regs[10]);
                64'hffffffff8004dde8: begin
                    $display("[ECPROBE @%0d] console_flush_all", tcyc);
                    // TEMP-DIAG: printk_rb_static state (PA 0x816170f8)
                    $display("  [PRB] head_id=%h tail_id=%h lastfin=%h fail=%h hlpos=%h tlpos=%h",
                        mem_win64(64'h0000000081617110),   // desc_ring.head_id
                        mem_win64(64'h0000000081617118),   // desc_ring.tail_id
                        mem_win64(64'h0000000081617120),   // desc_ring.last_finalized_seq
                        mem_win64(64'h0000000081617148),   // fail
                        mem_win64(64'h0000000081617138),   // text_data_ring.head_lpos
                        mem_win64(64'h0000000081617140));  // text_data_ring.tail_lpos
                    $display("  [PRB2] cb=%h descs=%h infos=%h d0=%h d1=%h d2=%h",
                        mem_win64(64'h00000000816170f8),   // count_bits|pad
                        mem_win64(64'h0000000081617100),   // descs ptr
                        mem_win64(64'h0000000081617108),   // infos ptr
                        mem_win64(64'h000000008166f190),   // descs[0].state_var
                        mem_win64(64'h000000008166f1a8),   // descs[1].state_var
                        mem_win64(64'h000000008166f1c0));  // descs[2].state_var
                end
                64'hffffffff80563502: $display("[ECPROBE @%0d] sbi_0_1_console_write a2(n)=%h", tcyc,
                                               u_soc.u_cpu.u_core.u_regfile.regs[12]);
                64'hffffffff80009144: $display("[ECPROBE @%0d] sbi_console_putchar a0=%h", tcyc,
                                               u_soc.u_cpu.u_core.u_regfile.regs[10]);
                default: ;
            endcase
        end
        // TEMP-DIAG: timer arming chain PC probes (2026-06-10 vmlinux).  Traces
        // why the kernel never issues SBI set_timer (no STIP -> idle forever):
        // riscv_timer_init_dt -> riscv_timer_starting_cpu -> tick_check_new_device
        // -> clockevents_program_event -> riscv_clock_next_event -> sbi_set_timer.
        if (u_soc.u_cpu.u_core.id_ex_valid && !u_soc.u_cpu.u_core.stall_ex
            && u_soc.imem_ready && ntm < 60) begin
            case (u_soc.u_cpu.u_core.id_ex_pc)
                64'hffffffff80a3287c: begin ntm <= ntm + 1;
                    $display("[TMPROBE @%0d] riscv_timer_init_dt", tcyc); end
                64'hffffffff80730dd8: begin ntm <= ntm + 1;
                    $display("[TMPROBE @%0d] riscv_timer_starting_cpu", tcyc); end
                64'hffffffff80078408: begin ntm <= ntm + 1;
                    $display("[TMPROBE @%0d] tick_check_new_device", tcyc); end
                64'hffffffff80077d9a: begin ntm <= ntm + 1;
                    $display("[TMPROBE @%0d] clockevents_program_event a1=%h", tcyc,
                             u_soc.u_cpu.u_core.u_regfile.regs[11]); end
                64'hffffffff80730d62: begin ntm <= ntm + 1;
                    $display("[TMPROBE @%0d] riscv_clock_next_event a0=%h time=%0d", tcyc,
                             u_soc.u_cpu.u_core.u_regfile.regs[10],
                             u_soc.u_cpu.u_core.time_val); end
                64'hffffffff800096a6: begin ntm <= ntm + 1;
                    $display("[TMPROBE @%0d] sbi_set_timer a0=%h time=%0d", tcyc,
                             u_soc.u_cpu.u_core.u_regfile.regs[10],
                             u_soc.u_cpu.u_core.time_val); end
                default: ;
            endcase
        end
        // refcount_warn_saturate(r, t): a0 = the corrupted refcount_t pointer,
        // a1 = saturation type.  Identifies WHICH object's count went bad
        // (2026-06-10 vmlinux).  Own cap: the ntm probes flood once the tick
        // is running (clockevents_program_event fires every ~4000 cycles).
        if (u_soc.u_cpu.u_core.id_ex_valid && !u_soc.u_cpu.u_core.stall_ex
            && u_soc.imem_ready && nrc < 20
            && u_soc.u_cpu.u_core.id_ex_pc == 64'hffffffff803bce1e) begin
            nrc <= nrc + 1;
            $display("[RCPROBE @%0d] refcount_warn_saturate r=%h type=%0d ra=%h", tcyc,
                     u_soc.u_cpu.u_core.u_regfile.regs[10],
                     u_soc.u_cpu.u_core.u_regfile.regs[11],
                     u_soc.u_cpu.u_core.u_regfile.regs[1]);
        end
        // TEMP-DIAG: count vprintk_emit entries (flood vs livelock discriminator)
        if (u_soc.u_cpu.u_core.id_ex_valid && !u_soc.u_cpu.u_core.stall_ex
            && u_soc.imem_ready
            && u_soc.u_cpu.u_core.id_ex_pc == 64'hffffffff8004e4aa)
            nvpe <= nvpe + 1;
        // On a load/store page fault to a kernel VA, dump the page-table walk to
        // see the leaf PTE permission/A/D bits behind the fault.
        if (u_soc.u_cpu.u_core.mem_trap_enter
            && (u_soc.u_cpu.u_core.csr_trap_val[63:40] == 24'hFFFFFF)
            && npw < 6) begin
            npw <= npw + 1;
            $display("  [MEMMMU we=%b tlbhit=%b tlb_w=%b tlb_d=%b tlb_u=%b permok=%b ptwst=%0d ptwfault=%b forif=%b sum=%b]",
                u_soc.u_cpu.u_mmu.mem_we, u_soc.u_cpu.u_mmu.mem_tlb_hit,
                u_soc.u_cpu.u_mmu.mem_tlb_w, u_soc.u_cpu.u_mmu.mem_tlb_d,
                u_soc.u_cpu.u_mmu.mem_tlb_u, u_soc.u_cpu.u_mmu.mem_perm_ok,
                u_soc.u_cpu.u_mmu.ptw_state, u_soc.u_cpu.u_mmu.ptw_fault_r,
                u_soc.u_cpu.u_mmu.ptw_for_if, u_soc.u_cpu.u_mmu.mstatus_sum);
            ptwalk(u_soc.u_cpu.u_core.csr_trap_val);
        end
        // Trace AMO/data accesses to the OpenSBI lottery region (boot-hart select)
        if (lpend) begin
            $display("   [lottery LD result @%0d] rdata=%h", tcyc, u_soc.dmem_rdata);
            lpend <= 1'b0;
        end
        if (u_soc.mmu_dmem_req && !u_soc.periph_is_periph && nlot < 30 &&
            (u_soc.mmu_dmem_pa[31:8] == 24'h8001b0 || u_soc.mmu_dmem_pa[31:8] == 24'h8001c0)) begin
            nlot <= nlot + 1;
            $display("[lottery @%0d] %s addr=%h wdata=%h amo=%b",
                     tcyc, u_soc.core_dmem_we ? "ST" : "LD", u_soc.mmu_dmem_pa,
                     u_soc.core_dmem_wdata, u_soc.u_cpu.u_core.ex_mem_ctrl.is_amo);
            if (!u_soc.core_dmem_we) lpend <= 1'b1;
        end
        // capture a pending load's result (dmem_rdata valid the cycle after)
        if (pend_ld) begin ring_dw[pend_idx] <= u_soc.dmem_rdata; pend_ld <= 1'b0; end

        // --- forwarded-operand-vs-regfile check (fix#1-family forward corruption) ---
        // Evaluated when a load/store advances EX->MEM (id_ex committing).
        if (u_soc.u_cpu.u_core.id_ex_valid && !u_soc.u_cpu.u_core.stall_ex
            && (u_soc.u_cpu.u_core.id_ex_ctrl.mem_read || u_soc.u_cpu.u_core.id_ex_ctrl.mem_write)
            && !u_soc.u_cpu.u_core.id_ex_ctrl.is_amo) begin : fwd_chk
            logic [4:0] r1, r2, em, mw;
            r1 = u_soc.u_cpu.u_core.id_ex_rs1_addr;  // base address reg
            r2 = u_soc.u_cpu.u_core.id_ex_rs2_addr;  // store data reg (stores)
            em = u_soc.u_cpu.u_core.ex_mem_rd_addr;
            mw = u_soc.u_cpu.u_core.mem_wb_rd_addr;
            // Base (rs1): stable iff not produced by an in-flight (EX/MEM, MEM/WB) instr.
            if (stable_reg(r1) && r1 != em && r1 != mw
                && (u_soc.u_cpu.u_core.fwd_rs1_data !== u_soc.u_cpu.u_core.u_regfile.regs[r1])
                && nfwd < 30) begin
                nfwd <= nfwd + 1;
                $display("[FWD BUG @%0d] pc=%h BASE x%0d fwd=%h regfile=%h sel=%b",
                    tcyc, u_soc.u_cpu.u_core.id_ex_pc, r1,
                    u_soc.u_cpu.u_core.fwd_rs1_data, u_soc.u_cpu.u_core.u_regfile.regs[r1],
                    u_soc.u_cpu.u_core.fwd_rs1_sel);
            end
            // Store data (rs2): only for stores.
            if (u_soc.u_cpu.u_core.id_ex_ctrl.mem_write
                && stable_reg(r2) && r2 != em && r2 != mw
                && (u_soc.u_cpu.u_core.fwd_rs2_data !== u_soc.u_cpu.u_core.u_regfile.regs[r2])
                && nfwd < 30) begin
                nfwd <= nfwd + 1;
                $display("[FWD BUG @%0d] pc=%h SDATA x%0d fwd=%h regfile=%h sel=%b",
                    tcyc, u_soc.u_cpu.u_core.id_ex_pc, r2,
                    u_soc.u_cpu.u_core.fwd_rs2_data, u_soc.u_cpu.u_core.u_regfile.regs[r2],
                    u_soc.u_cpu.u_core.fwd_rs2_sel);
            end
        end

        // --- D-load-vs-DDR check: EVERY cycle a cacheable load sits in WB (its FRESH
        // cycle and any held cycles during a freeze), the core's architectural load
        // RESULT (wb_data: word + byte-lane select + sign/zero extension) must equal
        // the value derived from the shared-DDR window.  This catches a wrong word
        // (fresh OR held = fix#2 family), a wrong byte offset, or a wrong funct3 -- the
        // full load-result corruption we hunt.  (Address corruption is NOT caught here;
        // a wrong s1 yields a self-consistent load.) ---
        if (ld_chk && u_soc.u_cpu.u_core.mem_wb_valid
            && u_soc.u_cpu.u_core.mem_wb_ctrl.mem_read) begin : dload_chk
            logic [63:0] ew; logic [63:0] exp; logic [2:0] f3;
            ew  = mem_win64(ld_addr) >> ({3'd0, ld_addr[2:0]} << 3);
            f3  = u_soc.u_cpu.u_core.mem_wb_funct3;
            case (f3)
                3'b000:  exp = {{56{ew[7]}},  ew[7:0]};      // LB
                3'b001:  exp = {{48{ew[15]}}, ew[15:0]};     // LH
                3'b010:  exp = {{32{ew[31]}}, ew[31:0]};     // LW
                3'b011:  exp = ew;                            // LD
                3'b100:  exp = {56'd0, ew[7:0]};             // LBU
                3'b101:  exp = {48'd0, ew[15:0]};            // LHU
                3'b110:  exp = {32'd0, ew[31:0]};            // LWU
                default: exp = ew;
            endcase
            if (u_soc.u_cpu.u_core.wb_data !== exp && ndld < 30) begin
                ndld <= ndld + 1;
                $display("[DLOAD BUG @%0d] pc=%h addr=%h f3=%b fresh=%b wb_data=%h exp=%h (ddr_word=%h)",
                    tcyc, ld_pc, ld_addr, f3, u_soc.u_cpu.u_core.mem_wb_fresh,
                    u_soc.u_cpu.u_core.wb_data, exp, mem_win64(ld_addr));
                // Decisive fork: is the raw 64-bit value the core received already
                // wrong (cache delivered bad data), or does it match DDR but the
                // sub-word shift/offset is wrong (core load-path bug)?
                $display("   [DLDBG] core_dmem_rdata=%h held=%h boff=%h | dc_rdata_q=%h dc_idx_data=%h v=%b tag_ok=%b",
                    u_soc.u_cpu.u_core.dmem_rdata, u_soc.u_cpu.u_core.dmem_rdata_held,
                    u_soc.u_cpu.u_core.mem_wb_byte_offset,
                    u_soc.gen_dcache.u_dc.rdata_q,
                    u_soc.gen_dcache.u_dc.data[ld_addr[13:5]][ld_addr[4:3]],
                    u_soc.gen_dcache.u_dc.valid[ld_addr[13:5]],
                    (u_soc.gen_dcache.u_dc.tagm[ld_addr[13:5]] == ld_addr[63:14]));
            end
        end
        // Latch a cacheable, aligned load as it advances MEM->WB (access complete).
        // ld_chk stays asserted while the load remains in WB; it is dropped only when
        // a non-load advances into WB (or a bubble), tracked by ex_mem advancing.
        if (!u_soc.u_cpu.u_core.stall_ex && !u_soc.u_cpu.u_core.flush_ex_mem
            && u_soc.u_cpu.u_core.imem_ready) begin
            if (u_soc.u_cpu.u_core.ex_mem_valid && u_soc.u_cpu.u_core.ex_mem_ctrl.mem_read
                && !u_soc.u_cpu.u_core.ex_mem_ctrl.is_amo && !u_soc.u_cpu.u_core.mal_cross
                && !u_soc.periph_is_periph && (u_soc.mmu_dmem_pa >= MEM_BASE)) begin
                ld_chk  <= 1'b1;
                ld_addr <= u_soc.mmu_dmem_pa;
                ld_pc   <= u_soc.u_cpu.u_core.ex_mem_pc;
            end else begin
                ld_chk  <= 1'b0;   // a non-checkable instruction took over WB
            end
        end
        // ring of cacheable data accesses on the completion cycle (~wait)
        if (u_soc.mmu_dmem_req && !u_soc.periph_is_periph && !u_soc.core_dmem_wait) begin
            ring_da [dh % 256] <= u_soc.mmu_dmem_pa;
            ring_dwe[dh % 256] <= u_soc.core_dmem_we;
            ring_dmal[dh % 256] <= u_soc.u_cpu.u_core.mal_cross;
            ring_dcy[dh % 256] <= tcyc;
            if (u_soc.core_dmem_we) ring_dw[dh % 256] <= u_soc.core_dmem_wdata;
            else begin pend_ld <= 1'b1; pend_idx <= dh % 256; end
            dh <= dh + 1;
        end
        // ring of recent register writes (rd, data)
        if (u_soc.u_cpu.u_core.wb_reg_write && u_soc.u_cpu.u_core.wb_rd_addr != 0) begin
            ring_rd [rwh % 64] <= u_soc.u_cpu.u_core.wb_rd_addr;
            ring_rdat[rwh % 64] <= u_soc.u_cpu.u_core.wb_data;
            ring_rcy[rwh % 64] <= tcyc;
            rwh <= rwh + 1;
        end
        if (^u_soc.u_cpu.u_core.fetch_pc !== 1'bx) begin
            if (u_soc.u_cpu.u_core.fetch_pc !== prev_pc) begin
                ring_pc[rh % 64] <= u_soc.u_cpu.u_core.fetch_pc;
                ring_cy[rh % 64] <= tcyc;
                rh <= rh + 1;
                prev_pc <= u_soc.u_cpu.u_core.fetch_pc;
            end
        end else if (!seen_x) begin
            seen_x <= 1;
            $display("[X @%0d] fetch_pc -> X. Last 64 distinct fetch_pc (oldest first):", tcyc);
            for (i = 0; i < 64; i = i + 1)
                $display("   cy=%0d  pc=%h", ring_cy[(rh + i) % 64], ring_pc[(rh + i) % 64]);
            $display("[X] Last 64 register writes (cy, x<rd>=data):");
            for (i = 0; i < 64; i = i + 1)
                $display("   cy=%0d  x%0d=%h", ring_rcy[(rwh + i) % 64],
                         ring_rd[(rwh + i) % 64], ring_rdat[(rwh + i) % 64]);
            $display("[X] Last 256 data accesses (cy, op, addr, data, mal):");
            for (i = 0; i < 256; i = i + 1)
                $display("   cy=%0d  %s addr=%h data=%h %s", ring_dcy[(dh + i) % 256],
                         ring_dwe[(dh + i) % 256] ? "ST" : "LD",
                         ring_da[(dh + i) % 256], ring_dw[(dh + i) % 256],
                         ring_dmal[(dh + i) % 256] ? "MAL" : "");
        end
`ifdef BOOT_DUMP_AT
        // One-shot dump of all integer registers at a given cycle (spin diagnosis).
        if (tcyc == `BOOT_DUMP_AT) begin
            $display("[REGDUMP @%0d] pc=%h", tcyc, u_soc.u_cpu.u_core.fetch_pc);
            for (i = 1; i < 32; i = i + 1)
                $display("   x%0d = %h", i, u_soc.u_cpu.u_core.u_regfile.regs[i]);
        end
`endif
`ifdef BOOT_HANG_PC
        // One-shot dump when fetch_pc first reaches a known hang address (e.g.
        // OpenSBI _start_hang) — same rings as the X dump, to find the branch in.
        if ((^u_soc.u_cpu.u_core.fetch_pc !== 1'bx)
            && (u_soc.u_cpu.u_core.fetch_pc === `BOOT_HANG_PC) && !seen_hang) begin
            seen_hang <= 1;
            $display("[HANG @%0d] fetch_pc reached %h. Last 64 distinct fetch_pc:",
                     tcyc, u_soc.u_cpu.u_core.fetch_pc);
            for (i = 0; i < 64; i = i + 1)
                $display("   cy=%0d  pc=%h", ring_cy[(rh + i) % 64], ring_pc[(rh + i) % 64]);
            $display("[HANG] Last 64 register writes (cy, x<rd>=data):");
            for (i = 0; i < 64; i = i + 1)
                $display("   cy=%0d  x%0d=%h", ring_rcy[(rwh + i) % 64],
                         ring_rd[(rwh + i) % 64], ring_rdat[(rwh + i) % 64]);
        end
`endif
        // One-shot dump when fetch_pc first runs away above the firmware image
        // (>= 0x8004_0000, below the 0x8020_0000 payload) -- to find the bad jump.
        if ((^u_soc.u_cpu.u_core.fetch_pc !== 1'bx)
            && (u_soc.u_cpu.u_core.fetch_pc >= 64'h0000_0000_8004_0000)
            && (u_soc.u_cpu.u_core.fetch_pc <  64'h0000_0000_8020_0000) && !seen_run) begin
            seen_run <= 1;
            $display("[RUNAWAY @%0d] fetch_pc=%h left firmware. Last 64 distinct fetch_pc:",
                     tcyc, u_soc.u_cpu.u_core.fetch_pc);
            for (i = 0; i < 64; i = i + 1)
                $display("   cy=%0d  pc=%h", ring_cy[(rh + i) % 64], ring_pc[(rh + i) % 64]);
            $display("[RUNAWAY] Last 64 register writes (cy, x<rd>=data):");
            for (i = 0; i < 64; i = i + 1)
                $display("   cy=%0d  x%0d=%h", ring_rcy[(rwh + i) % 64],
                         ring_rd[(rwh + i) % 64], ring_rdat[(rwh + i) % 64]);
        end
    end
`endif

// A full real-OpenSBI fw_payload boot to its S-mode payload + sentinel takes
// ~8M cycles in this harness; the cap must clear that.  Fast firmwares (the
// mini-SBI default) exit early on the completion sentinel, so a high cap is free.
`ifndef BOOT_MAX_CYCLES
  `define BOOT_MAX_CYCLES 12_000_000
`endif
    integer cyc = 0;
    initial begin
`ifdef BOOT_VCD
        // Opt-in only: $dumpvars(0, ...) records the whole 64 MiB mem_b array at
        // t=0, which makes the VCD huge and the (already ~15 min) run much slower.
        $dumpfile("wave/tb_rv_boot_soc.vcd"); $dumpvars(0, tb_rv_boot_soc);
`endif
        repeat (4) @(posedge clk);
        rst_n = 1;
        $display("\n----- boot console (firmware: %s) -----", `BOOT_HEX);
        // run until the firmware signals done, or timeout
        for (cyc = 0; cyc < `BOOT_MAX_CYCLES; cyc = cyc + 1) begin
            @(posedge clk);
            if ((cyc % 1_000_000) == 999_999) begin
                $display("\n[progress @%0dM cyc] pc=%010h if_fills=%0d d_reads=%0d chars=%0d mtime=%0d vpe=%0d",
                         (cyc+1)/1_000_000, u_soc.u_cpu.u_core.fetch_pc, if_ar, d_ar, nchars,
                         u_soc.u_cpu.u_core.time_val, nvpe);
                $display("  [IRQCHAIN] ier1=%b uirq=%b plic_en1=%b plic_pend=%b ext1=%b ext0=%b | seip=%0d meip=%0d stip=%0d | en1=%b th1=%0d pr1=%0d",
                         ever_ier1, ever_uirq, ever_en1, ever_pend1, ever_extirq1, ever_extirq0,
                         n_seip, n_meip, n_stip,
                         u_soc.u_periph.u_plic.enable1, u_soc.u_periph.u_plic.thresh1,
                         u_soc.u_periph.u_plic.prio[1]);
            end
`ifdef BOOT_TRACE
            // TEMP-DIAG: periodic printk_rb_static head/tail/fail dump
            if ((cyc % 1_000_000) == 999_999)
                $display("  [PRBP] head_id=%h tail_id=%h fail=%h",
                    mem_win64(64'h0000000081617110),
                    mem_win64(64'h0000000081617118),
                    mem_win64(64'h0000000081617148));
            // TEMP-DIAG: interrupt-delivery state (CLINT + CSR), for the
            // "timer armed but no MTIP" investigation.
            if ((cyc % 1_000_000) == 999_999)
                $display("  [IRQST] mtimecmp=%h tirq=%b mie=%h mip=%h mideleg=%h priv=%0d mie_bit=%b",
                    u_soc.u_periph.u_timer.mtimecmp,
                    u_soc.u_periph.u_timer.timer_irq,
                    u_soc.u_cpu.u_core.u_csr.mie_reg,
                    u_soc.u_cpu.u_core.u_csr.mip_val,
                    u_soc.u_cpu.u_core.u_csr.mideleg_reg,
                    u_soc.u_cpu.u_core.u_csr.cur_priv,
                    u_soc.u_cpu.u_core.u_csr.mstatus_mie);
            // TEMP-DIAG: physical-address write watch (BOOT_WATCH_PA=64'h...).
            // Every store/AMO write reaching the shared DDR within the watched
            // 8-byte word is logged with the MEM-stage PC (the store is held in
            // MEM by dmem_wait until the write-through completes, so ex_mem_pc
            // is the storing instruction).  For chasing single-object memory
            // corruption (e.g. the refcount at shmem_init's fs_context).
            if (`BOOT_WATCH_PA != 0
                && u_bfm.d_wready && u_bfm.d_wvalid
                && ((64'(u_bfm.d_waddr_q) & ~64'h7) == (`BOOT_WATCH_PA & ~64'h7)))
                $display("[WATCH @%0d] PA=%h wdata=%h wstrb=%h mem_pc=%h",
                    tcyc, 64'(u_bfm.d_waddr_q), u_bfm.d_wdata, u_bfm.d_wstrb,
                    u_soc.u_cpu.u_core.ex_mem_pc);
            if (`BOOT_WATCH_PA != 0 && (cyc % 1_000_000) == 999_999)
                $display("  [WATCHV] [%h]=%h",
                    (`BOOT_WATCH_PA & ~64'h7), mem_win64(`BOOT_WATCH_PA & ~64'h7));
`endif
            if (sentinel() === DONE_MAGIC || sentinel() === FAIL_MAGIC) cyc = `BOOT_MAX_CYCLES;
        end
        #1;
        $display("\n----- end of console (%0d UART chars; IF line-fills=%0d, data reads=%0d) -----",
                 nchars, if_ar, d_ar);
        $display("[IRQCHAIN final] ier1(THRI)=%b uart_irq=%b plic_en1=%b plic_pend=%b ext_ctx1=%b ext_ctx0=%b | seip_traps=%0d meip_traps=%0d stip_traps=%0d",
                 ever_ier1, ever_uirq, ever_en1, ever_pend1, ever_extirq1, ever_extirq0,
                 n_seip, n_meip, n_stip);
        $display("[PTWMASK] ptw_req masked a real D$ wait: %0d cyc (of which IF-PTW: %0d) | HARM (data op retired w/ D$ in flight): %0d | AMO premature-write (write phase during S_FILL): %0d",
                 ptwmask_cyc, ptwmask_if, ptwmask_adv, amo_prem);
        // Focused-test failure discriminator: a test that FAILs may leave
        // disc@0x2004 (1 = architectural check broke; >=2 = trap mcause),
        // A@0x2008, B@0x200C.  Only meaningful on FAIL (real firmware has
        // arbitrary data there), so gate on the FAIL sentinel.
        if (sentinel() === FAIL_MAGIC)
            $display("[FAILINFO] disc@2004=%08h A@2008=%08h B@200C=%08h",
                     peek(32'h2004), peek(32'h2008), peek(32'h200c));
        if (sentinel() === DONE_MAGIC) begin
            $display("tb_rv_boot_soc: PASS (firmware reached SBI done; sentinel=0x%08h)", sentinel());
            $display("ALL TESTS PASSED");
        end else if (sentinel() === FAIL_MAGIC) begin
            $display("tb_rv_boot_soc: FAIL (firmware trapped unexpectedly; sentinel=0x%08h)", sentinel());
            $display("TESTS FAILED");
        end else begin
            $display("tb_rv_boot_soc: FAIL (timeout; no completion sentinel; %0d chars seen)", nchars);
            $display("TESTS FAILED");
        end
        $finish;
    end

endmodule

`default_nettype wire
