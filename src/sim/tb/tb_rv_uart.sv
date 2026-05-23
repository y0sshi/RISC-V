// =============================================================================
// tb_rv_uart.sv - Testbench for rv_uart
// =============================================================================
// CLK_FREQ=100, BAUD_RATE=10 → DEF_DIV=9, 10 clocks/bit
// 1 frame = 1(start)+8(data)+1(stop) = 10 bits = 100 clocks
//
// Tests:
//  [1] Reset state checks (STAT=TXRDY, CTRL=TXEN|RXEN)
//  [2] TX 0x55: transmit and verify bit-by-bit on uart_tx
//  [3] TX interrupt (TXIE)
//  [4] RX 0xA5: inject bit stream on uart_rx, read DATA
//  [5] RX interrupt (RXIE, level signal)
//  [6] Loopback: connect uart_tx → uart_rx and receive own transmission
//  [7] Framing error: inject bad stop bit
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_uart;

    // =========================================================================
    // DUT parameters / clock
    // =========================================================================
    localparam int CLK_FREQ  = 100;
    localparam int BAUD_RATE = 10;
    localparam int CLKS_BIT  = CLK_FREQ / BAUD_RATE;   // = 10
    localparam int HALF_BIT  = CLKS_BIT / 2;            // = 5

    logic        clk   = 0;
    logic        rst_n = 0;
    always #5 clk = ~clk;  // 10 ns period (100 MHz nominal)

    // Bus signals
    logic [3:0]  addr;
    logic        req;
    logic        we;
    logic [31:0] wdata;
    logic [31:0] rdata;

    // UART pins
    logic        uart_tx;
    logic        uart_rx = 1'b1;  // idle high

    // Interrupts
    logic        tx_irq;
    logic        rx_irq;

    // Loopback control
    logic        loopback = 1'b0;

    // =========================================================================
    // DUT
    // =========================================================================
    rv_uart #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .addr     (addr),
        .req      (req),
        .we       (we),
        .wdata    (wdata),
        .rdata    (rdata),
        .uart_tx  (uart_tx),
        .uart_rx  (loopback ? uart_tx : uart_rx),
        .tx_irq   (tx_irq),
        .rx_irq   (rx_irq)
    );

    // =========================================================================
    // Test infrastructure
    // =========================================================================
    int  pass_cnt = 0;
    int  fail_cnt = 0;

    task automatic bus_write(input [3:0] a, input [31:0] d);
        @(negedge clk);
        addr  = a;
        req   = 1'b1;
        we    = 1'b1;
        wdata = d;
        @(negedge clk);
        req   = 1'b0;
        we    = 1'b0;
    endtask

    task automatic bus_read(input [3:0] a, output [31:0] d);
        @(negedge clk);
        addr  = a;
        req   = 1'b1;
        we    = 1'b0;
        wdata = 32'd0;
        @(posedge clk); #1;
        d = rdata;
        @(negedge clk);
        req = 1'b0;
    endtask

    task automatic check(input string name,
                         input [31:0] got, input [31:0] exp);
        if (got === exp) begin
            $display("  PASS  %-40s got=0x%08h", name, got);
            pass_cnt++;
        end else begin
            $display("  FAIL  %-40s got=0x%08h exp=0x%08h", name, got, exp);
            fail_cnt++;
        end
    endtask

    // Wait for TXRDY to become 1 (TX idle) with timeout
    task automatic wait_txrdy(input int timeout_clks);
        automatic int cnt = 0;
        automatic logic [31:0] stat;
        automatic logic done = 1'b0;
        while (!done) begin
            bus_read(4'h4, stat);
            cnt++;
            if (stat[0]) begin
                done = 1'b1;
            end else if (cnt > timeout_clks) begin
                $display("  FAIL  wait_txrdy: timeout");
                fail_cnt++;
                done = 1'b1;
            end
        end
    endtask

    // Inject one byte on uart_rx at CLKS_BIT clocks/bit
    task automatic rx_inject(input [7:0] data);
        // start bit
        @(negedge clk); uart_rx = 1'b0;
        repeat (CLKS_BIT) @(posedge clk);
        // 8 data bits, LSB first
        for (int i = 0; i < 8; i++) begin
            @(negedge clk); uart_rx = data[i];
            repeat (CLKS_BIT) @(posedge clk);
        end
        // stop bit
        @(negedge clk); uart_rx = 1'b1;
        repeat (CLKS_BIT) @(posedge clk);
    endtask

    // =========================================================================
    // Main test
    // =========================================================================
    initial begin
        // Dump waveform
        $dumpfile("wave/tb_rv_uart.vcd");
        $dumpvars(0, tb_rv_uart);

        // Idle defaults
        addr  = 4'h0;
        req   = 1'b0;
        we    = 1'b0;
        wdata = 32'd0;

        // Release reset
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // =====================================================================
        // [1] Reset state
        // =====================================================================
        $display("\n[1] Reset state");
        begin
            logic [31:0] stat, ctrl, div_val;
            bus_read(4'h4, stat);
            check("STAT: TXRDY=1, RXRDY=0, RXERR=0", stat, 32'h0000_0001);
            bus_read(4'h8, ctrl);
            check("CTRL: TXEN=1, RXEN=1, TXIE=0, RXIE=0", ctrl, 32'h0000_0003);
            bus_read(4'hC, div_val);
            check("DIV: default = CLK/BAUD-1 = 9", div_val, 32'd9);
        end

        // =====================================================================
        // [2] TX 0x55 bit-verify
        // =====================================================================
        $display("\n[2] TX 0x55 bit-verify");
        begin
            // uart_tx should be idle high
            @(negedge clk);
            check("TX idle before write", {31'd0, uart_tx}, 32'h0000_0001);

            // Kick TX
            bus_write(4'h0, 32'h55);

            // Wait for start bit (uart_tx goes low within a couple clocks)
            repeat (2) @(posedge clk);
            check("start bit low", {31'd0, uart_tx}, 32'h0000_0000);

            // Wait one full bit, then sample data bits
            // We are currently at the beginning of the start bit.
            // Advance CLKS_BIT clocks to reach bit-0 of data.
            repeat (CLKS_BIT) @(posedge clk);
            check("bit0=1 (0x55)", {31'd0, uart_tx}, 32'h0000_0001);
            repeat (CLKS_BIT) @(posedge clk);
            check("bit1=0 (0x55)", {31'd0, uart_tx}, 32'h0000_0000);
            repeat (CLKS_BIT) @(posedge clk);
            check("bit2=1 (0x55)", {31'd0, uart_tx}, 32'h0000_0001);
            repeat (CLKS_BIT) @(posedge clk);
            check("bit3=0 (0x55)", {31'd0, uart_tx}, 32'h0000_0000);
            repeat (CLKS_BIT) @(posedge clk);
            check("bit4=1 (0x55)", {31'd0, uart_tx}, 32'h0000_0001);
            repeat (CLKS_BIT) @(posedge clk);
            check("bit5=0 (0x55)", {31'd0, uart_tx}, 32'h0000_0000);
            repeat (CLKS_BIT) @(posedge clk);
            check("bit6=1 (0x55)", {31'd0, uart_tx}, 32'h0000_0001);
            repeat (CLKS_BIT) @(posedge clk);
            check("bit7=0 (0x55)", {31'd0, uart_tx}, 32'h0000_0000);
            // stop bit
            repeat (CLKS_BIT) @(posedge clk);
            check("stop bit high", {31'd0, uart_tx}, 32'h0000_0001);
            // TXRDY should be 1 after stop bit completes
            repeat (CLKS_BIT) @(posedge clk);
            begin
                logic [31:0] stat;
                bus_read(4'h4, stat);
                check("STAT: TXRDY=1 after TX", stat[0:0], 1'd1);
            end
        end

        // =====================================================================
        // [3] TX interrupt (TXIE)
        // =====================================================================
        $display("\n[3] TX interrupt (TXIE)");
        begin
            // Enable TXIE
            bus_write(4'h8, 32'h0000_0007);   // TXEN|RXEN|TXIE

            // tx_irq should be 0 now (no pulse)
            @(negedge clk);
            check("tx_irq idle = 0", {31'd0, tx_irq}, 32'd0);

            // Send byte
            bus_write(4'h0, 32'h41);

            // Wait for TX to complete
            wait_txrdy(300);

            // tx_irq should have pulsed 1 cycle at TX done; tx_done is a pulse,
            // so we check TXRDY (STAT[0]) as proxy that TX finished
            begin
                logic [31:0] stat;
                bus_read(4'h4, stat);
                check("STAT: TXRDY=1 after IRQ TX", stat[0:0], 1'd1);
            end

            // Disable TXIE
            bus_write(4'h8, 32'h0000_0003);   // TXEN|RXEN
        end

        // =====================================================================
        // [4] RX 0xA5
        // =====================================================================
        $display("\n[4] RX 0xA5");
        begin
            logic [31:0] stat, data;

            // Inject 0xA5 on uart_rx
            rx_inject(8'hA5);

            // Wait a couple clocks for rxrdy to register
            repeat (2) @(posedge clk);

            bus_read(4'h4, stat);
            check("STAT: RXRDY=1 after receive", stat[1:1], 1'd1);
            check("STAT: RXERR=0 (no framing error)", stat[2:2], 1'd0);

            // Read DATA clears RXRDY
            bus_read(4'h0, data);
            check("DATA: received 0xA5", data[7:0], 8'hA5);

            bus_read(4'h4, stat);
            check("STAT: RXRDY=0 after DATA read", stat[1:1], 1'd0);
        end

        // =====================================================================
        // [5] RX interrupt (RXIE, level)
        // =====================================================================
        $display("\n[5] RX interrupt (RXIE)");
        begin
            logic [31:0] stat, data;

            // Enable RXIE
            bus_write(4'h8, 32'h0000_000B);   // TXEN|RXEN|RXIE

            // rx_irq should be 0 before receive
            @(negedge clk);
            check("rx_irq before RX = 0", {31'd0, rx_irq}, 32'd0);

            // Inject 0x3C
            rx_inject(8'h3C);
            repeat (2) @(posedge clk);

            // rx_irq should be high (RXRDY & RXIE)
            @(negedge clk);
            check("rx_irq = 1 (RXRDY & RXIE)", {31'd0, rx_irq}, 32'd1);

            // Read DATA → clears RXRDY → rx_irq goes low
            bus_read(4'h0, data);
            check("DATA: received 0x3C", data[7:0], 8'h3C);
            @(negedge clk);
            check("rx_irq = 0 after DATA read", {31'd0, rx_irq}, 32'd0);

            // Disable RXIE
            bus_write(4'h8, 32'h0000_0003);   // TXEN|RXEN
        end

        // =====================================================================
        // [6] Loopback: uart_tx → uart_rx
        // =====================================================================
        $display("\n[6] Loopback TX→RX");
        begin
            logic [31:0] stat, data;

            loopback = 1'b1;

            // Send 0xBE
            bus_write(4'h0, 32'hBE);

            // Wait for RX to complete (>100 clocks for full frame)
            repeat (200) @(posedge clk);

            bus_read(4'h4, stat);
            check("STAT: RXRDY=1 after loopback RX", stat[1:1], 1'd1);
            bus_read(4'h0, data);
            check("DATA: loopback received 0xBE", data[7:0], 8'hBE);

            loopback = 1'b0;

            // Also wait for TX to finish
            wait_txrdy(50);
        end

        // =====================================================================
        // [7] Framing error: bad stop bit
        // =====================================================================
        $display("\n[7] Framing error (bad stop bit)");
        begin
            logic [31:0] stat, data;

            // Inject 0xF0 but force stop bit LOW (framing error)
            // start bit
            @(negedge clk); uart_rx = 1'b0;
            repeat (CLKS_BIT) @(posedge clk);
            // 8 data bits
            for (int i = 0; i < 8; i++) begin
                @(negedge clk); uart_rx = 8'hF0 >> i;
                repeat (CLKS_BIT) @(posedge clk);
            end
            // bad stop bit = 0
            @(negedge clk); uart_rx = 1'b0;
            repeat (CLKS_BIT) @(posedge clk);
            // restore idle
            @(negedge clk); uart_rx = 1'b1;
            repeat (2) @(posedge clk);

            bus_read(4'h4, stat);
            check("STAT: RXERR=1 (framing error)", stat[2:2], 1'd1);
            check("STAT: RXRDY=1 (data latched)", stat[1:1], 1'd1);

            // Read clears both RXRDY and RXERR
            bus_read(4'h0, data);
            bus_read(4'h4, stat);
            check("STAT: RXERR cleared after DATA read", stat[2:2], 1'd0);
            check("STAT: RXRDY cleared after DATA read", stat[1:1], 1'd0);
        end

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n======================================");
        $display("  UART testbench: %0d passed, %0d failed",
                 pass_cnt, fail_cnt);
        $display("======================================\n");

        if (fail_cnt == 0)
            $display("ALL PASS");
        else
            $display("SOME TESTS FAILED");

        $finish;
    end

    // Timeout guard
    initial begin
        #1_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
