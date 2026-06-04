# =============================================================================
# sbi_boot.S - Minimal "mini-SBI" boot firmware (OpenSBI stand-in) for sim
# =============================================================================
# Exercises, over a single SHARED DDR image reached through the I$/D$ + AXI path,
# the essential boot flow that real OpenSBI performs:
#   1. M-mode entry at RST_ADDR (0x8000_0000), set up the M trap vector.
#   2. Open PMP (region 0 = all RWX, NAPOT) so S/U may run.
#   3. Print a banner directly over the UART (M-mode console).
#   4. Drop to S-mode via MRET (mstatus.MPP = S, mepc = smain).
#   5. S-mode prints a string by issuing SBI-style ECALLs; each ECALL traps to
#      the M-mode handler (mcause=9) which does the UART putchar -- i.e. the
#      SBI console path M<->S.
#   6. S-mode issues an SBI "done" ECALL; the M handler writes a completion
#      sentinel to the tohost word and parks.  The testbench detects it.
#
# Build (RV64, no RVC needed but the core/I$ handle it either way):
#   riscv64-unknown-elf-gcc -march=rv64imac_zicsr -mabi=lp64 \
#       -nostdlib -nostartfiles -ffreestanding -T boot.ld sbi_boot.S -o sbi_boot.elf
#   riscv64-unknown-elf-objcopy -O verilog --adjust-vma=-0x80000000 \
#       sbi_boot.elf sbi_boot.hex
# =============================================================================

    .equ UART_BASE,   0xC0010000      # NS16550: THR=+0, LSR=+0x14
    .equ UART_LSR,    0x14            # line status register offset
    .equ LSR_THRE,    0x20            # TX holding empty (bit5)
    .equ TOHOST,      0x80002000      # completion sentinel word
    .equ DONE_MAGIC,  0x00C0FFEE
    .equ SBI_PUTCHAR, 1
    .equ SBI_DONE,    2

    .section .text
    .globl _start
_start:
    # ---- M trap vector ----
    la      t0, mtrap
    csrw    mtvec, t0

    # ---- PMP region 0 = all address space, RWX (NAPOT) ----
    li      t0, -1
    csrw    pmpaddr0, t0
    li      t0, 0x1F                  # A=NAPOT(11) | X | W | R
    csrw    pmpcfg0, t0

    # ---- M-mode banner (direct UART) ----
    la      a1, msg_m
1:  lbu     a0, 0(a1)
    beqz    a0, 2f
    li      t3, UART_BASE
3:  lw      t4, UART_LSR(t3)          # LSR
    andi    t4, t4, LSR_THRE          # THR empty?
    beqz    t4, 3b
    sw      a0, 0(t3)                 # THR <- char
    addi    a1, a1, 1
    j       1b
2:

    # ---- set mstatus.MPP = S (01), mepc = smain, then MRET ----
    csrr    t0, mstatus
    li      t1, ~(3 << 11)           # clear MPP[12:11]
    and     t0, t0, t1
    li      t1, (1 << 11)            # MPP = 01 (Supervisor)
    or      t0, t0, t1
    csrw    mstatus, t0
    la      t0, smain
    csrw    mepc, t0
    mret

# -----------------------------------------------------------------------------
# M-mode trap handler: SBI-style ECALL service
# -----------------------------------------------------------------------------
    .align 4
mtrap:
    csrr    t0, mcause
    li      t1, 9                     # environment call from S-mode
    bne     t0, t1, mfail

    li      t1, SBI_PUTCHAR
    beq     a7, t1, do_putchar
    li      t1, SBI_DONE
    beq     a7, t1, do_done
    j       mret_skip                 # unknown call: just return

do_putchar:
    li      t3, UART_BASE
4:  lw      t4, UART_LSR(t3)
    andi    t4, t4, LSR_THRE
    beqz    t4, 4b
    sw      a0, 0(t3)                 # putchar(a0) -> THR
    j       mret_skip

do_done:
    li      t0, TOHOST
    li      t1, DONE_MAGIC
    sw      t1, 0(t0)                 # signal completion to the testbench
5:  wfi
    j       5b                        # park

mret_skip:
    csrr    t0, mepc
    addi    t0, t0, 4                 # skip the ECALL instruction
    csrw    mepc, t0
    mret

mfail:
    li      t0, TOHOST
    li      t1, 0x0BADBAD0
    sw      t1, 0(t0)
6:  wfi
    j       6b

# -----------------------------------------------------------------------------
# S-mode entry: print a string via SBI ECALLs, then SBI "done"
# -----------------------------------------------------------------------------
    .align 4
smain:
    la      s0, msg_s
7:  lbu     a0, 0(s0)
    beqz    a0, 8f
    li      a7, SBI_PUTCHAR
    ecall                            # -> M handler -> UART
    addi    s0, s0, 1
    j       7b
8:
    li      a7, SBI_DONE
    ecall                            # -> M handler -> sentinel + park
9:  j       9b

    .section .rodata
msg_m:
    .string "M: mini-SBI boot, PMP set, entering S-mode\n"
msg_s:
    .string "S: hello from supervisor via SBI ecall console\nBOOT OK\n"
