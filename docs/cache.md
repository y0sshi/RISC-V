# I/D Caches (DDR latency amortization for Linux-class performance)

Status as of this work increment. With instructions and data both in external DDR
over AXI4 (see `docs/axi_ddr.md`), every fetch/load was a multi-cycle AXI round
trip -- far too slow for Linux. This increment adds an **instruction cache (I$)**
and a **data cache (D$)** inside `rv_soc` (the AXI/DDR SoC) to amortize that
latency with one burst line fill per miss and 1-cycle hits.

## Where the caches sit

The caches are a **drop-in between the CPU complex's physical-address memory I/F
and the AXI masters** -- the CPU core (`rv_cpu`/`rv_core`) is **unchanged**. The
core was already variable-latency tolerant (IF stalls on `~imem_ready`; data
freezes the pipeline on `dmem_wait`; PTW waits on `ptw_ready`), so the caches just
have to honor that contract: **HIT answers in 1 cycle, MISS asserts the stall and
line-fills over AXI**.

```
                rv_soc
  rv_cpu  --imem--> rv_icache --burst--> rv_axi_burst_bridge --> m_axi_if_*  (RO, 32b)
          --dmem--> [periph? -> rv_periph (uncached, 1-cyc)]
                    [DDR    -> rv_dcache] --+
          --ptw---------------------------- +--> rv_axi_burst_bridge --> m_axi_* (RW, XLEN)
                                  (PTW bypasses the D$, arbitrated, priority)
```

- **Peripherals (0xC0xx) are UNCACHED** -- served by `rv_periph` exactly as
  before; the D$ core-side request is gated with `~periph_is_periph`, so MMIO
  never enters the cache.
- **PTW reads BYPASS the D$** (single-beat AXI read, arbitrated onto the data
  master with priority). The D$ and PTW never overlap: a held data access freezes
  the pipeline, so no new translation/PTW can start while the D$ services a miss.
- **AMO / LR-SC and misaligned 2-phase accesses are transparent**: the core
  decomposes them into ordinary word load/store sequences at the cache interface,
  each of which honors the wait/rdata contract. The caches need no AMO-specific
  logic (single hart, no coherence).

`rv_soc_bram` (Harvard BRAM) and `rv_soc_act` (compliance unified memory) are
**unchanged** -- the caches are only in `rv_soc`. Set `ICACHE_EN` / `DCACHE_EN`
parameters to 0 to bypass a cache (direct single-beat AXI = pre-cache behavior),
useful for debugging.

## New RTL modules

### `src/rtl/bus/rv_axi_burst_bridge.sv`
Simple-bus <-> AXI4 master with **multi-beat INCR read bursts** (ARLEN = line
beats - 1) for line fills, plus single-beat writes (write-through). One
outstanding transaction. The consumer (cache or PTW) sets `s_len` (0 for a single
read / PTW; `LINE_BEATS-1` for a line fill); each returned beat streams out on
`s_rvalid`/`s_rdata` with `s_rbeat`/`s_rlast`; `s_done` pulses on completion.
`s_rdata` is combinational on the beat (the PTW and I$ sample it on the
completion cycle). The original single-beat `rv_axi_bridge` is retained for the
cache-bypass paths.

### `src/rtl/cache/rv_icache.sv` (read-only)
Direct-mapped, parameterized (`LINE_BYTES`, `SETS`). **BRAM-equivalent on a hit**:
the fetch address is registered (`addr_q`) so the lookup result corresponds to
`fetch_pc`, exactly the synchronous-read timing the core's IF was built for. HIT
-> `c_ready=1` with the window combinationally; MISS -> `c_ready=0` while a line
is fetched in one AXI burst, after which the held address re-looks-up and hits.

- **BRAM-backed line array (C-2b, 2026-06-14)**: the line data array is a true
  synchronous-read block RAM (`(* ram_style="block" *)`), read into a registered
  output `line_q` whose clock-enable matches the `addr_q` update enable, so
  `line_q` tracks `addr_q` in lockstep (= `line[set(addr_q)]` in the serve cycle,
  bit-identical to the old combinational read). The window is a part-select of
  `line_q`. After a fill the freshly written line cannot be read out of the BRAM
  on the same cycle, so a one-cycle settle state (`S_FILL2`) re-reads it before
  the held address re-looks-up (+1 MISS cycle; hit path unchanged). Tag/valid stay
  in fabric. This moves ~20k FF + the address-control LUTs out of fabric into 4
  RAMB36; the `addr_q` hold/re-arm semantics (bug #5 stale-PA fix) are unchanged.

- **RVC variable-length fetch**: `fetch_pc` may be 2-byte aligned, so the 32-bit
  window can span two 32-bit words. Within a line the window is extracted with a
  byte-granular part-select of the packed line (`line[idx][boff*8 +: 32]`). The
  single offset whose window crosses the **line** boundary (`boff == LINE_BYTES-2`)
  is served as a **2-line straddle HIT** when both adjacent lines are cached: a
  second registered read port (`line_q2`, set `idx+1`) supplies the high half, and
  the window is `{line_q2[15:0], line_q[LINEW-1 -: 16]}`. A cold straddle fills the
  missing line(s) through the normal `S_FILL`/`S_FILL2` path (up to two sequential
  fills) and then hits -- **there is no uncached bypass**, so every memory access
  is an aligned line burst (no unaligned ARADDR on real `S_AXI_HP`). This replaced
  the earlier single-beat bypass, whose multi-cycle uncached fetch turned a
  redirect whose target was a straddle address into a fetch/redirect squash race
  (the OpenSBI/Linux livelock fixed 2026-06-18).
- **FENCE.I**: `flush` clears all valid bits so self-modified / newly loaded code
  is re-fetched.

### `src/rtl/cache/rv_dcache.sv` (write-through, write-no-allocate)
Direct-mapped, parameterized. **Combinational tag lookup** so a hit/miss is
resolved (and `c_wait` driven) in the access cycle; the **data array is a
synchronous-read block RAM** (C-2b, 2026-06-14) -- the 2-D `data[SETS][WORDS]` is
flattened to a 1-D byte-write BRAM `data[SETS*WORDS]` (`(* ram_style="block" *)`,
one RAMB36) addressed by `{set,word}`. Tag/valid stay in fabric.

- **Load HIT**: `c_wait` stays low; the BRAM read register presents the word the
  next cycle (BRAM-identical 1-cycle latency).
- **Load MISS**: `c_wait` high while a whole line is fetched in one AXI burst.
  The requested word can no longer be captured from the beat stream (it now lives
  in the BRAM), so a one-cycle re-lookup state (`S_RELOOKUP`) reads it out after
  the fill (+1 MISS cycle; hit path unchanged).
- **STORE**: write-through -- every store is forwarded to memory (single-beat AXI
  write) and, if the line is currently cached, the cached word is updated in place
  (write-no-allocate: a store miss does not allocate). Memory therefore always
  holds the latest value, so the cache is always coherent with it (single hart).

`c_rdata` is registered and held until the next load completes, satisfying both
the WB-stage sample (one cycle after the access) and the misaligned phase-0
capture (`mal_first_data`).

## Core change: FENCE.I

`rv_decode` now decodes **FENCE.I** (`OP_FENCE`, funct3=001, Zifencei) into
`ctrl.is_fence_i` (plain FENCE funct3=000 stays a NOP). `rv_core` emits a 1-cycle
`fence_i_out` pulse (EX stage, gated by `csr_commit` like `tlb_flush_out`, so it
fires once under IF latency), threaded through `rv_cpu` to `rv_soc`, which drives
the I$ `flush`. In `rv_soc_bram` / `rv_soc_act` the pulse is left unconnected
(no I$), so FENCE.I remains a NOP there -- non-destructive.

## Contract details (the subtle parts)

- **`c_wait` must rise combinationally** the cycle a miss/store is presented (the
  same bug class as the bridge's `s_wait`): the D$ computes hit/miss
  combinationally (LUTRAM-style arrays) so the wait is known immediately.
- **`dmem_rdata` hold**: registered and only updated on a completing load, so the
  WB sampler and the misaligned phase-0 capture see stable data across stalls.
- **I$ 1-cycle hit, not 0-cycle**: the core expects `imem_rdata(N) =
  mem[fetch_pc(N)] = mem[imem_addr(N-1)]` (synchronous-read BRAM semantics). A
  combinational 0-cycle hit would present `mem[imem_addr(N)]` and mismatch, so the
  I$ registers the address -- hits are then indistinguishable from BRAM and reuse
  the proven always-ready IF path; misses reuse the proven `~imem_ready` freeze.

## Verification

Unit tests (v12.0 native + v13.0 docker):
- `make sim_axi_burst` : 52/52 -- burst line fills + single writes vs latency.
- `make sim_dcache` / `sim_dcache64` : 40/40 each -- hit/miss/fill/eviction,
  write-through hit update, same-line neighbours, latency sweep, hit/miss counters.
- `make sim_icache` / `sim_icache64` : 50/50 each -- aligned + RVC-window fetch,
  2-line straddle hit, FENCE.I refetch, MMU-gap resume, translation-change-mid-
  fill, latency sweep.

Integration -- `make sim_cache_soc` / `sim_cache_soc64` (6/6 each, v12 + v13):
two `rv_soc` instances (caches on vs off) run the same nested-loop program
(sum an 8-word DDR array 4x = 1440) at randomized AXI latency.
- **Transparency**: cached and uncached produce identical DDR results (= 1440).
- **Effectiveness** (measured AR handshakes):

  | AXI master | uncached | cached |
  |------------|----------|--------|
  | instruction | 1003     | **3**  |
  | data        | 287      | **1**  |

  Cache counters (cached run): I$ hit ~7948 / miss 3, D$ hit 31 / miss 2.

Non-regression (the cache work touches `rv_pkg`/`rv_decode`/`rv_core`/`rv_cpu`,
so the whole suite was re-run):
- All `sim_*` units green on v13; key ones (burst, caches, pipeline, intr,
  cache_soc) also green on v12.
- `make sim_axi`/`sim_axi_core`/`sim_axi_ifetch`/`sim_axi_soc` green (the
  burst-capable BFM is non-destructive to the single-beat paths).
- riscv-tests **RV64 117/117** and **RV32 88/88** (these run through
  `rv_soc_act`, which is unchanged; confirms the decode/core changes are
  non-destructive and FENCE.I stays a NOP in ACT mode).

## Remaining / future work

- **Write-back + set-associative** D$ for higher performance (this version is
  write-through direct-mapped for provable correctness). A write-back cache needs
  dirty bits + eviction write-out.
- **PTW-over-AXI through the D$** (currently bypassed) if PTE caching is wanted.
- Real-program soak over a single shared DDR image; board bring-up with the
  PS DDR (the burst bridge already emits proper INCR bursts for the HP port).
