# =============================================================================
# callfault_test.S - JAL / sequential fetch into a demand-paged (invalid) page.
#
# Reproducer for RTL bug #17 (fetch/PTW livelock on a demand-paged CALL target;
# memory userspace-compiled-binary-bug, second bug).  Linux userspace (musl
# busybox) called memset() in a not-yet-mapped text page: the JAL's redirect
# target INSTRUCTION-PAGE-FAULTED, but the JAL itself was held in EX by the
# ~imem_ready full-pipeline freeze (the dead fetch never raises imem_ready), so
# branch_taken_ex kept redir_eff high forever and the fault could neither latch
# nor be taken -> the MMU re-walked the dead VA forever (livelock: PC frozen at
# the target, ~3 PTW reads / 17 cycles, zero retires, interrupts undeliverable).
# The mret/sret variant (skid_ptwfault_test) does NOT catch this: an xRET's
# redirect source leaves EX on its commit cycle, so the fault gates reopen.
#
# Three phases (M-mode handler demand-maps the faulting page from mtval):
#   1. jal to a word-aligned target in an invalid page; verify ra AND the
#      return value (the held JAL must RETIRE - its ra write must land - before
#      the fault is taken).
#   2. jal to a mod4==2 target in an invalid page (bug #1 skip_low interaction:
#      sepc/mtval must be the mid-word target, and the re-fetch must not skid).
#   3. straight-line execution crossing from a mapped page into an invalid page
#      (fault with LIVE older instructions in the buffer/pipe: they must drain
#      and retire EXACTLY ONCE - a c.addi counting chain crossing the boundary
#      detects both a lost and a double-executed instruction).
#
#   make callfault_test  &&  (cd ../sim && rm -rf out/vl_boot && make vl_boot \
#     BOOT_HEX=../software/boot/callfault_test.hex BOOT_MAX=2000000)
#
# Old RTL: livelock at phase 1 (timeout, no sentinel).  Fixed RTL: DONE_MAGIC.
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

    li      t0, -1
    csrw    pmpaddr0, t0
    li      t0, 0x1F
    csrw    pmpcfg0, t0

    call    build_pt

    # Leave the three victim pages invalid (demand paging):
    #   0x80001000 (idx 1) phase-1 aligned call target
    #   0x80003000 (idx 3) phase-2 mid-word call target
    #   0x80005000 (idx 5) phase-3 sequential-crossing continuation
    la      t0, l0_table
    sd      zero, (1*8)(t0)
    sd      zero, (3*8)(t0)
    sd      zero, (5*8)(t0)
    sfence.vma

    # drop to S-mode at smain (mapped page 0)
    csrr    t0, mstatus
    li      t1, ~(3 << 11)
    and     t0, t0, t1
    li      t1, (1 << 11)             # MPP = S
    or      t0, t0, t1
    csrw    mstatus, t0
    la      t0, smain
    csrw    mepc, t0
    mret

    j       sfail

# -----------------------------------------------------------------------------
# S-mode main: the three call/fall-through phases.
# -----------------------------------------------------------------------------
smain:
    # Phase 1: word-aligned jal into the invalid page.  The JAL is held in EX
    # while its target's fetch faults; it must still retire (ra written) and the
    # fault must be taken with sepc/mtval = the target.
    jal     ra, vfunc1
retpoint1:
    la      t0, retpoint1
    bne     ra, t0, sfail             # held JAL lost its link write
    li      t1, 0x111
    bne     a0, t1, sfail

    # Phase 2: mid-word (mod4==2) jal into the invalid page (bug #1 interaction).
    jal     ra, vfunc2
    li      t1, 0x222
    bne     a0, t1, sfail

    # Phase 3: sequential fall-through into the invalid page with live older
    # instructions draining (the c.addi chain counts exactly once each).
    jal     ra, p4entry
    li      t1, 0x300 + 16
    bne     a0, t1, sfail

    j       spass

sfail:
    li      t0, TOHOST
    li      t1, FAIL_MAGIC
    sw      t1, 0(t0)
1:  j       1b

spass:
    li      t0, TOHOST
    li      t1, DONE_MAGIC
    sw      t1, 0(t0)
1:  j       1b

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
# M-mode trap handler: cause=12 (instruction page fault) = demand paging.  Map
# the page holding mtval (identity leaf) and re-execute.  Anything else = FAIL
# (disc@0x2004=mcause, @0x2008=mepc).
# -----------------------------------------------------------------------------
    .balign 4
mtrap:
    csrr    t0, mcause
    li      t1, 12                    # instruction page fault
    bne     t0, t1, mfail

    csrr    t3, mtval                 # faulting VA
    srli    t4, t3, 12                # VPN (identity: also the PPN)
    andi    t5, t4, 511               # l0 index
    slli    t5, t5, 3
    la      t2, l0_table
    add     t2, t2, t5
    slli    t4, t4, 10
    ori     t4, t4, PTE_LEAF
    sd      t4, 0(t2)
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
# Page 1 (0x8000_1000, initially INVALID): phase-1 aligned call target.
# -----------------------------------------------------------------------------
    .balign 4096                      # -> 0x8000_1000
vfunc1:
    li      a0, 0x111
    ret

# -----------------------------------------------------------------------------
# Page 2 (0x8000_2000) intentionally left empty: TOHOST lives at its base.
# Page 3 (0x8000_3000, initially INVALID): phase-2 mid-word call target.
# c.ebreak at the word base catches a 2-byte fetch skid (bug #1 style).
# -----------------------------------------------------------------------------
    .balign 4096                      # -> 0x8000_2000 (skip the TOHOST page)
    .skip   4096                      # -> 0x8000_3000 (no code in the TOHOST page)
    .2byte  0x9002                    # c.ebreak @ page base (mod4==0, WRONG)
vfunc2:                               # @ base+2 (mod4==2, the real target)
    li      a0, 0x222
    ret

# -----------------------------------------------------------------------------
# Page 4 (0x8000_4000, mapped): phase-3 runway.  A c.addi counting chain ends
# exactly at the page boundary; page 5 (INVALID) continues it.  The fault fires
# with the tail of the chain still in the fetch buffer / pipeline - those
# instructions must retire exactly once while the fault is pending.
# -----------------------------------------------------------------------------
    .balign 4096                      # -> 0x8000_4000
p4entry:
    .option push
    .option norvc                     # force the j to 4 bytes (fixed layout)
    j       p4tail
    .option pop
    .skip   0xFE0 - 4                 # -> page 4 offset 0xFE0
p4tail:
    li      a0, 0x300                 # 4 bytes -> chain starts at +0xFE4
    .rept   14                        # 14 * 2 bytes -> ends exactly at +0x1000
    c.addi  a0, 1
    .endr
# ---- page 5 (0x8000_5000, initially INVALID): chain continues + return ------
    .rept   2
    c.addi  a0, 1
    .endr
    ret

    .section .bss
    .balign 0x10000
l2_table:   .skip 4096
l1_table:   .skip 4096
l0_table:   .skip 4096
