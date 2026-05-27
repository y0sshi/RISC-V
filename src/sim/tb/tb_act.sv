`timescale 1ns/1ps

module tb_act;
    logic clk = 0;
    logic rst_n = 0;

    always #5 clk = ~clk; // 100MHz

    // ユニファイドメモリ (256KB = 32K entry * 64bit)
    logic [63:0] mem [0:32767];

    // tohostアドレス
    localparam TOHOST_ADDR = 64'h8000_1000;
    localparam MEM_BASE    = 64'h8000_0000;

    // メモリインターフェース (rv_core信号に合わせて調整)
    logic [63:0] imem_addr, imem_rdata;
    logic [63:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic        dmem_we;
    logic [7:0]  dmem_be;

    // メモリアクセス (簡易実装)
    always_ff @(posedge clk) begin
        // 命令フェッチ
        imem_rdata <= mem[(imem_addr - MEM_BASE) >> 3];

        // データR/W
        if (dmem_we) begin
            mem[(dmem_addr - MEM_BASE) >> 3] <= dmem_wdata;

            // tohost監視
            if (dmem_addr == TOHOST_ADDR) begin
                if (dmem_wdata == 64'd1) begin
                    $display("PASS");
                end else begin
                    $display("FAIL: code=%0d", dmem_wdata >> 1);
                end
                // シグネチャダンプ
                dump_signature();
                $finish;
            end
        end else begin
            dmem_rdata <= mem[(dmem_addr - MEM_BASE) >> 3];
        end
    end

    // シグネチャ領域ダンプ
    task dump_signature;
        integer fd, i;
        longint begin_sig, end_sig;
        begin
            // ELFのシンボル位置はリンカで決まる。
            // ここでは固定アドレス or プラスアルファで決め打ち
            // 実装簡易化のため、専用領域を全dump
            fd = $fopen(`SIG_FILE, "w");
            // begin_signature/end_signatureはhex内のシンボルから取得困難
            // -> Makefile側でobjdumpしてアドレス抽出する方式が確実
            for (i = 0; i < 1024; i = i + 1) begin
                $fwrite(fd, "%08x\n", mem[i + (begin_sig >> 3)][31:0]);
                $fwrite(fd, "%08x\n", mem[i + (begin_sig >> 3)][63:32]);
            end
            $fclose(fd);
        end
    endtask

    // メモリ初期化
    initial begin
        $readmemh(`HEX_FILE, mem);
        rst_n = 0;
        repeat(10) @(posedge clk);
        rst_n = 1;
    end

    // タイムアウト
    initial begin
        #1_000_000;
        $display("TIMEOUT");
        $finish;
    end

    // DUTインスタンス (rv_coreの信号に合わせて配線)
    rv_core dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .imem_addr  (imem_addr),
        .imem_rdata (imem_rdata),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_rdata (dmem_rdata),
        .dmem_we    (dmem_we),
        .dmem_be    (dmem_be)
    );
endmodule

