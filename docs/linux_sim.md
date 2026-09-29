# Booting Linux in simulation (P0-3 earlycon ACHIEVED 2026-06-10)

This builds a minimal RV64 Linux `Image`, wraps it into an OpenSBI `fw_payload`,
and boots it on `rv_soc` in the shared-DDR harness (`tb_rv_boot_soc`) -- the same
harness that runs the OpenSBI bring-up (`docs/opensbi_sim.md`).  Use the
**Verilator** path (`docs/verilator_sim.md`); iverilog is far too slow for the
tens-of-millions of cycles a kernel boot takes.

## Build the kernel image

```sh
docker build -t linux-rv64:latest -f tests/linux/Dockerfile tests/linux   # once
docker run --rm -v <repo>:/workspace -w /workspace/tests/linux linux-rv64:latest bash build.sh
# -> tests/linux/work/fw_payload_linux.hex
```

`tests/linux/build.sh` (idempotent; `FORCE_KERNEL=1` to reconfigure/rebuild):
1. Builds a **freestanding static `init`** (`init.c`, raw `write()` via `ecall`,
   no libc -- the `gcc-riscv64-linux-gnu` package ships no target libc) and an
   initramfs listing (`/dev/console`, `/init`).
2. Downloads + builds **Linux 6.12** `Image` with `ARCH=riscv defconfig` plus
   `kernel_fragment.config` (earlycon=sbi + 8250 console, built-in initramfs,
   `CONFIG_SMP=n`).
3. Compiles `rv_soc_linux.dts` -> dtb.  **`/memory` is 64 MiB == the shared-DDR
   BFM `DEPTH` (`1<<26`)**; do not exceed the BFM or OpenSBI's FDT relocation
   lands out of range (see `docs/opensbi_sim.md` "Final blocker").
4. Wraps `Image` into an OpenSBI generic `fw_payload` (`FW_PAYLOAD_OFFSET=0x200000`
   -> kernel at `0x80200000`), reusing the v1.2 tree under `tests/opensbi/work`.

## Boot it

```sh
cd src/sim
make vl_boot BOOT_HEX=../../tests/linux/work/fw_payload_linux.hex BOOT_MAX=500000000 BOOT_MTIME_DIV=64
```

## Bring-up status (2026-06-07): MMU/transition solved; deep in start_kernel

**Update 2026-06-07 — blocker 1 (and its whole MMU sub-stack) RESOLVED.**  Four
RTL fixes took the kernel from "garbage at MMU enable" all the way through the
physical->virtual transition and deep into `start_kernel` (past BSS clear, past
`setup_vm`, into `printk`).  All four are structural no-ops for bare-mode (M-mode
boot / every unit + compliance test) and keep **RV64 compliance 117/117**.

1. **I$ `addr_q` resume lag** (`rv_icache.sv`): the registered fetch address only
   advanced on `c_ready`, so after the MMU withdraws `c_req` for a TLB-miss page
   walk and then resumes at a NEW address, the first post-gap lookup served the
   stale pre-gap line.  Fix: also capture `addr_q` on the first re-presented
   request after an idle gap (`state==S_LOOKUP && c_req && !req_q`).  No-op while
   `c_req` is held continuously (bare mode / all tests).  Regression test added to
   `tb_rv_icache.sv` ("MMU-gap resume").
2. **`satp.MODE` not WARL** (`rv_csr.sv`): Linux probes the MMU mode by writing
   Sv57/Sv48/Sv39 and reading back.  We accepted any MODE, so Linux concluded
   "Sv57 supported", installed Sv57 page tables, and our Sv39-only MMU treated
   `satp` as Bare -> untranslated fetch -> garbage.  Fix: WARL — a write selecting
   an unsupported MODE (RV64: not Bare/Sv39) is ignored (satp retains its value),
   so the read-back makes Linux fall back to Sv39.
3. **Instruction page fault never implemented** (`rv_core.sv`): `if_fault` was a
   dangling input.  Linux's `relocate_enable_mmu` *deliberately* faults the first
   fetch after enabling `satp` to vector (via `stvec`) into the freshly-mapped
   virtual space.  Implemented: latch `if_fault` + the faulting VA and take the
   trap directly (cause=12) without waiting for `imem_ready` (the faulting fetch
   never completes), redirecting via the existing latched-redirect path.
4. **SATP-write fetch barrier** (`rv_core.sv`): without it the post-`satp`
   instruction is already prefetched under the OLD translation, so the fault lands
   late (after `csrw stvec` already ran -> wrong vector).  Fix: when a `satp`
   write commits, redirect to the next sequential PC so it re-fetches under the
   new `satp` and faults precisely.
5. **PTW vs D-cache bridge arbitration** (`rv_soc.sv`): the PTW and D-cache share
   the data burst bridge with a *combinational* `ptw_req`-priority mux.  A store's
   multi-cycle write-through B-response, completing while a PTW asserted `ptw_req`,
   was misattributed to the PTW (`ptw_ready = ptw_req & br_done`), so the PTW
   sampled the bridge's stale `rdata_hold` as a PTE -> bogus leaf -> spurious
   store page fault on a writable kernel page -> `panic("Attempted to kill the
   idle task!")`.  Fix: an **atomic arbiter** latches the bridge owner at
   transaction start and holds it to completion; `ptw_ready`/D-cache-`done` are
   routed to the granted master only.  No-op when VM is off (`ptw_req=0`).

### RESOLVED blocker (2026-06-07): exception storm `tp/sscratch=0x8003e000` -- RTL bug #4
The storm (every ~21 cyc a store page fault at `handle_exception`, `tval=0x8003exxx`,
because **`tp`(=`sscratch`)=0x8003e000**, an OpenSBI-firmware PHYSICAL address used as
a kernel pointer) was root-caused to a **CSR-write that re-fires while the EX stage is
stalled**.  `csr_we`/`trap_enter`/`mret_en`/`sret_en` were gated by
`csr_commit=imem_ready` but NOT `~stall_ex`.  When a CSR instruction is held in EX by a
non-IF stall (`dmem_wait` from the preceding write-through store, amo/mal/mem_stall)
while `imem_ready` stays 1, the CSR write re-executes every held cycle.  OpenSBI's trap
entry/exit `csrrw tp, mscratch, tp` is held behind the preceding store, so on the 2nd+
cycle it overwrites `mscratch` with its own (already-swapped) `tp` -> the kernel's `tp`
is lost and never restored on SBI return -> `_printk` dereferences the firmware-physical
pointer -> recursive store-fault storm.  **Fix** (`rv_core.sv`): `wire csr_commit_ex =
~stall_ex;` gating the four EX-stage commits plus `tlb_flush_out`/`fence_i_out`, and
`flush_ex_mem = trap_or_mret & ~stall_ex` (was `& imem_ready`).  `retire_en` stays on
`csr_commit` (WB-stage).  Same class as fix #3 (flush_ex `~stall_ex`).  **Non-destructive:
RV64 117/117, RV32 88/88, all sim_*, mini-SBI boot IF line-fills=654.**
How it was found: `[CSRW]`/`[TPWB]` monitors caught `tp` reverting to 0x8003e000 right
after an SBI ecall; `[MSCR]`/`[MSREG]` showed the 2nd `csrrw` re-firing under stall and
clobbering `mscratch`.  The `[DLOAD BUG]` self-check produced FALSE POSITIVES (stale
`ld_addr`) that initially mis-pointed at cache data corruption; per-cycle `[dc cN]`
traces proved loads/stores were correct and refocused on the CSR path.

## ✅ P0-3 ACHIEVED (2026-06-10): "Linux version 6.12.0" + full earlycon console

`make vl_boot BOOT_HEX=../../tests/linux/work/fw_payload_linux.hex BOOT_MAX=300000000`
now prints the OpenSBI banner followed by ~80 lines of kernel earlycon log:
`Linux version 6.12.0` / Machine model / SBI v1.0 + TIME/IPI/RFENCE detected /
`earlycon: sbi0` / memory zones + virtual layout / `Kernel command line:
earlycon=sbi console=ttyS0,115200` / clocksource riscv_clocksource (timestamps
advance off mtime) / BogoMIPS (lpj=4000, calibration skipped) / LSM / through
`vfs_caches_init`, reaching the idle loop (`default_idle_call`) by ~200M cycles.
Three independent fixes were needed (each alone was insufficient):

1. **RTL bug #5 — I$ serves a stale-translation line after a mid-fill PA change**
   (`rv_icache.sv`).  The first fetch after an MRET (M->S) translates under the
   STALE privilege for one cycle (bare physical).  If that wrong-PA lookup
   misses, the I$ commits to filling the wrong (firmware) line; the corrected
   PA appears on `c_addr` mid-fill, but the post-fill re-lookup served the stale
   `addr_q` line -> the core executed OpenSBI firmware bytes at a kernel VA.
   Concretely: `__sbi_ecall` return VA `0xffffffff800097d2` (correct PA
   0x802097d2, bare PA 0x800097d2) fetched firmware bytes `f884` =
   `c.sd s1,0x30(s1)` with s1=0 -> store fault tval=0x30 -> die -> **silent
   panic** (the old "udelay spin" was panic()'s infinite mdelay(100) loop --
   caller `panic+0x2ca`).  Fix: re-arm `addr_q <= c_addr` when a FILL/BYPASS
   completes with a request still presented (`m_done && c_req`), and gate the
   BYPASS serve with `req_q && (addr_q == c_addr_q)` (a REGISTERED previous-
   cycle address copy: comparing live `c_addr` is a combinational
   c_ready->stall->imem_addr->c_addr loop, which Verilator rejects as
   "did not converge").  Regression: tb_rv_icache "translation change mid-fill"
   (50/50).  mini-SBI IF AR count moves 654->652 (two duplicate wrong-path
   straddle bypass reads suppressed; line-fill address sequence identical).
2. **RTL bug #6 — SC writes memory but reports failure when held in MEM by an
   IF stall** (`rv_core.sv`).  The LR/SC reservation update was gated only by
   `!dmem_wait`; an SC whose write-through had completed, but which was HELD in
   MEM by `~imem_ready` (I$ miss), cleared `reservation_valid` on every held
   cycle, so the later MEM/WB capture recomputed `sc_success=0` -> rd=1
   (failure) although memory WAS written.  Linux's `atomic_long_try_cmpxchg`
   then looped "failing" forever: the printk ringbuffer head walked the whole
   descriptor ring (+4095) without ever reserving a record, every printk bumped
   `prb->fail`, console_flush_all had nothing to emit (SILENT console even with
   earlycon registered), and later printks livelocked in
   `prb_next_reserve_seq`; refcount_warn_saturate WARNs fired too.  Fix: gate
   the reservation update with the exact MEM/WB advance condition
   (`!amo_stall && !mal_stall && !dmem_wait && imem_ready`).  No-op for bare
   BRAM (imem_ready=1).  **Repro/regression: `src/software/boot/atomic_test.S`
   (`make atomic_test`; run with `BOOT_NO_ICACHE=1` -- fails on the old RTL,
   passes fixed; also passes caches-on).**
   Note: prb's initial `head_id/tail_id = 0x00000000ffffefff` LOOKS truncated
   but is the **legitimate upstream value** (`1U << bits` u32 arithmetic in
   `DESC0_ID`) -- do not mistake it for corruption.
3. **Kernel config — `CONFIG_RISCV_SBI_V01=y` required for earlycon=sbi**
   (`tests/linux/kernel_fragment.config`).  Linux 6.x `early_sbi_setup()` uses
   the SBI DBCN extension if available, else falls back to the legacy v0.1
   console putchar only `if IS_ENABLED(CONFIG_RISCV_SBI_V01)`, else returns
   -ENODEV.  OpenSBI v1.2 has NO DBCN (added in v1.3), and defconfig leaves
   V01 unset -> earlycon never registered.  (This also silently dropped
   `CONFIG_HVC_RISCV_SBI`, which depends on V01.)

### How it was traced (method notes)
- `[trap]` now prints `a7/a6/a0` (SBI EID/FID): zero console-putchar ecalls
  proved earlycon was not writing.
- `[UDELAY]` probe (caller ra = `panic+0x2ca`, a0=1000) identified the spin as
  panic()'s `mdelay(PANIC_TIMER_STEP)` loop.  The probe PC is vmlinux-layout
  dependent: override with `BOOT_UDELAY_PC=64'h...` (Makefile knob).
- `BOOT_EXEC` window: committed `inst=97e3f884` at `...97d2` vs vmlinux bytes
  `6462` -> `od` of fw_payload.bin at offset 0x97d2 matched the garbage =
  proof of the bare-PA fetch.
- TEMP-DIAG probes in `tb_rv_boot_soc.sv` (BOOT_TRACE-gated, **addresses are
  specific to the 2026-06-10 vmlinux**): `[ECPROBE]` PC probes through
  parse_early_param -> setup_earlycon -> early_sbi_setup -> register_console ->
  console_flush_all -> sbi_0_1_console_write; `[PRB]`/`[PRBP]` dump
  printk_rb_static head_id/tail_id/last_finalized_seq/fail directly from the
  shared-DDR BFM (PA 0x816170f8 + offsets); `vpe=` printk-entry counter in
  `[progress]`.  The `fail` counter incrementing while `head_id` walked the
  ring and descriptors stayed unwritten is what cornered bug #6.

## Timer-interrupt delivery FIXED (2026-06-10, second half): four more RTL bugs

The "idle forever" state was NOT an idle-loop problem: **the entire Linux boot
ran with ZERO interrupts delivered** (a `[trap]`-cause census over 30M+ cycles
showed only ecalls; the `handle_riscv_irq` PC seen in idle-loop samples was a
mis-attributed `arch_cpu_idle` tail).  Three independent bugs each sufficed to
kill the tick, and a fourth (the LR/SC one) would have corrupted atomics as
soon as interrupts started landing:

1. **RTL bug #7 -- LR/SC reservation survives traps/xRET** (`rv_core.sv`).
   Only SC cleared the reservation.  An interrupt taken between LR and SC
   whose handler AMOs the same address let the resumed SC succeed with the
   PRE-trap value, silently losing the handler's update (the refcount/atomic
   lost-update mechanism; priv spec: xRET voids the reservation).  Fix:
   `lrsc_kill = ((csr_trap_enter|ex_mret_en|ex_sret_en) & csr_commit_ex) |
   ifpf_take` clears `reservation_valid` (priority over an LR set on the same
   edge); strict no-op while no trap/xRET commits.
   **Repro/regression: `src/software/boot/lrsc_irq_test.S`** (`make
   lrsc_irq_test`): CLINT timer interrupts land inside an lr.d/sc.d loop while
   the M handler amoadd.d's the same counter; checks X == N + K.  The re-arm
   MUST use an absolute schedule (`mtimecmp = previous + prime STEP`, STEP=431):
   the sim is cycle-deterministic, so a handler-relative re-arm phase-locks the
   interrupt outside the LR->SC window and the test (falsely) passes on the
   old RTL.  With the absolute schedule: old RTL FAIL, fixed RTL PASS.
2. **RTL bug #8 -- CLINT was 32-bit-bus only** (`rv_timer.sv`, `rv_periph.sv`).
   OpenSBI's RV64 ACLINT driver writes mtimecmp with `sd` (has_64bit_mmio);
   only the LOW word landed, mtimecmp[63:32] stayed at its reset value
   0xFFFFFFFF -> MTIP could never fire.  64-bit `ld` of mtime returned a
   replicated-low-word garbage value.  Additionally `rv_periph` dropped the
   upper STORE lane (addr[2]=1 carries data on wdata[63:32]): 32-bit writes to
   UART IER/LCR, PLIC claim/complete, mtimecmp_hi were silently zeroed (UART
   survived by luck -- THR/DLL are at addr[2]=0).  Fix: `rv_timer` is now
   XLEN-parametric (RV64: 8-byte-aligned decode, wstrb selects half/full,
   reads return the aligned 64-bit pair), `rv_periph` gained a `wstrb` input +
   `wdata32` lane select for the 32-bit peripherals + unreplicated CLINT read
   data; both SoC wrappers wire `core_dmem_wstrb` through.
3. **RTL bug #9 -- non-delegated M interrupts not taken from S/U mode**
   (`rv_csr.sv`).  `m_irq_en = (cur_priv==PRIV_M) && mstatus_mie` lacked the
   "always enabled when running below M" term, so MTIP never trapped to M
   while the kernel ran in S-mode -- OpenSBI's MTIP->STIP relay could not
   start.  Fix: `m_irq_en = (cur_priv==PRIV_M) ? mstatus_mie : 1'b1`.
   (OpenSBI's `csr_set(mip, STIP)` is still dropped -- mip is read-only here --
   but the `STIP = timer_irq & mideleg[5]` level alias substitutes correctly:
   re-writing mtimecmp drops the level.)
4. **RTL bug #10 -- no CSR existence/privilege check** (`rv_csr.sv` +
   `rv_core.sv`).  Unimplemented CSRs read 0 / ignored writes WITHOUT an
   illegal-instruction trap, so OpenSBI's trap-and-detect hart-feature probing
   "detected" sscofpmf, smaia, smstateen and **sstc** -- and then programmed
   timer events into the NONEXISTENT stimecmp CSR instead of the CLINT
   (mtimecmp stayed -1 even though `sbi_set_timer` was called; found via the
   `[TMPROBE]` arming-chain probes + `[IRQST]` CLINT/CSR state dumps).  Fix:
   `csr_access_ok` (implemented-CSR decode + `cur_priv >= csr_addr[9:8]`) from
   rv_csr; a CSR instruction with `!csr_access_ok` raises illegal-instruction
   in EX (and `csr_we` is gated off).  mvendorid/marchid/mimpid/mconfigptr are
   mandatory read-zero CSRs and stay valid.  OpenSBI now reports
   `Boot HART ISA Extensions : time` only, and the timer arms in the CLINT.

**Verification**: real OpenSBI v1.2 full boot PASS; RV64 compliance 117/117 and
RV32 88/88 (after ALL of the above); all unit sims (timer/uart/plic/gpio/intr/
csr/sv/mmu/pipeline/fpu_pipe/amo/caches/axi_burst) pass; mini-SBI iverilog +
Verilator boots PASS with **IF line-fills=652** unchanged; `lrsc_irq_test`
FAILs with the reservation kill disabled and PASSes with it.

**Effect on the Linux boot**: ticks now run (HZ=250 -> mtimecmp +4000 cycles;
heavy M<->S traffic).  The kernel sails past the old 6.4s mid-WARN console
freeze, prints BOTH refcount WARNs fully (now at ~10.4s saturate / ~16.5s
underflow + complete backtrace + `end trace`), and keeps executing: from ~75M
to 300M cycles d_reads/if_fills climb steadily with no console output (initcall
phase or a new stall -- unresolved).  No `/init` output by 300M cycles yet.

## refcount corruption SOLVED (2026-06-10, late): RTL bug #11 -- AMO skips its
## read phase when the data translation is pending

The refcount WARNs were chased with `[RCPROBE]` (refcount_warn_saturate entry:
r = the corrupted refcount_t) -> the objects were STATIC kernel namespaces
(`init_net.count` at init_net+0xcc, `init_user_ns.ns.count` at
init_user_ns+0xec, both incremented by get_net/get_user_ns amoadd.w in
alloc_fs_context/alloc_super).  `BOOT_WATCH_PA` (a BFM write-watch on the
8-byte word, with the MEM-stage PC attached to every store reaching DDR)
showed DDR held the CORRECT value (3) right up to the moment the amoadd's own
WRITE phase stored 0 over it.  A `BOOT_DCWIN` per-cycle D-cache trace then
showed the smoking gun: the amoadd sat in MEM for 12 cycles with **no D$
request at all** (`creq=0` -- the MMU suppresses `mem_req_out` while the data
TLB miss is walked) and then went **straight to the WRITE phase**.

**Root cause**: `amo_state` (read->write) advanced on `!dmem_wait` alone.
While the AMO's translation is pending (`mem_stall`), no request is issued, so
`dmem_wait` is 0 and the FSM "completed" a read that never happened; the write
value was computed from the STALE `dmem_rdata` of the previous load (the
user_ns POINTER, upper half 0xFFFFFFFF -> +1 -> 0 stored to the refcount).
M-mode / bare runs have `vm_data=0 -> mem_stall=0`, so no bare test could ever
reproduce it -- only VM-enabled kernel code with a data-TLB-missing AMO.
The same hole existed in `mal_state`, the LR/SC reservation update, and the
**MEM/WB capture** (which double-captured a translation-pending instruction
with garbage rdata -> double retire + garbage rd write, later self-corrected).

**Fix** (`rv_core.sv`): add `!mem_stall` to the amo_state / mal_state /
reservation gates and add `mem_stall` to the MEM/WB BUBBLE branch (same class
as `dmem_wait`).  Strict no-op when VM is off.  Verified: both WARNs gone from
the boot, RV64 117/117, RV32 88/88, all unit sims.

## Tick-rate livelock + ttyS0 console fixed (2026-06-10, late)

1. **MTIME_DIV prescaler**: with mtime at +1/cycle (a "1 MHz CPU" vs the 1 MHz
   DT timebase), the 250 Hz periodic tick fires every 4000 cycles -- LESS than
   the tick handler costs, so the kernel livelocked in tick_handle_periodic
   catch-up (PC samples: all tick/scheduler symbols; console silent from ~75M
   while d_reads climbed).  `rv_timer` gained an `MTIME_DIV` parameter
   (default 1 = exact original behavior), plumbed through rv_periph/rv_soc/
   rv_soc_bram and the boot TB.  **Linux boots must use `make vl_boot ...
   BOOT_MTIME_DIV=64`** (emulates a 64 MHz core; tick every 256k cycles).
   With it the boot storms through the initcall phase (riscv-plic probes, NET
   registered, plist test, ALSA) in ~400M cycles.
2. **RTL bug #12 -- UART had no TX FIFO**: DT `compatible="ns16550a"` makes
   the Linux 8250 driver assume PORT_16550A (tx_loadsz=16) WITHOUT autoconfig;
   it bursts 16 bytes into THR per LSR.THRE, so the single-byte THR dropped
   ~15/16 characters the moment the console switched from earlycon(sbi) to
   ttyS0 (garbled console, blind for /init).  Fix: real 16-byte TX FIFO
   (THRE = FIFO empty, TEMT = empty + shifter idle).  The FIFO push MUST be
   EDGE-qualified: an MMIO store held in MEM across a pipeline freeze keeps
   `req` high for many cycles, and a level-sensitive push enqueued the same
   char once per held cycle (observed: 14 copies of each line's first char).
   8250 drivers always poll LSR between THR writes, so edge-qualification
   loses nothing.  sim_uart 25/25, mini-SBI IF=652 unchanged.

## P0-4 ACHIEVED + P0-5 root-caused (2026-06-10 end-of-session)

With `BOOT_MTIME_DIV=64` the kernel boots clean through the initcall phase with
NO refcount WARNs, switches console earlycon(sbi)->ttyS0 successfully
(`ttyS0 at MMIO 0xc0010000 (irq=1) is a 16550A` / `legacy console [ttyS0]
enabled` / `bootconsole [sbi0] disabled`), reaches **`Run /init as init
process`**, and `/init` runs in **userspace**: PC samples land at 0x1014e-0x1016e
(the init binary `.text`), and crucially at **0x1016a = the `j 0x1016a` infinite
loop AFTER the write `ecall` at 0x10166** -- so /init executed its write(1,...)
syscall.  P0-4 (PID1 in userspace) is done.

## ✅ P0-5 ACHIEVED (2026-06-11): "LINUX-USERSPACE-OK: init running" on console

`make vl_boot BOOT_HEX=.../fw_payload_linux.hex BOOT_MAX=800000000 BOOT_MTIME_DIV=64`
now prints, after the ttyS0 console switch and `Run /init as init process`
(~5.86 s / ~440M cyc), the userspace line **`LINUX-USERSPACE-OK: init running`** --
clean, not garbled.  /init's `write(1,...)` drains through the interrupt-driven
8250 TX path.  An always-on `[IRQCHAIN]` TB probe shows the full chain light up:
`ier1=1 uirq=1 plic_en1=1 plic_pend=1 ext1=1 ext0=0 | seip>0 meip=0`.

**Root cause (deeper than the earlier "context 1 unwired" guess) -- RTL bug #13:
the PLIC used a non-standard COMPACT register map.**  `rv_plic` decoded enable @
0x200/0x204 and threshold/claim @ 0x300+ (and `rv_periph` only routed a 64 KiB
window 0xC010_0000..0xC010_FFFF).  The Linux `riscv,plic0` driver uses the
fixed **SiFive PLIC map**: priority @ id*4 (matched by luck), but **enable @
0x2000 + ctx*0x80** and **threshold/claim @ 0x200000 + ctx*0x1000**.  So Linux's
S-context enable write (base+0x2080) was mis-decoded as a priority write to
source 32 and dropped (`plic_en1` stayed 0 -> `ext_irq[1]` never asserted ->
no SEIP), and its threshold/claim accesses (base+0x200000 = 0xC030_0000) fell
*outside* the decoded PLIC window entirely and leaked to DDR.  `compatible=
"riscv,plic0"` hard-codes these offsets in the driver, so the HARDWARE must match.
**Fix**: rewrite `rv_plic` to the standard map (22-bit `addr`); widen the
`rv_periph` PLIC decode to 0xC010_0000..0xC03F_FFFF and pass `addr-0x100000`.
`tb_rv_plic` updated to the standard offsets (36/36).  No-op for bare/mini-SBI
(they never touch the PLIC; IF line-fills unchanged).

**Related fix -- shared ext_irq routing (`rv_csr`):** the SoC ORs both PLIC
contexts onto one `ext_irq`.  rv_csr now routes it by delegation -- SEIP when
`mideleg[9]=1` (Linux), MEIP otherwise -- instead of always raising MEIP.  Without
this, a delegated external IRQ would ALSO raise MEIP, which the kernel in S takes
unconditionally, stealing the IRQ into M-mode (OpenSBI, no PLIC handler).  The
`[IRQCHAIN]` `meip=0` while `seip>0` confirms no stealing.  Bare/compliance keep
`mideleg[9]=0`, so `MEIP=ext_irq` exactly as before (no-op; RV64 117/117, RV32
88/88 unchanged).

### Next steps
- rwsem WARN x2 (non-fatal, `bus_type_sem` @tty_init, PID1) still open; chase
  with the #11 method (`[RCPROBE]`-style PC probe + `BOOT_WATCH_PA` +
  `BOOT_DCWIN`).
- Bare repro gap: bug #11 needs an S-mode + satp + TLB-miss + AMO test
  (planned alongside the RISCOF S/U + PMP work).
- Drive PID1 further: a real shell (buildroot) over ttyS0, RX-interrupt console
  input (precursor to P1 on-hardware bring-up).

### (resolved) blocker (2026-06-07): slow boot / `udelay` spin; no earlycon banner yet
With the storm gone, the kernel runs deep into `start_kernel` (memory-init `__memset`,
varied kernel code, 50M+ cycles of forward progress) but eventually spins ~26M cycles in
`udelay` (`0xffffffff8094f380`, an `rdtime`-polling loop: `elapsed = rdtime - start`,
loop while `elapsed < target`).  The `time` CSR (= CLINT `mtime`, `rv_timer` +1/cycle)
**does advance** (progress now prints `mtime=N` at N·1M cycles), so this is NOT a hang --
the `target` is just ~26M ticks.  `chars` is still 1724 (no kernel earlycon "Linux
version" yet).  Open questions for next session: (1) `udelay` caller/arg/target via the
`[UDELAY]` probe (is `riscv_timebase` set, or is the arg genuinely huge?); (2) is
`earlycon=sbi` actually registered (do any SBI console ecalls happen), or are we still
before `setup_arch`'s `parse_early_param`?; (3) write-through `__memset` is the rate
limiter -- consider a higher `BOOT_MAX` (hundreds of M) and/or perf.  DTS
`timebase-frequency=1000000`.  New trace knobs: `[UDELAY]`, `mtime=` in `[progress]`,
`BOOT_DCWIN=<cyc>` (per-cycle D-cache + `[MSCR]`/`[MSREG]` CSR window).

## (historical) Bring-up status (2026-06-06): boots into the kernel, hangs in early head.S

What works:
- OpenSBI v1.2 prints its **full banner + platform info** (1724 UART chars, through
  `Boot HART MEDELEG`) and `MRET`s into the kernel at `0x80200000` (S-mode) at
  ~8.85M cycles -- the same proven OpenSBI path.
- The kernel runs early `head.S`, calls `setup_vm`, and **enables the Sv39 MMU**
  (`relocate_enable_mmu`): execution moves to virtual `0xffffffff800010xx`.

Where it hangs -- **two distinct blockers**, both surfaced only by real kernel code
(dense RVC, 2-byte-aligned 32-bit instructions, the MMU-on I-fetch path) that the
unit/compliance/OpenSBI tests never exercised:

1. **I$ returns wrong instruction bytes after MMU enable (caches on).**
   At virtual `0xffffffff800010fa` the core commits `inst=...e422` (a garbage RVC
   stream that happens to self-loop) instead of the real `jal` (`0xf77ff0ef`).  The
   `Image`/`vmlinux` bytes at that address ARE correct (`f77ff0ef`); the garbage
   the core executes lives **elsewhere** in the image (~offset `0x2300`).  The I$
   is **physically tagged** (`rv_cpu`: `imem_addr = mmu_imem_pa`), so this is
   either the MMU mistranslating `0x...10fa` or the I$ returning the wrong line for
   physical `0x802010fa`.  Note `0x...10fa` is a **2-byte-aligned 32-bit `jal` that
   straddles a 4-byte word boundary** -- the exact case the variable-length-fetch /
   I$ part-select path is most fragile in (CLAUDE.md "RVC / 可変長フェッチ").  The
   kernel then loops on the garbage and eventually parks in the OpenSBI M-mode trap
   handler (`0x80000410`) by ~82M cycles.

2. **With the I$ bypassed (`BOOT_NO_DCACHE`/`BOOT_NO_ICACHE`), fetch is correct but
   the kernel still triggers an OpenSBI fatal `sbi_hart_hang` (`0x80009f26`)** after
   the banner (chars=1724) -- a separate early-boot fault the kernel hits even with
   correct instruction bytes.  Cause not yet isolated (no trap dump is printed, so
   OpenSBI hangs before/within `sbi_trap_error`).

### How it was traced (all via `make vl_boot ... BOOT_TRACE=1 BOOT_EXEC=1`)
- 1M-cycle `[progress]` PC samples localize the phase (firmware vs kernel-physical
  vs kernel-virtual).
- `[trap @cyc] ... mcause=.. mepc=..` (under `BOOT_TRACE`) shows every trap/MRET --
  it caught the `MRET` into the kernel and the early SBI `ECALL` (mcause=9) traffic.
- `EXEC cy=.. pc=.. inst=..` (under `BOOT_EXEC`, bound with `BOOT_EXEC_LO`) shows the
  committed-instruction stream; comparing `inst` to `objdump -d vmlinux` at the same
  PC is what revealed the I$ wrong-bytes bug.
- `objdump -d vmlinux` / `od -A x -t x4 Image` map PCs to source and confirm the
  on-disk bytes are correct.

### Next steps
- Resolve blocker 1: probe the MMU PA vs the I$ line for virtual `0x...10fa` (add a
  post-MMU `[IMIS]`-style check that compares I$ output to the shared DDR at the
  **translated PA**; the existing `[IMIS]` only runs while `satp=0`).  Likely a
  word-straddle / RVC part-select bug in `rv_icache` or the core IF, or an MMU PPN
  error for this mapping.
- Resolve blocker 2: capture the `mcause`/`mepc` of the trap that leads to
  `sbi_hart_hang` in the I$-off run; that is the "correct-fetch" kernel fault.
- Keep `/memory` == BFM size; raise `BOOT_MAX` as the kernel gets further.

See `docs/verilator_sim.md`, `docs/opensbi_sim.md`, and the `linux-boot-roadmap`
memory.
