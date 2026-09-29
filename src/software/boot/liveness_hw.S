# =============================================================================
# liveness_hw.S - minimal "is the RISC-V core fetching/executing from DDR" probe
# =============================================================================
# Purpose: a real-HW bring-up sanity check that depends on NOTHING except the
# core fetching its own instructions from PS-DDR (over m_axi_if -> S_AXI_HP0) and
# completing a store back to DDR (over m_axi).  No UART, no CSRs/traps, no MMU, no
# peripherals -- so if its markers appear, the core + FCLK clock + reset + the AXI
# fetch/store paths are all proven good, and any remaining boot failure is OpenSBI-
# or UART-specific.  If the markers do NOT appear, the failure is fundamental
# (clock/reset/fetch) and there is no point chasing the UART further.
#
# Link at the PS-DDR firmware base 0x0020_0000 (RST_ADDR) with
#   -Wl,--defsym,__BASE=0x00200000   (boot.ld).
# Load over JTAG with `dow liveness_hw.elf`, configure the PL, then:
#   mrd 0x00300000 2      ; expect 0x600D600D and a large, CHANGING counter
# Read 0x300004 twice a second apart -- if it advances, the core is alive & looping.
# =============================================================================

    .equ MARK,  0x00300000      # scratch DDR addr, clear of the tiny .text @0x200000
    .equ MAGIC, 0x600D600D      # recognizable "good" pattern

    .section .text
    .globl _start
_start:
    li    t0, MARK
    li    t1, MAGIC
    sw    t1, 0(t0)             # 0x300000 = MAGIC  (proves a store reached DDR)
    li    t2, 0
1:  addi  t2, t2, 1
    sw    t2, 4(t0)            # 0x300004 = free-running counter (proves it loops)
    j     1b
