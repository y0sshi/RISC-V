# =============================================================================
# skid_ptw_test.S - trap-return (mret) to a mod4==2 target whose fetch IF-PTWs.
#
# Reproducer for the userspace-compiled-binary bug (memory userspace-compiled-
# binary-bug): the step8 fetch skip_low (drop the leading halfword of the first
# post-redirect word when the target is mid-word, target[1]==1) is LOST when the
# redirect target's fetch takes an instruction-fetch page-table walk (cold TLB).
# A plain I$ miss does NOT lose it (see skid_redirect_test.S, which PASSes); the
# IF-PTW path is the trigger -- exactly Linux's first sret to the musl ELF entry
# at 0x101be (mod4==2), whose cold-TLB fetch fetched 0x101bc (=entry-2) = c.ebreak
# -> SIGTRAP -> init killed.
#
# Here: Sv39 identity-mapped, then mret to S-mode at `smid` (mod4==2) with a cold
# TLB (sfence.vma) so the first S-mode fetch IF-PTWs.  c.ebreak sits at smid-2;
# a skid runs it -> trap -> FAIL; correct skip_low runs smid's c.nop -> DONE.
#
#   make skid_ptw_test  &&  (cd ../sim && rm -rf out/vl_boot && make vl_boot \
#     BOOT_HEX=../software/boot/skid_ptw_test.hex BOOT_MAX=2000000)
# =============================================================================
    .equ TOHOST,     0x80002000
    .equ DONE_MAGIC, 0x00C0FFEE
    .equ FAIL_MAGIC, 0x0BADBAD0
    .equ PTE_LEAF,   0xCF              # V R W X A D (U=0: supervisor page)
    .equ PTE_PTR,    0x01              # V only (non-leaf pointer)

    .section .text
    .globl _start
_start:
    la      t0, mtrap
    csrw    mtvec, t0

    # PMP region 0 = all address space, RWX (NAPOT) so S-mode may run.
    li      t0, -1
    csrw    pmpaddr0, t0
    li      t0, 0x1F
    csrw    pmpcfg0, t0

    call    build_pt                  # Sv39 + satp (cold TLB)

    # drop to S-mode at smid (mod4==2): the first S-mode fetch IF-PTWs.
    csrr    t0, mstatus
    li      t1, ~(3 << 11)            # clear MPP
    and     t0, t0, t1
    li      t1, (1 << 11)             # MPP = S
    or      t0, t0, t1
    csrw    mstatus, t0
    la      t0, smid
    csrw    mepc, t0
    sfence.vma                        # cold TLB -> target fetch walks
    mret

    j       fail                      # mret must not fall through

# -----------------------------------------------------------------------------
# build_pt: identity-map 0x8000_0000 .. 0x8020_0000 (2 MiB) with 4 KiB pages.
# -----------------------------------------------------------------------------
build_pt:
    la      t0, l0_table
    li      t1, 0x80000000
    srli    t2, t1, 12
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

    la      t0, l1_table
    la      t1, l0_table
    srli    t1, t1, 12
    slli    t1, t1, 10
    ori     t1, t1, PTE_PTR
    sd      t1, 0(t0)

    la      t0, l2_table
    la      t1, l1_table
    srli    t1, t1, 12
    slli    t1, t1, 10
    ori     t1, t1, PTE_PTR
    sd      t1, 16(t0)                # VPN2 of 0x8000_0000 = 2 -> byte offset 16

    la      t1, l2_table
    srli    t1, t1, 12
    li      t2, 8
    slli    t2, t2, 60
    or      t1, t1, t2
    csrw    satp, t1
    sfence.vma
    ret

# -----------------------------------------------------------------------------
# M-mode trap handler: any unexpected trap (a mis-fetched c.ebreak) = FAIL.
# disc@0x2004 = mcause, A@0x2008 = mepc.
# -----------------------------------------------------------------------------
    .balign 4
mtrap:
    csrr    t0, mcause
    li      t2, 0x80002004
    sw      t0, 0(t2)
    csrr    t0, mepc
    sw      t0, 4(t2)
    li      t0, TOHOST
    li      t1, FAIL_MAGIC
    sw      t1, 0(t0)
1:  j       1b

# -----------------------------------------------------------------------------
# The mid-word S-mode redirect target (mod4==2), with a c.ebreak 2 bytes before.
# -----------------------------------------------------------------------------
    .balign 8
    .2byte  0x9002                    # c.ebreak  @ mod4==0  (the WRONG halfword)
smid:                                 # @ mod4==2  (the real redirect target)
    .2byte  0x0001                    # c.nop
    j       spass

spass:
    li      t0, TOHOST
    li      t1, DONE_MAGIC
    sw      t1, 0(t0)
1:  j       1b

fail:
    li      t0, TOHOST
    li      t1, FAIL_MAGIC
    sw      t1, 0(t0)
1:  j       1b

    # Page tables at 0x8001_0000+ (well clear of TOHOST 0x8000_2000, still inside
    # the identity-mapped 2 MiB) so the DONE/FAIL store cannot clobber a PTE.
    .section .bss
    .balign 0x10000
l2_table:   .skip 4096
l1_table:   .skip 4096
l0_table:   .skip 4096
