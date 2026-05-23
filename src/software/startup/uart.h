// =============================================================================
// uart.h - rv_soc ベアメタル UART ドライバ
// =============================================================================
#ifndef UART_H
#define UART_H

#include <stdint.h>
#include <stdarg.h>

// UART レジスタマップ (rv_uart.sv)
#define UART_BASE    (0xC0010000UL)
#define UART_DATA    (*(volatile uint32_t*)(UART_BASE + 0x00))
#define UART_STAT    (*(volatile uint32_t*)(UART_BASE + 0x04))
#define UART_CTRL    (*(volatile uint32_t*)(UART_BASE + 0x08))
#define UART_DIV     (*(volatile uint32_t*)(UART_BASE + 0x0C))

#define UART_TXRDY   (1u << 0)
#define UART_RXRDY   (1u << 1)
#define UART_TXEN    (1u << 0)
#define UART_RXEN    (1u << 1)

// 関数プロトタイプ
void uart_init(void);
void uart_putc(char c);
void uart_puts(const char *s);
char uart_getc(void);
int  uart_printf(const char *fmt, ...);

#endif // UART_H
