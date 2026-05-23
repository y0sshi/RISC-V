// =============================================================================
// uart.c - rv_soc ベアメタル UART ドライバ + 軽量 printf
// =============================================================================
// newlib に依存しない小さな実装。
// サポートする書式指定子:
//   %c  : 文字
//   %s  : 文字列
//   %d  : 符号付き 10 進数
//   %u  : 符号なし 10 進数
//   %x  : 小文字 16 進数
//   %X  : 大文字 16 進数
//   %p  : ポインタ (0x プレフィックス付き 16 進数)
//   %%  : '%' リテラル
//   %08x 等の幅・ゼロ埋め指定にも対応
// =============================================================================

#include "uart.h"
#include <stdint.h>
#include <stdarg.h>

// ============================================================
// UART 初期化
// ============================================================
void uart_init(void) {
    UART_CTRL = UART_TXEN | UART_RXEN;
}

// ============================================================
// 1 文字送信
// ============================================================
void uart_putc(char c) {
    while (!(UART_STAT & UART_TXRDY));  // TX 完了待ち
    UART_DATA = (uint32_t)(unsigned char)c;
}

// ============================================================
// 文字列送信 (\r\n 変換あり)
// ============================================================
void uart_puts(const char *s) {
    while (*s) {
        if (*s == '\n') uart_putc('\r');
        uart_putc(*s++);
    }
}

// ============================================================
// 1 文字受信 (ブロッキング)
// ============================================================
char uart_getc(void) {
    while (!(UART_STAT & UART_RXRDY));
    return (char)(UART_DATA & 0xFF);
}

// ============================================================
// 内部: 数値を文字列に変換して送信
// ============================================================
static void print_uint(unsigned int val, int base, int upper,
                        int width, char pad) {
    char buf[16];
    const char *digits = upper ? "0123456789ABCDEF"
                                : "0123456789abcdef";
    int i = 0;

    if (val == 0) {
        buf[i++] = '0';
    } else {
        while (val > 0) {
            buf[i++] = digits[val % base];
            val /= base;
        }
    }

    // ゼロ/スペース埋め
    while (i < width) buf[i++] = pad;

    // 逆順で送信
    while (i > 0) uart_putc(buf[--i]);
}

static void print_int(int val, int width, char pad) {
    if (val < 0) {
        uart_putc('-');
        val = -val;
        if (width > 0) width--;
    }
    print_uint((unsigned int)val, 10, 0, width, pad);
}

// ============================================================
// uart_printf: 軽量 printf 実装
// ============================================================
int uart_printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);

    int count = 0;

    while (*fmt) {
        if (*fmt != '%') {
            if (*fmt == '\n') uart_putc('\r');
            uart_putc(*fmt++);
            count++;
            continue;
        }
        fmt++;  // '%' をスキップ

        // --- フィールド幅・ゼロ埋め解析 ---
        char pad = ' ';
        int  width = 0;

        if (*fmt == '0') { pad = '0'; fmt++; }
        while (*fmt >= '0' && *fmt <= '9') {
            width = width * 10 + (*fmt - '0');
            fmt++;
        }

        // --- 書式指定子 ---
        switch (*fmt) {
        case 'c': {
            uart_putc((char)va_arg(ap, int));
            count++;
            break;
        }
        case 's': {
            const char *s = va_arg(ap, const char*);
            if (!s) s = "(null)";
            while (*s) {
                if (*s == '\n') uart_putc('\r');
                uart_putc(*s++);
                count++;
            }
            break;
        }
        case 'd': {
            int v = va_arg(ap, int);
            print_int(v, width, pad);
            count++;
            break;
        }
        case 'u': {
            unsigned int v = va_arg(ap, unsigned int);
            print_uint(v, 10, 0, width, pad);
            count++;
            break;
        }
        case 'x': {
            unsigned int v = va_arg(ap, unsigned int);
            print_uint(v, 16, 0, width, pad);
            count++;
            break;
        }
        case 'X': {
            unsigned int v = va_arg(ap, unsigned int);
            print_uint(v, 16, 1, width, pad);
            count++;
            break;
        }
        case 'p': {
            unsigned int v = (unsigned int)(uintptr_t)va_arg(ap, void*);
            uart_puts("0x");
            print_uint(v, 16, 0, 8, '0');
            count++;
            break;
        }
        case '%': {
            uart_putc('%');
            count++;
            break;
        }
        default:
            uart_putc('%');
            uart_putc(*fmt);
            count += 2;
            break;
        }
        fmt++;
    }

    va_end(ap);
    return count;
}
