// =============================================================================
// minpoll_pad_hw.S - minpoll + NOP padding in the poll loop.
// =============================================================================
// Same bare THRE-poll-and-send 'U' stream as minpoll_hw, but with several NOPs
// inserted INSIDE the poll loop so consecutive peripheral reads are spaced apart
// (and the backward branch fires less often per peripheral read).  This tests
// whether breaking the *tight* spacing of the peripheral LOADs / redirects fixes
// the hang (uartpoll/storeseq, which had DDR stores spacing things out, did NOT
// hang):
//   minpoll hangs but minpoll_pad streams -> the trigger is the TIGHT spacing of
//        back-to-back peripheral reads / redirects (points the RTL fix at the
//        peripheral-read vs pipeline-redirect timing)
//   both hang the same way -> spacing is irrelevant; trigger is the peripheral
//        read itself in a poll
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
    nop                            // padding: space out the reads / redirect
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    andi t1, t1, 0x20
    beqz t1, 99b
    li   t0, THR
    sw   a1, 0(t0)                 // send 'U'
    j    loop
