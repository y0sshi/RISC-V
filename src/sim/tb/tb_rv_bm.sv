// =============================================================================
// tb_rv_bm.sv - ベアメタル C プログラム実行テストベンチ
// =============================================================================
// 用途: crt0.S + rv_soc.ld でビルドした C プログラムを実行し
//       UART 出力をデコードして表示する。
//
// 機能:
//   - IMEM_FILE: 命令 hex (.text)
//   - DMEM_FILE: データ hex (.rodata + .data)
//   - UART TX モニター: ビット列をデコードして $write で文字出力
//   - UART RX ドライバー: uart_rx に文字列を注入可能
//   - タイムアウト後に自動終了
//
// UART 速度: CLK_FREQ=10 MHz, BAUD_RATE=1 MHz → 10 cycles/bit
//
// Author: Naofumi Yoshinaga
// =============================================================================

`timescale 1ns / 1ps

module tb_rv_bm;

    // =========================================================================
    // パラメータ (iverilog -P フラグで上書き可能)
    // =========================================================================
    parameter  IMEM_FILE = "";        // -PIMEM_FILE=\"path/to/imem.hex\"
    parameter  DMEM_FILE = "";        // -PDMEM_FILE=\"path/to/dmem.hex\"

    localparam int CLK_PERIOD   = 10;           // 10 ns
    localparam int CLK_FREQ_TB  = 10_000_000;   // 10 cycles/bit @ BAUD=1Mbps
    localparam int BAUD_RATE_TB = 1_000_000;
    localparam int BIT_CYCLES   = CLK_FREQ_TB / BAUD_RATE_TB;  // = 10
    localparam int TIMEOUT      = 200_000;      // 全体タイムアウト [cycles]

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
    // クロック
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // VCD ダンプ
    // =========================================================================
    initial begin
        $dumpfile("wave/tb_rv_bm.vcd");
        $dumpvars(0, tb_rv_bm);
    end

    // =========================================================================
    // UART TX モニター (バックグラウンド)
    // uart_tx のビット列をデコードして文字を $write 出力
    // =========================================================================
    logic [7:0] rx_byte;
    int         rx_char_cnt;

    initial begin
        rx_char_cnt = 0;
        $display("\n=== UART Output ===");
        forever begin
            // スタートビット待ち (HIGH → LOW)
            @(negedge uart_tx);
            // 0.5 bit 待って中央でサンプリング
            repeat(BIT_CYCLES / 2) @(posedge clk);
            // 8 データビット (LSB first)
            for (int i = 0; i < 8; i++) begin
                repeat(BIT_CYCLES) @(posedge clk);
                rx_byte[i] = uart_tx;
            end
            // ストップビット
            repeat(BIT_CYCLES) @(posedge clk);

            // デコード表示
            rx_char_cnt++;
            if (rx_byte >= 8'h20 && rx_byte < 8'h7F)
                $write("%c", rx_byte);
            else if (rx_byte == 8'h0A)
                $write("\n");
            else if (rx_byte == 8'h0D)
                ;
            else
                $write("[0x%02h]", rx_byte);
        end
    end

    // =========================================================================
    // UART RX ドライバー (必要に応じてコメント解除)
    // =========================================================================
    task automatic uart_rx_send_byte(input logic [7:0] data);
        uart_rx = 1'b0;                         // スタートビット
        repeat(BIT_CYCLES) @(posedge clk);
        for (int i = 0; i < 8; i++) begin       // データビット
            uart_rx = data[i];
            repeat(BIT_CYCLES) @(posedge clk);
        end
        uart_rx = 1'b1;                         // ストップビット
        repeat(BIT_CYCLES) @(posedge clk);
    endtask

    task automatic uart_rx_send_str(input string s);
        for (int i = 0; i < s.len(); i++)
            uart_rx_send_byte(s[i]);
    endtask

    // =========================================================================
    // リセット + 起動
    // =========================================================================
    int cycle_cnt;

    initial begin
        gpio_in = 4'h0;
        uart_rx = 1'b1;     // UART idle
        rst_n   = 1'b0;
        repeat(4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---- プログラム実行 → UART 出力を待つ ----
        // [DEBUG] 定期的なステータス表示
        for (cycle_cnt = 0; cycle_cnt < TIMEOUT; cycle_cnt++) begin
            @(posedge clk);
            if (cycle_cnt == 199)
                $display("[DBG] @200 cycles: uart_tx=%b, uart_rx=%b", uart_tx, uart_rx);
            if (cycle_cnt == 999)
                $display("[DBG] @1000 cycles: uart_tx=%b", uart_tx);
            if (cycle_cnt == 9999)
                $display("[DBG] @10000 cycles: uart_tx=%b, chars=%0d", uart_tx, rx_char_cnt);
            if (cycle_cnt == 99999)
                $display("[DBG] @100000 cycles: uart_tx=%b, chars=%0d", uart_tx, rx_char_cnt);
        end

        $display("\n=== End of simulation (%0d cycles, %0d chars) ===",
                 TIMEOUT, rx_char_cnt);
        $finish;
    end

    // =========================================================================
    // GPIO 変化モニター (オプション: デバッグ用)
    // =========================================================================
    always @(gpio_out) begin
        if (rst_n)
            $display("[GPIO] gpio_out changed to 0x%0h at t=%0t", gpio_out, $time);
    end

    // =========================================================================
    // Trap / MRET monitor (keep for future debugging)
    // =========================================================================
    always @(posedge clk) begin
        if (rst_n && dut.u_cpu.u_core.ex_trap_enter) begin
            $display("[TRAP]  @%0t: trap! pc=%08h  cause=%016h  mtvec=%016h",
                     $time,
                     dut.u_cpu.u_core.id_ex_pc,
                     dut.u_cpu.u_core.ex_trap_cause,
                     dut.u_cpu.u_core.trap_vector);
        end
        if (rst_n && dut.u_cpu.u_core.ex_mret_en) begin
            $display("[MRET]  @%0t: mret! mepc=%016h",
                     $time,
                     dut.u_cpu.u_core.mepc_out);
        end
    end

endmodule
