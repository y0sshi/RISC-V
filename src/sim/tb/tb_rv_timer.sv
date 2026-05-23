// =============================================================================
// tb_rv_timer.sv — Unit testbench for rv_csr Machine Timer interrupt
// =============================================================================
// Drives rv_csr directly (no pipeline).
// Stimulates timer_irq and checks irq_pending / irq_cause / CSR state.
//
// Tests:
//  [1]  Baseline        : timer_irq=0 → irq_pending=0
//  [2]  MTIE masked     : timer_irq=1, MTIE=0       → irq_pending=0
//  [3]  MIE masked      : MTIE=1, mstatus.MIE=0 (M) → irq_pending=0
//  [4]  MTIP asserts    : MIE=1  → irq_pending=1, irq_cause=INT|7
//  [5]  M-mode trap     : inject trap → mcause/mepc/MIE=0/priv=M
//  [6]  MRET            : timer_irq de-assert before MRET, verify recovery
//  [7]  S-mode masked   : priv=S, mideleg[5]=0, STIP absent → irq still M-mode
//  [8]  STIP delegates  : mideleg[5]=1, SIE=1 in S-mode → irq_cause=INT|5
//  [9]  S-mode trap     : inject STIP trap → scause/sepc/SIE=0/priv=S
//  [10] SRET            : timer_irq=0, SRET → recover SIE and priv
// =============================================================================
`timescale 1ns / 1ps

module tb_rv_timer;

    import rv_pkg::*;
    localparam int XLEN = rv_pkg::XLEN;

    // DUT signals
    logic              clk, rst_n;
    logic [11:0]       csr_addr;
    logic [XLEN-1:0]   csr_wdata;
    logic [2:0]        csr_op;
    logic              csr_we;
    logic [XLEN-1:0]   csr_rdata;
    logic              trap_enter;
    logic [XLEN-1:0]   trap_cause;
    logic [XLEN-1:0]   trap_val;
    logic [XLEN-1:0]   trap_epc;
    logic              mret_en;
    logic              sret_en;
    logic [XLEN-1:0]   trap_vector;
    logic [XLEN-1:0]   mepc_out;
    logic [XLEN-1:0]   sepc_out;
    priv_level_t       priv_level;
    logic              irq_pending;
    logic [XLEN-1:0]   irq_cause;
    logic [XLEN-1:0]   satp_val;
    logic              mstatus_sum;
    logic              mstatus_mxr;
    logic              timer_irq;

    rv_csr #(.XLEN(XLEN)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .csr_addr    (csr_addr),
        .csr_wdata   (csr_wdata),
        .csr_op      (csr_op),
        .csr_we      (csr_we),
        .csr_rdata   (csr_rdata),
        .trap_enter  (trap_enter),
        .trap_cause  (trap_cause),
        .trap_val    (trap_val),
        .trap_epc    (trap_epc),
        .mret_en     (mret_en),
        .sret_en     (sret_en),
        .trap_vector (trap_vector),
        .mepc_out    (mepc_out),
        .sepc_out    (sepc_out),
        .priv_level  (priv_level),
        .irq_pending (irq_pending),
        .irq_cause   (irq_cause),
        .retire_en   (1'b0),
        .timer_val   (64'h0),
        .timer_irq   (timer_irq),
        .sw_irq      (1'b0),
        .ext_irq     (1'b0),
        .satp_val    (satp_val),
        .mstatus_sum (mstatus_sum),
        .mstatus_mxr (mstatus_mxr)
    );

    // Clock: 10 ns period
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // Helpers
    // =========================================================================
    int pass_cnt, fail_cnt;

    task check_v(input string name, input logic [XLEN-1:0] got, exp);
        if (got === exp) begin
            $display("  PASS: %-52s = 0x%0h", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %-52s  got=0x%0h  exp=0x%0h", name, got, exp);
            fail_cnt++;
        end
    endtask

    task check_x(input string name, input logic got, exp);
        if (got === exp) begin
            $display("  PASS: %-52s = %0b", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %-52s  got=%0b  exp=%0b", name, got, exp);
            fail_cnt++;
        end
    endtask

    task check_priv(input string name, input priv_level_t got, exp);
        if (got === exp) begin
            $display("  PASS: %-52s = %0d", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %-52s  got=%0d  exp=%0d", name, got, exp);
            fail_cnt++;
        end
    endtask

    // Write CSR (CSRRW, 1 cycle)
    task csr_write(input logic [11:0] addr, input logic [XLEN-1:0] data);
        csr_addr  = addr;
        csr_wdata = data;
        csr_op    = 3'b001;
        csr_we    = 1'b1;
        @(posedge clk); #1;
        csr_we    = 1'b0;
    endtask

    // Read CSR (combinational, no clock)
    task csr_rd(input logic [11:0] addr);
        csr_addr  = addr;
        csr_wdata = '0;
        csr_op    = 3'b010;
        csr_we    = 1'b0;
        #1;
    endtask

    // =========================================================================
    // Interrupt cause constants
    // =========================================================================
    localparam [XLEN-1:0] MTIP_CAUSE = XLEN == 64
        ? 64'h8000_0000_0000_0007 : 32'h8000_0007;
    localparam [XLEN-1:0] STIP_CAUSE = XLEN == 64
        ? 64'h8000_0000_0000_0005 : 32'h8000_0005;

    // =========================================================================
    initial begin
        $dumpfile("wave/tb_rv_timer.vcd");
        $dumpvars(0, tb_rv_timer);
        pass_cnt = 0; fail_cnt = 0;

        csr_addr = '0; csr_wdata = '0; csr_op = '0; csr_we = 1'b0;
        trap_enter = 1'b0; trap_cause = '0; trap_val = '0; trap_epc = '0;
        mret_en = 1'b0; sret_en = 1'b0; timer_irq = 1'b0;

        rst_n = 0; repeat(3) @(posedge clk); rst_n = 1; @(posedge clk); #1;

        $display("=== rv_csr Machine Timer Interrupt Test (XLEN=%0d) ===", XLEN);

        // Set MTVEC = 0x8000_0000
        csr_write(CSR_MTVEC, XLEN'(32'h8000_0000));

        // --------------------------------------------------------------------
        // [1] Baseline: no interrupt
        // --------------------------------------------------------------------
        $display("\n[1] Baseline: timer_irq=0 → irq_pending=0");
        timer_irq = 1'b0;
        #1;
        check_x("irq_pending = 0", irq_pending, 1'b0);

        // --------------------------------------------------------------------
        // [2] MTIE masked: timer_irq=1 but MTIE bit not set
        // --------------------------------------------------------------------
        $display("\n[2] MTIE masked: timer_irq=1, MTIE=0 → irq_pending=0");
        csr_write(CSR_MIE, XLEN'(0));      // all IE bits clear
        timer_irq = 1'b1; #1;
        check_x("irq_pending = 0 (MTIE=0)", irq_pending, 1'b0);

        // --------------------------------------------------------------------
        // [3] MIE (mstatus) masked: MTIE=1 but mstatus.MIE=0 while in M-mode
        // --------------------------------------------------------------------
        $display("\n[3] MIE masked: MTIE=1, mstatus.MIE=0 in M-mode → irq_pending=0");
        csr_write(CSR_MIE, XLEN'(1 << 7));  // MTIE[7] = 1
        // mstatus.MIE is already 0 after reset (changed by test [4] write,
        // but we force it back to 0 here)
        csr_write(CSR_MSTATUS, XLEN'(0));   // MIE[3]=0, all clear
        // priv_level is still M-mode (from reset)
        timer_irq = 1'b1; #1;
        check_x("irq_pending = 0 (MIE=0)", irq_pending, 1'b0);
        check_priv("priv still M-mode", priv_level, PRIV_M);

        // --------------------------------------------------------------------
        // [4] MTIP fires: MTIE=1 + mstatus.MIE=1 → irq_pending=1
        // --------------------------------------------------------------------
        $display("\n[4] MTIP fires: MIE=1, MTIE=1, timer_irq=1 → irq_pending=1");
        csr_write(CSR_MSTATUS, XLEN'(1 << 3));  // MIE[3] = 1
        timer_irq = 1'b1; #1;
        check_x("irq_pending = 1",              irq_pending, 1'b1);
        check_v("irq_cause = INT|7 (MTIP)",     irq_cause,   MTIP_CAUSE);

        // --------------------------------------------------------------------
        // [5] M-mode MTIP trap
        // --------------------------------------------------------------------
        $display("\n[5] M-mode MTIP trap");
        trap_cause = MTIP_CAUSE;
        trap_epc   = XLEN'(32'hA000);
        trap_val   = '0;
        trap_enter = 1'b1;
        #1; // let combinational outputs settle
        check_v("trap_vector = MTVEC", trap_vector, XLEN'(32'h8000_0000));
        @(posedge clk); #1;
        trap_enter = 1'b0; trap_cause = '0; trap_epc = '0;
        check_priv("priv = M after trap",             priv_level, PRIV_M);
        check_v("mcause = MTIP_CAUSE",                mepc_out,   XLEN'(32'hA000));
        // read mcause via CSR port
        csr_rd(CSR_MCAUSE);
        check_v("mcause = INT|7",                     csr_rdata, MTIP_CAUSE);
        csr_rd(CSR_MSTATUS);
        check_x("mstatus.MIE=0 (disabled in handler)", csr_rdata[3], 1'b0);
        check_x("mstatus.MPIE=1 (saved MIE)",          csr_rdata[7], 1'b1);

        // --------------------------------------------------------------------
        // [6] MRET recovery (de-assert timer_irq first)
        // --------------------------------------------------------------------
        $display("\n[6] MRET: recover from M-mode timer trap");
        timer_irq = 1'b0;   // software cleared timer (wrote mtimecmp)
        // MPP=M (came from M-mode), so MRET stays in M-mode
        mret_en = 1'b1; @(posedge clk); #1; mret_en = 1'b0;
        check_priv("priv = M after MRET (MPP=M)", priv_level, PRIV_M);
        csr_rd(CSR_MSTATUS);
        check_x("mstatus.MIE=1 (restored)",       csr_rdata[3], 1'b1);
        check_x("irq_pending=0 (timer_irq=0)",    irq_pending,  1'b0);

        // --------------------------------------------------------------------
        // [7] S-mode, mideleg[5]=0 → STIP absent; only MTIP (M-mode irq)
        // --------------------------------------------------------------------
        $display("\n[7] S-mode no delegation: STIP absent, only MTIP visible");
        // Transition to S-mode via MRET (MPP=S)
        csr_write(CSR_MSTATUS, XLEN'((2'b01 << 11) | (1 << 7)));  // MPP=S, MPIE=1
        mret_en = 1'b1; @(posedge clk); #1; mret_en = 1'b0;
        check_priv("priv = S after MRET", priv_level, PRIV_S);
        // mideleg[5] = 0 (STIP not delegated): mip[5] = timer_irq & mideleg[5] = 0
        // MTIP (bit7) is still set; M-mode IRQ visible from S-mode when mie[7]=1
        csr_write(CSR_MIE, XLEN'(0));       // disable MTIE to isolate STIP test
        timer_irq = 1'b1; #1;
        check_x("irq_pending=0 (MTIE=0, STIP absent)", irq_pending, 1'b0);

        // --------------------------------------------------------------------
        // [8] STIP delegation: mideleg[5]=1, SIE=1 → irq_cause = INT|5
        // --------------------------------------------------------------------
        $display("\n[8] STIP delegation: mideleg[5]=1, SIE=1, timer_irq=1");
        csr_write(CSR_MIDELEG, XLEN'(1 << 5));    // delegate STIP to S-mode
        csr_write(CSR_STVEC,   XLEN'(32'hC000_0000));
        // Enable STIE in MIE (bit 5 is the S-mode timer IE)
        csr_write(CSR_MIE, XLEN'(1 << 5));       // STIE[5] = 1
        // Enable SIE in sstatus (bit 1)
        csr_write(CSR_SSTATUS, XLEN'(1 << 1));    // SIE[1] = 1
        timer_irq = 1'b1; #1;
        check_x("irq_pending=1 (STIP delegated)",  irq_pending, 1'b1);
        check_v("irq_cause = INT|5 (STIP)",        irq_cause,   STIP_CAUSE);

        // --------------------------------------------------------------------
        // [9] S-mode STIP trap (delegated → updates S-mode CSRs)
        // --------------------------------------------------------------------
        $display("\n[9] S-mode STIP trap (delegated)");
        trap_cause = STIP_CAUSE;
        trap_epc   = XLEN'(32'hB000);
        trap_val   = '0;
        trap_enter = 1'b1;
        #1; // let combinational outputs settle
        check_v("trap_vector = STVEC (delegated)", trap_vector, XLEN'(32'hC000_0000));
        @(posedge clk); #1;
        trap_enter = 1'b0; trap_cause = '0; trap_epc = '0;
        check_priv("priv = S after STIP trap",       priv_level, PRIV_S);
        csr_rd(CSR_SCAUSE);
        check_v("scause = INT|5",                    csr_rdata, STIP_CAUSE);
        csr_rd(CSR_SEPC);
        check_v("sepc = 0xB000",                     csr_rdata, XLEN'(32'hB000));
        csr_rd(CSR_SSTATUS);
        check_x("sstatus.SIE=0 (disabled in handler)", csr_rdata[1], 1'b0);
        check_x("sstatus.SPIE=1 (saved SIE)",           csr_rdata[5], 1'b1);
        check_x("sstatus.SPP=1 (came from S-mode)",     csr_rdata[8], 1'b1);
        // mcause must NOT be overwritten
        csr_rd(CSR_MCAUSE);
        check_v("mcause unchanged = MTIP_CAUSE",     csr_rdata, MTIP_CAUSE);

        // --------------------------------------------------------------------
        // [10] SRET recovery
        // --------------------------------------------------------------------
        $display("\n[10] SRET: recover from S-mode timer trap");
        timer_irq = 1'b0;   // software cleared timer
        sret_en = 1'b1; @(posedge clk); #1; sret_en = 1'b0;
        check_priv("priv = S after SRET (SPP=1)",  priv_level, PRIV_S);
        csr_rd(CSR_SSTATUS);
        check_x("sstatus.SIE=1 (restored SPIE)",   csr_rdata[1], 1'b1);
        check_x("sstatus.SPP=0 after SRET",        csr_rdata[8], 1'b0);
        check_x("irq_pending=0 (timer_irq=0)",     irq_pending,  1'b0);

        // --------------------------------------------------------------------
        $display("\n=== Results: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL PASS");
        else               $display("SOME TESTS FAILED");
        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish; end

endmodule
