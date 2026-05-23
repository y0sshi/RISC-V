// =============================================================================
// tb_rv_plic.sv - Testbench for rv_plic (RISC-V PLIC)
// =============================================================================
// Test cases:
//   [1]  Reset state (all zeros, ext_irq=0)
//   [2]  Priority register read/write
//   [3]  Threshold register read/write
//   [4]  Enable register read/write (M-mode / S-mode)
//   [5]  Pending set on rising edge of src_irq
//   [6]  ext_irq[0] asserted (M-mode): enable, pending, prio > thresh
//   [7]  ext_irq suppressed when prio <= threshold
//   [8]  Claim: read claim reg → returns best ID, ext_irq goes LOW
//   [9]  Complete: write source ID → pending cleared
//   [10] Two simultaneous sources: higher-priority wins
//   [11] S-mode context (ext_irq[1]) independent of M-mode
//   [12] Pending cleared only on complete, not on src_irq de-assert
//
// Bus helper tasks operate with 4-cycle req pulses and combinational rdata.
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_plic;

    // =========================================================================
    // DUT signals
    // =========================================================================
    logic        clk;
    logic        rst_n;

    logic [11:0] addr;
    logic        req;
    logic        we;
    logic [31:0] wdata;
    logic [31:0] rdata;

    logic [8:1]  src_irq;
    logic [1:0]  ext_irq;

    rv_plic #(
        .NSRC      (8),
        .NCTX      (2),
        .PRIO_BITS (3)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .addr     (addr),
        .req      (req),
        .we       (we),
        .wdata    (wdata),
        .rdata    (rdata),
        .src_irq  (src_irq),
        .ext_irq  (ext_irq)
    );

    // =========================================================================
    // Clock: 10 ns period
    // =========================================================================
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // Address constants
    // =========================================================================
    // Priority: base 0x000, source N at offset N*4
    function automatic logic [11:0] PRIO_ADDR(input int src);
        return 12'(src * 4);
    endfunction

    localparam logic [11:0] PENDING_ADDR  = 12'h100;
    localparam logic [11:0] ENABLE0_ADDR  = 12'h200;   // M-mode enable
    localparam logic [11:0] ENABLE1_ADDR  = 12'h204;   // S-mode enable
    localparam logic [11:0] THRESH0_ADDR  = 12'h300;   // M-mode threshold
    localparam logic [11:0] CLAIM0_ADDR   = 12'h304;   // M-mode claim/complete
    localparam logic [11:0] THRESH1_ADDR  = 12'h308;   // S-mode threshold
    localparam logic [11:0] CLAIM1_ADDR   = 12'h30C;   // S-mode claim/complete

    // =========================================================================
    // Bus tasks
    // =========================================================================
    task automatic bus_write(input logic [11:0] a, input logic [31:0] d);
        @(posedge clk); #1;
        addr  <= a;
        wdata <= d;
        req   <= 1'b1;
        we    <= 1'b1;
        @(posedge clk); #1;
        req   <= 1'b0;
        we    <= 1'b0;
        addr  <= '0;
        wdata <= '0;
    endtask

    logic [31:0] rd_val;
    task automatic bus_read(input logic [11:0] a);
        @(posedge clk); #1;
        addr  <= a;
        req   <= 1'b1;
        we    <= 1'b0;
        @(posedge clk); #1;
        rd_val = rdata;
        req    <= 1'b0;
        addr   <= '0;
    endtask

    // =========================================================================
    // Check helper
    // =========================================================================
    int pass_cnt = 0;
    int fail_cnt = 0;

    task automatic chk(
        input string  name,
        input logic [63:0] got,
        input logic [63:0] exp
    );
        if (got === exp) begin
            $display("  PASS  %-40s got=0x%08h", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL  %-40s got=0x%08h  exp=0x%08h", name, got, exp);
            fail_cnt++;
        end
    endtask

    // =========================================================================
    // Main test
    // =========================================================================
    initial begin
        // -- Init -----------------------------------------------------------
        addr    = '0;
        req     = 0;
        we      = 0;
        wdata   = '0;
        src_irq = '0;
        rst_n   = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // =================================================================
        $display("\n[1] Reset state");
        // =================================================================
        bus_read(PENDING_ADDR);
        chk("pending = 0 after reset", rd_val, 32'h0);

        bus_read(ENABLE0_ADDR);
        chk("enable[0] = 0 after reset", rd_val, 32'h0);

        bus_read(THRESH0_ADDR);
        chk("threshold[0] = 0 after reset", rd_val, 32'h0);

        bus_read(CLAIM0_ADDR);
        chk("claim[0] = 0 (no source)", rd_val, 32'h0);

        chk("ext_irq[0]=0 after reset", {31'h0, ext_irq[0]}, 32'h0);
        chk("ext_irq[1]=0 after reset", {31'h0, ext_irq[1]}, 32'h0);

        // =================================================================
        $display("\n[2] Priority register read/write");
        // =================================================================
        bus_write(PRIO_ADDR(1), 32'h3);
        bus_read (PRIO_ADDR(1));
        chk("priority[1] = 3", rd_val, 32'h3);

        bus_write(PRIO_ADDR(2), 32'h5);
        bus_read (PRIO_ADDR(2));
        chk("priority[2] = 5", rd_val, 32'h5);

        bus_write(PRIO_ADDR(0), 32'h7);   // source 0 is reserved, write ignored
        bus_read (PRIO_ADDR(0));
        chk("priority[0] = 0 (reserved)", rd_val, 32'h0);

        // =================================================================
        $display("\n[3] Threshold register read/write");
        // =================================================================
        bus_write(THRESH0_ADDR, 32'h2);
        bus_read (THRESH0_ADDR);
        chk("threshold[0] = 2", rd_val, 32'h2);

        bus_write(THRESH1_ADDR, 32'h4);
        bus_read (THRESH1_ADDR);
        chk("threshold[1] = 4", rd_val, 32'h4);

        // =================================================================
        $display("\n[4] Enable register read/write");
        // =================================================================
        // Enable source 1 for M-mode (bit 1)
        bus_write(ENABLE0_ADDR, 32'h2);   // bit[1]=1
        bus_read (ENABLE0_ADDR);
        chk("enable[0] bit1=1 (src1 M-mode)", rd_val[1], 1'h1);
        chk("enable[0] bit2=0",               rd_val[2], 1'h0);

        // Enable source 1,2 for S-mode
        bus_write(ENABLE1_ADDR, 32'h6);   // bit[1]=1, bit[2]=1
        bus_read (ENABLE1_ADDR);
        chk("enable[1] bit1=1 (src1 S-mode)", rd_val[1], 1'h1);
        chk("enable[1] bit2=1 (src2 S-mode)", rd_val[2], 1'h1);

        // =================================================================
        $display("\n[5] Pending set on rising edge of src_irq");
        // =================================================================
        src_irq[1] = 1'b1;
        @(posedge clk); @(posedge clk); #1;  // allow edge latch
        bus_read(PENDING_ADDR);
        chk("pending[1]=1 after src_irq[1] rise", rd_val[1], 1'h1);

        src_irq[1] = 1'b0;   // de-assert, but pending should remain
        @(posedge clk); #1;
        bus_read(PENDING_ADDR);
        chk("pending[1]=1 after src_irq de-assert", rd_val[1], 1'h1);

        // =================================================================
        $display("\n[6] ext_irq[0] assertion (M-mode)");
        // =================================================================
        // Setup: threshold[0]=0, priority[1]=3, enable[0][1]=1, pending[1]=1
        bus_write(THRESH0_ADDR, 32'h0);
        @(posedge clk); #1;
        chk("ext_irq[0]=1 (prio>thresh, enabled, pending)", {31'h0, ext_irq[0]}, 32'h1);

        // =================================================================
        $display("\n[7] ext_irq suppressed when prio <= threshold");
        // =================================================================
        bus_write(THRESH0_ADDR, 32'h3);  // threshold = priority[1] = 3
        @(posedge clk); #1;
        chk("ext_irq[0]=0 (prio not > thresh)", {31'h0, ext_irq[0]}, 32'h0);
        bus_write(THRESH0_ADDR, 32'h0);  // restore

        // =================================================================
        $display("\n[8] Claim: read claim → best ID returned, ext_irq LOW");
        // =================================================================
        @(posedge clk); #1;
        chk("ext_irq[0]=1 before claim", {31'h0, ext_irq[0]}, 32'h1);

        bus_read(CLAIM0_ADDR);
        chk("claim[0] = source 1", rd_val, 32'h1);
        @(posedge clk); #1;   // claimed0 sets next cycle
        chk("ext_irq[0]=0 after claim", {31'h0, ext_irq[0]}, 32'h0);

        // =================================================================
        $display("\n[9] Complete: write source ID → pending cleared");
        // =================================================================
        bus_write(CLAIM0_ADDR, 32'h1);   // complete source 1
        @(posedge clk); #1;
        bus_read(PENDING_ADDR);
        chk("pending[1]=0 after complete", rd_val[1], 1'h0);
        chk("ext_irq[0]=0 after complete", {31'h0, ext_irq[0]}, 32'h0);

        // =================================================================
        $display("\n[10] Two sources: higher priority wins");
        // =================================================================
        // Setup both source 1 (prio=3) and source 2 (prio=5) pending and enabled
        bus_write(PRIO_ADDR(1), 32'h3);
        bus_write(PRIO_ADDR(2), 32'h5);
        bus_write(ENABLE0_ADDR, 32'h6);  // enable src 1 and 2 for M-mode
        bus_write(THRESH0_ADDR, 32'h0);

        src_irq[1] = 1'b1;
        src_irq[2] = 1'b1;
        @(posedge clk); @(posedge clk); #1;  // edge latch
        src_irq[1] = 1'b0;
        src_irq[2] = 1'b0;

        bus_read(PENDING_ADDR);
        chk("pending[1]=1 AND pending[2]=1", rd_val[2:1], 2'h3);

        bus_read(CLAIM0_ADDR);
        chk("claim = source 2 (higher prio)", rd_val, 32'h2);  // prio[2]=5 > prio[1]=3

        // Complete source 2
        bus_write(CLAIM0_ADDR, 32'h2);
        @(posedge clk); #1;
        bus_read(PENDING_ADDR);
        chk("pending[2]=0 after complete", rd_val[2], 1'h0);
        chk("pending[1]=1 still pending",  rd_val[1], 1'h1);

        // Now source 1 should win
        @(posedge clk); #1;
        chk("ext_irq[0]=1 (src1 still pending)", {31'h0, ext_irq[0]}, 32'h1);

        bus_read(CLAIM0_ADDR);
        chk("claim = source 1 now", rd_val, 32'h1);
        bus_write(CLAIM0_ADDR, 32'h1);  // complete
        @(posedge clk); #1;

        // =================================================================
        $display("\n[11] S-mode context independent from M-mode");
        // =================================================================
        // Setup: source 3, prio=6, S-mode enable only, M-mode threshold high
        bus_write(PRIO_ADDR(3), 32'h6);
        bus_write(ENABLE0_ADDR, 32'h0);   // M-mode: no enable
        bus_write(ENABLE1_ADDR, 32'h8);   // S-mode: enable source 3 (bit 3)
        bus_write(THRESH0_ADDR, 32'h0);
        bus_write(THRESH1_ADDR, 32'h0);

        src_irq[3] = 1'b1;
        @(posedge clk); @(posedge clk); #1;
        src_irq[3] = 1'b0;

        chk("ext_irq[0]=0 (src3 not M-enabled)", {31'h0, ext_irq[0]}, 32'h0);
        chk("ext_irq[1]=1 (src3 S-enabled)",     {31'h0, ext_irq[1]}, 32'h1);

        bus_read(CLAIM1_ADDR);
        chk("claim[1] = source 3", rd_val, 32'h3);
        bus_write(CLAIM1_ADDR, 32'h3);  // complete
        @(posedge clk); #1;
        chk("ext_irq[1]=0 after S-mode complete", {31'h0, ext_irq[1]}, 32'h0);

        // =================================================================
        $display("\n[12] Pending latch: stays set even when src_irq goes low");
        // =================================================================
        bus_write(ENABLE0_ADDR, 32'h10);  // enable source 4 for M-mode
        bus_write(PRIO_ADDR(4), 32'h2);
        bus_write(THRESH0_ADDR, 32'h0);

        src_irq[4] = 1'b1;
        @(posedge clk); @(posedge clk); #1;
        src_irq[4] = 1'b0;           // de-assert before claim

        @(posedge clk); @(posedge clk); #1;
        bus_read(PENDING_ADDR);
        chk("pending[4] held after src_irq gone", rd_val[4], 1'h1);
        chk("ext_irq[0]=1 (pending still set)", {31'h0, ext_irq[0]}, 32'h1);

        // Clean up
        bus_read(CLAIM0_ADDR);
        bus_write(CLAIM0_ADDR, rd_val[7:0]);

        // =================================================================
        $display("\n======================================");
        $display("  PLIC testbench: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("======================================\n");
        if (fail_cnt == 0)
            $display("ALL PASS");
        else
            $display("FAILED %0d test(s)", fail_cnt);
        $finish;
    end

    // Timeout guard
    initial begin
        #1_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
