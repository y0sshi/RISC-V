# =============================================================================
# mal_load_irq_test.S - misaligned 8-byte LOAD vs timer IRQ under a D$ miss
# =============================================================================
# Reproducer for RTL bug #16 (misaligned-LOAD phase-0 word lost to flush_ex_mem).
# Separate from #15 (mal_state restart-livelock).  Root cause: when a timer
# interrupt is taken on the YOUNGER instruction in EX while an OLDER misaligned
# 8-byte LOAD is legitimately retiring from MEM, flush_ex_mem (which bubbles the
# EX->MEM transition to squash the interrupted EX instruction) ALSO unconditionally
# reset the misaligned 2-phase FSM, ZEROING mal_first_data on the very cycle the
# phase-0 word is captured (mal_phase1_start).  The load then wrote back only its
# phase-1 (high) half; the phase-0 (low) half came back 0.  Under a D$ miss the
# phase-1 read takes long enough that the interrupt-retire coincidence happens
# often.  Fix (rv_core.sv): reset the mal FSM only on the load/store's OWN MEM
# fault (mem_trap_enter), not on a generic flush_ex_mem -- the older retiring load
# must keep its captured phase-0 word.  Old RTL: FAIL; fixed RTL: PASS.
#
# This test data-VERIFIES the main-loop misaligned load:
#   - Pre-fill, interrupts OFF, each misaligned 8-byte slot at BUF+4 + i*STRIDE
#     with a unique value  val(i) = TAG | i.  (round-trips fine without IRQ.)
#   - Hot loop, interrupts ON: load slot i, compare to TAG | i.
#   - On mismatch: record loaded/expected/i/addr to a diagnostic region (DIAG),
#     then write FAIL_MAGIC (TB reports FAIL).  With #16 the load loses its low
#     half: loaded == (TAG | i) & 0xFFFFFFFF00000000.  (To print the captured
#     loaded/expected, add a temporary 8-byte LE read of DIAG=0x80020120 in the
#     final block of tb_rv_boot_soc.sv.)
#   - The timer sweeps every alignment (absolute schedule, coprime STEP) so an
#     interrupt eventually lands inside a load's D$-miss window.
#
# Control: build with -DNOIRQ (interrupts never enabled) and this PASSes, proving
# the misaligned load round-trip itself is correct -- the trigger is
# IRQ x misaligned-load x variable latency (D$ miss).
#
# Run:  make mal_load_irq_test  &&  (cd ../sim && make vl_boot \
#   BOOT_HEX=../software/boot/mal_load_irq_test.hex)
# (Verilator: rm -rf out/vl_boot first if RTL changed.)
# =============================================================================

    .equ CLINT_MTIMECMP, 0xC0004000
    .equ CLINT_MTIME,    0xC000BFF8
    .equ TOHOST,         0x80002000
    .equ DONE_MAGIC,     0x00C0FFEE
    .equ FAIL_MAGIC,     0x0BADBAD0
    .equ DIAG,           0x80020120    # diagnostic dump: loaded/exp/i/addr
    .equ BUF,            0x80100000    # large buffer base (well above code/stack)
    .equ HBUF,           0x80020200    # handler scratch (8-aligned; +4 -> misaligned)
    .equ MISALIGN,       4             # +4 -> 8-byte access spans an 8-byte word
    .equ LINES,          256           # 256 * 64B = 16 KiB sweep == the D$ size
    .equ STRIDE,         64            # > one 32B cache line -> fresh line each load
    .equ PASSES,         8             # repeat the whole sweep
    .equ PERIOD,         400
    .equ STEP,           397           # coprime sweep (see div_irq_test.S)
    .equ TAG,            0xABCD000000000000   # high bits: value = TAG | i
    .equ HVAL,           0xCAFEF00DBADC0DE5   # handler self-check value (8 bytes)

    .section .text
    .globl _start
_start:
    la      t0, mtrap
    csrw    mtvec, t0

    li      s1, 0x80020100            # K: handler interrupt count
    sd      zero, 0(s1)
    li      s3, LINES
    li      s11, TAG

    # ---- pre-fill, interrupts OFF: slot i = TAG | i -------------------------
    li      s2, BUF + MISALIGN
    li      s4, 0
pf_loop:
    or      t1, s11, s4              # value = TAG | i
    sd      t1, 0(s2)               # misaligned 8-byte store
    addi    s2, s2, STRIDE
    addi    s4, s4, 1
    blt     s4, s3, pf_loop

    # ---- arm CLINT timer: s5 = mtime + PERIOD (absolute schedule) -----------
    li      t1, CLINT_MTIME
    ld      t2, 0(t1)
    li      t3, PERIOD
    add     s5, t2, t3
    li      t1, CLINT_MTIMECMP
    sd      s5, 0(t1)

    # ---- enable MTIE + global MIE (build with -DNOIRQ for the IRQ-off control)
#ifndef NOIRQ
    li      t0, (1 << 7)              # mie.MTIE
    csrs    mie, t0
    li      t0, (1 << 3)              # mstatus.MIE
    csrs    mstatus, t0
#endif

    li      s6, PASSES                # pass counter

pass_loop:
    li      s2, BUF + MISALIGN        # s2[2:0] = 4 -> every 8-byte access crosses
    li      s4, 0                     # line index
mloop:
    ld      t1, 0(s2)                # misaligned 8-byte load (D$ miss, mal_cross)
    or      t2, s11, s4              # expected = TAG | i
    bne     t1, t2, fail            # stale/corrupt -> diagnose + fail
    addi    s2, s2, STRIDE
    addi    s4, s4, 1
    blt     s4, s3, mloop

    addi    s6, s6, -1
    bnez    s6, pass_loop

    # ---- disable interrupts before final check ------------------------------
    li      t0, (1 << 3)
    csrc    mstatus, t0
    ld      t2, 0(s1)                # K: must be > 0 (interrupts really fired)
#ifndef NOIRQ
    beqz    t2, fail
#endif

pass:
    li      t1, TOHOST
    li      t2, DONE_MAGIC
    sw      t2, 0(t1)
1:  wfi
    j       1b

fail:
    # record loaded(t1)/expected(t2)/i(s4)/addr(s2) for the TB to dump
    li      t3, DIAG
    sd      t1, 0(t3)
    sd      t2, 8(t3)
    sd      s4, 16(t3)
    sd      s2, 24(t3)
    li      t1, TOHOST
    li      t2, FAIL_MAGIC
    sw      t2, 0(t1)
1:  wfi
    j       1b

# -----------------------------------------------------------------------------
# M-mode trap handler (MTIP only): a misaligned 8-byte store+load+verify right
# at the handler entry (cold-fetch I$ fill keeps ~imem_ready high), then K++ and
# re-arm the timer on the absolute schedule.  Runs with interrupts masked, so
# the self-check is reliable.  Uses only a0..a5 (never the main loop's regs).
# -----------------------------------------------------------------------------
    .align 4
mtrap:
    li      a0, HBUF
    addi    a0, a0, MISALIGN          # +4 -> misaligned 8-byte address
    li      a1, HVAL
    sd      a1, 0(a0)                 # misaligned 8-byte store
    ld      a2, 0(a0)                 # misaligned 8-byte load
    bne     a2, a1, fail              # corrupted misaligned access -> fail

    ld      a3, 0(s1)                 # K++
    addi    a3, a3, 1
    sd      a3, 0(s1)

    li      a4, STEP                  # absolute re-arm: mtimecmp = prev + STEP
    add     s5, s5, a4
    li      a2, CLINT_MTIMECMP
    sd      s5, 0(a2)
    mret
