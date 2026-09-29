# =============================================================================
# skid_redirect_test.S - trap-return (mret) to a 2-byte-aligned (mod4==2) target
# must execute the instruction AT the target, not the halfword 2 bytes BEFORE it.
#
# Reproducer for the userspace-compiled-binary bug (see memory
# userspace-compiled-binary-bug): the step8 fetch machinery's skip_low (drop the
# leading halfword of the first post-redirect word when the target is mid-word,
# target[1]==1) is lost when the redirect target's fetch is multi-cycle (I$ miss
# or PTW).  Linux's first sret to a musl ELF entry at 0x101be (mod4==2) fetched
# 0x101bc (= entry-2) = c.ebreak -> SIGTRAP -> init killed -> kernel panic.
#
# Here: mret to `target_mid` (mod4==2) after fence.i (so the target word misses in
# I$ and fills over multiple cycles).  A c.ebreak sits at target_mid-2 (mod4==0).
# If the fetch skids to the low halfword, c.ebreak traps -> FAIL; correct skip_low
# runs target_mid's instruction -> DONE.
#
#   make skid_redirect_test  &&  (cd ../sim && rm -rf out/vl_boot && make vl_boot \
#     BOOT_HEX=../software/boot/skid_redirect_test.hex BOOT_MAX=2000000)
# =============================================================================
    .equ TOHOST,      0x80002000
    .equ DONE_MAGIC,  0x00C0FFEE
    .equ FAIL_MAGIC,  0x0BADBAD0

    .section .text
    .globl _start
_start:
    la      t0, mtrap
    csrw    mtvec, t0

    # mret returns to MPP (set M) at the mid-word target mepc.
    li      t0, (3 << 11)       # mstatus.MPP = M
    csrs    mstatus, t0
    la      t0, target_mid
    csrw    mepc, t0
    fence.i                     # flush I$ -> target word misses (multi-cycle fill)
    mret

    j       fail                # mret must not fall through

    # ---- trap handler: a mis-fetched c.ebreak (cause=3) lands here = FAIL ----
    .balign 4
mtrap:
    li      t2, TOHOST
    li      t1, FAIL_MAGIC
    sw      t1, 0(t2)
1:  j       1b

    # ---- the redirect target, deliberately at a mod4==2 byte offset ----
    .balign 8
    .2byte  0x9002              # c.ebreak  @ mod4==0  (the WRONG halfword)
target_mid:                     # @ mod4==2  (the real redirect target)
    .2byte  0x0001              # c.nop
    j       pass

pass:
    li      t2, TOHOST
    li      t1, DONE_MAGIC
    sw      t1, 0(t2)
1:  j       1b

fail:
    li      t2, TOHOST
    li      t1, FAIL_MAGIC
    sw      t1, 0(t2)
1:  j       1b
