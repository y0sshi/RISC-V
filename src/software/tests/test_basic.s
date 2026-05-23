# =============================================================================
# test_basic.s - Basic RV32I instruction tests
# =============================================================================
# A simple hand-written test program to verify basic instruction execution.
# Returns 0 in a0 (x10) on success, non-zero on failure.
# Terminates with ECALL.
# =============================================================================

    .text
    .globl _start

_start:
    # --------------------------------------------------
    # Test 1: ADDI
    # --------------------------------------------------
    addi x1, x0, 10        # x1 = 10
    addi x2, x0, 20        # x2 = 20

    # --------------------------------------------------
    # Test 2: ADD
    # --------------------------------------------------
    add  x3, x1, x2        # x3 = 10 + 20 = 30
    addi x4, x0, 30        # x4 = 30 (expected)
    bne  x3, x4, fail      # if x3 != 30, fail

    # --------------------------------------------------
    # Test 3: SUB
    # --------------------------------------------------
    sub  x5, x2, x1        # x5 = 20 - 10 = 10
    bne  x5, x1, fail      # if x5 != 10, fail

    # --------------------------------------------------
    # Test 4: AND, OR, XOR
    # --------------------------------------------------
    addi x6, x0, 0x0F      # x6 = 0x0F
    addi x7, x0, 0x33      # x7 = 0x33
    and  x8, x6, x7        # x8 = 0x03
    addi x9, x0, 0x03      # expected
    bne  x8, x9, fail

    or   x8, x6, x7        # x8 = 0x3F
    addi x9, x0, 0x3F      # expected
    bne  x8, x9, fail

    xor  x8, x6, x7        # x8 = 0x3C
    addi x9, x0, 0x3C      # expected
    bne  x8, x9, fail

    # --------------------------------------------------
    # Test 5: SLL, SRL, SRA
    # --------------------------------------------------
    addi x10, x0, 1        # x10 = 1
    slli x11, x10, 4       # x11 = 16
    addi x12, x0, 16       # expected
    bne  x11, x12, fail

    addi x10, x0, -16      # x10 = 0xFFFFFFF0
    srai x11, x10, 4       # x11 = 0xFFFFFFFF (-1)
    addi x12, x0, -1       # expected
    bne  x11, x12, fail

    # --------------------------------------------------
    # Test 6: LUI
    # --------------------------------------------------
    lui  x13, 0x12345       # x13 = 0x12345000
    srli x14, x13, 12      # x14 = 0x12345
    lui  x15, 0x00012       # x15 = 0x00012000
    addi x15, x15, 0x345   # x15 = 0x12345
    bne  x14, x15, fail

    # --------------------------------------------------
    # Test 7: JAL
    # --------------------------------------------------
    jal  x1, jal_target
    j    fail               # should not reach here

jal_target:
    # x1 should contain the return address (address of `j fail` above)

    # --------------------------------------------------
    # PASS
    # --------------------------------------------------
    addi x10, x0, 0        # a0 = 0 (PASS)
    ecall                   # terminate

fail:
    addi x10, x0, 1        # a0 = 1 (FAIL)
    ecall                   # terminate
