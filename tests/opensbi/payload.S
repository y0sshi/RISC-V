# =============================================================================
# payload.S - Tiny S-mode payload for OpenSBI fw_payload (sim boot test)
# =============================================================================
# OpenSBI (M-mode) initializes, prints its banner over the NS16550 UART (via the
# DTB), then drops to S-mode and jumps here.  This payload:
#   1. prints a line via the SBI legacy console_putchar ecall (a7=1), proving the
#      M<->S SBI console path on top of real OpenSBI, and
#   2. writes the completion sentinel the boot harness watches, then parks.
# No stack / no S-mode interrupts are used, so it cannot corrupt OpenSBI before
# the sentinel write (the sentinel is written only after all ecalls complete).
#
# Linked at FW_TEXT_START + FW_PAYLOAD_OFFSET = 0x8000_0000 + 0x20_0000.
# =============================================================================

    # FW_BASE selects the firmware/DDR base (= RST_ADDR = BFM BASE_ADDR).  The
    # default 0x8000_0000 keeps every prior artifact byte-identical; pass
    # -DFW_BASE=0x00200000 (build.sh FW_BASE=...) to re-link for the real-HW
    # PS-DDR base.  TOHOST is base + 0x2000 (matches tb_rv_boot_soc TOHOST_OFF).
#ifndef FW_BASE
#define FW_BASE 0x80000000
#endif
    .equ TOHOST,     (FW_BASE + 0x2000)
    .equ DONE_MAGIC, 0x00C0FFEE
    .equ SBI_PUTCHAR, 1            # legacy console_putchar (EID 0x01)

    .section .text
    .globl _start
_start:
    la      a3, msg
1:  lbu     a0, 0(a3)
    beqz    a0, 2f
    li      a7, SBI_PUTCHAR
    ecall                          # SBI console putchar -> OpenSBI -> UART
    addi    a3, a3, 1
    j       1b
2:
    li      t0, TOHOST
    li      t1, DONE_MAGIC
    sw      t1, 0(t0)              # completion sentinel for the harness
    fence
3:  wfi
    j       3b

    .section .rodata
msg:
    .string "PAYLOAD: hello from S-mode via real OpenSBI\n"
