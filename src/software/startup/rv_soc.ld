/* =============================================================================
 * rv_soc.ld - Linker Script for rv_soc bare-metal (RV32IM / RV64IM)
 * =============================================================================
 *
 * ハードウェア物理アドレスマップ:
 *   IMEM : 0x0000_0000, 16 KB  (命令フェッチ専用ポート)
 *   DMEM : 0x8000_0000, 16 KB  (データ読み書き)
 *
 * セクション配置:
 *   .text                  → IMEM  (命令コード)
 *   .rodata / .data        → DMEM  (読み取り専用データ・初期化済みグローバル変数)
 *   .bss                   → DMEM  (ゼロ初期化変数、crt0.S でゼロクリア)
 *   stack                  → DMEM 末尾 (下方向に伸びる)
 *
 * 生成するhexファイル:
 *   imem.hex : .text のみ抽出      (IMEM_FILE)
 *   dmem.hex : .rodata + .data 抽出 → アドレスを -0x8000_0000 シフト (DMEM_FILE)
 * =============================================================================
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K   /* 命令メモリ */
    DMEM (rwx) : ORIGIN = 0x80000000, LENGTH = 15K   /* データメモリ (1KB をスタックに予約) */
    STACK      : ORIGIN = 0x80003C00, LENGTH = 1K    /* スタック領域 */
}

SECTIONS {
    /* ================================================================
     * 命令メモリ (IMEM): コードのみ
     * ================================================================ */
    .text : ALIGN(4) {
        KEEP(*(.text.start))    /* crt0 _start を先頭に配置 */
        *(.text*)
        *(.text.unlikely*)
    } > IMEM

    ASSERT(. <= ORIGIN(IMEM) + LENGTH(IMEM),
           "ERROR: .text が IMEM (16 KB) をオーバーフロー")

    /* ================================================================
     * データメモリ (DMEM): 全データセクション
     * シミュレーションでは DMEM_FILE でプリロードされる
     * ================================================================ */

    /* 読み取り専用データ (文字列リテラル、const グローバル変数) */
    .rodata : ALIGN(4) {
        *(.rodata*)
        *(.srodata*)
        *(.srodata.cst*)
    } > DMEM

    /* 初期化済みグローバル変数 */
    .data : ALIGN(4) {
        _data_start = .;
        /* GP (global pointer) を small-data 領域の中央に設定
         * GP ± 2KB の範囲を GP-relative アクセスでカバー */
        __global_pointer$ = . + 0x800;
        *(.sdata*)
        *(.sdata2*)
        *(.data*)
        _data_end = .;
    } > DMEM

    /* ゼロ初期化変数 (crt0.S で実行時にゼロクリア) */
    .bss : ALIGN(4) {
        _bss_start = .;
        *(.sbss*)
        *(.sbss2*)
        *(.bss*)
        *(COMMON)
        _bss_end = ALIGN(4);
    } > DMEM

    ASSERT(_bss_end <= ORIGIN(DMEM) + LENGTH(DMEM),
           "ERROR: data/bss が DMEM (15 KB) をオーバーフロー")

    /* スタックトップ (DMEM 末尾) */
    _stack_top = ORIGIN(DMEM) + LENGTH(DMEM) + LENGTH(STACK);

    /* ================================================================
     * 不要セクションを破棄
     * ================================================================ */
    /DISCARD/ : {
        *(.eh_frame*)
        *(.riscv.attributes)
        *(.comment)
        *(.note*)
    }
}
