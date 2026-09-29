/* boot.ld - flat link for the mini-SBI boot firmware.
 * Code, rodata and a small stack all live in the shared DDR image.
 *
 * The link base defaults to the sim DDR base 0x8000_0000.  Override it for the
 * Zybo PS-DDR boot with:  -Wl,--defsym,__BASE=0x00200000  (and a matching
 * -DFW_BASE / objcopy --adjust-vma).  ORIGIN inside MEMORY{} cannot reference a
 * symbol, so placement is driven directly by `. = __BASE` (a plain relocatable
 * SECTIONS without a constrained MEMORY region -> identical default output). */
OUTPUT_ARCH("riscv")
ENTRY(_start)

__BASE = DEFINED(__BASE) ? __BASE : 0x80000000;

SECTIONS {
    . = __BASE;
    .text   : { *(.text*) }
    .rodata : { *(.rodata*) }
    .data   : { *(.data*) }
    .bss    : { *(.bss*) *(COMMON) }
    . = ALIGN(16);
    _end = .;
}
