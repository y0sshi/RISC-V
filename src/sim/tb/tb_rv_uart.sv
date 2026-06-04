// =============================================================================
// tb_rv_uart.sv - Testbench for rv_uart (NS16550-compatible)
// =============================================================================
// CLK_FREQ=160, BAUD_RATE=10 -> default divisor = 160/(16*10) = 1
//   -> bit period = 16 * divisor = 16 clocks/bit (16x oversampling).
// 1 frame = 1(start)+8(data)+1(stop) = 10 bits = 160 clocks.
//
// Register map (reg-shift=2): THR/RBR@0x00, IER@0x04, IIR/FCR@0x08, LCR@0x0C,
//   MCR@0x10, LSR@0x14, MSR@0x18, SCR@0x1C.  LSR: DR[0] FE[3] THRE[5] TEMT[6].
//
// Tests: reset/SCR, TX bit-verify, divisor latch RW, RX, loopback, framing error.
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_uart;

    localparam int CLK_FREQ  = 160;
    localparam int BAUD_RATE = 10;
    localparam int CLKS_BIT  = 16;   // 16 * default divisor(=1)

    logic        clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [4:0]  addr;
    logic        req, we;
    logic [31:0] wdata, rdata;
    logic        uart_tx;
    logic        uart_rx = 1'b1;
    logic        tx_irq, rx_irq;
    logic        loopback = 1'b0;

    rv_uart #(.CLK_FREQ (CLK_FREQ), .BAUD_RATE (BAUD_RATE)) dut (
        .clk (clk), .rst_n (rst_n),
        .addr (addr), .req (req), .we (we), .wdata (wdata), .rdata (rdata),
        .uart_tx (uart_tx), .uart_rx (loopback ? uart_tx : uart_rx),
        .tx_irq (tx_irq), .rx_irq (rx_irq)
    );

    // register byte offsets
    localparam THR=5'h00, IER=5'h04, FCR=5'h08, LCR=5'h0C,
               MCR=5'h10, LSR=5'h14, MSR=5'h18, SCR=5'h1C;

    int pass_cnt = 0, fail_cnt = 0;

    task automatic bus_write(input [4:0] a, input [31:0] d);
        @(negedge clk); addr=a; req=1; we=1; wdata=d;
        @(negedge clk); req=0; we=0;
    endtask
    task automatic bus_read(input [4:0] a, output [31:0] d);
        // Sample the combinational rdata DURING the access cycle (before the
        // posedge), matching how rv_periph registers it -- otherwise a register
        // with a read-clear side effect (LSR.FE, RBR->DR) is read post-clear.
        @(negedge clk); addr=a; req=1; we=0; wdata=0;
        #1; d = rdata;
        @(posedge clk);
        @(negedge clk); req=0;
    endtask
    task automatic check(input string name, input [31:0] got, input [31:0] exp);
        if (got === exp) begin $display("  PASS  %-40s got=0x%08h", name, got); pass_cnt++; end
        else begin $display("  FAIL  %-40s got=0x%08h exp=0x%08h", name, got, exp); fail_cnt++; end
    endtask
    task automatic wait_thre(input int timeout_clks);
        automatic int cnt=0; automatic logic [31:0] s; automatic logic done=0;
        while (!done) begin
            bus_read(LSR, s); cnt++;
            if (s[5]) done=1;
            else if (cnt>timeout_clks) begin $display("  FAIL wait_thre timeout"); fail_cnt++; done=1; end
        end
    endtask
    task automatic rx_inject(input [7:0] data);
        @(negedge clk); uart_rx=0;                       // start
        repeat (CLKS_BIT) @(posedge clk);
        for (int i=0;i<8;i++) begin @(negedge clk); uart_rx=data[i]; repeat (CLKS_BIT) @(posedge clk); end
        @(negedge clk); uart_rx=1;                       // stop
        repeat (CLKS_BIT) @(posedge clk);
    endtask

    initial begin
        $dumpfile("wave/tb_rv_uart.vcd"); $dumpvars(0, tb_rv_uart);
        addr=0; req=0; we=0; wdata=0;
        repeat (4) @(negedge clk); rst_n=1; @(negedge clk);

        // [1] Reset state
        $display("\n[1] Reset state / scratch");
        begin
            logic [31:0] s;
            bus_read(LSR, s); check("LSR = THRE|TEMT (0x60)", s, 32'h0000_0060);
            bus_read(LCR, s); check("LCR = 0", s, 32'd0);
            bus_write(SCR, 32'hA5); bus_read(SCR, s); check("SCR scratch RW", s, 32'h0000_00A5);
        end

        // [2] TX 0x55 bit-verify
        $display("\n[2] TX 0x55 bit-verify");
        begin
            @(negedge clk); check("TX idle high", {31'd0,uart_tx}, 32'd1);
            bus_write(THR, 32'h55);
            repeat (2) @(posedge clk);
            check("start bit low", {31'd0,uart_tx}, 32'd0);
            repeat (CLKS_BIT) @(posedge clk); check("bit0=1", {31'd0,uart_tx}, 32'd1);
            repeat (CLKS_BIT) @(posedge clk); check("bit1=0", {31'd0,uart_tx}, 32'd0);
            repeat (CLKS_BIT) @(posedge clk); check("bit2=1", {31'd0,uart_tx}, 32'd1);
            repeat (CLKS_BIT) @(posedge clk); check("bit3=0", {31'd0,uart_tx}, 32'd0);
            repeat (CLKS_BIT) @(posedge clk); check("bit4=1", {31'd0,uart_tx}, 32'd1);
            repeat (CLKS_BIT) @(posedge clk); check("bit5=0", {31'd0,uart_tx}, 32'd0);
            repeat (CLKS_BIT) @(posedge clk); check("bit6=1", {31'd0,uart_tx}, 32'd1);
            repeat (CLKS_BIT) @(posedge clk); check("bit7=0", {31'd0,uart_tx}, 32'd0);
            repeat (CLKS_BIT) @(posedge clk); check("stop=1",  {31'd0,uart_tx}, 32'd1);
            wait_thre(400);
        end

        // [3] Divisor latch read/write (DLAB), then restore
        $display("\n[3] Divisor latch (DLAB)");
        begin
            logic [31:0] s;
            bus_write(LCR, 32'h80);            // DLAB=1
            bus_write(THR, 32'h02);            // DLL=2
            bus_write(IER, 32'h00);            // DLM=0
            bus_read(THR, s); check("DLL readback=2", s, 32'd2);
            bus_read(IER, s); check("DLM readback=0", s, 32'd0);
            bus_write(THR, 32'h01);            // restore DLL=1
            bus_write(LCR, 32'h00);            // DLAB=0
        end

        // [4] RX 0xA5
        $display("\n[4] RX 0xA5");
        begin
            logic [31:0] s, d;
            rx_inject(8'hA5);
            repeat (2) @(posedge clk);
            bus_read(LSR, s); check("LSR.DR=1", {31'd0,s[0]}, 32'd1);
            check("LSR.FE=0", {31'd0,s[3]}, 32'd0);
            bus_read(THR, d); check("RBR = 0xA5", d[7:0], 8'hA5);   // read RBR
            bus_read(LSR, s); check("LSR.DR=0 after read", {31'd0,s[0]}, 32'd0);
        end

        // [5] Loopback TX->RX
        $display("\n[5] Loopback");
        begin
            logic [31:0] s, d;
            loopback = 1;
            bus_write(THR, 32'hBE);
            repeat (CLKS_BIT*12) @(posedge clk);
            bus_read(LSR, s); check("LSR.DR=1 (loopback)", {31'd0,s[0]}, 32'd1);
            bus_read(THR, d); check("RBR = 0xBE", d[7:0], 8'hBE);
            loopback = 0;
            wait_thre(100);
        end

        // [6] Framing error
        $display("\n[6] Framing error (bad stop)");
        begin
            logic [31:0] s, d;
            @(negedge clk); uart_rx=0; repeat (CLKS_BIT) @(posedge clk);   // start
            for (int i=0;i<8;i++) begin @(negedge clk); uart_rx=(8'hF0>>i); repeat (CLKS_BIT) @(posedge clk); end
            @(negedge clk); uart_rx=0; repeat (CLKS_BIT) @(posedge clk);   // bad stop
            @(negedge clk); uart_rx=1; repeat (2) @(posedge clk);
            bus_read(LSR, s); check("LSR.FE=1", {31'd0,s[3]}, 32'd1);
            check("LSR.DR=1", {31'd0,s[0]}, 32'd1);
            bus_read(THR, d);                          // read RBR (clears DR)
            bus_read(LSR, s); check("LSR.FE cleared after LSR read", {31'd0,s[3]}, 32'd0);
        end

        $display("\n======================================");
        $display("  UART (16550) testbench: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("======================================");
        if (fail_cnt == 0) $display("ALL PASS"); else $display("SOME TESTS FAILED");
        $finish;
    end

    initial begin #2_000_000; $display("TIMEOUT"); $finish; end

endmodule
