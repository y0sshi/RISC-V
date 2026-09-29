# =============================================================================
# div_irq_test.S - multi-cycle divide vs timer interrupt (lost/corrupt result)
# =============================================================================
# Reproducer for a suspected C-2a regression: with the multi-cycle (radix-2)
# integer divider, a timer interrupt can land ON a divide in EX (during its
# iteration or exactly at its completion boundary).  The interrupt-at-divide
# interaction must leave the divide's architectural result correct (the divide
# is squashed and re-executed, or retires before the trap).
#
# This never fired on the old single-cycle divider (a divide occupied EX for
# one cycle only) and the kernel does not use FP, so the FP-divide path was the
# only multi-cycle op an interrupt could hit -- which early boot never does.
#
# Structure (mirrors lrsc_irq_test.S):
#   - M-mode, CLINT timer (mtimecmp) interrupt on an ABSOLUTE schedule with a
#     STEP coprime to the loop period, so the interrupt sweeps every offset of
#     the divide (cycle-deterministic sim phase-locks a handler-relative re-arm).
#   - Pre-compute the golden quotient/remainder with interrupts DISABLED.
#   - Main loop: recompute div/rem N times and compare each to golden; the
#     handler runs its OWN divide (different operands) to dirty the shared
#     div_result register, then K++ and re-arm.
#   - Pass requires every result correct AND K > 0 (interrupts really fired).
#
# Run:  make div_irq_test  &&  (cd ../sim && make vl_boot \
#   BOOT_HEX=../software/boot/div_irq_test.hex)
# =============================================================================

    .equ CLINT_MTIMECMP, 0xC0004000
    .equ CLINT_MTIME,    0xC000BFF8
    .equ TOHOST,         0x80002000
    .equ DONE_MAGIC,     0x00C0FFEE
    .equ FAIL_MAGIC,     0x0BADBAD0
    .equ N,              5000
    .equ PERIOD,         400
    .equ STEP,           431          # coprime sweep (see lrsc_irq_test.S)

    .section .text
    .globl _start
_start:
    la      t0, mtrap
    csrw    mtvec, t0

    li      s1, 0x80020100            # K: handler interrupt count
    sd      zero, 0(s1)

    # Main-loop operands (fixed): s7 = dividend, s8 = divisor.
    li      s7, 0x0000123456789ABC
    li      s8, 0x0000000000010007

    # ---- golden results, computed with interrupts DISABLED ------------------
    divu    s9,  s7, s8              # golden quotient
    remu    s10, s7, s8              # golden remainder
    divuw   s11, s7, s8              # golden W-type quotient (low 32 / low 32)

    # ---- arm CLINT timer: s5 = mtime + PERIOD (absolute schedule) -----------
    li      t1, CLINT_MTIME
    ld      t2, 0(t1)
    li      t3, PERIOD
    add     s5, t2, t3
    li      t1, CLINT_MTIMECMP
    sd      s5, 0(t1)

    # ---- enable MTIE + global MIE -------------------------------------------
    li      t0, (1 << 7)             # mie.MTIE
    csrs    mie, t0
    li      t0, (1 << 3)             # mstatus.MIE
    csrs    mstatus, t0

    li      s3, N
    li      s4, 0                    # i

loop:
    divu    t1, s7, s8               # quotient under interrupt pressure
    bne     t1, s9, fail
    remu    t2, s7, s8               # remainder under interrupt pressure
    bne     t2, s10, fail
    divuw   t3, s7, s8               # W-type quotient under interrupt pressure
    bne     t3, s11, fail
    addi    s4, s4, 1
    blt     s4, s3, loop

    # ---- disable interrupts before checking ---------------------------------
    li      t0, (1 << 3)
    csrc    mstatus, t0

    ld      t2, 0(s1)                # K
    beqz    t2, fail                 # no interrupts fired -> vacuous

pass:
    li      t1, TOHOST
    li      t2, DONE_MAGIC
    sw      t2, 0(t1)
1:  wfi
    j       1b

fail:
    li      t1, TOHOST
    li      t2, FAIL_MAGIC
    sw      t2, 0(t1)
1:  wfi
    j       1b

# -----------------------------------------------------------------------------
# M-mode trap handler (MTIP only): run a DIFFERENT divide (dirties the shared
# div_result register), count, re-arm timer on the absolute schedule.
# Uses only a0..a5 (main loop owns s0..s11, t1..t3).
# -----------------------------------------------------------------------------
    .align 4
mtrap:
    li      a0, 0x00000000DEADBEEF   # handler operands -> different result
    li      a1, 0x0000000000000101
    divu    a2, a0, a1              # dirty div_result with a non-golden value
    rem     a2, a0, a1
    divw    a2, a0, a1

    ld      a3, 0(s1)               # K++
    addi    a3, a3, 1
    sd      a3, 0(s1)

    li      a4, STEP                # absolute re-arm: mtimecmp = prev + STEP
    add     s5, s5, a4
    li      a2, CLINT_MTIMECMP
    sd      s5, 0(a2)
    mret
