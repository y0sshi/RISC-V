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
        logic signed [2*CKW-1:0] pss, psu;
        logic        [2*CKW-1:0] puu;
        dz = (b=='0); dzw = (b[31:0]=='0);
        ov  = (a=={1'b1,{(CKW-1){1'b0}}}) && (b=='1);
        ovw = (a[31:0]==32'h8000_0000) && (b[31:0]==32'hFFFF_FFFF);
        // full-width products for the MUL/MULH family (step6 pipelined MUL too)
        pss = $signed({{CKW{a[CKW-1]}}, a}) * $signed({{CKW{b[CKW-1]}}, b}); // signed*signed
        puu = {{CKW{1'b0}}, a} * {{CKW{1'b0}}, b};                            // unsigned*unsigned
        psu = $signed({{CKW{a[CKW-1]}}, a}) * $signed({{CKW{1'b0}}, b});      // signed*unsigned
        unique case (o)
          MDU_MUL:    dgolden = pss[CKW-1:0];
          MDU_MULH:   dgolden = pss[2*CKW-1:CKW];
          MDU_MULHSU: dgolden = psu[2*CKW-1:CKW];
          MDU_MULHU:  dgolden = puu[2*CKW-1:CKW];
          MDU_MULW:   dgolden = CKW'($signed(a[31:0] * b[31:0]));
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
        // ALL M-ext ops now go through the busy/start_stall handshake (step6
        // pipelined MUL too), so check MUL/MULH*/MULW retires as well as DIV/REM.
        is_d = u_soc.u_cpu.u_core.id_ex_ctrl.is_muldiv
               && u_soc.u_cpu.u_core.id_ex_valid
               && !u_soc.u_cpu.u_core.muldiv_busy_int
               && !u_soc.u_cpu.u_core.muldiv_start_stall
               && !u_soc.u_cpu.u_core.stall_ex;   // M-ext op retiring this cycle
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

    // (ISS co-sim block moved below the function/tcyc definitions; see iss_blk.)

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
    integer ndesync = 0;     // step-8 fetch PC-tag<->data desync detector cap
    integer nfchk   = 0;     // step-8 fetched-instruction correctness detector cap
    logic [XLEN-1:0] prev_ifid_pc = 64'hFFFF_FFFF_FFFF_FFFF;
    // step-8 halfword-buffer push CONTINUITY detector: a dropped word (hb_dup
    // false-fire / push gated) SKIPS an instruction without any individual word
    // being byte-wrong, so [FCHK]/[DESYNC] stay silent.  Each non-flush hb_push
    // must advance bfpc by exactly one word (+4) from the previous push; a +8 gap =
    // a word was SKIPPED, a +0 repeat = a word PUSHED TWICE (executed twice).
    integer nhbsk   = 0;
    logic [XLEN-1:0] last_push_bfpc = '0;
    logic            last_push_vld  = 1'b0;
    // step-8 CONTROL-FLOW continuity detector.  Fetch delivery is proven correct
    // (FCHK/DESYNC/HBSKIP all silent), so the corruption is an EXECUTION-stage
    // anomaly: an instruction wrongly SKIPPED / DOUBLED, or an interrupt taken with
    // a WRONG mepc (the interrupt-vs-variable-latency race the bug needs -- it
    // vanishes under MTIME_INSTR).  exp_next_pc models the architectural next-PC
    // from the EX-commit stream (prev+len / branch target / trap_vector / mepc).
    // Every instruction PROCESSED in EX must equal exp_next_pc; a mismatch is the
    // bug, at the exact PC/cycle.  Faults that re-execute (mem page fault / I-fetch
    // fault / satp barrier) just re-point exp_next_pc to their redirect target.
    integer ncflow  = 0;
    logic [XLEN-1:0] exp_next_pc = '0;
    logic            cf_synced   = 1'b0;
    // exp_pa: shadow of the PHYSICAL address that pairs with the core's bfpc tag.
    // It mirrors bfpc's update rule EXACTLY (capture imem_addr's translation,
    // mmu_imem_pa, on every imem_ready) so exp_pa == translate(bfpc) at all times.
    // When the I$ commits a fetched word into the core's halfword buffer (hb_push),
    // the data is window(addr_q) but it is TAGGED with bfpc; correctness requires
    // translate(bfpc) == addr_q.  Any hb_push where addr_q != exp_pa means a word
    // was mis-tagged (the step-8 FTQ/I$ lockstep broke = the real-HW fetch-skip
    // bug) -- the dedicated detector docs/freq_50mhz.md sec 21.2 says is needed
    // (ICMIS/IPA/HBGAP stay silent because each piece is internally consistent).
    logic [XLEN-1:0] exp_pa = MEM_BASE & ~64'h3;
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
    // Software Sv39 VA->PA translation over the shared DDR (no print).  Returns the
    // physical address, or 64'hFFFF_FFFF_FFFF_FFFF when the VA is unmapped/invalid.
    // Used by the instruction-fetch correctness detector to verify that the word the
    // aligner hands to decode matches the instruction actually in memory at its PC --
    // catching ANY step-8 fetch error (aligner mis-pick, halfword-buffer skid bug,
    // PC-tag desync) regardless of whether addr_q itself diverged.
    localparam logic [63:0] VA2PA_BAD = 64'hFFFF_FFFF_FFFF_FFFF;
    function automatic logic [63:0] va2pa(input [63:0] va);
        logic [63:0] satp_v, base, pte, ppn, mask; integer i; logic [8:0] vpn;
        logic [63:0] r; integer lowbits;
        begin
            satp_v = u_soc.u_cpu.satp_out;
            if (satp_v[63:60] == 4'd0) return va;          // Bare: VA==PA
            base = (satp_v & 64'hFFF_FFFF_FFFF) << 12;
            r = VA2PA_BAD;
            for (i = 2; i >= 0; i = i - 1) begin
                vpn = va[12 + i*9 +: 9];
                pte = mem_win64(base + 64'(vpn)*8);
                if (!pte[0]) begin r = VA2PA_BAD; i = -1; end          // not valid
                else if (pte[1] || pte[3]) begin                       // leaf (R or X)
                    ppn     = pte[53:10];
                    lowbits = 12 + i*9;
                    mask    = (64'h1 << lowbits) - 64'h1;
                    r       = ((ppn << 12) & ~mask) | (va & mask);
                    i = -1;
                end else base = (pte[53:10]) << 12;                    // descend
            end
            return r;
        end
    endfunction
    function automatic logic [15:0] mem_hw(input [63:0] pa);  // 16-bit halfword at pa
        logic [63:0] o; o = pa - MEM_BASE;
        return {u_bfm.mem_b[o+1], u_bfm.mem_b[o+0]};
    endfunction
    // Read n (<=8) bytes starting at VIRTUAL address va, byte-wise through the live
    // page table (handles a page-crossing misaligned access).  Returns 0-filled for
    // any byte that is unmapped / outside DRAM.  Used by the misaligned-load checker.
    function automatic logic [63:0] mem_va_bytes(input [63:0] va, input integer n);
        logic [63:0] r, pa, off; integer i;
        r = 64'h0;
        for (i = 0; i < n; i = i + 1) begin
            pa = va2pa(va + i[63:0]);
            if (pa !== VA2PA_BAD && pa >= MEM_BASE && (pa - MEM_BASE) < (1<<26)) begin
                off = pa - MEM_BASE;
                r[i*8 +: 8] = u_bfm.mem_b[off];
            end
        end
        return r;
    endfunction
`ifdef BOOT_ISS
    // ISS co-sim ALU: independent reference for the integer ALU result, used to keep
    // the shadow register file architecturally correct.
    function automatic logic [63:0] iss_alu(input alu_op_t op,
                                            input logic [63:0] a, b);
        logic [63:0] r;
        logic [31:0] w;   // 32-bit W-type result (bit-select on a paren-expr is illegal SV)
        w = 32'h0;
        case (op)
            ALU_ADD:    r = a + b;
            ALU_SUB:    r = a - b;
            ALU_SLL:    r = a << b[5:0];
            ALU_SLT:    r = ($signed(a) <  $signed(b)) ? 64'd1 : 64'd0;
            ALU_SLTU:   r = (a < b)                    ? 64'd1 : 64'd0;
            ALU_XOR:    r = a ^ b;
            ALU_SRL:    r = a >> b[5:0];
            ALU_SRA:    r = $signed(a) >>> b[5:0];
            ALU_OR:     r = a | b;
            ALU_AND:    r = a & b;
            ALU_PASS_B: r = b;
            ALU_ADDW:   begin w = a[31:0] + b[31:0];                  r = {{32{w[31]}}, w}; end
            ALU_SUBW:   begin w = a[31:0] - b[31:0];                  r = {{32{w[31]}}, w}; end
            ALU_SLLW:   begin w = a[31:0] << b[4:0];                  r = {{32{w[31]}}, w}; end
            ALU_SRLW:   begin w = a[31:0] >> b[4:0];                  r = {{32{w[31]}}, w}; end
            ALU_SRAW:   begin w = $signed(a[31:0]) >>> b[4:0];        r = {{32{w[31]}}, w}; end
            default:    r = 64'hx;
        endcase
        return r;
    endfunction

    // ===== ISS co-sim: independent integer shadow register file =====
    // Re-executes each EX-committing instruction from the SHADOW operands and (1)
    // CHECKS the core's forwarded operands against the shadow -- catching a WRONG
    // FORWARDED VALUE (the prime remaining suspect, invisible to [FWD] which only
    // checks the non-forwarded case and to every value detector, since a wrong
    // operand propagates self-consistently) -- and (2) UPDATES the shadow with the
    // independently computed result (ALU/M/load/link/AMO).  CSR/FP synced from core;
    // SC result resolves in MEM so its rd is marked unknown.  First [ISS] = the bug.
    logic [63:0] sx [0:31];
    logic        sxv [0:31];
    // Independent shadow of the SOFTWARE-written CSRs (sscratch/mscratch/satp/stvec/
    // mtvec/sie/mie): the integer datapath is ISS-clean, so a CSR read returning a
    // wrong value (-> a GP register -> corruption) is the only remaining suspect.
    // These CSRs are written ONLY by CSR instructions (not by trap-entry hardware),
    // so a shadow updated on CSR writes can verify the core's CSR reads.  The
    // hardware-set trap CSRs (xepc/xcause/xstatus/xtval/xip) are NOT tracked.
    logic [63:0] scsr [0:4095];
    logic        scsrv [0:4095];
    // Independent mstatus + privilege model (the last uncovered path): trap PUSHes
    // SPP/SPIE/SIE (or MPP/MPIE/MIE), xRET POPs them.  Compare the core's mstatus/
    // sstatus reads MASKED to the bits we model.  priv: U=00, S=01, M=11.
    logic [63:0] shadow_mstatus = 64'h0;
    logic [1:0]  shadow_priv    = 2'b11;        // reset -> M
    logic        ms_init = 1'b0;
    localparam logic [63:0] MS_CMP_M = 64'h219AA;  // SIE/MIE/SPIE/MPIE/SPP/MPP/MPRV
    localparam logic [63:0] MS_CMP_S = 64'h00122;  // SIE/SPIE/SPP (sstatus view)
    integer niss = 0;
    logic   iss_init = 1'b0;
    function automatic logic iss_csr_tracked(input logic [11:0] a);
        return (a==12'h140 || a==12'h340 || a==12'h180 || a==12'h105 ||
                a==12'h305 || a==12'h104 || a==12'h304 ||  // sscratch/mscratch/satp/stvec/mtvec/sie/mie
                a==12'h303 ||                              // mideleg (interrupt-cause model)
                a==12'h141 || a==12'h142 || a==12'h143 ||  // sepc/scause/stval (hw-set at trap)
                a==12'h341 || a==12'h342 || a==12'h343);   // mepc/mcause/mtval
    endfunction
    // Interrupt-decision counters ([IRQPEND]/[IRQCAUSE]) and branch-direction
    // ([BRDIR]) -- the two control-flow paths the value detectors + base ISS miss
    // (the core's irq_pending/irq_cause/branch_taken_ex are TRUSTED by CFLOW).
    integer nirq = 0;
    integer nbrd = 0;
    integer ncfunk = 0;
    integer cov_last = 0;
    always @(posedge clk) if (rst_n) begin : iss_blk
        automatic ctrl_signals_t c;
        automatic logic [4:0]  r1, r2, rd;
        automatic logic [63:0] s1, s2, imm, pc, fwd1, fwd2, a1, a2, rdv, addr;
        automatic logic [2:0]  f3;
        automatic integer       nb;
        automatic logic         excmt, r1u, r2u;
        if (!iss_init) begin
            for (int k = 0; k < 32; k++) begin sx[k] = 64'h0; sxv[k] = 1'b1; end
            for (int k = 0; k < 4096; k++) scsrv[k] = 1'b0;
            iss_init = 1'b1;
        end
        // ISS coverage snapshot: how many of x1..x31 are KNOWN (sxv=1).  If most are
        // UNKNOWN near the crash, "0-fire" is not trustworthy (the ISS is blind).
        if (tcyc > 380000000 && (tcyc - cov_last) >= 4000000) begin : iss_cov
            automatic integer nk; nk = 0;
            for (int k = 1; k < 32; k++) if (sxv[k]) nk = nk + 1;
            cov_last = tcyc;
            $display("[ISSCOV @%0d] known_regs=%0d/31", tcyc, nk);
        end
        // ===== INDEPENDENT INTERRUPT DECISION (the prime remaining suspect) =====
        // The core's irq_pending / irq_cause are combinational outputs of rv_csr,
        // and CFLOW TRUSTS them (exp_next_pc follows ex_trap_enter/trap_vector).  A
        // mis-timed or mis-prioritized interrupt (the timer-phase race that vanishes
        // under MTIME_INSTR) would therefore slip past every existing detector.
        // Re-derive pending+cause HERE from the ground-truth pending sources
        // (timer_irq/sw_irq/ext_irq core inputs) and the INDEPENDENT CSR shadows
        // (scsr[mie/mideleg] + shadow_mstatus/shadow_priv), mirroring rv_csr's
        // mip64/m_irq_bits/s_irq_bits/priority exactly.  Run BEFORE this cycle's
        // trap-push / CSR-write shadow updates so the shadow reflects the same
        // pre-edge committed state the core's registered CSRs do.
        if (ms_init) begin : iss_irq
            automatic logic tirq, sirq, eirq;
            automatic logic [63:0] s_mie, s_mdlg;
            automatic logic mip1, mip3, mip5, mip7, mip9, mip11;
            automatic logic mb11, mb7, mb3, sb9, sb5, sb1;
            automatic logic m_en, s_en, exp_pend;
            automatic logic t_meip, t_msip, t_mtip, t_seip, t_ssip, t_stip;
            automatic logic [63:0] exp_cause;
            tirq  = u_soc.u_cpu.u_core.timer_irq;
            sirq  = u_soc.u_cpu.u_core.sw_irq;
            eirq  = u_soc.u_cpu.u_core.ext_irq;
            // Effective architectural mie = M-bits from the mie(0x304) shadow,
            // S-bits(1,5,9) overridden by the sie(0x104) shadow once Linux writes
            // it (rv_csr: a sie write updates only mie_reg & S_IRQ_MASK).
            s_mie  = scsrv[12'h304] ? scsr[12'h304] : 64'h0;
            if (scsrv[12'h104])
                s_mie = (s_mie & ~64'h222) | (scsr[12'h104] & 64'h222);
            s_mdlg = scsrv[12'h303] ? scsr[12'h303] : 64'h0;
            if ((^{tirq,sirq,eirq} !== 1'bx) && (^s_mie[11:0] !== 1'bx)
                && (^s_mdlg[11:0] !== 1'bx) && (^shadow_mstatus[3:0] !== 1'bx)) begin
                mip1  = sirq & s_mdlg[1];
                mip3  = sirq;
                mip5  = tirq & s_mdlg[5];
                mip7  = tirq;
                mip9  = eirq & s_mdlg[9];
                mip11 = eirq & ~s_mdlg[9];
                mb11 = mip11 & s_mie[11] & ~s_mdlg[11];
                mb7  = mip7  & s_mie[7]  & ~s_mdlg[7];
                mb3  = mip3  & s_mie[3]  & ~s_mdlg[3];
                sb9  = mip9  & s_mie[9];   // sie = mie & S_IRQ_MASK; sip = mip & mask
                sb5  = mip5  & s_mie[5];
                sb1  = mip1  & s_mie[1];
                m_en = (shadow_priv == 2'b11) ? shadow_mstatus[3] : 1'b1;
                s_en = (shadow_priv == 2'b00)
                       || (shadow_priv == 2'b01 && shadow_mstatus[1]);
                t_meip = m_en & mb11;
                t_msip = m_en & mb3 & ~t_meip;
                t_mtip = m_en & mb7 & ~t_meip & ~t_msip;
                t_seip = s_en & sb9 & ~t_meip & ~t_msip & ~t_mtip;
                t_ssip = s_en & sb1 & ~t_meip & ~t_msip & ~t_mtip & ~t_seip;
                t_stip = s_en & sb5 & ~t_meip & ~t_msip & ~t_mtip & ~t_seip & ~t_ssip;
                exp_pend = (m_en & (mb11|mb7|mb3)) | (s_en & (sb9|sb5|sb1));
                exp_cause = t_meip ? (64'h1<<63)|64'd11 :
                            t_msip ? (64'h1<<63)|64'd3  :
                            t_mtip ? (64'h1<<63)|64'd7  :
                            t_seip ? (64'h1<<63)|64'd9  :
                            t_ssip ? (64'h1<<63)|64'd1  :
                            t_stip ? (64'h1<<63)|64'd5  : 64'h0;
                if ((^u_soc.u_cpu.u_core.irq_pending !== 1'bx)
                    && (exp_pend !== u_soc.u_cpu.u_core.irq_pending) && nirq < 30) begin
                    nirq = nirq + 1;
                    $display("[IRQPEND @%0d] core=%b exp=%b | t/s/e=%b%b%b mie=%h mdlg=%h ms=%h priv=%0d",
                             tcyc, u_soc.u_cpu.u_core.irq_pending, exp_pend,
                             tirq, sirq, eirq, s_mie[11:0], s_mdlg[11:0],
                             shadow_mstatus & 64'hFFF, shadow_priv);
                end
                if (exp_pend && (^u_soc.u_cpu.u_core.irq_cause !== 1'bx)
                    && (exp_cause !== u_soc.u_cpu.u_core.irq_cause) && nirq < 30) begin
                    nirq = nirq + 1;
                    $display("[IRQCAUSE @%0d] core=%h exp=%h | t/s/e=%b%b%b mie=%h mdlg=%h ms=%h priv=%0d",
                             tcyc, u_soc.u_cpu.u_core.irq_cause, exp_cause,
                             tirq, sirq, eirq, s_mie[11:0], s_mdlg[11:0],
                             shadow_mstatus & 64'hFFF, shadow_priv);
                end
            end
        end
        // ---- trap entry: capture the hardware-set xepc/xcause/xtval (= the INTENDED
        // values) so a LOST or CORRUPTED trap-CSR write -- the step8 csr_commit class
        // -- is caught when the handler reads back a stale value.  S vs M by vector.
        if ((u_soc.u_cpu.u_core.csr_trap_enter && !u_soc.u_cpu.u_core.stall_ex)
            || u_soc.u_cpu.u_core.ifpf_take) begin : iss_trap
            automatic logic to_s;
            to_s = scsrv[12'h105] && (u_soc.u_cpu.u_core.trap_vector == scsr[12'h105]);
            if (to_s) begin
                scsr[12'h141]=u_soc.u_cpu.u_core.csr_trap_epc;   scsrv[12'h141]=1'b1;
                scsr[12'h142]=u_soc.u_cpu.u_core.csr_trap_cause; scsrv[12'h142]=1'b1;
                scsr[12'h143]=u_soc.u_cpu.u_core.csr_trap_val;   scsrv[12'h143]=1'b1;
                if (ms_init) begin                 // sstatus PUSH (S-mode trap)
                    shadow_mstatus[8] = (shadow_priv==2'b01) ? 1'b1 : 1'b0;  // SPP
                    shadow_mstatus[5] = shadow_mstatus[1];                    // SPIE=SIE
                    shadow_mstatus[1] = 1'b0;                                 // SIE=0
                    shadow_priv       = 2'b01;
                end
            end else begin
                scsr[12'h341]=u_soc.u_cpu.u_core.csr_trap_epc;   scsrv[12'h341]=1'b1;
                scsr[12'h342]=u_soc.u_cpu.u_core.csr_trap_cause; scsrv[12'h342]=1'b1;
                scsr[12'h343]=u_soc.u_cpu.u_core.csr_trap_val;   scsrv[12'h343]=1'b1;
                if (ms_init) begin                 // mstatus PUSH (M-mode trap)
                    shadow_mstatus[12:11] = shadow_priv;                      // MPP
                    shadow_mstatus[7]     = shadow_mstatus[3];                // MPIE=MIE
                    shadow_mstatus[3]     = 1'b0;                             // MIE=0
                    shadow_priv           = 2'b11;
                end
            end
        end
        excmt = u_soc.u_cpu.u_core.id_ex_valid && !u_soc.u_cpu.u_core.stall_ex
                && !u_soc.u_cpu.u_core.flush_ex_mem
                && !u_soc.u_cpu.u_core.fpu_start_stall
                && !u_soc.u_cpu.u_core.muldiv_start_stall;
        if (excmt) begin
            c    = u_soc.u_cpu.u_core.id_ex_ctrl;
            r1   = u_soc.u_cpu.u_core.id_ex_rs1_addr;
            r2   = u_soc.u_cpu.u_core.id_ex_rs2_addr;
            rd   = u_soc.u_cpu.u_core.id_ex_rd_addr;
            imm  = u_soc.u_cpu.u_core.id_ex_imm;
            pc   = u_soc.u_cpu.u_core.id_ex_pc;
            f3   = u_soc.u_cpu.u_core.id_ex_funct3;
            fwd1 = u_soc.u_cpu.u_core.fwd_rs1_data;
            fwd2 = u_soc.u_cpu.u_core.fwd_rs2_data;
            s1   = sx[r1];
            s2   = sx[r2];
            // xRET POPs the saved interrupt-enable / privilege from mstatus.
            if (ms_init && c.is_sret) begin
                shadow_mstatus[1] = shadow_mstatus[5];                 // SIE = SPIE
                shadow_priv       = shadow_mstatus[8] ? 2'b01 : 2'b00; // priv = SPP
                shadow_mstatus[5] = 1'b1;                              // SPIE = 1
                shadow_mstatus[8] = 1'b0;                             // SPP = U
            end
            if (ms_init && c.is_mret) begin
                shadow_mstatus[3]     = shadow_mstatus[7];             // MIE = MPIE
                shadow_priv           = shadow_mstatus[12:11];         // priv = MPP
                shadow_mstatus[7]     = 1'b1;                          // MPIE = 1
                shadow_mstatus[12:11] = 2'b00;                        // MPP = U
            end
            r1u = !c.is_fp && (c.alu_src1 == ALU_SRC1_RS1 || c.mem_read || c.mem_write
                               || c.branch || c.jalr || c.is_muldiv || c.is_amo);
            r2u = !c.is_fp && (c.alu_src2 == ALU_SRC2_RS2 || c.mem_write || c.branch
                               || c.is_muldiv || (c.is_amo && !c.is_lr));
            if (r1u && r1 != 5'd0 && sxv[r1] && (fwd1 !== s1) && niss < 25) begin
                niss = niss + 1;
                $display("[ISS @%0d] pc=%h FWD-RS1 x%0d core=%h shadow=%h", tcyc, pc, r1, fwd1, s1);
            end
            if (r2u && r2 != 5'd0 && sxv[r2] && (fwd2 !== s2) && niss < 25) begin
                niss = niss + 1;
                $display("[ISS @%0d] pc=%h FWD-RS2 x%0d core=%h shadow=%h", tcyc, pc, r2, fwd2, s2);
            end
            // CONDITIONAL-BRANCH operands use a SEPARATE registered mux (step10
            // br_rs*_data via wb_data_brn), distinct from the ALU's fwd_rs*_data.  A
            // wrong branch operand (load->branch interlock failing under step8 timing)
            // flips the branch direction with no value detector seeing it -- so check
            // br_rs*_data against the shadow too.
            if (c.branch && r1 != 5'd0 && sxv[r1]
                && (u_soc.u_cpu.u_core.br_rs1_data !== s1) && niss < 25) begin
                niss = niss + 1;
                $display("[ISS @%0d] pc=%h BR-RS1 x%0d core_br=%h shadow=%h (fwd=%h)",
                         tcyc, pc, r1, u_soc.u_cpu.u_core.br_rs1_data, s1, fwd1);
            end
            if (c.branch && r2 != 5'd0 && sxv[r2]
                && (u_soc.u_cpu.u_core.br_rs2_data !== s2) && niss < 25) begin
                niss = niss + 1;
                $display("[ISS @%0d] pc=%h BR-RS2 x%0d core_br=%h shadow=%h (fwd=%h)",
                         tcyc, pc, r2, u_soc.u_cpu.u_core.br_rs2_data, s2, fwd2);
            end
            // INDEPENDENT BRANCH DIRECTION: re-derive taken/not-taken from the
            // SHADOW operands and compare to the core's branch_taken_ex (TRUSTED by
            // CFLOW's exp_next_pc).  Catches a comparator/resolution bug or a wrong
            // branch operand that flips the path with no value detector seeing it.
            if (c.branch && sxv[r1] && sxv[r2]) begin : iss_brdir
                automatic logic tk;
                case (f3)
                    3'b000:  tk = (s1 === s2);
                    3'b001:  tk = (s1 !== s2);
                    3'b100:  tk = ($signed(s1) <  $signed(s2));
                    3'b101:  tk = ($signed(s1) >= $signed(s2));
                    3'b110:  tk = (s1 <  s2);
                    3'b111:  tk = (s1 >= s2);
                    default: tk = 1'bx;
                endcase
                if ((tk !== 1'bx) && (^u_soc.u_cpu.u_core.branch_taken_ex !== 1'bx)
                    && (tk !== u_soc.u_cpu.u_core.branch_taken_ex) && nbrd < 25) begin
                    nbrd = nbrd + 1;
                    $display("[BRDIR @%0d] pc=%h f3=%b core_tk=%b exp_tk=%b s1=%h s2=%h",
                             tcyc, pc, f3, u_soc.u_cpu.u_core.branch_taken_ex, tk, s1, s2);
                end
            end
            // ---- ISS COVERAGE PROBE (is "0-fire" trustworthy?) -----------------
            // The ISS marks rd UNKNOWN (sxv=0) for MMIO loads (CLINT/PLIC/UART) and
            // SC.  A control-flow decision (cond-branch / JALR target) on an UNKNOWN
            // operand is a DOUBLE blind spot: BRDIR skips it (needs sxv) and CFLOW
            // TRUSTS branch_taken_ex/target.  These are the ONLY control-flow
            // divergences the whole detector suite cannot see.  Flag them near the
            // crash window so we know whether the bug could hide here.
            if (tcyc > 380000000) begin
                if (c.branch && ((r1 != 5'd0 && !sxv[r1]) || (r2 != 5'd0 && !sxv[r2]))
                    && ncfunk < 60) begin
                    ncfunk = ncfunk + 1;
                    $display("[CFUNK @%0d] BR pc=%h x%0d(v%b) x%0d(v%b) tk=%b",
                             tcyc, pc, r1, sxv[r1], r2, sxv[r2],
                             u_soc.u_cpu.u_core.branch_taken_ex);
                end
                if (c.jalr && r1 != 5'd0 && !sxv[r1] && ncfunk < 60) begin
                    ncfunk = ncfunk + 1;
                    $display("[CFUNK @%0d] JALR pc=%h x%0d(v0) tgt=%h",
                             tcyc, pc, r1, u_soc.u_cpu.u_core.branch_target_ex);
                end
            end
            // ---- CSR instruction ----
            if ((c.wb_src == WB_SRC_CSR) || c.csr_write) begin : iss_csr
                automatic logic [11:0] ca;
                automatic logic [63:0] cold, cnew, cwr, msk;
                ca   = u_soc.u_cpu.u_core.id_ex_csr_addr;
                cwr  = f3[2] ? {59'b0, r1} : s1;            // imm form vs register form
                if (ca == 12'h300 || ca == 12'h100) begin
                    // ---- mstatus(0x300) / sstatus(0x100): independent push/pop model ----
                    msk = (ca==12'h100) ? MS_CMP_S : MS_CMP_M;
                    if (!ms_init) begin
                        shadow_mstatus = (ca==12'h300)
                            ? u_soc.u_cpu.u_core.csr_rdata_ex
                            : (shadow_mstatus & ~MS_CMP_S)
                              | (u_soc.u_cpu.u_core.csr_rdata_ex & MS_CMP_S);
                        shadow_priv = u_soc.u_cpu.u_core.priv_level;
                        ms_init = 1'b1;
                    end else begin
                        if ((c.wb_src==WB_SRC_CSR) && rd != 5'd0
                            && ((u_soc.u_cpu.u_core.csr_rdata_ex & msk) !== (shadow_mstatus & msk))
                            && niss < 25) begin
                            niss = niss + 1;
                            $display("[ISS @%0d] pc=%h XSTATUS-RD a=%h core=%h shadow=%h msk=%h priv=%0d",
                                     tcyc, pc, ca, u_soc.u_cpu.u_core.csr_rdata_ex & msk,
                                     shadow_mstatus & msk, msk, shadow_priv);
                        end
                        if (c.csr_write) case (f3[1:0])
                            2'b01: shadow_mstatus = (shadow_mstatus & ~msk) | (cwr & msk);
                            2'b10: shadow_mstatus = shadow_mstatus |  (cwr & msk);
                            2'b11: shadow_mstatus = shadow_mstatus & ~(cwr & msk);
                            default: ;
                        endcase
                    end
                    if (c.reg_write && rd != 5'd0) begin
                        sx[rd]=u_soc.u_cpu.u_core.csr_rdata_ex; sxv[rd]=1'b1;
                    end
                end else begin
                    // ---- generic software-written CSR shadow ----
                    cold = (iss_csr_tracked(ca) && scsrv[ca]) ? scsr[ca]
                                                              : u_soc.u_cpu.u_core.csr_rdata_ex;
                    if (iss_csr_tracked(ca) && scsrv[ca] && (c.wb_src==WB_SRC_CSR) && rd != 5'd0
                        && (u_soc.u_cpu.u_core.csr_rdata_ex !== cold) && niss < 25) begin
                        niss = niss + 1;
                        $display("[ISS @%0d] pc=%h CSR-RD a=%h core=%h shadow=%h",
                                 tcyc, pc, ca, u_soc.u_cpu.u_core.csr_rdata_ex, cold);
                    end
                    case (f3[1:0])
                        2'b01:   cnew = cwr;
                        2'b10:   cnew = cold | cwr;
                        2'b11:   cnew = cold & ~cwr;
                        default: cnew = cold;
                    endcase
                    if (c.csr_write && iss_csr_tracked(ca)) begin scsr[ca]=cnew; scsrv[ca]=1'b1; end
                    if (c.reg_write && rd != 5'd0) begin sx[rd]=cold; sxv[rd]=1'b1; end
                end
            end
            else if (c.reg_write && rd != 5'd0) begin
                sxv[rd] = 1'b1;
                if (c.is_sc)
                    sxv[rd] = 1'b0;
                else if (c.is_muldiv)
                    sx[rd] = dgolden(c.muldiv_op, s1, s2);
                else if (c.is_amo) begin
                    nb  = (f3 == 3'b011) ? 8 : 4;
                    rdv = mem_va_bytes(s1, nb);
                    sx[rd] = (f3 == 3'b010) ? {{32{rdv[31]}}, rdv[31:0]} : rdv;
                end else case (c.wb_src)
                    WB_SRC_ALU: begin
                        a1 = (c.alu_src1==ALU_SRC1_RS1) ? s1
                           : (c.alu_src1==ALU_SRC1_PC)  ? pc : 64'h0;
                        a2 = (c.alu_src2==ALU_SRC2_RS2) ? s2
                           : (c.alu_src2==ALU_SRC2_IMM) ? imm : 64'd4;
                        sx[rd] = iss_alu(c.alu_op, a1, a2);
                    end
                    WB_SRC_PC4: sx[rd] = pc + (c.is_compressed ? 64'd2 : 64'd4);
                    WB_SRC_MEM: begin
                        addr = s1 + imm;
                        // Only model DRAM loads; an MMIO/peripheral load (CLINT/PLIC/
                        // UART @0xC...) is not in the BFM image, so mark its rd unknown.
                        if (va2pa(addr) !== VA2PA_BAD && va2pa(addr) >= MEM_BASE
                            && (va2pa(addr) - MEM_BASE) < (1<<26)) begin
                            nb   = (f3[1:0]==2'b00)?1 : (f3[1:0]==2'b01)?2 : (f3[1:0]==2'b10)?4 : 8;
                            rdv  = mem_va_bytes(addr, nb);
                            case (f3)
                              3'b000:  sx[rd] = {{56{rdv[7]}},  rdv[7:0]};
                              3'b001:  sx[rd] = {{48{rdv[15]}}, rdv[15:0]};
                              3'b010:  sx[rd] = {{32{rdv[31]}}, rdv[31:0]};
                              default: sx[rd] = rdv;
                            endcase
                        end else sxv[rd] = 1'b0;       // MMIO / unmapped: unknown
                    end
                    WB_SRC_CSR: sx[rd] = u_soc.u_cpu.u_core.csr_rdata_ex;
                    WB_SRC_FPU: sx[rd] = u_soc.u_cpu.u_core.fpu_result_i;
                    default:    sx[rd] = u_soc.u_cpu.u_core.ex_result;
                endcase
            end
        end
    end
    // ===== STEP 2: independent satp / translation cross-check =====
    // Both the base ISS and EVERY value detector translate VAs with the CORE's
    // satp_out (the va2pa() helper), so a load/store the core executes under a STALE
    // TLB entry / mistimed satp barrier -- reading or writing the WRONG physical
    // address -- is a SHARED blind spot: STLOSS/DLOAD check the SAME wrong PA the
    // core used and pass, while the INTENDED PA is left stale (a later load returns
    // its stale/NULL contents -> the kdevtmpfs path-pointer NULL deref).  Re-walk the
    // page table FRESHLY (no TLB) for every TLB-HIT data access and compare to the
    // core's actual hardware PA (mmu_dmem_pa).  A fresh-walk-vs-hardware divergence =
    // the core translated under a state inconsistent with the current satp_out page
    // tables.  Only TLB hits are checked: a PTW fill is fresh by construction (it
    // walked the current tables), so it trivially agrees.  PTW folds superpage VA
    // bits into the stored ppn (rv_mmu PTW_L1/L2 leaf), so {tlb_ppn,va[11:0]} ==
    // va2pa() exactly for a correct entry -> no superpage false positives.  The
    // capture cycle (mem_can_capture, which implies vm_data on) latches the VA; the
    // next cycle the registered mmu_dmem_pa (mt_pa_xlat) is valid for that access.
    logic [XLEN-1:0] sx_va  = '0;
    logic            sx_we  = 1'b0;
    logic            sx_vld = 1'b0;
    integer          nsatp        = 0;
    integer          sx_lastflush = 0;
    always @(posedge clk) if (rst_n) begin : satp_xchk
        automatic logic [63:0] wp;
        if (u_soc.u_cpu.tlb_flush_out) sx_lastflush = tcyc;
        // Compare the access captured LAST cycle (its PA is now registered & valid).
        if (sx_vld && (u_soc.u_cpu.satp_out[63:60] != 4'd0)
            && (^sx_va !== 1'bx) && (^u_soc.u_cpu.mmu_dmem_pa !== 1'bx)) begin
            wp = va2pa(sx_va);
            if (wp !== VA2PA_BAD && (wp !== u_soc.u_cpu.mmu_dmem_pa) && nsatp < 40) begin
                nsatp = nsatp + 1;
                $display("[SATPXLAT @%0d] va=%h core_pa=%h walk_pa=%h we=%b satp=%h priv=%0d since_flush=%0d",
                         tcyc, sx_va, u_soc.u_cpu.mmu_dmem_pa, wp, sx_we,
                         u_soc.u_cpu.satp_out, u_soc.u_cpu.priv_out, tcyc - sx_lastflush);
            end
        end
        sx_vld <= u_soc.u_cpu.u_mmu.mem_can_capture;
        sx_va  <= u_soc.u_cpu.core_dmem_va;
        sx_we  <= u_soc.u_cpu.core_dmem_we;
    end
`endif
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
    // MISALIGNED-load result checker (the DLOAD check above EXCLUDES mal_cross; a
    // misaligned load whose phase-0 word is lost to a younger-instruction trap is
    // exactly the #16 class -- and the prime suspect for the step-8 interrupt race,
    // since path resolution does unaligned 8-byte string loads).  Captures the load
    // VA at retire and compares the architectural result to the bytes actually in
    // memory (byte-wise through the page table).
    integer nmalld = 0;
    logic            mal_ld_chk = 1'b0;
    logic [XLEN-1:0] mal_ld_va  = '0;
    logic [XLEN-1:0] mal_ld_pc  = '0;
    logic [2:0]      mal_ld_f3  = '0;
    // STORE-EFFECT-LOST checker.  A committed store's intended value (rs2, proven
    // correct by the forwarding check) must appear in memory afterwards.  A store
    // whose WRITE is dropped/squashed/skipped by the step-8 interrupt race leaves
    // memory stale -- invisible to every other detector (a later load correctly
    // returns the stale value, so DLOAD/MALLD pass).  Captured non-AMO DRAM stores
    // are held in a small delay buffer and checked once the AXI write has drained.
    localparam int SVQ = 48;
    integer nstl = 0;
    logic [XLEN-1:0] svq_va   [SVQ];
    logic [63:0]     svq_data [SVQ];
    logic [3:0]      svq_sz   [SVQ];
    logic [XLEN-1:0] svq_pc   [SVQ];
    integer          svq_cyc  [SVQ];
    logic            svq_vld  [SVQ];
    integer          svq_wr = 0;   // tail (enqueue)
    integer          svq_rd = 0;   // head (check/dequeue)
    // AMO write-phase checker.  AMO/LR-SC are EXCLUDED from every other detector
    // (forwarding/DLOAD/MALLD/STLOSS all gate on !is_amo), so a true AMO whose
    // read-modify-WRITE phase is skipped/lost by the step-8 interrupt race -- the
    // netlink-atomic class -- is the only remaining uncovered corruption.  Track
    // whether the AMO in MEM issued its memory write before it retires.
    integer namo = 0;
    logic            amo_wrote = 1'b0;   // current MEM-stage AMO has issued its write
    logic            amo_seen  = 1'b0;   // an AMO is/has been in MEM this residence
    logic [XLEN-1:0] amo_wpa   = '0;
    logic [63:0]     amo_wdata = '0;
    logic [XLEN-1:0] amo_wpc   = '0;
    logic            amo_chk_vld = 1'b0;
    integer          amo_chk_cyc = 0;
    logic [XLEN-1:0] amo_chk_pa  = '0;
    logic [63:0]     amo_chk_d   = '0;
    logic [XLEN-1:0] amo_chk_pc  = '0;
    // AMO/LR stale-READ checker.  The loaded OLD value (rd) of an LR or true AMO must
    // equal memory at its address at read time.  The netlink class was the read being
    // SKIPPED so the modify computed from a STALE prior dmem_rdata -- AMOLOST cannot
    // see this (memory matches the WRONG value the core wrote).  Snapshot memory at
    // the read phase (before any write) and compare the architectural rd at retire.
    integer nsrd = 0;
    logic            srd_pend = 1'b0;
    logic [63:0]     srd_old  = '0;
    logic [XLEN-1:0] srd_pa   = '0;
    logic [XLEN-1:0] srd_pc   = '0;
    logic [2:0]      srd_f3   = '0;
    // LR/SC RESERVATION shadow.  The SC success/fail report (sc_success -> rd) is the
    // last uncovered atomic semantic.  Model the reservation with CLEAN timing (set
    // on LR retire, void on ANY committed trap/xRET, the priv-spec rule) and compare
    // to the core's sc_success at each SC.  A divergence = the core kept/lost a
    // reservation wrongly (the netlink/lrsc class) -> a cmpxchg succeeds with a stale
    // value or spins, exactly the interrupt-vs-atomic corruption the bug needs.
    integer nresv = 0;
    logic            rv_shadow_v = 1'b0;
    logic [XLEN-1:0] rv_shadow_a = '0;
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
    // === [STDROP] RANDLAT-immune store/AMO write-to-DRAM matcher ==============
    // Every committed DRAM store and every AMO write phase is WRITE-THROUGH and so
    // produces EXACTLY ONE AXI write transaction, applied by the BFM to mem_b in
    // rv_axi_dualport_mem_bfm's W_WWAIT (observable as d_wready & d_wvalid).  We do
    // NOT use a fixed drain window: under BFM_RANDLAT the AXI write latency is
    // arbitrary, which is exactly why the old STLOSS (enqueue + compare 64 cy later)
    // false-positives.  Instead we ENQUEUE each accepted core write (the same 1:1
    // bus-completion edge the ring/STMEM detectors use) and POP it when the matching
    // BFM apply is OBSERVED.  Per-(8B-aligned)-address matching tolerates unrelated
    // extra writers (e.g. a PTW A/D writeback) and out-of-order pops across
    // addresses (writes to ONE word still drain in program order on a single
    // in-order master).  Two failure modes:
    //   [STDROP]    a pending write never drains (aged out, or overwritten a full
    //               ring lap later) = the write-phase-loss class (#16 / netlink).
    //   [STCORRUPT] a write drains with data/strobe != the enqueued intent.
    localparam int SDQ = 1024;
    logic [63:0] sdq_pa   [SDQ];   // 8-byte-aligned word PA
    logic [63:0] sdq_data [SDQ];   // intended write data (full 64-bit)
    logic [7:0]  sdq_strb [SDQ];   // byte strobe
    logic [63:0] sdq_pc   [SDQ];
    integer      sdq_cyc  [SDQ];
    logic        sdq_amo  [SDQ];   // 1 = AMO write phase, 0 = plain store
    logic        sdq_vld  [SDQ];
    integer      sdq_wr    = 0;    // ring enqueue index
    integer      sdq_scrub = 0;    // age-out scrub pointer (one slot / cycle)
    integer      n_sd_enq = 0, n_sd_drain = 0, n_sd_match = 0, n_sd_nomatch = 0;
    integer      n_stdrop = 0, n_stcorrupt = 0;
    // A genuine AXI write drains within ~aw+w+b+spread (<= ~100 cy even under
    // RANDLAT); anything pending 100k cy later was dropped.  The overwrite path
    // (a full SDQ lap of newer writes elapsed) is the traffic-adaptive companion.
    localparam integer SD_DROP_AGE = 100_000;
    // Capture each write at the cycle the core first PRESENTS the request (this
    // deterministically PRECEDES the BFM apply -- the bridge must see the request
    // before it issues AW+W+the W-handshake the BFM drains on).  Dedup by MEM-stage
    // instruction identity: a single store's multi-cycle request hold (stall /
    // ~imem_ready freeze) shares one ex_mem_pc and collapses to ONE enqueue, while
    // back-to-back distinct stores (different ex_mem_pc) each enqueue.
    logic        sd_req_q  = 1'b0;
    logic [63:0] sd_cap_pc = '0;
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
                u_soc.u_cpu.u_core.bfpc, u_soc.u_cpu.u_core.imem_addr,
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
`ifdef BOOT_FETCHWIN
        // step-8 IF-stage (FTQ + halfword buffer + aligner) cycle-by-cycle trace, to
        // localize the 4-byte fetch SKID (FCHK: if_id_inst = the word at if_id_pc+4).
        // Prints the served word (bfpc/addr_q/imem_rdata), the buffer push/flush/dup +
        // skip_low controls, the FTQ/redirect steering, and the aligner output + IF/ID.
        if (tcyc >= `BOOT_FETCHWIN && tcyc <= `BOOT_FETCHWIN + 1400) begin
            $display("[FW c%0d] imrdy=%b iaddr=%h bfpc=%h aq=%h ird=%08h | rpq=%b rtgt=%h reff=%b rstl=%b brk=%b tmr=%b ifpf=%b | push=%b flush=%b dup=%b skl=%b hd=%0d ht=%0d hc=%0d | av=%b h0pc=%h ainst=%08h | ifv=%b ifpc=%h ifinst=%08h sid=%b",
                tcyc, u_soc.imem_ready, u_soc.u_cpu.u_core.imem_addr,
                u_soc.u_cpu.u_core.bfpc, u_soc.gen_icache.u_ic.addr_q, u_soc.imem_rdata,
                u_soc.u_cpu.u_core.redir_pend_q, u_soc.u_cpu.u_core.redir_pend_tgt_q,
                u_soc.u_cpu.u_core.redir_eff, u_soc.u_cpu.u_core.redirect_stall,
                u_soc.u_cpu.u_core.branch_taken_ex, u_soc.u_cpu.u_core.trap_or_mret,
                u_soc.u_cpu.u_core.ifpf_take,
                u_soc.u_cpu.u_core.hb_push, u_soc.u_cpu.u_core.hb_flush,
                u_soc.u_cpu.u_core.hb_dup, u_soc.u_cpu.u_core.skip_low_q,
                u_soc.u_cpu.u_core.hb_head, u_soc.u_cpu.u_core.hb_tail,
                u_soc.u_cpu.u_core.hb_count,
                u_soc.u_cpu.u_core.align_valid, u_soc.u_cpu.u_core.h0pc,
                u_soc.u_cpu.u_core.align_inst,
                u_soc.u_cpu.u_core.if_id_valid, u_soc.u_cpu.u_core.if_id_pc,
                u_soc.u_cpu.u_core.if_id_inst, u_soc.u_cpu.u_core.stall_id);
            $display("   [FW2 c%0d] gnt=%b fhd=%0d ftl=%0d fcnt=%0d fhead_addr=%h genpc=%h fpop=%b freload=%b | ic_st=%0d creq=%b reqq=%b funsrv=%b cready=%b",
                tcyc, u_soc.u_cpu.u_core.imem_gnt,
                u_soc.u_cpu.u_core.ftq_head, u_soc.u_cpu.u_core.ftq_tail,
                u_soc.u_cpu.u_core.ftq_count,
                u_soc.u_cpu.u_core.ftq[u_soc.u_cpu.u_core.ftq_head],
                u_soc.u_cpu.u_core.gen_pc, u_soc.u_cpu.u_core.ftq_pop,
                u_soc.u_cpu.u_core.ftq_reload,
                u_soc.gen_icache.u_ic.state, u_soc.gen_icache.u_ic.c_req,
                u_soc.gen_icache.u_ic.req_q, u_soc.gen_icache.u_ic.fill_unserved,
                u_soc.gen_icache.u_ic.c_ready);
        end
`endif
`ifdef BOOT_CYCTRACE
        if (tcyc < 50)
            $display("[c%0d] fpc=%h ir=%b ird=%08h memwin=%08h sid=%b sex=%b idxpc=%h idxv=%b",
                tcyc, u_soc.u_cpu.u_core.bfpc, u_soc.imem_ready, u_soc.imem_rdata,
                (^u_soc.u_cpu.u_core.bfpc !== 1'bx && u_soc.u_cpu.u_core.bfpc >= MEM_BASE)
                    ? mem_win(u_soc.u_cpu.u_core.bfpc) : 32'hDEADDEAD,
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
          tcyc, u_soc.u_cpu.u_core.bfpc,
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
                tcyc, u_soc.u_cpu.u_core.bfpc, u_soc.imem_ready,
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
        if (u_soc.imem_ready && (^u_soc.u_cpu.u_core.bfpc !== 1'bx)
            && (u_soc.u_cpu.u_core.bfpc >= MEM_BASE)
            && (u_soc.imem_rdata !== mem_win(u_soc.u_cpu.u_core.bfpc)) && nmis < 20) begin
            nmis <= nmis + 1;
            $display("[IMIS @%0d] pc=%h I$=%h mem=%h",
                     tcyc, u_soc.u_cpu.u_core.bfpc, u_soc.imem_rdata,
                     mem_win(u_soc.u_cpu.u_core.bfpc));
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
        // [STPC]: core-side store-PC watch.  When the core commits a store to the
        // watched physical word (BOOT_WATCH_PA, word-aligned), print the MEM-stage
        // PC that issued it -- so the [ST]-diff'd corrupting/squashed store can be
        // tied straight to the instruction (and we can inspect the IF/flush state
        // around it).  Inert when BOOT_WATCH_PA=0.
        if ((`BOOT_WATCH_PA != 64'h0)
            && u_soc.mmu_dmem_req && u_soc.core_dmem_we && !u_soc.periph_is_periph
            && !u_soc.core_dmem_wait
            && ((u_soc.mmu_dmem_pa & ~64'h7) == (`BOOT_WATCH_PA & ~64'h7)))
            $display("[STPC @%0d] pa=%h wdata=%h wstrb=%b pc=%h exmemv=%b",
                     tcyc, u_soc.mmu_dmem_pa, u_soc.core_dmem_wdata,
                     u_soc.core_dmem_wstrb, u_soc.u_cpu.u_core.ex_mem_pc,
                     u_soc.u_cpu.u_core.ex_mem_valid);
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
        // ---- step-8 fetch PC-tag <-> data DESYNC detector -------------------
        // exp_pa mirrors bfpc: capture the translation (mmu_imem_pa) of the VA the
        // core presents on every imem_ready, exactly as bfpc captures the VA.  So
        // exp_pa == translate(bfpc).  At an hb_push (the core commits the fetched
        // word, tagged bfpc, into the aligner buffer) the served data is
        // window(addr_q); if addr_q != exp_pa the committed instruction is
        // mis-tagged = the FTQ/I$ lockstep desync that crashes Linux on hardware.
        if (u_soc.imem_ready) exp_pa <= u_soc.mmu_imem_pa;
        if (u_soc.u_cpu.u_core.hb_push
            && (^u_soc.gen_icache.u_ic.addr_q !== 1'bx) && (^exp_pa !== 1'bx)
            && (u_soc.gen_icache.u_ic.addr_q >= MEM_BASE)
            && (u_soc.gen_icache.u_ic.addr_q != exp_pa) && ndesync < 30) begin
            ndesync <= ndesync + 1;
            $display("[DESYNC @%0d] addr_q=%h exp_pa=%h bfpc=%h imem_rdata=%h mem@addr_q=%h",
                     tcyc, u_soc.gen_icache.u_ic.addr_q, exp_pa,
                     u_soc.u_cpu.u_core.bfpc, u_soc.imem_rdata,
                     mem_win(u_soc.gen_icache.u_ic.addr_q));
        end
        // ---- step-8 FETCHED-INSTRUCTION correctness detector ----------------
        // The decisive check: the instruction word the aligner hands to DECODE
        // (if_id_inst @ if_id_pc) must equal the instruction actually in memory at
        // that PC (translated through the live page table).  This catches EVERY
        // fetch error -- aligner mis-pick, halfword-buffer skid, PC-tag desync --
        // even ones where addr_q itself stayed consistent (so [DESYNC] is silent).
        // Checked once per newly-committed IF/ID instruction.
        if (u_soc.u_cpu.u_core.if_id_valid
            && (^u_soc.u_cpu.u_core.if_id_pc !== 1'bx)
            && (u_soc.u_cpu.u_core.if_id_pc !== prev_ifid_pc)
            && nfchk < 40) begin : fchk_blk
            logic [63:0] pa0, pa2; logic [15:0] got_lo, got_hi, exp_lo, exp_hi;
            logic mism;
            pa0 = va2pa(u_soc.u_cpu.u_core.if_id_pc);
            mism = 1'b0; exp_lo = 16'h0; exp_hi = 16'h0;
            got_lo = u_soc.u_cpu.u_core.if_id_inst[15:0];
            got_hi = u_soc.u_cpu.u_core.if_id_inst[31:16];
            if (pa0 !== VA2PA_BAD && pa0 >= MEM_BASE && (pa0 - MEM_BASE) < (1<<26)) begin
                exp_lo = mem_hw(pa0);
                if (got_lo !== exp_lo) mism = 1'b1;
                if (got_lo[1:0] == 2'b11) begin           // 32-bit: check high half too
                    pa2 = va2pa(u_soc.u_cpu.u_core.if_id_pc + 64'd2);
                    if (pa2 !== VA2PA_BAD && pa2 >= MEM_BASE && (pa2 - MEM_BASE) < (1<<26)) begin
                        exp_hi = mem_hw(pa2);
                        if (got_hi !== exp_hi) mism = 1'b1;
                    end
                end
                if (mism) begin
                    nfchk <= nfchk + 1;
                    $display("[FCHK @%0d] pc=%h got=%04h_%04h exp=%04h_%04h pa0=%h bfpc=%h addr_q=%h",
                             tcyc, u_soc.u_cpu.u_core.if_id_pc, got_hi, got_lo,
                             exp_hi, exp_lo, pa0, u_soc.u_cpu.u_core.bfpc,
                             u_soc.gen_icache.u_ic.addr_q);
                end
            end
        end
        if (u_soc.u_cpu.u_core.if_id_valid)
            prev_ifid_pc <= u_soc.u_cpu.u_core.if_id_pc;
        // ---- step-8 halfword-buffer push CONTINUITY (skip/dup) detector -----
        if (u_soc.u_cpu.u_core.hb_flush) begin
            last_push_vld <= 1'b0;
        end else if (u_soc.u_cpu.u_core.hb_push) begin
            if (last_push_vld && (^u_soc.u_cpu.u_core.bfpc !== 1'bx)
                && (u_soc.u_cpu.u_core.bfpc !== (last_push_bfpc + 64'd4))
                && nhbsk < 40) begin
                nhbsk <= nhbsk + 1;
                $display("[HBSKIP @%0d] bfpc=%h last=%h delta=%0d addr_q=%h skiplow=%b imrd=%h",
                         tcyc, u_soc.u_cpu.u_core.bfpc, last_push_bfpc,
                         $signed(u_soc.u_cpu.u_core.bfpc - last_push_bfpc),
                         u_soc.gen_icache.u_ic.addr_q, u_soc.u_cpu.u_core.skip_low_q,
                         u_soc.imem_rdata);
            end
            last_push_bfpc <= u_soc.u_cpu.u_core.bfpc;
            last_push_vld  <= 1'b1;
        end
        // ---- step-8 CONTROL-FLOW continuity / wrong-mepc detector -----------
        begin : cflow_blk
            logic        cf_proc, cf_sex;
            logic [XLEN-1:0] cf_pc, cf_len;
            cf_sex = u_soc.u_cpu.u_core.stall_ex;
            cf_pc  = u_soc.u_cpu.u_core.id_ex_pc;
            cf_len = u_soc.u_cpu.u_core.id_ex_ctrl.is_compressed ? XLEN'(2) : XLEN'(4);
            // an id_ex instruction is architecturally processed in EX this cycle
            cf_proc = u_soc.u_cpu.u_core.id_ex_valid && !cf_sex
                      && !u_soc.u_cpu.u_core.fpu_start_stall
                      && !u_soc.u_cpu.u_core.muldiv_start_stall;
            if (u_soc.u_cpu.u_core.ifpf_take) begin
                exp_next_pc <= u_soc.u_cpu.u_core.trap_vector; cf_synced <= 1'b1;
            end else if (u_soc.u_cpu.u_core.mem_trap_enter && !cf_sex) begin
                exp_next_pc <= u_soc.u_cpu.u_core.trap_vector; cf_synced <= 1'b1;
            end else if (cf_proc) begin
                if (cf_synced && (^cf_pc !== 1'bx) && (^exp_next_pc !== 1'bx)
                    && (cf_pc !== exp_next_pc) && ncflow < 40) begin
                    ncflow <= ncflow + 1;
                    $display("[CFLOW @%0d] got=%h exp=%h inst=%08h | irq=%b extrap=%b mret=%b sret=%b brtk=%b | mepc=%h mtvec=%h",
                             tcyc, cf_pc, exp_next_pc, u_soc.u_cpu.u_core.id_ex_inst,
                             u_soc.u_cpu.u_core.irq_pending,
                             u_soc.u_cpu.u_core.ex_trap_enter,
                             u_soc.u_cpu.u_core.ex_mret_en, u_soc.u_cpu.u_core.ex_sret_en,
                             u_soc.u_cpu.u_core.branch_taken_ex,
                             u_soc.u_cpu.u_core.mepc_out, u_soc.u_cpu.u_core.trap_vector);
                end
                if (u_soc.u_cpu.u_core.ex_trap_enter)
                    exp_next_pc <= u_soc.u_cpu.u_core.trap_vector;
                else if (u_soc.u_cpu.u_core.ex_mret_en)
                    exp_next_pc <= u_soc.u_cpu.u_core.mepc_out;
                else if (u_soc.u_cpu.u_core.ex_sret_en)
                    exp_next_pc <= u_soc.u_cpu.u_core.sepc_out;
                else if (u_soc.u_cpu.u_core.branch_taken_ex)
                    exp_next_pc <= u_soc.u_cpu.u_core.branch_target_ex;
                else if (u_soc.u_cpu.u_core.satp_write_redir)
                    exp_next_pc <= u_soc.u_cpu.u_core.satp_redir_tgt;
                else
                    exp_next_pc <= cf_pc + cf_len;
                cf_synced <= 1'b1;
            end
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
            // Parallel latch for MISALIGNED (mal_cross) loads: capture the access VA.
            if (u_soc.u_cpu.u_core.ex_mem_valid && u_soc.u_cpu.u_core.ex_mem_ctrl.mem_read
                && !u_soc.u_cpu.u_core.ex_mem_ctrl.is_amo && u_soc.u_cpu.u_core.mal_cross
                && !u_soc.periph_is_periph) begin
                mal_ld_chk <= 1'b1;
                mal_ld_va  <= u_soc.u_cpu.u_core.ex_mem_alu_result;  // access VA
                mal_ld_pc  <= u_soc.u_cpu.u_core.ex_mem_pc;
                mal_ld_f3  <= u_soc.u_cpu.u_core.ex_mem_funct3;
            end else begin
                mal_ld_chk <= 1'b0;
            end
            // Capture a committed non-AMO DRAM STORE (aligned or misaligned) into the
            // delay buffer: its intended value (rs2) must reach memory later.
            if (u_soc.u_cpu.u_core.ex_mem_valid && u_soc.u_cpu.u_core.ex_mem_ctrl.mem_write
                && !u_soc.u_cpu.u_core.ex_mem_ctrl.is_amo
                && !u_soc.periph_is_periph && (u_soc.mmu_dmem_pa >= MEM_BASE)) begin
                // Invalidate any still-pending capture to the SAME 8-byte word: it
                // will be overwritten before we can verify it (stack churn), so we
                // cannot tell a legit overwrite from a lost write -- skip it.
                for (int sj = 0; sj < SVQ; sj = sj + 1)
                    if (svq_vld[sj] && ((svq_va[sj] & ~64'h7)
                        == (u_soc.u_cpu.u_core.ex_mem_alu_result & ~64'h7)))
                        svq_vld[sj] <= 1'b0;
                svq_va  [svq_wr % SVQ] <= u_soc.u_cpu.u_core.ex_mem_alu_result;
                svq_data[svq_wr % SVQ] <= u_soc.u_cpu.u_core.ex_mem_rs2_data;
                svq_sz  [svq_wr % SVQ] <= (u_soc.u_cpu.u_core.ex_mem_funct3[1:0] == 2'b00) ? 4'd1
                                       : (u_soc.u_cpu.u_core.ex_mem_funct3[1:0] == 2'b01) ? 4'd2
                                       : (u_soc.u_cpu.u_core.ex_mem_funct3[1:0] == 2'b10) ? 4'd4 : 4'd8;
                svq_pc  [svq_wr % SVQ] <= u_soc.u_cpu.u_core.ex_mem_pc;
                svq_cyc [svq_wr % SVQ] <= tcyc;
                svq_vld [svq_wr % SVQ] <= 1'b1;
                svq_wr <= svq_wr + 1;
            end
        end
        // --- STORE-EFFECT-LOST check: drain one buffered store per cycle once its
        // AXI write has had time to land (>=64 cycles old), compare memory to intent ---
        if (svq_rd < svq_wr && svq_vld[svq_rd % SVQ] && (tcyc - svq_cyc[svq_rd % SVQ] >= 64)) begin : stl_chk
            logic [63:0] got, want; integer nbb;
            nbb  = svq_sz[svq_rd % SVQ];
            got  = mem_va_bytes(svq_va[svq_rd % SVQ], nbb);
            want = svq_data[svq_rd % SVQ] & ((nbb >= 8) ? 64'hFFFF_FFFF_FFFF_FFFF
                                                        : ((64'h1 << (nbb*8)) - 64'h1));
            if ((got !== want) && nstl < 30) begin
                nstl <= nstl + 1;
                $display("[STLOSS @%0d] pc=%h va=%h sz=%0d mem=%h intended=%h",
                    tcyc, svq_pc[svq_rd % SVQ], svq_va[svq_rd % SVQ], nbb, got, want);
            end
            svq_vld[svq_rd % SVQ] <= 1'b0;
            svq_rd <= svq_rd + 1;
        end
        // --- AMO write-phase-skip / write-loss check ------------------------
        begin : amo_blk
            logic amo_in_mem, amo_retire;
            amo_in_mem = u_soc.u_cpu.u_core.ex_mem_valid
                         && u_soc.u_cpu.u_core.ex_mem_ctrl.is_amo
                         && !u_soc.u_cpu.u_core.ex_mem_ctrl.is_lr
                         && !u_soc.u_cpu.u_core.ex_mem_ctrl.is_sc;
            amo_retire = amo_in_mem && !u_soc.u_cpu.u_core.stall_ex;
            // capture the AMO's memory write when it is issued+accepted
            if (amo_in_mem && u_soc.mmu_dmem_req && u_soc.core_dmem_we
                && !u_soc.core_dmem_wait && !u_soc.periph_is_periph
                && (u_soc.mmu_dmem_pa >= MEM_BASE)) begin
                amo_wrote <= 1'b1;
                amo_wpa   <= u_soc.mmu_dmem_pa;
                amo_wdata <= u_soc.core_dmem_wdata;
                amo_wpc   <= u_soc.u_cpu.u_core.ex_mem_pc;
            end
            // amo_seen = this AMO has performed a DRAM access (so it must also WRITE);
            // gating on DRAM avoids a false skip for an (unusual) uncached/periph AMO.
            if (amo_in_mem && u_soc.mmu_dmem_req && !u_soc.periph_is_periph
                && (u_soc.mmu_dmem_pa >= MEM_BASE)) amo_seen <= 1'b1;
            // at retire: the AMO must have issued its write (read-modify-WRITE).
            if (amo_retire && !amo_wrote && amo_seen && namo < 30) begin
                namo <= namo + 1;
                $display("[AMOSKIP @%0d] pc=%h va=%h -- AMO retired WITHOUT a memory write",
                    tcyc, u_soc.u_cpu.u_core.ex_mem_pc, u_soc.u_cpu.u_core.ex_mem_alu_result);
            end
            // verify the issued AMO write actually landed in memory (a few cycles
            // after retire, once the AXI write has drained).  amo_chk_cyc delays it.
            if (amo_retire && amo_wrote && (^amo_wpa !== 1'bx)) begin
                amo_chk_vld <= 1'b1;  amo_chk_cyc <= tcyc;
                amo_chk_pa  <= amo_wpa; amo_chk_d <= amo_wdata; amo_chk_pc <= amo_wpc;
            end
            if (amo_chk_vld && (tcyc - amo_chk_cyc >= 64)) begin
                if ((mem_win64(amo_chk_pa) !== amo_chk_d) && namo < 30) begin
                    namo <= namo + 1;
                    $display("[AMOLOST @%0d] pc=%h pa=%h mem=%h written=%h",
                        tcyc, amo_chk_pc, amo_chk_pa, mem_win64(amo_chk_pa), amo_chk_d);
                end
                amo_chk_vld <= 1'b0;
            end
            // reset per-AMO tracking when the AMO has left MEM (no AMO present)
            if (!amo_in_mem) begin amo_wrote <= 1'b0; amo_seen <= 1'b0; end
        end
        // --- AMO/LR stale-READ check ----------------------------------------
        begin : srd_blk
            logic alr_in_mem;
            alr_in_mem = u_soc.u_cpu.u_core.ex_mem_valid
                         && u_soc.u_cpu.u_core.ex_mem_ctrl.is_amo
                         && !u_soc.u_cpu.u_core.ex_mem_ctrl.is_sc;
            // snapshot OLD memory at the AMO/LR address during the read phase, before
            // any write (gate: not yet snapshotted, valid DRAM PA, not the write cyc).
            if (alr_in_mem && !srd_pend && !u_soc.u_cpu.u_core.amo_state
                && u_soc.mmu_dmem_req && !u_soc.core_dmem_we && !u_soc.periph_is_periph
                && (u_soc.mmu_dmem_pa >= MEM_BASE)) begin
                srd_pend <= 1'b1;
                srd_old  <= mem_win64(u_soc.mmu_dmem_pa);
                srd_pa   <= u_soc.mmu_dmem_pa;
                srd_pc   <= u_soc.u_cpu.u_core.ex_mem_pc;
                srd_f3   <= u_soc.u_cpu.u_core.ex_mem_funct3;
            end
            // at WB: the architectural loaded OLD value must match the snapshot.
            if (srd_pend && u_soc.u_cpu.u_core.mem_wb_valid
                && u_soc.u_cpu.u_core.mem_wb_ctrl.is_amo
                && !u_soc.u_cpu.u_core.mem_wb_ctrl.is_sc) begin : srd_cmp
                logic [63:0] exp;
                exp = (srd_f3 == 3'b010) ? {{32{srd_old[31]}}, srd_old[31:0]} : srd_old;
                if ((u_soc.u_cpu.u_core.wb_data !== exp) && nsrd < 30) begin
                    nsrd <= nsrd + 1;
                    $display("[STALERD @%0d] pc=%h pa=%h rd=%h memOLD=%h",
                        tcyc, srd_pc, srd_pa, u_soc.u_cpu.u_core.wb_data, exp);
                end
                srd_pend <= 1'b0;
            end
        end
        // --- LR/SC reservation shadow vs core sc_success --------------------
        begin : resv_blk
            logic lr_adv, sc_adv, rv_void, exp_sc;
            lr_adv = u_soc.u_cpu.u_core.ex_mem_ctrl.is_lr && u_soc.u_cpu.u_core.ex_mem_valid
                     && !u_soc.u_cpu.u_core.stall_ex;
            sc_adv = u_soc.u_cpu.u_core.ex_mem_ctrl.is_sc && u_soc.u_cpu.u_core.ex_mem_valid
                     && !u_soc.u_cpu.u_core.stall_ex;
            rv_void = (((u_soc.u_cpu.u_core.csr_trap_enter | u_soc.u_cpu.u_core.ex_mret_en
                         | u_soc.u_cpu.u_core.ex_sret_en) && !u_soc.u_cpu.u_core.stall_ex)
                       | u_soc.u_cpu.u_core.ifpf_take);
            exp_sc = rv_shadow_v && (rv_shadow_a == u_soc.u_cpu.u_core.ex_mem_alu_result);
            if (sc_adv && (u_soc.u_cpu.u_core.sc_success !== exp_sc) && nresv < 30) begin
                nresv <= nresv + 1;
                $display("[RESVBUG @%0d] pc=%h sc_addr=%h core_succ=%b shadow_v=%b shadow_a=%h",
                    tcyc, u_soc.u_cpu.u_core.ex_mem_pc, u_soc.u_cpu.u_core.ex_mem_alu_result,
                    u_soc.u_cpu.u_core.sc_success, rv_shadow_v, rv_shadow_a);
            end
            if (rv_void)      rv_shadow_v <= 1'b0;
            else if (sc_adv)  rv_shadow_v <= 1'b0;
            else if (lr_adv) begin
                rv_shadow_v <= 1'b1;
                rv_shadow_a <= u_soc.u_cpu.u_core.ex_mem_alu_result;
            end
        end
        // --- MISALIGNED-load result vs memory (byte-wise through the page table) ---
        if (mal_ld_chk && u_soc.u_cpu.u_core.mem_wb_valid
            && u_soc.u_cpu.u_core.mem_wb_ctrl.mem_read) begin : malld_chk
            logic [63:0] raw, exp; integer nb;
            case (mal_ld_f3[1:0])
                2'b00:   nb = 1;
                2'b01:   nb = 2;
                2'b10:   nb = 4;
                default: nb = 8;
            endcase
            raw = mem_va_bytes(mal_ld_va, nb);
            case (mal_ld_f3)
                3'b000:  exp = {{56{raw[7]}},  raw[7:0]};
                3'b001:  exp = {{48{raw[15]}}, raw[15:0]};
                3'b010:  exp = {{32{raw[31]}}, raw[31:0]};
                3'b011:  exp = raw;
                3'b100:  exp = {56'd0, raw[7:0]};
                3'b101:  exp = {48'd0, raw[15:0]};
                3'b110:  exp = {32'd0, raw[31:0]};
                default: exp = raw;
            endcase
            if ((u_soc.u_cpu.u_core.wb_data !== exp) && nmalld < 30) begin
                nmalld <= nmalld + 1;
                $display("[MALLD BUG @%0d] pc=%h va=%h f3=%b wb_data=%h exp=%h",
                    tcyc, mal_ld_pc, mal_ld_va, mal_ld_f3,
                    u_soc.u_cpu.u_core.wb_data, exp);
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
        if (^u_soc.u_cpu.u_core.bfpc !== 1'bx) begin
            if (u_soc.u_cpu.u_core.bfpc !== prev_pc) begin
                ring_pc[rh % 64] <= u_soc.u_cpu.u_core.bfpc;
                ring_cy[rh % 64] <= tcyc;
                rh <= rh + 1;
                prev_pc <= u_soc.u_cpu.u_core.bfpc;
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
            $display("[REGDUMP @%0d] pc=%h", tcyc, u_soc.u_cpu.u_core.bfpc);
            for (i = 1; i < 32; i = i + 1)
                $display("   x%0d = %h", i, u_soc.u_cpu.u_core.u_regfile.regs[i]);
        end
`endif
`ifdef BOOT_HANG_PC
        // One-shot dump when fetch_pc first reaches a known hang address (e.g.
        // OpenSBI _start_hang) — same rings as the X dump, to find the branch in.
        if ((^u_soc.u_cpu.u_core.bfpc !== 1'bx)
            && (u_soc.u_cpu.u_core.bfpc === `BOOT_HANG_PC) && !seen_hang) begin
            seen_hang <= 1;
            $display("[HANG @%0d] fetch_pc reached %h. Last 64 distinct fetch_pc:",
                     tcyc, u_soc.u_cpu.u_core.bfpc);
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
        if ((^u_soc.u_cpu.u_core.bfpc !== 1'bx)
            && (u_soc.u_cpu.u_core.bfpc >= 64'h0000_0000_8004_0000)
            && (u_soc.u_cpu.u_core.bfpc <  64'h0000_0000_8020_0000) && !seen_run) begin
            seen_run <= 1;
            $display("[RUNAWAY @%0d] fetch_pc=%h left firmware. Last 64 distinct fetch_pc:",
                     tcyc, u_soc.u_cpu.u_core.bfpc);
            for (i = 0; i < 64; i = i + 1)
                $display("   cy=%0d  pc=%h", ring_cy[(rh + i) % 64], ring_pc[(rh + i) % 64]);
            $display("[RUNAWAY] Last 64 register writes (cy, x<rd>=data):");
            for (i = 0; i < 64; i = i + 1)
                $display("   cy=%0d  x%0d=%h", ring_rcy[(rwh + i) % 64],
                         ring_rd[(rwh + i) % 64], ring_rdat[(rwh + i) % 64]);
        end
        // =================================================================
        // [STDROP] / [STCORRUPT] : RANDLAT-immune write-to-DRAM matcher
        // =================================================================
        // (A) ENQUEUE -- capture each committed DRAM write (plain store OR AMO
        // write phase) once, at the cycle the core first presents the request.
        begin : sd_enq
            logic sd_req;
            sd_req = u_soc.mmu_dmem_req && u_soc.core_dmem_we
                     && !u_soc.periph_is_periph && (u_soc.mmu_dmem_pa >= MEM_BASE)
                     && (^u_soc.mmu_dmem_pa !== 1'bx);
            if (sd_req && (!sd_req_q
                           || (u_soc.u_cpu.u_core.ex_mem_pc !== sd_cap_pc))) begin
                // overwrite-of-valid: this ring slot still holds an undrained write
                // a full SDQ lap later -> it was DROPPED (never reached DRAM).
                if (sdq_vld[sdq_wr % SDQ] && n_stdrop < 40) begin
                    n_stdrop <= n_stdrop + 1;
                    $display("[STDROP @%0d] DROPPED(overwrite) pa=%h pc=%h amo=%b data=%h strb=%02h enq_cyc=%0d",
                        tcyc, sdq_pa[sdq_wr % SDQ], sdq_pc[sdq_wr % SDQ], sdq_amo[sdq_wr % SDQ],
                        sdq_data[sdq_wr % SDQ], sdq_strb[sdq_wr % SDQ], sdq_cyc[sdq_wr % SDQ]);
                end
                sdq_pa  [sdq_wr % SDQ] <= (u_soc.mmu_dmem_pa & ~64'h7);
                sdq_data[sdq_wr % SDQ] <= u_soc.core_dmem_wdata;
                sdq_strb[sdq_wr % SDQ] <= u_soc.core_dmem_wstrb;
                sdq_pc  [sdq_wr % SDQ] <= u_soc.u_cpu.u_core.ex_mem_pc;
                sdq_cyc [sdq_wr % SDQ] <= tcyc;
                sdq_amo [sdq_wr % SDQ] <= u_soc.u_cpu.u_core.ex_mem_ctrl.is_amo;
                sdq_vld [sdq_wr % SDQ] <= 1'b1;
                sdq_wr  <= sdq_wr + 1;
                sd_cap_pc <= u_soc.u_cpu.u_core.ex_mem_pc;
                n_sd_enq <= n_sd_enq + 1;
            end
            sd_req_q <= sd_req;
        end
        // (B) DRAIN -- a BFM write actually reaches mem_b this cycle.  Match it to
        // the OLDEST pending enqueue at the same aligned word.
        if (u_bfm.d_wready && u_bfm.d_wvalid) begin : sd_drain
            logic [63:0] d_pa; integer best, j, best_cyc;
            d_pa = (64'(u_bfm.d_waddr_q) & ~64'h7);
            n_sd_drain <= n_sd_drain + 1;
            best = -1; best_cyc = 0;
            for (j = 0; j < SDQ; j = j + 1)
                if (sdq_vld[j] && (sdq_pa[j] == d_pa)
                    && (best < 0 || sdq_cyc[j] < best_cyc)) begin
                    best = j; best_cyc = sdq_cyc[j];
                end
            if (best < 0) begin
                // a DRAM write with no matching core store enqueue (e.g. a PTW A/D
                // writeback, or a write captured before this detector existed) --
                // benign, just account for it.
                n_sd_nomatch <= n_sd_nomatch + 1;
            end else begin : sd_cmp
                logic [63:0] want, got; logic bad; integer bi;
                want = sdq_data[best]; got = u_bfm.d_wdata; bad = 1'b0;
                for (bi = 0; bi < 8; bi = bi + 1)
                    if (u_bfm.d_wstrb[bi] && (got[bi*8 +: 8] !== want[bi*8 +: 8]))
                        bad = 1'b1;
                if (u_bfm.d_wstrb !== sdq_strb[best]) bad = 1'b1;
                if (bad && n_stcorrupt < 40) begin
                    n_stcorrupt <= n_stcorrupt + 1;
                    $display("[STCORRUPT @%0d] pa=%h pc=%h amo=%b enq_cyc=%0d strb c=%02h m=%02h data c=%h m=%h",
                        tcyc, d_pa, sdq_pc[best], sdq_amo[best], sdq_cyc[best],
                        sdq_strb[best], u_bfm.d_wstrb, want, got);
                end
                sdq_vld[best] <= 1'b0;
                n_sd_match <= n_sd_match + 1;
            end
        end
        // (C) AGE-OUT scrub -- visit one ring slot per cycle; a write still pending
        // far past any plausible AXI latency was DROPPED (covers quiet periods the
        // overwrite path cannot reach).
        if (sdq_vld[sdq_scrub] && (sdq_scrub != sdq_wr % SDQ)
            && (tcyc - sdq_cyc[sdq_scrub] >= SD_DROP_AGE)) begin
            if (n_stdrop < 40) begin
                n_stdrop <= n_stdrop + 1;
                $display("[STDROP @%0d] DROPPED(aged) pa=%h pc=%h amo=%b data=%h strb=%02h enq_cyc=%0d age=%0d",
                    tcyc, sdq_pa[sdq_scrub], sdq_pc[sdq_scrub], sdq_amo[sdq_scrub],
                    sdq_data[sdq_scrub], sdq_strb[sdq_scrub], sdq_cyc[sdq_scrub],
                    tcyc - sdq_cyc[sdq_scrub]);
            end
            sdq_vld[sdq_scrub] <= 1'b0;
        end
        sdq_scrub <= (sdq_scrub + 1) % SDQ;
        // (D) HEARTBEAT -- prove both streams flow (guards against a silent
        // detector whose signal refs resolve to 0 / never fire).
        if (tcyc % 4_000_000 == 0) begin : sd_hb
            integer pend, k;
            pend = 0;
            for (k = 0; k < SDQ; k = k + 1) if (sdq_vld[k]) pend = pend + 1;
            $display("[STDROP-HB @%0d] enq=%0d drain=%0d match=%0d nomatch=%0d pend=%0d drops=%0d corrupt=%0d",
                tcyc, n_sd_enq, n_sd_drain, n_sd_match, n_sd_nomatch, pend, n_stdrop, n_stcorrupt);
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
                         (cyc+1)/1_000_000, u_soc.u_cpu.u_core.bfpc, if_ar, d_ar, nchars,
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
