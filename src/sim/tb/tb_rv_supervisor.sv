// =============================================================================
// tb_rv_supervisor.sv — Unit testbench for rv_csr Supervisor-mode
// =============================================================================
// Tests Supervisor-mode CSRs, exception delegation, and SRET.
// Drives rv_csr directly (no pipeline); simulates trap_enter / sret_en / mret_en.
// =============================================================================
`timescale 1ns / 1ps

module tb_rv_supervisor;

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
    logic [XLEN-1:0]   satp_val;
    logic              mstatus_sum;
    logic              mstatus_mxr;

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
        .retire_en   (1'b0),
        .timer_val   (64'h0),
        .timer_irq   (1'b0),
        .sw_irq      (1'b0),
        .ext_irq     (1'b0),
        .satp_val    (satp_val),
        .mstatus_sum (mstatus_sum),
        .mstatus_mxr (mstatus_mxr)
    );

    // Clock
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // Helpers
    // =========================================================================
    int pass_cnt, fail_cnt;

    task check_v(input string name, input logic [XLEN-1:0] got, exp);
        if (got === exp) begin
            $display("  PASS: %-50s = 0x%0h", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %-50s  got=0x%0h  exp=0x%0h", name, got, exp);
            fail_cnt++;
        end
    endtask

    task check_x(input string name, input logic got, exp);
        if (got === exp) begin
            $display("  PASS: %-50s = %0b", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %-50s  got=%0b  exp=%0b", name, got, exp);
            fail_cnt++;
        end
    endtask

    task check_priv(input string name, input priv_level_t got, exp);
        if (got === exp) begin
            $display("  PASS: %-50s = %0d", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL: %-50s  got=%0d  exp=%0d", name, got, exp);
            fail_cnt++;
        end
    endtask

    // Write a CSR (CSRRW, 1 clock cycle)
    task csr_write(input logic [11:0] addr, input logic [XLEN-1:0] data);
        csr_addr  = addr;
        csr_wdata = data;
        csr_op    = 3'b001;   // CSRRW
        csr_we    = 1'b1;
        @(posedge clk); #1;
        csr_we    = 1'b0;
    endtask

    // Set CSR address for reading (combinational, no clock)
    // After calling, read csr_rdata combinationally.
    task csr_rd(input logic [11:0] addr);
        csr_addr  = addr;
        csr_wdata = '0;
        csr_op    = 3'b010;   // CSRRS with rs1=0 (no write)
        csr_we    = 1'b0;
        #1;
    endtask

    // =========================================================================
    initial begin
        $dumpfile("wave/tb_rv_supervisor.vcd");
        $dumpvars(0, tb_rv_supervisor);
        pass_cnt = 0; fail_cnt = 0;

        csr_addr = '0; csr_wdata = '0; csr_op = '0; csr_we = 1'b0;
        trap_enter = 1'b0; trap_cause = '0; trap_val = '0; trap_epc = '0;
        mret_en = 1'b0; sret_en = 1'b0;

        rst_n = 0; repeat(3) @(posedge clk); rst_n = 1; @(posedge clk); #1;

        $display("=== rv_csr Supervisor-mode Unit Test (XLEN=%0d) ===", XLEN);

        // ----------------------------------------------------------------
        // [1] MEDELEG / MIDELEG read/write
        // ----------------------------------------------------------------
        $display("\n[1] MEDELEG / MIDELEG R/W");
        // Delegate U-mode ECALL (8), S-mode ECALL (9), page faults (12,13,15)
        csr_write(CSR_MEDELEG, XLEN'((1<<8)|(1<<9)|(1<<12)|(1<<13)|(1<<15)));
        csr_rd(CSR_MEDELEG);
        check_v("MEDELEG after write",
                csr_rdata, XLEN'((1<<8)|(1<<9)|(1<<12)|(1<<13)|(1<<15)));

        csr_write(CSR_MIDELEG, XLEN'((1<<1)|(1<<5)|(1<<9)));  // SSIP, STIP, SEIP
        csr_rd(CSR_MIDELEG);
        check_v("MIDELEG after write", csr_rdata, XLEN'((1<<1)|(1<<5)|(1<<9)));

        // ----------------------------------------------------------------
        // [2] STVEC / SSCRATCH R/W
        // ----------------------------------------------------------------
        $display("\n[2] STVEC / SSCRATCH R/W");
        csr_write(CSR_STVEC,    XLEN'(32'hC000_0000));
        csr_rd(CSR_STVEC);
        check_v("STVEC BASE aligned", csr_rdata, XLEN'(32'hC000_0000));

        csr_write(CSR_SSCRATCH, XLEN'(32'hDEAD_BEEF));
        csr_rd(CSR_SSCRATCH);
        check_v("SSCRATCH",         csr_rdata, XLEN'(32'hDEAD_BEEF));

        // ----------------------------------------------------------------
        // [3] SSTATUS: SIE[1], SPIE[5], SPP[8], SUM[18], MXR[19]
        // ----------------------------------------------------------------
        $display("\n[3] SSTATUS R/W (SIE/SPIE/SPP/SUM/MXR)");
        csr_write(CSR_SSTATUS, XLEN'((1<<1)|(1<<5)|(1<<8)|(1<<18)|(1<<19)));
        csr_rd(CSR_SSTATUS);
        check_x("SSTATUS SIE[1]=1",  csr_rdata[1],  1'b1);
        check_x("SSTATUS SPIE[5]=1", csr_rdata[5],  1'b1);
        check_x("SSTATUS SPP[8]=1",  csr_rdata[8],  1'b1);
        check_x("SSTATUS SUM[18]=1", csr_rdata[18], 1'b1);
        check_x("SSTATUS MXR[19]=1", csr_rdata[19], 1'b1);
        // MIE[3] must NOT be visible in sstatus
        check_x("SSTATUS MIE[3]=0",  csr_rdata[3],  1'b0);

        // Clear sstatus bits
        csr_write(CSR_SSTATUS, XLEN'(0));
        csr_rd(CSR_SSTATUS);
        check_v("SSTATUS cleared",    csr_rdata, XLEN'(0));

        // ----------------------------------------------------------------
        // [4] Non-delegated trap: ECALL_S → M-mode (medeleg=0)
        // ----------------------------------------------------------------
        $display("\n[4] Non-delegated trap: ECALL_S → M-mode (medeleg[9]=0)");
        // Clear medeleg to ensure no delegation
        csr_write(CSR_MEDELEG, XLEN'(0));
        // Set MTVEC = 0x8000_0000
        csr_write(CSR_MTVEC, XLEN'(32'h8000_0000));
        // Transition to S-mode: write mstatus MPP=S(01), MPIE=1, then MRET
        csr_write(CSR_MSTATUS, XLEN'((2'b01 << 11) | (1 << 7)));
        mret_en = 1'b1; @(posedge clk); #1; mret_en = 1'b0;
        check_priv("priv=S after MRET",  priv_level, PRIV_S);

        // Trap with ECALL_S (cause=9), no delegation → M-mode
        trap_cause = XLEN'(EXC_ECALL_S); trap_epc = XLEN'(32'h1000);
        trap_val = XLEN'(0); trap_enter = 1'b1;
        #1; // let combinational logic (assign trap_vector) settle across delta cycles
        check_v("trap_vector=MTVEC (no delegation)", trap_vector, XLEN'(32'h8000_0000));
        @(posedge clk); #1;
        trap_enter = 1'b0; trap_cause = '0; trap_epc = '0;
        check_priv("priv=M after non-delegated trap", priv_level, PRIV_M);
        csr_rd(CSR_MCAUSE);
        check_v("mcause=EXC_ECALL_S",    csr_rdata, XLEN'(EXC_ECALL_S));
        csr_rd(CSR_MEPC);
        check_v("mepc=0x1000",            csr_rdata, XLEN'(32'h1000));
        // scause must NOT be updated
        csr_rd(CSR_SCAUSE);
        check_v("scause unchanged (=0)",  csr_rdata, XLEN'(0));

        // ----------------------------------------------------------------
        // [5] Delegated trap: ECALL_U from U-mode → S-mode
        // ----------------------------------------------------------------
        $display("\n[5] Delegated trap: ECALL_U (medeleg[8]=1, U-mode) → S-mode");
        // Return to U-mode via MRET (MPP=00)
        csr_write(CSR_MSTATUS, XLEN'((2'b00 << 11) | (1 << 7)));
        mret_en = 1'b1; @(posedge clk); #1; mret_en = 1'b0;
        check_priv("priv=U before trap", priv_level, PRIV_U);

        // Delegate U-mode ECALL (bit 8) to S-mode
        csr_write(CSR_MEDELEG, XLEN'(1 << 8));

        // Trap: ECALL_U (cause=8) delegated → S-mode (stvec=0xC000_0000)
        trap_cause = XLEN'(EXC_ECALL_U); trap_epc = XLEN'(32'h2000);
        trap_val = XLEN'(0); trap_enter = 1'b1;
        #1; // let combinational logic (assign trap_vector) settle across delta cycles
        check_v("trap_vector=STVEC (delegated)", trap_vector, XLEN'(32'hC000_0000));
        @(posedge clk); #1;
        trap_enter = 1'b0; trap_cause = '0; trap_epc = '0;
        check_priv("priv=S after delegated trap",  priv_level,  PRIV_S);
        csr_rd(CSR_SCAUSE);
        check_v("scause=EXC_ECALL_U",    csr_rdata, XLEN'(EXC_ECALL_U));
        csr_rd(CSR_SEPC);
        check_v("sepc=0x2000",           csr_rdata, XLEN'(32'h2000));
        // mcause must NOT change (still EXC_ECALL_S from test [4])
        csr_rd(CSR_MCAUSE);
        check_v("mcause unchanged",      csr_rdata, XLEN'(EXC_ECALL_S));

        // ----------------------------------------------------------------
        // [6] SRET: S-mode → U-mode (SPP=0, came from U-mode)
        // ----------------------------------------------------------------
        $display("\n[6] SRET: S-mode → U-mode (SPP=0)");
        // sepc=0x2000, SPP=0 (was in U-mode when trap taken)
        check_v("sepc_out before SRET",  sepc_out, XLEN'(32'h2000));
        sret_en = 1'b1; @(posedge clk); #1; sret_en = 1'b0;
        check_priv("priv=U after SRET",  priv_level, PRIV_U);
        csr_rd(CSR_SSTATUS);
        check_x("SPP=0 after SRET",      csr_rdata[8], 1'b0);
        // SPIE should have been restored to SIE (which was 0)

        // ----------------------------------------------------------------
        // [7] Delegated ECALL_S from S-mode → S-mode (SPP=1)
        // ----------------------------------------------------------------
        $display("\n[7] Delegated trap: ECALL_S (medeleg[9]=1, S-mode) → S-mode");
        // Go to S-mode via MRET
        csr_write(CSR_MSTATUS, XLEN'((2'b01 << 11) | (1 << 7)));
        mret_en = 1'b1; @(posedge clk); #1; mret_en = 1'b0;
        check_priv("priv=S before test [7]", priv_level, PRIV_S);

        // Delegate both U and S ecall to S-mode
        csr_write(CSR_MEDELEG, XLEN'((1<<8)|(1<<9)));

        // ECALL_S from S-mode (delegated)
        trap_cause = XLEN'(EXC_ECALL_S); trap_epc = XLEN'(32'h3000);
        trap_val = XLEN'(0); trap_enter = 1'b1;
        #1; // let combinational logic (assign trap_vector) settle across delta cycles
        check_v("trap_vector=STVEC", trap_vector, XLEN'(32'hC000_0000));
        @(posedge clk); #1;
        trap_enter = 1'b0; trap_cause = '0; trap_epc = '0;
        check_priv("priv=S after delegated S-ECALL", priv_level, PRIV_S);
        csr_rd(CSR_SCAUSE);
        check_v("scause=EXC_ECALL_S",    csr_rdata, XLEN'(EXC_ECALL_S));
        csr_rd(CSR_SEPC);
        check_v("sepc=0x3000",           csr_rdata, XLEN'(32'h3000));
        // SPP should be 1 (came from S-mode)
        csr_rd(CSR_SSTATUS);
        check_x("SPP=1 (from S-mode)",   csr_rdata[8], 1'b1);

        // ----------------------------------------------------------------
        // [8] SRET → S-mode (SPP=1)
        // ----------------------------------------------------------------
        $display("\n[8] SRET: S-mode → S-mode (SPP=1)");
        sret_en = 1'b1; @(posedge clk); #1; sret_en = 1'b0;
        check_priv("priv=S after SRET (SPP=1)", priv_level, PRIV_S);
        csr_rd(CSR_SSTATUS);
        check_x("SPP=0 after SRET",      csr_rdata[8], 1'b0);

        // ----------------------------------------------------------------
        // [9] MRET still works correctly with S-mode CSRs present
        // ----------------------------------------------------------------
        $display("\n[9] MRET still works after S-mode addition");
        // Take a non-delegated trap (medeleg=0 for breakpoint cause=3)
        csr_write(CSR_MEDELEG, XLEN'(0));
        csr_write(CSR_MTVEC,   XLEN'(32'h8000_0000));
        trap_cause = XLEN'(EXC_BREAKPOINT); trap_epc = XLEN'(32'h4000);
        trap_val = XLEN'(0); trap_enter = 1'b1;
        @(posedge clk); #1;
        trap_enter = 1'b0; trap_cause = '0; trap_epc = '0;
        check_priv("priv=M after EBREAK trap", priv_level, PRIV_M);
        csr_rd(CSR_MCAUSE);
        check_v("mcause=EXC_BREAKPOINT", csr_rdata, XLEN'(EXC_BREAKPOINT));
        csr_rd(CSR_MEPC);
        check_v("mepc=0x4000",           csr_rdata, XLEN'(32'h4000));

        // MRET → restore to S-mode (MPP=S, since we came from S via test [8])
        mret_en = 1'b1; @(posedge clk); #1; mret_en = 1'b0;
        check_priv("priv=S after MRET",  priv_level, PRIV_S);

        // ----------------------------------------------------------------
        // [10] SIE masked view of MIE
        // ----------------------------------------------------------------
        $display("\n[10] SIE masked view of MIE");
        // Start from a clean MIE with only M-mode bits set: MSIP[3], MTIP[7]
        csr_write(CSR_MIE, XLEN'(32'h0088));  // bit3=1 (MSIP), bit7=1 (MTIP)
        csr_rd(CSR_SIE);
        // SIE = MIE & S_IRQ_MASK(bits 1,5,9) = 0x0088 & 0x0222 = 0x0000
        check_v("SIE = 0 (no S-bits in MIE)", csr_rdata, XLEN'(0));

        // Write SIE: set SSIP[1] and SEIP[9], leave STIP[5]=0
        // S_IRQ_MASK = bits 1,5,9 = 0x0222
        // csr_new for SIE = 0x0202 → & S_IRQ_MASK = 0x0202 (bit1=1, bit9=1, bit5=0)
        csr_write(CSR_SIE, XLEN'(32'h0202));  // SSIP[1]=1, STIP[5]=0, SEIP[9]=1
        csr_rd(CSR_MIE);
        // MIE = (old_MIE & ~S_IRQ_MASK) | (SIE_write & S_IRQ_MASK)
        //     = (0x0088 & ~0x0222) | 0x0202
        //     = 0x0088 | 0x0202
        //     = 0x028A  (bit1, bit3, bit7, bit9 set)
        check_v("MIE after SIE write", csr_rdata, XLEN'(32'h028A));

        // ----------------------------------------------------------------
        // [11] Page fault delegation (medeleg bits 12/13/15)
        // ----------------------------------------------------------------
        $display("\n[11] Page fault delegation and trap to S-mode");
        csr_write(CSR_MEDELEG, XLEN'((1<<12)|(1<<13)|(1<<15)));
        csr_write(CSR_STVEC,   XLEN'(32'hD000_0000));
        // Transition to U-mode for the test
        csr_write(CSR_MSTATUS, XLEN'((2'b00 << 11) | (1 << 7)));
        mret_en = 1'b1; @(posedge clk); #1; mret_en = 1'b0;
        check_priv("priv=U for page fault test", priv_level, PRIV_U);

        // Load page fault (cause=13) from U-mode → delegated to S-mode
        trap_cause = XLEN'(EXC_LOAD_PAGE_FAULT); trap_epc = XLEN'(32'h5000);
        trap_val = XLEN'(32'hBAD0_0000); trap_enter = 1'b1;
        #1; // let combinational logic (assign trap_vector) settle across delta cycles
        check_v("trap_vector=STVEC (load page fault)", trap_vector, XLEN'(32'hD000_0000));
        @(posedge clk); #1;
        trap_enter = 1'b0; trap_cause = '0; trap_epc = '0; trap_val = '0;
        check_priv("priv=S after delegated page fault", priv_level, PRIV_S);
        csr_rd(CSR_SCAUSE);
        check_v("scause=EXC_LOAD_PAGE_FAULT", csr_rdata, XLEN'(EXC_LOAD_PAGE_FAULT));
        csr_rd(CSR_STVAL);
        check_v("stval=fault address",        csr_rdata, XLEN'(32'hBAD0_0000));
        csr_rd(CSR_SEPC);
        check_v("sepc=0x5000",                csr_rdata, XLEN'(32'h5000));

        // ----------------------------------------------------------------
        // Results
        // ----------------------------------------------------------------
        $display("\n=== Results: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("ALL PASS");
        else               $display("SOME TESTS FAILED");
        $finish;
    end

    initial begin #200000; $display("TIMEOUT"); $finish; end

endmodule
