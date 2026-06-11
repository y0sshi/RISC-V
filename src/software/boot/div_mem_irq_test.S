# =============================================================================
# div_mem_irq_test.S - loads/stores ADJACENT to multi-cycle divides vs IRQ
# =============================================================================
# Hypothesis for the C-2a Linux regression (WARN storm @65M, looks like a
# corrupted pointer): the divide's multi-cycle EX stall corrupts an in-flight
# load/store result (a load in MEM/WB or a store re-issuing) when a timer
# interrupt also lands near the divide.  div_irq_test only checks divide
# RESULTS (which are correct); this checks LOADED/STORED values across divides.
#
# Each iteration stresses all orderings:
#   ld  -> divide       (load in EX/MEM when the divide enters EX)
#   divide -> ld        (load right after a divide retires)
#   sd  -> divide -> ld (store then read back across a divide)
# Every loaded value is compared to its known golden; any mismatch -> fail.
# Timer interrupts sweep (absolute schedule, coprime STEP); the handler runs
# divides AND memory ops of its own.
#
# Run:  make div_mem_irq_test  &&  (cd ../sim && make vl_boot \
#   BOOT_HEX=../software/boot/div_mem_irq_test.hex)
# =============================================================================

    .equ CLINT_MTIMECMP, 0xC0004000
    .equ CLINT_MTIME,    0xC000BFF8
    .equ TOHOST,         0x80002000
    .equ DONE_MAGIC,     0x00C0FFEE
    .equ FAIL_MAGIC,     0x0BADBAD0
    .equ N,              5000
    .equ PERIOD,         400
    .equ STEP,           397          # coprime sweep

    .equ BUF,            0x80020000    # data buffer
    .equ HBUF,           0x80020800    # handler's private buffer
    .equ VAL_A,          0x1122334455667788
    .equ VAL_B,          0xCAFEF00DDEADBEEF

    .section .text
    .globl _start
_start:
    la      t0, mtrap
    csrw    mtvec, t0

    li      s1, 0x80020100            # K: handler interrupt count
    sd      zero, 0(s1)

    # buffer: [0]=VAL_A, [8]=VAL_B
    li      s2, BUF
    li      s9, VAL_A
    li      s10, VAL_B
    sd      s9,  0(s2)
    sd      s10, 8(s2)

    # divide operands + golden quotient
    li      s7, 0x0000123456789ABC
    li      s8, 0x0000000000010007
    divu    s11, s7, s8              # golden quotient (interrupts off)

    # ---- arm CLINT timer (absolute schedule) --------------------------------
    li      t1, CLINT_MTIME
    ld      t2, 0(t1)
    li      t3, PERIOD
    add     s5, t2, t3
    li      t1, CLINT_MTIMECMP
    sd      s5, 0(t1)

    li      t0, (1 << 7)             # mie.MTIE
    csrs    mie, t0
    li      t0, (1 << 3)             # mstatus.MIE
    csrs    mstatus, t0

    li      s3, N
    li      s4, 0                    # i

loop:
    # --- ld -> divide: load V then immediately divide (load in EX/MEM at start)
    ld      t1, 0(s2)                # t1 = VAL_A
    divu    t4, s7, s8               # multi-cycle divide right after the load
    bne     t1, s9, fail             # load result must survive
    bne     t4, s11, fail            # quotient must be correct

    # --- divide -> ld: divide then load (load right after divide retires)
    divu    t5, s7, s8
    ld      t2, 8(s2)                # t2 = VAL_B
    bne     t5, s11, fail
    bne     t2, s10, fail

    # --- sd -> divide -> ld: store, divide, read back across the divide
    sd      s9, 16(s2)               # store VAL_A to [16]
    divu    t6, s7, s8
    ld      t3, 16(s2)               # read it back
    bne     t6, s11, fail
    bne     t3, s9, fail

    addi    s4, s4, 1
    blt     s4, s3, loop

    li      t0, (1 << 3)
    csrc    mstatus, t0
    ld      t2, 0(s1)                # K
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
# M-mode trap handler: divides + memory ops, count, re-arm.  Uses a0..a6.
# -----------------------------------------------------------------------------
    .align 4
mtrap:
    li      a0, HBUF
    li      a1, 0x0F0F0F0F0F0F0F0F
    sd      a1, 0(a0)                # handler store
    li      a5, 0x00000000DEADBEEF
    li      a6, 0x0000000000000101
    divu    a2, a5, a6               # handler divides (dirty div_result)
    rem     a2, a5, a6
    ld      a3, 0(a0)                # handler load right after divides
    # (a3 is just exercised; not checked here)

    ld      a3, 0(s1)               # K++
    addi    a3, a3, 1
    sd      a3, 0(s1)

    li      a4, STEP
    add     s5, s5, a4
    li      a2, CLINT_MTIMECMP
    sd      s5, 0(a2)
    mret
