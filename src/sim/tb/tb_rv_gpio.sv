// =============================================================================
// tb_rv_gpio.sv - Testbench for rv_gpio
// =============================================================================
// Test cases:
//   [1]  Reset state (OUT=0, DIR=0, IRQ_EN=0, gpio_out=0, irq=0)
//   [2]  Direction control (DIR=1111 → gpio_out driven by OUT)
//   [3]  Output write: set OUT, verify gpio_out changes
//   [4]  Input read: gpio_in sampled after 2-FF synchroniser
//   [5]  Input read-only: write to IN register has no effect
//   [6]  IRQ: enable bit, change gpio_in → irq asserted
//   [7]  IRQ clear: write 1 to IRQ_EN register (ACK) → irq de-asserted
//   [8]  IRQ masked: change disabled bit → irq stays low
//   [9]  DIR=0 (input): gpio_out stays 0 regardless of OUT register
//   [10] Read-back of DIR and IRQ_EN registers
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_gpio;

    // =========================================================================
    // DUT signals
    // =========================================================================
    localparam int W = 4;

    logic        clk;
    logic        rst_n;

    logic [3:0]  addr;
    logic        req;
    logic        we;
    logic [31:0] wdata;
    logic [31:0] rdata;

    logic [W-1:0] gpio_in;
    logic [W-1:0] gpio_out;
    logic          irq;

    rv_gpio #(.WIDTH(W)) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .addr     (addr),
        .req      (req),
        .we       (we),
        .wdata    (wdata),
        .rdata    (rdata),
        .gpio_in  (gpio_in),
        .gpio_out (gpio_out),
        .irq      (irq)
    );

    // =========================================================================
    // Clock: 10 ns period
    // =========================================================================
    initial clk = 0;
    always #5 clk = ~clk;

    // =========================================================================
    // Register address constants
    // =========================================================================
    localparam logic [3:0] ADDR_OUT    = 4'h0;
    localparam logic [3:0] ADDR_IN     = 4'h4;
    localparam logic [3:0] ADDR_DIR    = 4'h8;
    localparam logic [3:0] ADDR_IRQ_EN = 4'hC;

    // =========================================================================
    // Bus tasks
    // =========================================================================
    task automatic bus_write(input logic [3:0] a, input logic [31:0] d);
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
    task automatic bus_read(input logic [3:0] a);
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
        input logic [31:0] got,
        input logic [31:0] exp
    );
        if (got === exp) begin
            $display("  PASS  %-42s got=0x%08h", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL  %-42s got=0x%08h  exp=0x%08h", name, got, exp);
            fail_cnt++;
        end
    endtask

    // =========================================================================
    // Main test
    // =========================================================================
    initial begin
        // Init
        addr    = '0;
        req     = 0;
        we      = 0;
        wdata   = '0;
        gpio_in = 4'h0;
        rst_n   = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // =================================================================
        $display("\n[1] Reset state");
        // =================================================================
        bus_read(ADDR_OUT);
        chk("OUT = 0 after reset",    rd_val, 32'h0);
        bus_read(ADDR_DIR);
        chk("DIR = 0 after reset",    rd_val, 32'h0);
        bus_read(ADDR_IRQ_EN);
        chk("IRQ_EN = 0 after reset", rd_val, 32'h0);
        chk("gpio_out = 0",  {28'h0, gpio_out}, 32'h0);
        chk("irq = 0",       {31'h0, irq},      32'h0);

        // =================================================================
        $display("\n[2] DIR register: enable all outputs");
        // =================================================================
        bus_write(ADDR_DIR, 32'hF);    // 4'b1111 → all pins = output
        bus_read(ADDR_DIR);
        chk("DIR = 0xF (all output)", rd_val, 32'hF);
        chk("gpio_out still 0 (OUT=0)", {28'h0, gpio_out}, 32'h0);

        // =================================================================
        $display("\n[3] OUT register: drive gpio_out");
        // =================================================================
        bus_write(ADDR_OUT, 32'hA);   // 4'b1010
        @(posedge clk); #1;
        chk("gpio_out = 0xA (DIR=F, OUT=A)", {28'h0, gpio_out}, 32'hA);

        bus_write(ADDR_OUT, 32'h5);   // 4'b0101
        @(posedge clk); #1;
        chk("gpio_out = 0x5 (OUT toggled)",  {28'h0, gpio_out}, 32'h5);

        bus_read(ADDR_OUT);
        chk("OUT readback = 0x5",            rd_val, 32'h5);

        // =================================================================
        $display("\n[4] IN register: gpio_in sampled through 2-FF synchroniser");
        // =================================================================
        gpio_in = 4'h9;   // 4'b1001
        // Need 2 FF clock cycles + 1 for stable output
        repeat(4) @(posedge clk); #1;
        bus_read(ADDR_IN);
        chk("IN = 0x9 after gpio_in set", rd_val, 32'h9);

        gpio_in = 4'h6;
        repeat(4) @(posedge clk); #1;
        bus_read(ADDR_IN);
        chk("IN = 0x6 after gpio_in change", rd_val, 32'h6);

        // =================================================================
        $display("\n[5] IN register is read-only");
        // =================================================================
        bus_write(ADDR_IN, 32'hF);    // should be ignored
        bus_read(ADDR_IN);
        chk("IN = 0x6 (write ignored)", rd_val, 32'h6);

        // =================================================================
        $display("\n[6] IRQ: change-detect interrupt");
        // =================================================================
        // Enable irq for bits [1:0]
        bus_write(ADDR_IRQ_EN, 32'h3);   // bit0 and bit1 enabled
        bus_read(ADDR_IRQ_EN);
        chk("IRQ_EN = 0x3", rd_val, 32'h3);

        // gpio_in already at 0x6 (4'b0110), change bit0 (enabled)
        gpio_in = 4'h7;   // bit0 changes: 0→1
        repeat(4) @(posedge clk); #1;
        chk("irq=1 (bit0 changed, enabled)", {31'h0, irq}, 32'h1);

        // =================================================================
        $display("\n[7] IRQ clear: write 1 to ACK");
        // =================================================================
        bus_write(ADDR_IRQ_EN, 32'h3);   // ACK bit0 pending (write=clear)
        @(posedge clk); #1;
        chk("irq=0 after ACK",  {31'h0, irq}, 32'h0);
        // IRQ_EN bits should be cleared (ACK clears pending, not irq_en)
        // After ACK, if gpio_in doesn't change again, irq stays 0
        bus_read(ADDR_IRQ_EN);
        chk("IRQ_EN still 0x3 (ACK doesnt disable)", rd_val, 32'h3);

        // =================================================================
        $display("\n[8] IRQ masked: disabled bit change does not assert irq");
        // =================================================================
        // bit2 and bit3 are NOT in IRQ_EN (only bits 0,1)
        gpio_in = 4'hF;   // bits 2,3 change, but not enabled
        repeat(4) @(posedge clk); #1;
        // bit0 and bit1 also changed (6→7→F), so check only masked scenario
        // Clear again then test bit3 only
        bus_write(ADDR_IRQ_EN, 32'h3);   // ACK pending
        @(posedge clk); #1;

        gpio_in = 4'h7;   // bit3 changes (F→7), not enabled; bit0,1,2 also change
        // But bits 0,1 are enabled → irq may fire. Let's test bit[3] only:
        // Disable all, then change only bit3
        bus_write(ADDR_IRQ_EN, 32'h0);   // disable irq (writes 0 to irq_en)
        // Wait for ACK to take effect
        @(posedge clk); @(posedge clk);
        // Re-enable only bit3=0 (keep bit3 disabled)
        bus_write(ADDR_IRQ_EN, 32'h4);   // enable bit2 only
        gpio_in = 4'h0;   // all bits change
        repeat(4) @(posedge clk); #1;
        bus_write(ADDR_IRQ_EN, 32'h4);   // ACK any pending from bit2
        @(posedge clk); #1;
        // Now gpio_in=0x0, change bit3 only (not enabled)
        gpio_in = 4'h8;   // bit3=1, others=0  → only bit3 changes
        repeat(4) @(posedge clk); #1;
        chk("irq=0 (bit3 changed but not enabled)", {31'h0, irq}, 32'h0);

        // =================================================================
        $display("\n[9] DIR=0: gpio_out stays 0 regardless of OUT");
        // =================================================================
        bus_write(ADDR_DIR, 32'h0);   // all pins = input
        bus_write(ADDR_OUT, 32'hF);   // write to OUT register
        @(posedge clk); #1;
        chk("gpio_out=0 (DIR=0 masks output)", {28'h0, gpio_out}, 32'h0);
        bus_read(ADDR_OUT);
        chk("OUT register holds 0xF",          rd_val, 32'hF);

        // Partial DIR: only bit1 = output
        bus_write(ADDR_DIR, 32'h2);   // bit1 output, others input
        bus_write(ADDR_OUT, 32'hF);
        @(posedge clk); #1;
        chk("gpio_out=0x2 (only bit1 output)", {28'h0, gpio_out}, 32'h2);

        // =================================================================
        $display("\n[10] Register read-back: DIR and IRQ_EN");
        // =================================================================
        bus_write(ADDR_DIR, 32'hA);   // 4'b1010
        bus_read(ADDR_DIR);
        chk("DIR readback = 0xA", rd_val, 32'hA);

        bus_write(ADDR_IRQ_EN, 32'h5);   // 4'b0101
        bus_read(ADDR_IRQ_EN);
        chk("IRQ_EN readback = 0x5", rd_val, 32'h5);

        // =================================================================
        $display("\n======================================");
        $display("  GPIO testbench: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("======================================\n");
        if (fail_cnt == 0)
            $display("ALL PASS");
        else
            $display("FAILED %0d test(s)", fail_cnt);
        $finish;
    end

    // Timeout
    initial begin
        #500_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
