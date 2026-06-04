/* boot.ld - flat link for the mini-SBI boot firmware at DDR base 0x8000_0000.
 * Code, rodata and a small stack all live in the shared DDR image. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    DDR (rwx) : ORIGIN = 0x80000000, LENGTH = 1M
}

SECTIONS {
    . = 0x80000000;
    .text   : { *(.text*) }   > DDR
    .rodata : { *(.rodata*) } > DDR
    .data   : { *(.data*) }   > DDR
    .bss    : { *(.bss*) *(COMMON) } > DDR
    . = ALIGN(16);
    _end = .;
}
