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
    localparam logic [63:0] MEM_BASE = 64'h8000_0000;

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
    rv_soc #(.XLEN(XLEN), .RST_ADDR(MEM_BASE), .AXI_ID_WIDTH(IDW),
             .CLK_FREQ(CLKF), .BAUD_RATE(BAUD),
             .ICACHE_EN(ICEN), .DCACHE_EN(DCEN),
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
    logic [7:0] ard=8'd0, rd_=8'd0, awd=8'd0, wd=8'd0, bd=8'd0;

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

    // diagnostics
    integer if_ar = 0, d_ar = 0;
    always @(posedge clk) if (rst_n) begin
        if (i_arvalid & i_arready) if_ar = if_ar + 1;
        if (arvalid   & arready  ) d_ar  = d_ar  + 1;
    end

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
`endif
        if (u_soc.u_cpu.u_core.trap_or_mret)
            $display("[trap @%0d] tgt=%h te=%b mte=%b mret=%b sret=%b mcause=%h mepc=%h mtval=%h",
                tcyc, u_soc.u_cpu.u_core.redir_tgt,
                u_soc.u_cpu.u_core.ex_trap_enter, u_soc.u_cpu.u_core.mem_trap_enter,
                u_soc.u_cpu.u_core.ex_mret_en, u_soc.u_cpu.u_core.ex_sret_en,
                u_soc.u_cpu.u_core.u_csr.mcause_reg, u_soc.u_cpu.u_core.u_csr.mepc_out,
                u_soc.u_cpu.u_core.u_csr.mtval_reg);
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
            if ((cyc % 1_000_000) == 999_999)
                $display("\n[progress @%0dM cyc] pc=%010h if_fills=%0d d_reads=%0d chars=%0d",
                         (cyc+1)/1_000_000, u_soc.u_cpu.u_core.fetch_pc, if_ar, d_ar, nchars);
            if (sentinel() === DONE_MAGIC || sentinel() === FAIL_MAGIC) cyc = `BOOT_MAX_CYCLES;
        end
        #1;
        $display("\n----- end of console (%0d UART chars; IF line-fills=%0d, data reads=%0d) -----",
                 nchars, if_ar, d_ar);
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
