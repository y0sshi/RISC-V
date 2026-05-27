/* =============================================================================
 * link_act.ld - Linker Script for riscv-arch-test / riscv-tests
 * =============================================================================
 * Unified memory layout (IMEM/DMEM merged)
 *   RAM : 0x8000_0000, 256 KB
 *
 * Section layout:
 *   .text.init -> 0x8000_0000 (entry point)
 *   .text      -> instructions
 *   .rodata    -> read-only data
 *   .data      -> initialized data
 *   .bss       -> zero-initialized data
 *   .tohost    -> 0x8000_1000 (monitored by TB, fixed address)
 *   .signature -> signature region (begin_signature .. end_signature)
 * =============================================================================
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 256K
}

SECTIONS {
    . = 0x80000000;

    .text.init : ALIGN(4) {
        KEEP(*(.text.init))
    } > RAM

    .text : ALIGN(4) {
        *(.text*)
    } > RAM

    .rodata : ALIGN(8) {
        *(.rodata*)
        *(.srodata*)
    } > RAM

    .data : ALIGN(8) {
        *(.data*)
        *(.sdata*)
    } > RAM

    .bss : ALIGN(8) {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    /* tohost/fromhost: fixed address monitored by TB */
    . = ALIGN(0x1000);
    .tohost 0x80001000 : {
        *(.tohost)
    } > RAM

    /* Signature region (between RVMODEL_DATA_BEGIN and RVMODEL_DATA_END) */
    .signature ALIGN(16) : {
        PROVIDE(begin_signature = .);
        *(.signature)
        PROVIDE(end_signature = .);
    } > RAM

    _stack_top = ORIGIN(RAM) + LENGTH(RAM);

    /DISCARD/ : {
        *(.eh_frame*)
        *(.riscv.attributes)
        *(.comment)
        *(.note*)
    }
}

