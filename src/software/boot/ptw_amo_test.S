# =============================================================================
# ptw_amo_test.S - AMO write-loss under an IF-PTW that masks the D$ wait
# =============================================================================
# Focused reproducer for the real-HW "netlink atomic_dec loss" (nl_table_users
# stuck at 1, CONFIG_NET=y intermittent hang -- memory zybo-netlink-atomic-bug).
#
# Root cause (rv_soc.sv:364):  core_dmem_wait = ptw_req ? 1'b0 : dc_c_wait;
# ANY ptw_req -- INCLUDING an instruction-fetch page-table walk (ptw_for_if=1)
# that is independent of the held data access -- forces the core's dmem_wait to
# 0, hiding an IN-FLIGHT D-cache access.  When an amoadd.w's READ phase takes a
# D$ miss (multi-cycle line fill) and, during that fill, the next instruction
# fetch TLB-misses and starts an IF-PTW, the mask drops dmem_wait to 0 -> the
# AMO's amo_state advances 0->1 (read "complete") before the fill finished and
# the WRITE phase is presented while the D$ is still filling (state != S_LOOKUP)
# -> the store is never latched -> the AMO retires with its write LOST.  The
# counter keeps its pre-decrement value (exactly 1 on HW).
#
# This bug is MMU-gated (no ptw_req when satp=0), so every M-mode unit/atomic
# test passes; and it needs the D$-fill window to overlap an IF-PTW, so the
# low-latency dual-port BFM rarely hits it.  This test forces the overlap:
#   - Sv39 ON, identity-mapped with 4 KiB leaf pages (TLB thrash, 16 entries).
#   - amoadd.w placed at the LAST word of a code page so the next fetch crosses
#     into a page that the per-iteration alias loads have evicted from the TLB
#     -> an IF-PTW fires right as the amoadd takes its D$ fill.
#   - The counter lives in the executing code page (always TLB-present) so the
#     amoadd's DATA access hits the TLB (no competing data PTW) and the D$ fill
#     overlaps cleanly with the IF-PTW.
#   - High AXI read latency widens both the fill and the PTW (run with
#     BOOT_AR_DELAY/BOOT_R_DELAY).
#
# Invariant: the counter equals the iteration index, so amoadd.w +1 must return
# old == i every time.  A lost write (or a stale read) breaks it -> FAIL.
#
# What makes the window open is the I$ thrashing: Linux code is huge so the I$
# misses constantly and the next-fetch IF-PTW lands inside the amoadd's read-miss
# fill.  This test therefore EXECUTES a large (>16 KiB I$) NOP region every
# iteration so the I$ thrashes, with the amoadd at a page end (its read misses
# the D$, and the fetch after it IF-PTWs).  The counter lives on a separate
# (non-executed) data page.  This reproduces on the plain dual-port BFM (no
# serialization needed); BOOT_SERIALIZE=1 also reproduces.
#
# Run (PRE-fix FAILs with disc@2004=1; the rv_soc.sv:364 fix makes it PASS):
#   make ptw_amo_test  &&  (cd ../sim && rm -rf out/vl_boot && \
#     MSYS_NO_PATHCONV=1 make vl_boot BOOT_HEX=../software/boot/ptw_amo_test.hex \
#     BOOT_AR_DELAY=12 BOOT_R_DELAY=3 BOOT_MAX=200000000 )
# The TB prints [PTWMASK] ...; the smoking gun is "AMO premature-write ... > 0"
# (pre-fix) -> 0 (post-fix).
# =============================================================================

    .equ TOHOST,     0x80002000
    .equ CTR,        0x80080000        # counter: separate data page, clear of the
                                       # executed NOP region / TOHOST / stack / PTs
    .equ DONE_MAGIC, 0x00C0FFEE
    .equ FAIL_MAGIC, 0x0BADBAD0
    .equ N,          2000
    .equ CODE_PAGES, 6                 # executed NOP pages/iter (>16 KiB I$)
    .equ PTE_LEAF,   0xCF              # V R W X A D (U=0: supervisor page)
    .equ PTE_PTR,    0x01              # V only (non-leaf pointer)

    .section .text
    .option norvc                     # 4-byte instructions only (offset control)
    .globl _start
_start:
    la      t0, mtrap
    csrw    mtvec, t0

    # ---- PMP region 0 = all address space, RWX (NAPOT) so S-mode may run ----
    li      t0, -1
    csrw    pmpaddr0, t0
    li      t0, 0x1F
    csrw    pmpcfg0, t0

    call    build_pt                  # set up Sv39 + satp (translation off until MRET)

    # ---- drop to S-mode at smain ----
    csrr    t0, mstatus
    li      t1, ~(3 << 11)            # clear MPP
    and     t0, t0, t1
    li      t1, (1 << 11)             # MPP = S
    or      t0, t0, t1
    csrw    mstatus, t0
    la      t0, smain
    csrw    mepc, t0
    mret

# -----------------------------------------------------------------------------
# build_pt: identity-map 0x8000_0000 .. 0x8020_0000 (2 MiB) with 4 KiB pages.
#   L2[2] -> L1 ; L1[0] -> L0 ; L0[0..511] = leaf identity pages.
# Runs in M-mode (translation off) so all addresses are physical.
# -----------------------------------------------------------------------------
build_pt:
    # L0: 512 leaf PTEs identity-mapping the 2 MiB
    la      t0, l0_table
    li      t1, 0x80000000
    srli    t2, t1, 12               # PPN of first page
    li      t3, 512
    li      t4, PTE_LEAF
1:
    slli    t5, t2, 10
    or      t5, t5, t4
    sd      t5, 0(t0)
    addi    t0, t0, 8
    addi    t2, t2, 1
    addi    t3, t3, -1
    bnez    t3, 1b

    # L1[0] -> L0
    la      t0, l1_table
    la      t1, l0_table
    srli    t1, t1, 12
    slli    t1, t1, 10
    ori     t1, t1, PTE_PTR
    sd      t1, 0(t0)

    # L2[2] -> L1   (VPN2 of 0x8000_0000 = 2 -> byte offset 16)
    la      t0, l2_table
    la      t1, l1_table
    srli    t1, t1, 12
    slli    t1, t1, 10
    ori     t1, t1, PTE_PTR
    sd      t1, 16(t0)

    # satp = (8 << 60) | (l2_table >> 12)
    la      t1, l2_table
    srli    t1, t1, 12
    li      t2, 8
    slli    t2, t2, 60
    or      t1, t1, t2
    csrw    satp, t1
    sfence.vma
    ret

# -----------------------------------------------------------------------------
# M-mode trap handler: any unexpected trap (incl. a corruption-induced fault)
# = FAIL.
# -----------------------------------------------------------------------------
    .balign 4
mtrap:
    # Record discriminator + context so the TB can tell an unexpected trap
    # (corruption-induced fault) apart from an architectural amoadd mismatch.
    # disc@0x2004 = mcause (>= 2); A@0x2008 = mepc; B@0x200C = mtval.
    csrr    t0, mcause
    li      t2, 0x80002004
    sw      t0, 0(t2)
    csrr    t0, mepc
    sw      t0, 4(t2)
    csrr    t0, mtval
    sw      t0, 8(t2)
    li      t0, TOHOST
    li      t1, FAIL_MAGIC
    sw      t1, 0(t0)
1:  wfi
    j       1b

# -----------------------------------------------------------------------------
# S-mode entry
# -----------------------------------------------------------------------------
    .balign 4
smain:
    li      s1, CTR
    sw      zero, 0(s1)              # counter = 0
    li      s4, 0                    # iteration index = expected old value
    li      s5, N
    j       run_start

# -----------------------------------------------------------------------------
# Executed loop body: CODE_PAGES pages of NOPs (falls through, executed EVERY
# iteration -> the 16 KiB I$ thrashes and its line fills compete with D$/PTW on
# the single DDR under BOOT_SERIALIZE).  The block is sized so `amoadd.w` is the
# LAST word of the last NOP page, so the fetch right after it crosses into the
# next page (kept TLB-evicted by the per-iteration alias loads) -> an IF-PTW
# fires while the amoadd takes its D$ line fill.
#   .fill count = CODE_PAGES*1024 - 2 words -> do_amo at offset
#   CODE_PAGES*4096 - 8 = (last page)+0xFF8.
# -----------------------------------------------------------------------------
    .balign 4096
run_start:
    .fill   (CODE_PAGES*1024 - 2), 4, 0x00000013
do_amo:                              # offset CODE_PAGES*4096 - 8 (= page end - 8)
    li      t0, 1
    amoadd.w a0, t0, 0(s1)           # last word of the last NOP page

    # ---- next page ----
    bne     a0, s4, s_fail           # old must equal the iteration index

    # evict the counter's D$ line + thrash the 16-entry TLB (24 distinct data
    # pages, all the same D$ set as the counter via the 16 KiB stride).
    li      t3, 24
    li      t4, 16384
    mv      t2, s1
2:  add     t2, t2, t4
    lw      t5, 0(t2)
    addi    t3, t3, -1
    bnez    t3, 2b

    addi    s4, s4, 1
    blt     s4, s5, run_start

    # ---- success ----
    li      t0, TOHOST
    li      t1, DONE_MAGIC
    sw      t1, 0(t0)
3:  wfi
    j       3b

s_fail:
    # disc@0x2004 = 1 (architectural amoadd mismatch = REPRODUCTION);
    # A@0x2008 = bad old value (a0); B@0x200C = expected (iteration index).
    li      t2, 0x80002004
    li      t3, 1
    sw      t3, 0(t2)
    sw      a0, 4(t2)
    sw      s4, 8(t2)
    li      t0, TOHOST
    li      t1, FAIL_MAGIC
    sw      t1, 0(t0)
4:  wfi
    j       4b

    .section .bss
    .balign 4096
l2_table:   .skip 4096
l1_table:   .skip 4096
l0_table:   .skip 4096
