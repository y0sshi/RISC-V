#ifndef _MODEL_TEST_H
#define _MODEL_TEST_H

// =============================================================================
// Data section: tohost / fromhost
// =============================================================================
#define RVMODEL_DATA_SECTION                             \
    .pushsection .tohost, "aw", @progbits;               \
    .align 8; .global tohost; tohost: .dword 0;          \
    .align 8; .global fromhost; fromhost: .dword 0;      \
    .popsection;

// =============================================================================
// Test termination: write 1 to tohost, then spin
// =============================================================================
#define RVMODEL_HALT                                     \
    li t0, 1;                                            \
    la t1, tohost;                                       \
    sd t0, 0(t1);                                        \
    self_loop: j self_loop;

// =============================================================================
// Boot-time hook (FPU enable etc. already done in crt_act.S)
// =============================================================================
#define RVMODEL_BOOT

// =============================================================================
// Signature region markers
// =============================================================================
#define RVMODEL_DATA_BEGIN                               \
    RVMODEL_DATA_SECTION                                 \
    .align 4; .global begin_signature; begin_signature:

#define RVMODEL_DATA_END                                 \
    .align 4; .global end_signature; end_signature:

// =============================================================================
// I/O macros (unused under simulation, leave empty)
// =============================================================================
#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

// =============================================================================
// Interrupt control hooks (empty stubs)
// =============================================================================
#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLEAR_MSW_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT

#endif // _MODEL_TEST_H

