// =============================================================================
// tb_rv_soc.sv - SoC Integration Testbench
// =============================================================================
// 用途①: 統合テスト (test_soc_integ.hex)
//   - GPIO_OUT の変化を確認
//   - UART TX スタートビット確認
//
// 用途②: C ベアメタルプログラムの UART 出力モニター
//   - uart_tx を監視してビット列をデコード → $display で文字出力
//   - 任意の IMEM_FILE / DMEM_FILE を指定して実行
//
// UART 速度: CLK_FREQ=10 MHz, BAUD_RATE=1 MHz → 10 cycles/bit
//
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_soc;

    // =========================================================================
    // Parameters (iverilog -P フラグで上書き可能)
    // =========================================================================
    parameter  IMEM_FILE   = "tests/test_soc_integ.hex";
    parameter  DMEM_FILE   = "";      // C プログラム用 DMEM 初期化 hex

    localparam int CLK_PERIOD   = 10;         // 10 ns → 100 MHz sim clock
    localparam int CLK_FREQ_TB  = 10_000_000; // 10 cycles/bit @ BAUD=1MHz
    localparam int BAUD_RATE_TB = 1_000_000;
    localparam int BIT_CYCLES   = CLK_FREQ_TB / BAUD_RATE_TB; // = 10
    localparam int TIMEOUT      = 100_000;    // 全体タイムアウト [cycles]

    // =========================================================================
    // DUT 信号
    // =========================================================================
    logic       clk;
    logic       rst_n;
    logic [3:0] gpio_in;
    logic [3:0] gpio_out;
    logic       uart_rx;
    logic       uart_tx;

    // =========================================================================
    // DUT インスタンス
    // =========================================================================
    rv_soc_bram #(
        .CLK_FREQ  (CLK_FREQ_TB),
        .BAUD_RATE (BAUD_RATE_TB),
        .IMEM_FILE (IMEM_FILE),
        .DMEM_FILE (DMEM_FILE)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .gpio_in  (gpio_in),
        .gpio_out (gpio_out),
        .uart_rx  (uart_rx),
        .uart_tx  (uart_tx)
    );

    // =========================================================================
    // クロック (10 ns 周期)
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // VCD ダンプ
    // =========================================================================
    initial begin
        $dumpfile("wave/tb_rv_soc.vcd");
        $dumpvars(0, tb_rv_soc);
    end

    // =========================================================================
    // UART TX モニター (バックグラウンド動作)
    // uart_tx を監視してビット列をデコードし $write で文字出力
    // =========================================================================
    logic [7:0] uart_rx_byte;
    int         uart_rx_char_cnt;

    initial begin
        uart_rx_char_cnt = 0;
        forever begin
            // --- スタートビット待ち (HIGH → LOW エッジ) ---
            @(negedge uart_tx);

            // --- スタートビット中央まで 0.5bit 待機 ---
            repeat(BIT_CYCLES / 2) @(posedge clk);

            // --- 8 データビットをサンプリング (LSB first) ---
            for (int i = 0; i < 8; i++) begin
                repeat(BIT_CYCLES) @(posedge clk);
                uart_rx_byte[i] = uart_tx;
            end

            // --- ストップビット待ち ---
            repeat(BIT_CYCLES) @(posedge clk);

            // --- デコード結果を表示 ---
            uart_rx_char_cnt++;
            if (uart_rx_byte >= 8'h20 && uart_rx_byte < 8'h7F)
                $write("%c", uart_rx_byte);          // 印字可能文字
            else if (uart_rx_byte == 8'h0A)
                $write("\n");                         // LF
            else if (uart_rx_byte == 8'h0D)
                ;                                     // CR は無視
            else
                $write("[0x%02h]", uart_rx_byte);    // 制御文字
        end
    end

    // =========================================================================
    // 統合テスト (test_soc_integ.hex 用)
    // =========================================================================
    int pass_cnt;
    int fail_cnt;
    int wait_cnt;

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;

        gpio_in = 4'h0;
        uart_rx = 1'b1;   // UART idle (mark)
        rst_n   = 1'b0;
        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // -----------------------------------------------
        $display("[1] GPIO_OUT = 0xA");
        // -----------------------------------------------
        wait_cnt = 0;
        while (gpio_out !== 4'hA && wait_cnt < TIMEOUT) begin
            @(posedge clk); wait_cnt++;
        end
        if (gpio_out === 4'hA) begin
            $display("  PASS  gpio_out=0xA  (%0d cycles)", wait_cnt);
            pass_cnt++;
        end else begin
            $display("  FAIL  gpio_out=0x%0h (expect 0xA, timeout)", gpio_out);
            fail_cnt++;
        end

        // -----------------------------------------------
        $display("[2] GPIO_OUT = 0x5");
        // -----------------------------------------------
        wait_cnt = 0;
        while (gpio_out !== 4'h5 && wait_cnt < TIMEOUT) begin
            @(posedge clk); wait_cnt++;
        end
        if (gpio_out === 4'h5) begin
            $display("  PASS  gpio_out=0x5  (%0d cycles)", wait_cnt);
            pass_cnt++;
        end else begin
            $display("  FAIL  gpio_out=0x%0h (expect 0x5, timeout)", gpio_out);
            fail_cnt++;
        end

        // -----------------------------------------------
        $display("[3] UART TX start bit");
        // -----------------------------------------------
        wait_cnt = 0;
        while (uart_tx !== 1'b0 && wait_cnt < TIMEOUT) begin
            @(posedge clk); wait_cnt++;
        end
        if (uart_tx === 1'b0) begin
            $display("  PASS  uart_tx=0 (start bit, %0d cycles)", wait_cnt);
            pass_cnt++;
        end else begin
            $display("  FAIL  uart_tx still HIGH (timeout)");
            fail_cnt++;
        end

        // -----------------------------------------------
        // C プログラムの UART 出力を受け取る場合は
        // 出力が完了するまで待機する
        // (test_soc_integ.hex は 1 文字だけなので短時間で完了)
        // -----------------------------------------------
        repeat(500) @(posedge clk);

        $display("\n==============================");
        $display("  SoC integration: %0d PASS, %0d FAIL", pass_cnt, fail_cnt);
        $display("  UART decoded chars: %0d", uart_rx_char_cnt);
        $display("==============================");
        if (fail_cnt == 0) $display("ALL PASS");
        else               $display("FAILED %0d test(s)", fail_cnt);
        $finish;
    end

    // =========================================================================
    // グローバルタイムアウト
    // =========================================================================
    initial begin
        #(CLK_PERIOD * TIMEOUT);
        $display("GLOBAL TIMEOUT (%0d cycles)", TIMEOUT);
        $finish;
    end

endmodule
