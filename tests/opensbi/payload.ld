/* payload.ld - link the S-mode payload at the OpenSBI fw_payload entry
 * (FW_TEXT_START 0x80000000 + FW_PAYLOAD_OFFSET 0x200000). */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS {
    . = 0x80200000;
    .text   : { *(.text*) }
    .rodata : { *(.rodata*) }
    .data   : { *(.data*) }
    .bss    : { *(.bss*) *(COMMON) }
    . = ALIGN(16);
    _end = .;
}
