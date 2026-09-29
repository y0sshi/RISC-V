# =============================================================================
# jaltest_hw.S - does a `jal` into a cold I$ line (+ `ret`) fetch correctly?
# =============================================================================
# Pattern from the bring-up tests: programs WITHOUT jal/ret run; programs WITH a
# jal to a far (cold) cache line go silent.  Hypothesis: the I$ line-fill at a
# control-flow REDIRECT target returns garbage on real HW (sequential fills and
# short backward jumps to already-filled lines are fine).  That would kill OpenSBI
# (full of calls) while the tiny inline tests pass.
#
# All prints use the inline PUTC (no call) so the ONLY jal/ret under test is the
# one to sub_b.  Output is BURSTED (4 chars each) and looped forever so a single
# missed char cannot fool us:
#   continuous "AAAABBBBCCCC\r\n..."  -> jal-to-cold-line + ret both WORK
#   "AAAA" then silence               -> jal into the cold line fetched garbage
#   "AAAABBBB" then silence           -> jal worked, `ret` (jalr) target failed
# Marker 0x300000 bumps each full loop; if it stays 0xDEADBEEF the first jal died.
#
# Link at 0x0020_0000:  -Wl,--defsym,__BASE=0x00200000  (boot.ld).
# =============================================================================

    .equ THR,  0xC0010000
    .equ DLM,  0xC0010004
    .equ FCR,  0xC0010008
    .equ LCR,  0xC001000C
    .equ LSR,  0xC0010014
    .equ DIVISOR, 27
    .equ MARKER,  0x00300000

    .macro PUTC ch
    li   a1, \ch
99: li   t0, LSR
    lw   t1, 0(t0)
    andi t1, t1, 0x20
    beqz t1, 99b
    li   t0, THR
    sw   a1, 0(t0)
    .endm

    .macro BURST ch
    PUTC \ch
    PUTC \ch
    PUTC \ch
    PUTC \ch
    .endm

    .section .text
    .globl _start
_start:
    li t0, LCR; li t1, 0x80; sw t1, 0(t0)
    li t0, THR; li t1, DIVISOR; sw t1, 0(t0)
    li t0, DLM; sw x0, 0(t0)
    li t0, LCR; li t1, 0x03; sw t1, 0(t0)
    li t0, FCR; li t1, 0x07; sw t1, 0(t0)

    li s1, 0                       # loop counter -> marker
loop:
    BURST 'A'                      # inline (sequential fetch) -- works
    jal ra, sub_b                  # <-- the test: call into a cold/far line
    BURST 'C'                      # reached only if `ret` came back
    PUTC '\r'
    PUTC '\n'
    addi s1, s1, 1
    li t0, MARKER
    sw s1, 0(t0)                   # JTAG-visible loop count
    li t2, 0x00100000              # inter-line delay
1:  addi t2, t2, -1
    bnez t2, 1b
    j loop

    # big gap so sub_b lands in a far cache line that must be filled on the jal
    .rept 400
    addi x0, x0, 0
    .endr
sub_b:
    BURST 'B'                      # printed from inside the called subroutine
    ret
