# =============================================================================
# atomic_test.S - AMO / LR-SC stress under the cached (variable-latency) path
# =============================================================================
# Reproducer harness for atomic-RMW corruption suspected from the Linux boot
# (printk ringbuffer livelock + refcount_warn_saturate WARNs).  Hammers
# amoadd.d / lr.d+sc.d / amoxor.d on counters whose cache line is evicted
# every iteration (aliasing loads at direct-mapped strides), with a
# write-through store immediately before the loop's next AMO so the AMO
# arrives in EX/MEM while dmem_wait from the store is still draining.
# Verifies the AMO return value EVERY iteration (old value must equal i),
# then the final counter values.  Writes the harness sentinel (DONE/FAIL).
#
# Run:  make atomic_test  &&  (cd ../sim && make vl_boot \
#   BOOT_HEX=../software/boot/atomic_test.hex)
# =============================================================================

    .equ TOHOST,     0x80002000
    .equ DONE_MAGIC, 0x00C0FFEE
    .equ FAIL_MAGIC, 0x0BADBAD0
    .equ N,          200

    .section .text
    .globl _start
_start:
    li      sp, 0x80010000
    li      s0, 0x80020000          # counter A: amoadd.d += 1 per iter
    li      s1, 0x80020008          # counter B: lr.d/sc.d += 1 per iter
    li      s2, 0x80020010          # word C: amoxor.d ^= 0xA5A5 per iter
    sd      zero, 0(s0)
    sd      zero, 0(s1)
    sd      zero, 0(s2)
    li      t2, 0x8002001C          # D: 32-bit counter (addr[2]=1: upper half
    sw      zero, 0(t2)             #    of the 8-byte word -- 0x18 was NOT)
    li      t2, 0x80020020          # E: 32-bit counter (addr[2]=0)
    sw      zero, 0(t2)
    li      s3, N
    li      s4, 0                   # i

loop:
    # --- amoadd.d with per-iteration return-value check (old == i) ---------
    li      t0, 1
    amoadd.d t1, t0, (s0)
    bne     t1, s4, fail

    # --- evict the counter line: touch direct-mapped aliases ----------------
    # strides cover 2 KiB (32B x 64 sets, rv_soc default) through 16 KiB
    # (boot-harness sized) direct-mapped D$ geometries.
    li      t2, 0x80020800
    ld      t3, 0(t2)
    li      t2, 0x80021000
    ld      t3, 0(t2)
    li      t2, 0x80024000
    ld      t3, 0(t2)
    li      t2, 0x80028000
    ld      t3, 0(t2)

    # --- lr.d / sc.d increment (retry loop) ---------------------------------
retry:
    lr.d    t1, (s1)
    bne     t1, s4, fail            # old value must equal i
    addi    t1, t1, 1
    sc.d    t4, t1, (s1)
    bnez    t4, retry

    # --- amoxor.d ------------------------------------------------------------
    li      t0, 0xA5A5
    amoxor.d t5, t0, (s2)

    # --- 32-bit AMOs at both word offsets (refcount_t-style) ----------------
    # D: 0x8002001C (addr[2]=1, upper word of the 8-byte beat)
    # E: 0x80020020 (addr[2]=0)
    li      t0, 1
    li      t2, 0x8002001C
    amoadd.w t1, t0, (t2)
    bne     t1, s4, fail            # old value must equal i (sign-ext ok: small)
    li      t2, 0x80020020
    li      t0, -1
    amoadd.w t1, t0, (t2)
    sub     t5, zero, s4
    sext.w  t5, t5
    bne     t1, t5, fail            # old value must equal -i (sign-extended)

    # --- write-through store right before the loop's next AMO ---------------
    sd      s4, 0x40(s0)            # adjacent line: leaves dmem_wait draining

    addi    s4, s4, 1
    blt     s4, s3, loop

    # --- final checks --------------------------------------------------------
    ld      t0, 0(s0)
    bne     t0, s3, fail            # A == N
    ld      t0, 0(s1)
    bne     t0, s3, fail            # B == N
    ld      t0, 0(s2)
    bnez    t0, fail                # C: N even -> xor cancels to 0
    li      t2, 0x8002001C
    lw      t0, 0(t2)
    bne     t0, s3, fail            # D == N
    li      t2, 0x80020020
    lw      t0, 0(t2)
    sub     t5, zero, s3
    sext.w  t5, t5
    bne     t0, t5, fail            # E == -N

pass:
    li      t1, TOHOST
    li      t2, DONE_MAGIC
    sw      t2, 0(t1)
1:  wfi
    j       1b

fail:
    li      t1, TOHOST
    li      t2, FAIL_MAGIC
    sw      t2, 0(t1)
1:  wfi
    j       1b
