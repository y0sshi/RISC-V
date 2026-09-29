# =============================================================================
# lrsc_irq_test.S - LR/SC reservation vs trap/interrupt (lost-update repro)
# =============================================================================
# Reproducer for the Linux refcount corruption (2026-06-10): the LR/SC
# reservation survived traps and xRET, so a timer interrupt taken BETWEEN an
# LR and its SC, whose handler performs an AMO to the SAME address, let the
# resumed SC succeed with the PRE-trap loaded value -- silently losing the
# handler's update (Linux: atomic_fetch_add in IRQ/softirq context vs a
# try_cmpxchg loop in task context -> refcount saturate/underflow WARNs).
#
# The privileged spec requires xRET to void any outstanding LR reservation;
# this test fails on RTL that lacks the trap/xRET reservation kill.
#
# Structure:
#   - M-mode, CLINT timer (mtimecmp) interrupt every PERIOD cycles.
#   - Main loop: lr.d / <wide window> / sc.d increment of counter X, N times.
#   - MTIP handler: amoadd.d +1 to the SAME counter X, K++ (private counter),
#     re-arm mtimecmp, mret.
#   - Final check: X == N + K exactly, and K > 0 (interrupts really fired).
#     A lost update makes X < N + K.
#
# Register split (no save/restore needed): main loop owns s0..s4,t1..t3;
# the handler only uses a0..a4.
#
# Run:  make lrsc_irq_test  &&  (cd ../sim && make vl_boot \
#   BOOT_HEX=../software/boot/lrsc_irq_test.hex)
# =============================================================================

    .equ CLINT_MTIMECMP, 0xC0004000
    .equ CLINT_MTIME,    0xC000BFF8
    .equ TOHOST,         0x80002000
    .equ DONE_MAGIC,     0x00C0FFEE
    .equ FAIL_MAGIC,     0x0BADBAD0
    .equ N,              5000
    .equ PERIOD,         400
    # Re-arm STEP: prime, and added to the PREVIOUS mtimecmp (absolute
    # schedule, NOT handler-relative).  The whole simulation is cycle-
    # deterministic, so a handler-relative re-arm phase-locks the interrupt
    # to the same loop offset every time (observed: always the LR or the
    # post-SC branch, never inside the LR->SC window).  An absolute schedule
    # with STEP coprime to the loop period sweeps every loop offset.
    .equ STEP,           431

    .section .text
    .globl _start
_start:
    la      t0, mtrap
    csrw    mtvec, t0

    li      s0, 0x80020000          # X: shared counter (lr/sc vs handler amoadd)
    li      s1, 0x80020100          # K: handler interrupt count (handler-only)
    sd      zero, 0(s0)
    sd      zero, 0(s1)

    # ---- arm the CLINT timer: s5 = mtime + PERIOD (absolute schedule) -------
    li      t1, CLINT_MTIME
    ld      t2, 0(t1)
    li      t3, PERIOD
    add     s5, t2, t3
    li      t1, CLINT_MTIMECMP
    sd      s5, 0(t1)

    # ---- enable MTIE + global MIE -------------------------------------------
    li      t0, (1 << 7)            # mie.MTIE
    csrs    mie, t0
    li      t0, (1 << 3)            # mstatus.MIE
    csrs    mstatus, t0

    li      s3, N
    li      s4, 0                   # i

loop:
retry:
    lr.d    t1, (s0)
    # widen the LR->SC window so interrupts land inside it often
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    addi    t2, t1, 1
    sc.d    t3, t2, (s0)
    bnez    t3, retry
    addi    s4, s4, 1
    blt     s4, s3, loop

    # ---- disable interrupts before checking ---------------------------------
    li      t0, (1 << 3)
    csrc    mstatus, t0

    # ---- final check: X == N + K, K > 0 -------------------------------------
    ld      t1, 0(s0)               # X
    ld      t2, 0(s1)               # K
    beqz    t2, fail                # no interrupts fired -> test is vacuous
    li      t3, N
    add     t2, t2, t3              # N + K
    bne     t1, t2, fail

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
# M-mode trap handler (MTIP only): AMO the shared counter, count, re-arm timer
# -----------------------------------------------------------------------------
    .align 4
mtrap:
    li      a1, 1
    amoadd.d a3, a1, (s0)           # handler's +1 to the SAME address as lr/sc

    ld      a3, 0(s1)               # K++
    addi    a3, a3, 1
    sd      a3, 0(s1)

    li      a4, STEP                # re-arm on the ABSOLUTE schedule:
    add     s5, s5, a4              # mtimecmp = previous mtimecmp + STEP
    li      a2, CLINT_MTIMECMP
    sd      s5, 0(a2)
    mret
