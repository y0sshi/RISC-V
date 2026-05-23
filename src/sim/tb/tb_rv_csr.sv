// =============================================================================
// tb_rv_csr.sv - Unit testbench for rv_csr
// =============================================================================
// Tests:
//   1. CSRRW  — write new value, read old value
//   2. CSRRS  — set bits
//   3. CSRRC  — clear bits
//   4. ECALL  — trap entry: mepc/mcause/mtvec written, priv stays M
//   5. MRET   — trap return: mepc_out, mstatus restored
//   6. mcycle — increments every clock
//
// Simulation: iverilog tb_rv_csr.sv ../../rtl/core/rv_csr.sv
//             -I ../../rtl/include -g2012
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_csr;

    import rv_pkg::*;

    // =========================================================================
    // Parameters
    // =========================================================================
    parameter int XLEN = 32;
    localparam int CLK_PERIOD = 10;

    // =========================================================================
    // DUT signals
    // =========================================================================
    logic             clk, rst_n;
    logic [11:0]      csr_addr;
    logic [XLEN-1:0]  csr_wdata;
    logic [2:0]       csr_op;
    logic             csr_we;
    logic [XLEN-1:0]  csr_rdata;

    logic             trap_enter;
    logic [XLEN-1:0]  trap_cause;
    logic [XLEN-1:0]  trap_val;
    logic [XLEN-1:0]  trap_epc;
    logic             mret_en;

    logic [XLEN-1:0]  trap_vector;
    logic [XLEN-1:0]  mepc_out;
    priv_level_t      priv_level;
    logic             irq_pending;

    logic             retire_en;
    logic [63:0]      timer_val;
    logic             timer_irq, sw_irq, ext_irq;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    rv_csr #(.XLEN(XLEN), .HARTID(0)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .csr_addr   (csr_addr),
        .csr_wdata  (csr_wdata),
        .csr_op     (csr_op),
        .csr_we     (csr_we),
        .csr_rdata  (csr_rdata),
        .trap_enter (trap_enter),
        .trap_cause (trap_cause),
        .trap_val   (trap_val),
        .trap_epc   (trap_epc),
        .mret_en    (mret_en),
        .trap_vector(trap_vector),
        .mepc_out   (mepc_out),
        .priv_level (priv_level),
        .irq_pending(irq_pending),
        .retire_en  (retire_en),
        .timer_val  (timer_val),
        .timer_irq  (timer_irq),
        .sw_irq     (sw_irq),
        .ext_irq    (ext_irq)
    );

    // =========================================================================
    // Clock
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // =========================================================================
    // Test helpers
    // =========================================================================
    int pass_cnt, fail_cnt;

    task do_reset;
        rst_n      = 0;
        csr_addr   = '0;
        csr_wdata  = '0;
        csr_op     = 3'b001;   // CSRRW default
        csr_we     = 0;
        trap_enter = 0;
        trap_cause = '0;
        trap_val   = '0;
        trap_epc   = '0;
        mret_en    = 0;
        retire_en  = 0;
        timer_val  = '0;
        timer_irq  = 0;
        sw_irq     = 0;
        ext_irq    = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
    endtask

    // Single-cycle CSR write (CSRRW), return old value
    task csrrw(input logic [11:0] addr, input logic [XLEN-1:0] wdata,
               output logic [XLEN-1:0] old_val);
        @(negedge clk);
        csr_addr  = addr;
        csr_wdata = wdata;
        csr_op    = 3'b001;   // CSRRW
        csr_we    = 1;
        #1;                   // let always_comb settle after csr_addr change
        old_val   = csr_rdata;
        @(posedge clk);       // write committed
        #1;
        csr_we    = 0;
    endtask

    // Single-cycle CSR read
    task csrr(input logic [11:0] addr, output logic [XLEN-1:0] val);
        @(negedge clk);
        csr_addr = addr;
        csr_we   = 0;
        #1;                   // let always_comb settle after csr_addr change
        val      = csr_rdata;
    endtask

    task check(input string name, input logic [XLEN-1:0] got, exp);
        if (got === exp) begin
            $display("  PASS: %s = 0x%08h", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %s got=0x%08h exp=0x%08h", name, got, exp);
            fail_cnt++;
        end
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    logic [XLEN-1:0] rd_val, old_val, cyc0;

    initial begin
        $dumpfile("wave/tb_rv_csr.vcd");
        $dumpvars(0, tb_rv_csr);
        pass_cnt = 0;
        fail_cnt = 0;

        $display("=== rv_csr Unit Test ===");

        do_reset;

        // ------------------------------------------------------------------
        // Test 1: CSRRW mscratch
        // ------------------------------------------------------------------
        $display("\n[1] CSRRW mscratch");
        csrrw(CSR_MSCRATCH, 32'hDEAD_BEEF, old_val);
        check("old_val (should be 0)", old_val, 32'h0);
        csrr(CSR_MSCRATCH, rd_val);
        check("mscratch after write",  rd_val,  32'hDEAD_BEEF);

        // ------------------------------------------------------------------
        // Test 2: CSRRS mscratch (set bits)
        // ------------------------------------------------------------------
        $display("\n[2] CSRRS mscratch (set 0xFF00_0000)");
        @(negedge clk);
        csr_addr  = CSR_MSCRATCH;
        csr_wdata = 32'hFF00_0000;
        csr_op    = 3'b010;   // CSRRS
        csr_we    = 1;
        old_val   = csr_rdata;
        @(posedge clk); #1; csr_we = 0;
        check("old_val", old_val, 32'hDEAD_BEEF);
        csrr(CSR_MSCRATCH, rd_val);
        check("mscratch after RS", rd_val, 32'hFFAD_BEEF);

        // ------------------------------------------------------------------
        // Test 3: CSRRC mscratch (clear bits)
        // ------------------------------------------------------------------
        $display("\n[3] CSRRC mscratch (clear 0x00FF_FF00)");
        @(negedge clk);
        csr_addr  = CSR_MSCRATCH;
        csr_wdata = 32'h00FF_FF00;
        csr_op    = 3'b011;   // CSRRC
        csr_we    = 1;
        old_val   = csr_rdata;
        @(posedge clk); #1; csr_we = 0;
        check("old_val", old_val, 32'hFFAD_BEEF);
        csrr(CSR_MSCRATCH, rd_val);
        check("mscratch after RC", rd_val, 32'hFF00_00EF);

        // ------------------------------------------------------------------
        // Test 4: mtvec write + read back
        // ------------------------------------------------------------------
        $display("\n[4] mtvec write");
        csrrw(CSR_MTVEC, 32'h8000_0000, old_val);  // Direct mode (bit[0]=0)
        csrr(CSR_MTVEC, rd_val);
        check("mtvec", rd_val, 32'h8000_0000);
        // trap_vector should equal mtvec BASE (Direct mode)
        @(negedge clk);
        check("trap_vector", trap_vector, 32'h8000_0000);

        // ------------------------------------------------------------------
        // Test 5: ECALL trap entry
        // ------------------------------------------------------------------
        $display("\n[5] ECALL trap entry");
        @(negedge clk);
        trap_enter = 1;
        trap_epc   = 32'h1000_0004;
        trap_cause = XLEN'(EXC_ECALL_M);   // 4'd11 = 0xB
        trap_val   = 32'h0;
        @(posedge clk); #1;
        trap_enter = 0;
        // Check mepc
        csrr(CSR_MEPC, rd_val);
        check("mepc", rd_val, 32'h1000_0004);
        // Check mcause
        csrr(CSR_MCAUSE, rd_val);
        check("mcause", rd_val, 32'h0000_000B);  // EXC_ECALL_M = 11
        // mstatus.MIE should be 0 (disabled on trap entry)
        csrr(CSR_MSTATUS, rd_val);
        check("mstatus.MIE=0", rd_val[3], 1'b0);
        check("mstatus.MPIE=0 (was 0 before)", rd_val[7], 1'b0);
        // trap_vector should point to mtvec
        check("trap_vector on trap", trap_vector, 32'h8000_0000);

        // ------------------------------------------------------------------
        // Test 6: MRET
        // ------------------------------------------------------------------
        $display("\n[6] MRET");
        @(negedge clk);
        mret_en = 1;
        @(posedge clk); #1;
        mret_en = 0;
        // mepc_out should be the saved EPC
        check("mepc_out", mepc_out, 32'h1000_0004);
        // mstatus.MPIE should be set to 1 after MRET
        csrr(CSR_MSTATUS, rd_val);
        check("mstatus.MPIE=1 after MRET", rd_val[7], 1'b1);

        // ------------------------------------------------------------------
        // Test 7: mcycle increments
        // ------------------------------------------------------------------
        $display("\n[7] mcycle counter");
        csrr(CSR_MCYCLE, rd_val);
        cyc0 = rd_val;
        repeat (4) @(posedge clk);
        csrr(CSR_MCYCLE, rd_val);
        // rd_val should be cyc0 + >=4 (some extra cycles from reads)
        if (rd_val > cyc0)
            $display("  PASS: mcycle increments (%0d → %0d)", cyc0, rd_val);
        else begin
            $display("  FAIL: mcycle did not increment (%0d → %0d)", cyc0, rd_val);
            fail_cnt++;
        end

        // ------------------------------------------------------------------
        // Test 8: mhartid read-only
        // ------------------------------------------------------------------
        $display("\n[8] mhartid (HARTID=0)");
        csrr(CSR_MHARTID, rd_val);
        check("mhartid", rd_val, '0);

        // ------------------------------------------------------------------
        // Results
        // ------------------------------------------------------------------
        $display("\n=== Results: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL PASS");
        else
            $display("SOME TESTS FAILED");

        $finish;
    end

    // Timeout guard
    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
