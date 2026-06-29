# =============================================================================
# skid_ptwfault_test.S - redirect to a mod4==2 target whose page faults first.
#
# Faithful reproducer for the userspace-compiled-binary bug (memory
# userspace-compiled-binary-bug).  Neither a plain I$ miss (skid_redirect_test)
# nor a cold-TLB IF-PTW with the page already valid (skid_ptw_test) loses the
# step8 skip_low.  Linux's first sret to the musl ELF entry at 0x101be (mod4==2)
# instead INSTRUCTION-PAGE-FAULTED (cause=12, page unmapped) -> kernel demand-
# paged it -> sret BACK to the SAME mid-word target -> skip_low LOST on the
# re-fetch -> fetched 0x101bc (=entry-2) = c.ebreak -> SIGTRAP -> init killed.
#
# This test mirrors that exactly:
#   - Sv39 identity map, but the page holding `vtarget` (0x8000_8000) is left
#     INVALID initially.
#   - mret to S-mode at vtarget (mod4==2) -> instruction page fault (cause=12).
#   - The M-mode handler maps the page and mret's BACK to vtarget (re-fetch).
#   - If the re-fetch skids to the low halfword, c.ebreak (at vtarget-2) traps
#     (cause=3) -> FAIL; correct skip_low runs vtarget's c.nop -> DONE.
#
#   make skid_ptwfault_test  &&  (cd ../sim && rm -rf out/vl_boot && make vl_boot \
#     BOOT_HEX=../software/boot/skid_ptwfault_test.hex BOOT_MAX=2000000)
# =============================================================================
    .equ TOHOST,     0x80002000
    .equ DONE_MAGIC, 0x00C0FFEE
    .equ FAIL_MAGIC, 0x0BADBAD0
    .equ PTE_LEAF,   0xCF              # V R W X A D (U=0: supervisor page)
    .equ PTE_PTR,    0x01              # V only (non-leaf pointer)
    .equ VPAGE,      0x80001000        # the (initially invalid) target page
    .equ VIDX,       1                 # l0_table index of VPAGE ((VPAGE>>12)&511)

    .section .text
    .globl _start
_start:
    la      t0, mtrap
    csrw    mtvec, t0

    li      t0, -1
    csrw    pmpaddr0, t0
    li      t0, 0x1F
    csrw    pmpcfg0, t0

    call    build_pt

    # Leave VPAGE invalid so the first fetch there page-faults (demand paging).
    la      t0, l0_table
    sd      zero, (VIDX*8)(t0)
    sfence.vma

    # drop to S-mode at vtarget (mod4==2) in the invalid page.
    csrr    t0, mstatus
    li      t1, ~(3 << 11)
    and     t0, t0, t1
    li      t1, (1 << 11)             # MPP = S
    or      t0, t0, t1
    csrw    mstatus, t0
    la      t0, vtarget
    csrw    mepc, t0
    mret

    j       fail

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
    sd      t1, 16(t0)

    la      t1, l2_table
    srli    t1, t1, 12
    li      t2, 8
    slli    t2, t2, 60
    or      t1, t1, t2
    csrw    satp, t1
    sfence.vma
    ret

# -----------------------------------------------------------------------------
# M-mode trap handler.  cause=12 (instruction page fault) at the target = demand
# page: map VPAGE and re-execute (mret).  Any other trap (notably cause=3, the
# mis-fetched c.ebreak) = FAIL.  disc@0x2004=mcause, A@0x2008=mepc.
# -----------------------------------------------------------------------------
    .balign 4
mtrap:
    csrr    t0, mcause
    li      t1, 12                    # instruction page fault
    bne     t0, t1, mfail

    # map VPAGE (l0_table[VIDX] = leaf PTE), then re-execute the faulting fetch.
    la      t2, l0_table
    li      t3, VPAGE
    srli    t3, t3, 12
    slli    t3, t3, 10
    li      t4, PTE_LEAF
    or      t3, t3, t4
    sd      t3, (VIDX*8)(t2)
    sfence.vma
    mret

mfail:
    li      t2, 0x80002004
    csrr    t0, mcause
    sw      t0, 0(t2)
    csrr    t0, mepc
    sw      t0, 4(t2)
    li      t0, TOHOST
    li      t1, FAIL_MAGIC
    sw      t1, 0(t0)
1:  j       1b

# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# The mid-word redirect target, placed at the start of its own (initially
# invalid) page VPAGE (0x8000_1000 = the page after the <4 KiB code page).
# c.ebreak sits at VPAGE (mod4==0); vtarget at VPAGE+2 (mod4==2).
# -----------------------------------------------------------------------------
    .balign 4096                      # -> 0x8000_1000 (page after the code page)
    .2byte  0x9002                    # c.ebreak  @ VPAGE   (mod4==0, WRONG)
vtarget:                              # @ VPAGE+2 (mod4==2, the real target)
    .2byte  0x0001                    # c.nop
    j       spass

    .section .bss
    .balign 0x10000
l2_table:   .skip 4096
l1_table:   .skip 4096
l0_table:   .skip 4096
