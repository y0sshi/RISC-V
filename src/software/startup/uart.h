// =============================================================================
// uart.h - rv_soc ベアメタル UART ドライバ
// =============================================================================
#ifndef UART_H
#define UART_H

#include <stdint.h>
#include <stdarg.h>

// UART レジスタマップ (rv_uart.sv: NS16550 互換, reg-shift=2 / 4-byte 間隔)
#define UART_BASE    (0xC0010000UL)
#define UART_THR     (*(volatile uint32_t*)(UART_BASE + 0x00))  // write: TX holding
#define UART_RBR     (*(volatile uint32_t*)(UART_BASE + 0x00))  // read : RX buffer
#define UART_IER     (*(volatile uint32_t*)(UART_BASE + 0x04))
#define UART_FCR     (*(volatile uint32_t*)(UART_BASE + 0x08))  // write: FIFO ctrl
#define UART_LCR     (*(volatile uint32_t*)(UART_BASE + 0x0C))
#define UART_MCR     (*(volatile uint32_t*)(UART_BASE + 0x10))
#define UART_LSR     (*(volatile uint32_t*)(UART_BASE + 0x14))

#define LSR_DR       (1u << 0)   // RX data ready
#define LSR_THRE     (1u << 5)   // TX holding register empty
#define LCR_8N1      (0x03u)     // 8 data bits, no parity, 1 stop
#define FCR_ENABLE   (0x07u)     // enable + clear RX/TX FIFOs
#define MCR_DTR_RTS  (0x03u)

// 関数プロトタイプ
void uart_init(void);
void uart_putc(char c);
void uart_puts(const char *s);
char uart_getc(void);
int  uart_printf(const char *fmt, ...);

#endif // UART_H
