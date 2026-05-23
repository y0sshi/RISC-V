// =============================================================================
// hello/main.c - rv_soc ベアメタル Hello World デモ
// =============================================================================
// 動作確認:
//   1. uart_printf  → UART TX → テストベンチ(モニター)で文字列受信・表示
//   2. 整数演算 (ループ・加算・乗算)
//   3. グローバル変数 (.data / .bss セクション)
//   4. 文字列リテラル (.rodata → DMEM)
// =============================================================================

#include "../startup/uart.h"

// =============================================================
// グローバル変数テスト
// =============================================================
static int      g_counter  = 42;       // .data (初期値あり)
static int      g_sum      = 0;        // .bss  (ゼロ初期化)
static const char g_banner[] =         // .rodata
    "==============================\r\n";

// =============================================================
// 簡単なフィボナッチ (ループ版)
// =============================================================
static int fibonacci(int n) {
    int a = 0, b = 1;
    for (int i = 0; i < n; i++) {
        int tmp = a + b;
        a = b;
        b = tmp;
    }
    return a;
}

// =============================================================
// main
// =============================================================
int main(void) {
    uart_init();

    // --- バナー ---
    uart_puts(g_banner);
    uart_printf("  rv_soc bare-metal Hello World\n");
    uart_printf("  RV32IM  |  IMEM=16KB  |  DMEM=16KB\n");
    uart_puts(g_banner);

    // --- グローバル変数 (.data) の確認 ---
    uart_printf("\n[1] Global variable (.data)\n");
    uart_printf("    g_counter = %d  (expect 42)\n", g_counter);
    g_counter++;
    uart_printf("    g_counter = %d  (expect 43)\n", g_counter);

    // --- .bss のゼロ初期化確認 ---
    uart_printf("\n[2] BSS zero-init\n");
    uart_printf("    g_sum = %d  (expect 0)\n", g_sum);

    // --- ループ + 加算 ---
    uart_printf("\n[3] Sum 1..10\n");
    for (int i = 1; i <= 10; i++) g_sum += i;
    uart_printf("    sum = %d  (expect 55)\n", g_sum);

    // --- 乗算 (M拡張) ---
    uart_printf("\n[4] Multiply (M-ext)\n");
    int a = 123, b = 456;
    uart_printf("    %d * %d = %d  (expect 56088)\n", a, b, a * b);

    // --- 16進数表示 ---
    uart_printf("\n[5] Hex output\n");
    uart_printf("    UART_BASE = %p\n", (void*)0xC0010000UL);
    uart_printf("    0xDEAD    = 0x%08X\n", 0xDEAD);

    // --- フィボナッチ ---
    uart_printf("\n[6] Fibonacci\n");
    for (int i = 0; i <= 10; i++) {
        uart_printf("    fib(%2d) = %d\n", i, fibonacci(i));
    }

    uart_printf("\n");
    uart_puts(g_banner);
    uart_printf("  Done.\n");
    uart_puts(g_banner);

    return 0;
}
