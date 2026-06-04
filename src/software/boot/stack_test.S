# =============================================================================
# stack_test.S - Minimal reproduction of the variable-latency stack bug
# =============================================================================
# Hammers the function prologue/epilogue pattern (sd ra/s0 ; recursive call ;
# ld ra/s0 ; ret) that corrupts the stack pointer in OpenSBI under the AXI/cache
# (variable-latency) memory path -- but small and fast so it iterates quickly in
# tb_rv_boot_soc.  Computes a recursive sum 1..N and writes the harness sentinel
# (DONE on the correct result, FAIL otherwise).
# =============================================================================

    .equ TOHOST,     0x80002000
    .equ DONE_MAGIC, 0x00C0FFEE
    .equ FAIL_MAGIC, 0x0BADBAD0
    .equ NREC,       20
    .equ EXPECT,     210            # 1+2+...+20

    .section .text
    .globl _start
_start:
    li      sp, 0x80010000          # stack top (in DDR, above code)
    li      a0, NREC
    call    rec                     # a0 = rec(NREC)
    li      t0, EXPECT
    li      t1, TOHOST
    bne     a0, t0, 1f
    li      t2, DONE_MAGIC
    sw      t2, 0(t1)
    j       2f
1:  li      t2, FAIL_MAGIC
    sw      t2, 0(t1)
2:  wfi
    j       2b

# rec(n): if (n==0) return 0; else return n + rec(n-1)
rec:
    addi    sp, sp, -16
    sd      ra, 8(sp)
    sd      s0, 0(sp)
    mv      s0, a0                  # s0 = n  (callee-saved across the recursive call)
    beqz    a0, 3f
    addi    a0, a0, -1
    call    rec                     # a0 = rec(n-1)
    add     a0, a0, s0              # a0 = rec(n-1) + n
    j       4f
3:  li      a0, 0
4:  ld      ra, 8(sp)
    ld      s0, 0(sp)
    addi    sp, sp, 16
    ret
