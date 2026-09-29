// =============================================================================
// crt_act.S - Minimal startup for riscv-arch-test / riscv-tests
// =============================================================================
// ACT/riscv-tests do NOT call main(). Test body runs directly from .text.init.
// This file performs only minimal setup before falling through to test code.
// =============================================================================

    .section .text.init, "ax", @progbits
    .global _start
    .type   _start, @function

_start:
    // -------------------------------------------------------------------------
    // 1. Disable all interrupts
    // -------------------------------------------------------------------------
    csrw    mie, zero
    csrw    mip, zero

    // -------------------------------------------------------------------------
    // 2. Set mtvec to trap handler
    // -------------------------------------------------------------------------
    la      t0, _trap_handler
    csrw    mtvec, t0

    // -------------------------------------------------------------------------
    // 3. Enable FPU (mstatus.FS = 01 Initial)
    //    Required for F/D extension tests
    // -------------------------------------------------------------------------
    li      t0, (1 << 13)
    csrs    mstatus, t0
    csrw    fcsr, zero

    // -------------------------------------------------------------------------
    // 4. Set stack pointer
    // -------------------------------------------------------------------------
    la      sp, _stack_top

    // -------------------------------------------------------------------------
    // 5. Zero-clear .bss (RV64: 8-byte stride)
    // -------------------------------------------------------------------------
    la      a0, _bss_start
    la      a1, _bss_end
    bgeu    a0, a1, .Ltest_start

.Lzero_bss:
    sd      zero, 0(a0)
    addi    a0, a0, 8
    bltu    a0, a1, .Lzero_bss

    // -------------------------------------------------------------------------
    // 6. Fall through to test body
    //    Test code is concatenated after this in .text.init
    // -------------------------------------------------------------------------
.Ltest_start:

// =============================================================================
// _trap_handler: trap dispatcher
//   Distinguish ECALL (test-end signal) from real exceptions
// =============================================================================
    .global _trap_handler
    .align  2

_trap_handler:
    csrr    t0, mcause
    li      t1, 11
    beq     t0, t1, .Lhandle_ecall // Machine ECALL

    // Other exception: report failure via tohost
    li      t0, 1
    la      t1, tohost
    sd      t0, 0(t1)
.Ltrap_loop:
    j       .Ltrap_loop

.Lhandle_ecall:
    // a0 = test result (0 = PASS, non-zero = FAIL number)
    // gp (x3) may also hold test number (riscv-tests convention)
    li      t0, 1
    la      t1, tohost
    sd      t0, 0(t1)
1:  j       1b

// =============================================================================
// Weak _halt symbol
//   Used when test code does not override
// =============================================================================
    .weak   _halt
    .global _halt

_halt:
    li      t0, 1
    la      t1, tohost
    sd      t0, 0(t1)
1:  j       1b

