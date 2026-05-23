/* =============================================================================
 * link.ld - Linker Script for RISC-V Test Programs
 * =============================================================================
 * Simple linker script placing code at address 0x0 and data at 0x10000.
 * Suitable for simulation with separate instruction and data memories.
 * ===========================================================================*/

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    DMEM (rwx) : ORIGIN = 0x00010000, LENGTH = 16K
}

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text)
        *(.text.*)
    } > IMEM

    .rodata : {
        *(.rodata)
        *(.rodata.*)
    } > IMEM

    .data : {
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    } > DMEM

    .bss : {
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        __bss_end = .;
    } > DMEM

    /* Stack at top of DMEM */
    __stack_top = ORIGIN(DMEM) + LENGTH(DMEM);
}
