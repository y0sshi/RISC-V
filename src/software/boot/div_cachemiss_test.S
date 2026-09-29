# =============================================================================
# div_cachemiss_test.S - divide entering EX while a prior load/store is stalled
# =============================================================================
# Targets the suspected C-2a corruption: muldiv_valid_in fires WITHOUT checking
# stall_ex, so a divide can "start" (FSM -> busy) on a cycle stall_ex is already
# held by a PRIOR load/store's dmem_wait (a D-cache MISS).  On that cycle the
# EX/MEM bubble is NOT inserted (the bubble lives in the !stall_ex branch), so
# the held load/store can be re-captured into MEM/WB repeatedly while the divide
# runs -> duplicate retire / re-issued access.  Cache hits (div_mem_irq_test)
# never set dmem_wait, so this needs MISSES.
#
# Strategy: stride through a buffer LARGER than the D-cache, line by line, so
# every access misses (dmem_wait), with a divide immediately after each
# load/store.  Store a unique pointer-like value per line, then read every line
# back and verify -- a duplicate/min-stretched store or a corrupted load shows
# up as a mismatch.  Timer interrupts also sweep in.
#
# Run:  make div_cachemiss_test  &&  (cd ../sim && make vl_boot \
#   BOOT_HEX=../software/boot/div_cachemiss_test.hex)
# =============================================================================

    .equ CLINT_MTIMECMP, 0xC0004000
    .equ CLINT_MTIME,    0xC000BFF8
    .equ TOHOST,         0x80002000
    .equ DONE_MAGIC,     0x00C0FFEE
    .equ FAIL_MAGIC,     0x0BADBAD0
    .equ BUF,            0x80100000    # large buffer base (well above code/stack)
    .equ LINES,          512           # 512 * 64B = 32 KiB > 16 KiB D-cache
    .equ STRIDE,         64            # cache line bytes
    .equ PASSES,         8             # repeat the whole sweep
    .equ PERIOD,         400
    .equ STEP,           397
    # pointer-like base (lowmem-ish), so a 1-bit flip is detectable
    .equ PTRBASE,        0xffffffd600000000

    .section .text
    .globl _start
_start:
    la      t0, mtrap
    csrw    mtvec, t0
    li      s1, 0x800F0000           # K (handler count), above BUF? no -> below BUF
    li      s1, 0x80020100
    sd      zero, 0(s1)

    li      s7, 0x0000123456789ABC   # divide operands
    li      s8, 0x0000000000010007
    divu    s11, s7, s8              # golden quotient

    # arm timer
    li      t1, CLINT_MTIME
    ld      t2, 0(t1)
    li      t3, PERIOD
    add     s5, t2, t3
    li      t1, CLINT_MTIMECMP
    sd      s5, 0(t1)
    li      t0, (1 << 7)
    csrs    mie, t0
    li      t0, (1 << 3)
    csrs    mstatus, t0

    li      s9, PTRBASE
    li      s6, PASSES               # pass counter

pass_loop:
    # ---- WRITE phase: store PTRBASE+(line*STRIDE) at BUF+line*STRIDE -----
    li      s2, BUF
    li      s3, LINES
    li      s4, 0
    mv      s10, s9                  # value to store (PTRBASE + line index *64)
wloop:
    sd      s10, 0(s2)               # store (MISS -> dmem_wait), then divide
    divu    t2, s7, s8               # divide starts while the store may dmem_wait
    bne     t2, s11, fail
    addi    s2, s2, STRIDE
    addi    s10, s10, STRIDE
    addi    s4, s4, 1
    blt     s4, s3, wloop

    # ---- READ phase: read back each line, verify == PTRBASE+line*STRIDE --
    li      s2, BUF
    li      s4, 0
    mv      s10, s9
rloop:
    ld      t1, 0(s2)                # load (MISS -> dmem_wait), then divide
    divu    t3, s7, s8               # divide starts while the load may dmem_wait
    bne     t3, s11, fail
    bne     t1, s10, fail            # the loaded pointer must be exact
    addi    s2, s2, STRIDE
    addi    s10, s10, STRIDE
    addi    s4, s4, 1
    blt     s4, s3, rloop

    addi    s6, s6, -1
    bnez    s6, pass_loop

    li      t0, (1 << 3)
    csrc    mstatus, t0
    ld      t2, 0(s1)
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

    .align 4
mtrap:
    li      a5, 0x00000000DEADBEEF
    li      a6, 0x0000000000000101
    divu    a2, a5, a6
    rem     a2, a5, a6
    ld      a3, 0(s1)
    addi    a3, a3, 1
    sd      a3, 0(s1)
    li      a4, STEP
    add     s5, s5, a4
    li      a2, CLINT_MTIMECMP
    sd      s5, 0(a2)
    mret
