// =============================================================================
// minpoll_hw.S - minimal repro: does a BARE tight THRE-poll-and-send loop hang?
// =============================================================================
// ILA showed jaltest_hw hangs in a tight THRE-poll spin (lw LSR; andi; beqz),
// not at ret.  uartblast_hw (no poll) streams forever.  This strips EVERYTHING
// (no jal/ret, no BURST, no markers, no DDR) down to the suspected trigger:
//   - a peripheral LOAD (lw LSR) in a tight loop
//   - a backward branch (beqz) every iteration
//   - NO intervening DDR/cache traffic
// and just streams 'U' forever through the standard THRE poll.
//
//   'U' streams forever                -> the bare poll is NOT the trigger;
//        jaltest needs jal/ret/footprint too (re-opens the question)
//   'U' stops after a few chars (hang) -> MINIMAL repro of the real bug,
//        independent of jal/ret -- confirms the peripheral-poll diagnosis
//
// Observation is the UART output ONLY (no DDR markers).  Run with bringup_fw.tcl
// minpoll_hw.elf, TeraTerm 57600.
//
// Link at 0x0020_0000:  -Wl,--defsym,__BASE=0x00200000  (boot.ld).
// =============================================================================

    .equ THR,  0xC0010000
    .equ DLM,  0xC0010004
    .equ FCR,  0xC0010008
    .equ LCR,  0xC001000C
    .equ LSR,  0xC0010014
    .equ DIVISOR, 27

    .section .text
    .globl _start
_start:
    li t0, LCR; li t1, 0x80; sw t1, 0(t0)
    li t0, THR; li t1, DIVISOR; sw t1, 0(t0)
    li t0, DLM; sw x0, 0(t0)
    li t0, LCR; li t1, 0x03; sw t1, 0(t0)
    li t0, FCR; li t1, 0x07; sw t1, 0(t0)

loop:
    li   a1, 'U'
99: li   t0, LSR
    lw   t1, 0(t0)                 // peripheral LOAD (THRE poll)
    andi t1, t1, 0x20
    beqz t1, 99b                  // tight backward branch every iter
    li   t0, THR
    sw   a1, 0(t0)                 // send 'U'
    j    loop
