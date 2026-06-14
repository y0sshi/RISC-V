# =============================================================================
# mal_cachemiss_test.S - misaligned 8-byte access retiring while I$ is not ready
# =============================================================================
# Bare-metal reproducer for RTL bug #15 (mal_state restart-livelock).
#
# A misaligned 8-byte access runs as a 2-phase MEM access (mal_state FSM): phase
# 0 issues the first aligned word and stalls the pipeline (mal_stall), phase 1
# issues the second word with mal_stall=0.  On the cycle phase 1 finishes
# (dmem_wait=0, mem_stall=0) the instruction wants to RETIRE -- but if stall_ex
# is STILL held by an UNRELATED source it cannot retire that cycle.  The only
# such source for a load/store in MEM is ~imem_ready (the NEXT instruction fetch
# is mid I$ line-fill / straddle-bypass).  The old RTL unconditionally reset
# mal_state to 0 there, so the next cycle mal_stall re-asserted and phase 0
# RESTARTED -> if that ~imem_ready recurs every completion the access never
# retires, stall_if stays high forever, no interrupt can be taken -> LIVELOCK.
# (Same restart class as muldiv_done #14 / fpu_done; amo_state was already
# guarded, mal_state was the one left exposed.  See CLAUDE.md "RTL #15".)
#
# How the coincidence is produced here (this mirrors how full Linux exposed #15
# -- a misaligned C.SD whose retire kept landing under a periodic ~imem_ready):
#   - A timer interrupt redirects to the handler (mtrap).  The redirect is a
#     COLD fetch into the handler region, so the handler's first instructions
#     MISS the I$ and line-fill -> ~imem_ready is high across the handler entry.
#   - The handler does a misaligned 8-byte store+load right there, so its phase-1
#     completion repeatedly lands on a ~imem_ready cycle == bug #15.
#   - The handler runs with interrupts masked, so its own store->load->compare
#     is reliable; a mismatch there means a corrupted misaligned access.
#   - The timer re-arms on an ABSOLUTE schedule with a STEP coprime to the loop
#     period, so the interrupt sweeps every alignment of the handler entry vs
#     the I$ fill (cycle-deterministic sim phase-locks otherwise).
#   - The main loop just strides misaligned loads through a buffer larger than
#     the D$ (cache-miss pressure + many interrupt landing points).  It does NOT
#     data-verify: the #15 signal is HANG vs COMPLETE, and verifying a misaligned
#     load that an interrupt may land on is a separate concern (see note below).
#
# Old RTL: livelocks in the handler (no DONE_MAGIC within BOOT_MAX -> timeout).
# Fixed RTL: PASS (handler self-check holds, loop completes, K>0).
#
# NOTE (separate from #15): an earlier variant that data-verified the main-loop
# misaligned LOAD (compare against a pre-filled value) FAILS on the FIXED RTL
# when a timer interrupt lands on the load under a D$ miss -- the loaded value
# comes back stale.  That is NOT the #15 livelock (it happens with the fix in
# place and without any straddle); it looks like a misaligned-load-vs-interrupt
# interaction worth a separate look.  Kept out of this repro to keep the #15
# signal clean.
#
# Run:  make mal_cachemiss_test  &&  (cd ../sim && make vl_boot \
#   BOOT_HEX=../software/boot/mal_cachemiss_test.hex)
# (Verilator: rm -rf out/vl_boot first if RTL changed.)
# =============================================================================

    .equ CLINT_MTIMECMP, 0xC0004000
    .equ CLINT_MTIME,    0xC000BFF8
    .equ TOHOST,         0x80002000
    .equ DONE_MAGIC,     0x00C0FFEE
    .equ FAIL_MAGIC,     0x0BADBAD0
    .equ BUF,            0x80100000    # large buffer base (well above code/stack)
    .equ HBUF,           0x80020200    # handler scratch (8-aligned; +4 -> misaligned)
    .equ MISALIGN,       4             # +4 -> 8-byte access spans an 8-byte word
    .equ LINES,          256           # 256 * 64B = 16 KiB sweep == the D$ size
    .equ STRIDE,         64            # > one 32B cache line -> fresh line each load
    .equ PASSES,         8             # repeat the whole sweep
    .equ PERIOD,         400
    .equ STEP,           397           # coprime sweep (see lrsc_irq_test.S / div_irq_test.S)
    .equ HVAL,           0xCAFEF00DBADC0DE5   # handler self-check value (8 bytes)

    .section .text
    .globl _start
_start:
    la      t0, mtrap
    csrw    mtvec, t0

    li      s1, 0x80020100            # K: handler interrupt count
    sd      zero, 0(s1)
    li      s3, LINES

    # ---- arm CLINT timer: s5 = mtime + PERIOD (absolute schedule) -----------
    li      t1, CLINT_MTIME
    ld      t2, 0(t1)
    li      t3, PERIOD
    add     s5, t2, t3
    li      t1, CLINT_MTIMECMP
    sd      s5, 0(t1)

    # ---- enable MTIE + global MIE -------------------------------------------
    li      t0, (1 << 7)              # mie.MTIE
    csrs    mie, t0
    li      t0, (1 << 3)              # mstatus.MIE
    csrs    mstatus, t0

    li      s6, PASSES                # pass counter

pass_loop:
    li      s2, BUF + MISALIGN        # s2[2:0] = 4 -> every 8-byte access crosses
    li      s4, 0                     # line index
mloop:
    ld      t1, 0(s2)                 # misaligned 8-byte load (D$ miss, mal_cross)
                                      # NOT verified: the #15 signal is hang vs done
    addi    s2, s2, STRIDE
    addi    s4, s4, 1
    blt     s4, s3, mloop

    addi    s6, s6, -1
    bnez    s6, pass_loop

    # ---- disable interrupts before checking ---------------------------------
    li      t0, (1 << 3)
    csrc    mstatus, t0
    ld      t2, 0(s1)                 # K: must be > 0 (interrupts really fired)
    beqz    t2, fail

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
# M-mode trap handler (MTIP only): a misaligned 8-byte store+load+verify right
# at the handler entry (where the cold-fetch I$ fill keeps ~imem_ready high ==
# the #15 coincidence), then K++ and re-arm the timer on the absolute schedule.
# Runs with interrupts masked, so the self-check is reliable.  Uses only a0..a5.
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
