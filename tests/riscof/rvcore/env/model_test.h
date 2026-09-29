#ifndef _MODEL_TEST_H
#define _MODEL_TEST_H

// =============================================================================
// RVMODEL macros for this RTL core (ACT_MODE: rv_soc + rv_unified_mem).
// Mirrors tests/env/model_test.h: tohost-based halt + begin/end_signature region.
// The testbench (tb_rv_act.sv) watches a store to `tohost` and dumps the
// begin_signature..end_signature region as 32-bit little-endian words.
// =============================================================================

#define RVMODEL_DATA_SECTION                             \
    .pushsection .tohost, "aw", @progbits;               \
    .align 8; .global tohost; tohost: .dword 0;          \
    .align 8; .global fromhost; fromhost: .dword 0;      \
    .popsection;

// Test termination: write 1 to tohost, then spin.
#define RVMODEL_HALT                                     \
    li t0, 1;                                            \
    la t1, tohost;                                       \
    sd t0, 0(t1);                                        \
    self_loop: j self_loop;

#define RVMODEL_BOOT

// Signature region markers.
#define RVMODEL_DATA_BEGIN                               \
    RVMODEL_DATA_SECTION                                 \
    .align 4; .global begin_signature; begin_signature:

#define RVMODEL_DATA_END                                 \
    .align 4; .global end_signature; end_signature:

// I/O macros (unused under simulation).
#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

// Interrupt control hooks (empty stubs).
#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLEAR_MSW_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT

#endif // _MODEL_TEST_H
