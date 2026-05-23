// =============================================================================
// syscalls.c - newlib システムコールスタブ for rv_soc
// =============================================================================
// newlib の printf / scanf / malloc がそのまま使えるように
// UART を _write / _read にマップする。
//
// UART レジスタマップ (rv_uart.sv):
//   0xC001_0000  DATA : TX書き込み / RX読み出し (8-bit)
//   0xC001_0004  STAT : [0]=TXRDY, [1]=RXRDY (read-only)
//   0xC001_0008  CTRL : [0]=TXEN, [1]=RXEN, [2]=TXIE, [3]=RXIE
//   0xC001_000C  DIV  : クロック分周比 (baud divisor)
//
// Author: Naofumi Yoshinaga
// =============================================================================

#include <sys/stat.h>
#include <sys/types.h>
#include <stdint.h>
#include <errno.h>

// ============================================================
// UART 周辺機器レジスタ
// ============================================================
#define UART_BASE   (0xC0010000UL)

static inline volatile uint32_t* uart_reg(uint32_t offset) {
    return (volatile uint32_t*)(UART_BASE + offset);
}

#define UART_DATA   (*uart_reg(0x00))
#define UART_STAT   (*uart_reg(0x04))
#define UART_CTRL   (*uart_reg(0x08))
#define UART_DIV    (*uart_reg(0x0C))

#define UART_TXRDY  (1u << 0)
#define UART_RXRDY  (1u << 1)
#define UART_TXEN   (1u << 0)
#define UART_RXEN   (1u << 1)

// ============================================================
// ヒープ管理
// ============================================================
extern char _bss_end[];     // リンカスクリプトで定義 (BSS 末尾)

static char *_heap_ptr = 0;

void *_sbrk(ptrdiff_t incr) {
    extern char _stack_top[];   // リンカスクリプトで定義 (スタックトップ)
    if (_heap_ptr == 0)
        _heap_ptr = _bss_end;
    char *prev = _heap_ptr;
    if ((_heap_ptr + incr) > _stack_top) {
        errno = ENOMEM;
        return (void*)-1;
    }
    _heap_ptr += incr;
    return (void*)prev;
}

// ============================================================
// _write: UART TX 出力 (printf → UART)
// ============================================================
int _write(int fd, const char *buf, int len) {
    (void)fd;

    // 初回呼び出し時に UART を有効化
    static int uart_ready = 0;
    if (!uart_ready) {
        UART_CTRL = UART_TXEN | UART_RXEN;
        uart_ready = 1;
    }

    for (int i = 0; i < len; i++) {
        // TX 完了待ち (TXRDY = 1 になるまでポーリング)
        while (!(UART_STAT & UART_TXRDY));
        UART_DATA = (uint32_t)(unsigned char)buf[i];
    }
    return len;
}

// ============================================================
// _read: UART RX 入力 (scanf / getchar → UART)
// ============================================================
int _read(int fd, char *buf, int len) {
    (void)fd;

    for (int i = 0; i < len; i++) {
        // RX データ待ち (RXRDY = 1 になるまでポーリング)
        while (!(UART_STAT & UART_RXRDY));
        buf[i] = (char)(UART_DATA & 0xFF);   // 読み出しで RXRDY クリア

        // エコーバック + CR→CRLF 変換
        if (buf[i] == '\r') {
            buf[i] = '\n';
            _write(fd, "\r\n", 2);
            return i + 1;           // 行単位で返す
        }
        _write(fd, &buf[i], 1);     // 入力文字をエコー
    }
    return len;
}

// ============================================================
// 最低限必要な newlib スタブ
// ============================================================
int _close(int fd) {
    (void)fd;
    return -1;
}

int _fstat(int fd, struct stat *st) {
    (void)fd;
    st->st_mode = S_IFCHR;  // キャラクタデバイスとして振る舞う
    return 0;
}

int _isatty(int fd) {
    (void)fd;
    return 1;   // TTY として認識させる → stdout が行バッファになる
}

int _lseek(int fd, int offset, int whence) {
    (void)fd; (void)offset; (void)whence;
    return -1;
}

int _getpid(void) {
    return 1;
}

int _kill(int pid, int sig) {
    (void)pid; (void)sig;
    errno = EINVAL;
    return -1;
}

void _exit(int code) {
    (void)code;
    // ベアメタルではプロセス終了 = 無限ループ
    extern void _halt(void);
    _halt();
    __builtin_unreachable();
}
