# =============================================================================
# uart_hw.S - bare-metal NS16550 UART hello (no OpenSBI), for real-HW bring-up.
# =============================================================================
# Drives the SoC UART (0xC001_0000, reg-shift=2) DIRECTLY at the hardware baud
# (57600 @ 25 MHz PL clock => 16550 divisor 27) and prints a string in a loop.
# This isolates "does the UART peripheral emit correct bits on pin V15 at 57600"
# from anything OpenSBI-specific.
#
# The UART lives inside rv_soc (rv_periph), NOT on the AXI/DDR path, so this also
# differs from liveness_hw.S by exercising the peripheral decode + UART TX.
#
# JTAG-visible progress marker at 0x0030_0000 = number of messages FULLY sent
# (i.e. every char passed the THRE poll and was written to THR):
#   marker advances + TeraTerm shows text  -> UART + baud + wiring all good
#   marker advances + TeraTerm silent      -> bits written to THR but not arriving:
#                                             baud mismatch (actual FCLK != 25 MHz)
#                                             or TX-shift / wiring problem
#   marker stuck at poison (0xDEADBEEF)     -> hung in the THRE poll: LSR THRE never
#                                             sets -> UART TX state machine stalled
#
# Link at 0x0020_0000:  -Wl,--defsym,__BASE=0x00200000  (boot.ld).
# =============================================================================

    .equ THR,  0xC0010000      # TX holding / RX buffer / DLL(when DLAB=1)
    .equ DLM,  0xC0010004      # IER / DLM(when DLAB=1)         (reg 1, shift 2)
    .equ FCR,  0xC0010008      # FIFO control                  (reg 2, shift 2)
    .equ LCR,  0xC001000C      # line control                  (reg 3, shift 2)
    .equ LSR,  0xC0010014      # line status (bit5 = THRE)     (reg 5, shift 2)
    .equ DIVISOR, 27           # 25e6 / (16 * 57600) ~= 27 -> 57870 baud (+0.47%)
    .equ MARKER, 0x00300000

    .section .text
    .globl _start
_start:
    # ---- 16550 init: program the baud divisor, then 8N1, enable FIFOs ----
    li   t0, LCR
    li   t1, 0x80
    sw   t1, 0(t0)             # LCR.DLAB = 1 (divisor latch access)
    li   t0, THR
    li   t1, DIVISOR
    sw   t1, 0(t0)             # DLL = divisor low
    li   t0, DLM
    sw   x0, 0(t0)             # DLM = divisor high = 0
    li   t0, LCR
    li   t1, 0x03
    sw   t1, 0(t0)             # 8 data bits, 1 stop, no parity; DLAB = 0
    li   t0, FCR
    li   t1, 0x07
    sw   t1, 0(t0)             # enable + clear RX/TX FIFOs

    li   s1, 0                 # message counter (JTAG-visible at MARKER)
loop:
    la   a0, msg
1:  lbu  a1, 0(a0)
    beqz a1, sent
2:  li   t0, LSR               # poll until THRE (transmit holding empty)
    lw   t1, 0(t0)
    andi t1, t1, 0x20
    beqz t1, 2b
    li   t0, THR
    sw   a1, 0(t0)             # write the character
    addi a0, a0, 1
    j    1b
sent:
    addi s1, s1, 1
    li   t0, MARKER
    sw   s1, 0(t0)             # JTAG-visible: count of fully-sent messages
    li   t2, 0x00800000        # crude inter-message delay
3:  addi t2, t2, -1
    bnez t2, 3b
    j    loop

    .section .rodata
msg:
    .string "RVUART-HW-OK 57600 8N1\r\n"
