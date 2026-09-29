# OpenSBI-style boot in simulation (shared DDR + fw_payload)

This sets up a simulation environment that boots an M-mode firmware image from a
**single shared DDR** through the cached AXI path -- the sim analogue of the real
board where the instruction and data masters fan into an AXI SmartConnect and
reach one PS DDR.  It is the harness a real **OpenSBI `fw_payload`** drops into,
and it is proven today by a small **mini-SBI stand-in firmware**.

## Components

| File | Role |
|------|------|
| `src/sim/tb/rv_axi_dualport_mem_bfm.sv` | One byte memory, two AXI slave ports (IF read-only + data read/write), burst reads, `$readmemh` init. = one shared DDR. |
| `src/sim/tb/tb_rv_boot_soc.sv` | Boots a firmware hex on `rv_soc` (I$/D$ on) with both masters into the shared DDR; deserializes the UART (8N1) to the console; detects completion via a tohost sentinel. |
| `src/software/boot/sbi_boot.S` | Mini-SBI stand-in firmware (OpenSBI essentials). |
| `src/software/boot/boot.ld` | Links the firmware flat at DDR base `0x8000_0000`. |

## Run the stand-in (works now)

```sh
cd src/software && make boot          # build boot/sbi_boot.hex (RV64, via docker gcc)
cd ../sim       && make sim_boot      # boot it on rv_soc (caches on), shared DDR
```

Expected console:

```
----- boot console (firmware: ../software/boot/sbi_boot.hex) -----
M: mini-SBI boot, PMP set, entering S-mode
S: hello from supervisor via SBI ecall console
BOOT OK
----- end of console (98 UART chars; IF line-fills=322, data reads=4) -----
tb_rv_boot_soc: PASS (firmware reached SBI done; sentinel=0x00c0ffee)
```

What the stand-in exercises -- exactly the integration OpenSBI needs, end to end
over the cached shared-DDR AXI path:
- M-mode entry at `RST_ADDR`, M trap vector, **PMP** opened (region 0 = all RWX).
- **M-mode UART console** (direct register poll/write).
- **M->S transition** via `MRET` (`mstatus.MPP=S`, `mepc`).
- **SBI console path**: S-mode `ECALL` -> M trap handler (`mcause=9`) -> UART
  putchar -> `MRET` back to S (the SBI `console_putchar` shape).
- **SBI "done"**: an `ECALL` whose handler writes the completion sentinel.

### Bug found & fixed by this harness

`rv_periph` returned a 32-bit MMIO register zero-extended on the low 32 bits.  On
**RV64** the core right-shifts a sub-XLEN load by `addr[2:0]*8` to pick the byte
lane of a 64-bit word, so a 32-bit register at a word offset with `addr[2]=1`
(e.g. UART `STAT` @ +4) was shifted out (`>>32`) and read as 0 -- the S-mode
console hung polling TXRDY.  Fix: replicate the register across every 32-bit lane
(`periph_rdata <= {(XLEN/32){reg32}}`).  RV32 is bit-identical (no regression);
RV64 MMIO loads now work.  This path was never exercised before (prior SoC tests
only did peripheral *writes* + CSR reads; `sim_bm` is RV32, where `addr[2]` is not
used for lane select).

## Dropping in real OpenSBI (`PLATFORM=generic` + `fw_payload`)

The generic OpenSBI platform is fully DTB-driven, so no custom C platform is
needed -- but see the **console caveat** below.

**This has been done** -- a reproducible build script is checked in at
`tests/opensbi/build.sh` (payload `tests/opensbi/payload.S`, DTS
`docs/opensbi/rv_soc.dts`).  Run it in the riscof_run docker (riscv64-unknown-elf
gcc + dtc + make), then boot the result:

```sh
# clone OpenSBI v1.2 INSIDE docker (host git on Windows applies CRLF, which breaks
# OpenSBI's python kconfig shebangs):
docker run --rm -v <repo>:/workspace -w /workspace/tests/opensbi/work riscof_run:latest \
    bash -lc 'git clone --depth 1 --branch v1.2 https://github.com/riscv-software-src/opensbi.git'
# build payload + DTB + fw_payload + base-relative hex:
docker run --rm -v <repo>:/workspace -w /workspace/tests/opensbi riscof_run:latest bash build.sh
# boot it in the harness (src/sim path is relative so MSYS does not mangle it):
cd src/sim && make sim_boot BOOT_HEX=../../tests/opensbi/work/fw_payload.hex
```

Key build choices (see `tests/opensbi/build.sh`):
- **OpenSBI v1.2** (not master): the bare-metal `riscv64-unknown-elf` linker has
  `-pie` disabled (`--disable-shared`); master makes PIE mandatory, v1.2 builds
  non-PIE (`-fno-pie`) by default.
- `PLATFORM_RISCV_ISA=rv64imac_zicsr_zifencei` (gcc 13 needs explicit zicsr).
- `FW_TEXT_START=0x80000000` (= `RST_ADDR`); `FW_PAYLOAD_PATH` is a tiny S-mode
  payload at `FW_PAYLOAD_OFFSET=0x200000`; `FW_FDT_PATH` embeds the DTB.
- hex: `objcopy -O binary fw_payload.elf` then `objcopy -I binary -O verilog`
  (byte 0 of the .bin == `0x80000000`, so the BFM loads it base-relative).
- The shared DDR BFM is sized to **64 MiB** (`DEPTH=1<<26`).  It must cover the
  firmware + the payload (2 MiB offset) **and** OpenSBI's **FDT relocation target**
  (~`0x8220_0000` = 34 MiB, which the embedded DTB's 256 MiB `/memory` node lets
  OpenSBI choose).  8 MiB was too small: loads from the relocated FDT returned X.

### Bring-up result: FULL OpenSBI v1.2 boot (resolved 2026-06-06)

Real OpenSBI v1.2 now **boots to completion** in this harness:

```sh
cd src/sim && make sim_boot BOOT_HEX=../../tests/opensbi/work/fw_payload.hex
```

prints the full banner + platform info, drops to **S-mode**, and the S-mode
payload prints `PAYLOAD: hello ...` over the SBI console, then writes the
completion sentinel:

```
OpenSBI v1.2
   ____                    _____ ____ _____
  ...
Platform Name             : rv_soc (RV64GC教育コア)
Platform Console Device   : uart8250
Domain0 Next Address      : 0x0000000080200000
Domain0 Next Mode         : S-mode
Boot HART Base ISA        : rv64ic
...
PAYLOAD: hello ...
tb_rv_boot_soc: PASS (firmware reached SBI done; sentinel=0x00c0ffee)
ALL TESTS PASSED
```

Getting here required fixing **six + three real RTL bugs** the simpler tests
never exercised (see "Bugs found" below), then two **harness** fixes (NOT core
bugs): the 64 MiB BFM above, and enough cycles -- a full boot reaches the
sentinel at **~8M cycles** (the `BOOT_MAX_CYCLES` default is 12M; fast firmwares
exit early on the sentinel).  The boot is **slow but correct**: the I$/D$ default
to **16 KiB** (512 sets) in the boot harness (the larger D$ cuts DDR data reads
~4x); the divergence instruments (`[RUNAWAY]`/`[DLOAD BUG]`/`[FWD BUG]`) stay
silent throughout, confirming no remaining core corruption.

`rv_soc` resets to `RST_ADDR=0x8000_0000`; OpenSBI's `FW_TEXT_START` matches, and
the payload/DTB land in the shared DDR image (BFM base-relative to `0x8000_0000`).

### Console: NS16550-compatible (resolved)

`rv_uart` is now **NS16550 register-compatible** (reg-shift=2, reg-io-width=4,
16x oversampling baud), so the stock OpenSBI `uart8250` driver and the Linux
`8250`/`ns16550` driver work unmodified -- no custom platform needed.  In the DTB
use:

```dts
serial@c0010000 {
    compatible = "ns16550a";
    reg = <0x0 0xc0010000 0x0 0x1000>;
    reg-shift = <2>;
    reg-io-width = <4>;
    clock-frequency = <CLK_HZ>;   /* the PL clock feeding rv_uart */
    current-speed = <115200>;
};
```

The driver writes DLL/DLM = `clock-frequency/(16*baud)`; with the 16x baud
generator that yields the correct line rate.  Set `clock-frequency` to the actual
PL clock.  The mini-SBI stand-in and the bare-metal C driver (`startup/uart.c`)
both already use the 16550 register map (THR@0, LSR@0x14).

## Bugs found during OpenSBI bring-up

Real OpenSBI exercises paths the unit/integration tests never did (real branchy
RVC code over the I$, atomics over AXI, MMIO loads on RV64, the standard CLINT/
8250).  Each surfaced a genuine RTL bug, now fixed:

1. **`rv_periph` RV64 MMIO load lane** -- a 32-bit MMIO register at a word offset
   with `addr[2]=1` (UART STAT @ +4) was zero-extended on the low 32 bits and
   shifted out by the core's `>>32` lane select.  Fix: replicate across lanes.
2. **UART NS16550 compatibility** -- so OpenSBI `uart8250` / Linux 8250 work
   (see "Console", above).
3. **`rv_axi_burst_bridge` `s_rdata` not held** -- the cache-bypass data port reads
   `dmem_rdata` one cycle after completion; the burst bridge presented read data
   only combinationally on the beat.  Fix: hold the last beat in `rdata_hold`.
4. **`rv_icache` `addr_q` != `fetch_pc`** -- the I$ latched `imem_addr` every cycle,
   so a branch/trap redirect that changed `imem_addr` while the I$ held
   `c_ready=0` during a miss fill made `addr_q` diverge from the core's `fetch_pc`;
   the I$ then returned the redirect target's window mis-tagged as `fetch_pc`.
   Fix: advance `addr_q` only on `c_ready` (the same enable as `fetch_pc`),
   init = `RST_ADDR`.
5. **`rv_timer` standard SiFive CLINT layout** -- was mtimecmp@0x0 / mtime@0x8
   with only `addr[3:2]` decoded, so OpenSBI's `riscv,clint0` driver (msip@0x0,
   mtimecmp@0x4000, mtime@0xBFF8) collided msip onto mtimecmp.  Fix: full SiFive
   layout + msip -> `sw_irq` wired to the core.
6. **AMO 2-phase FSM duplicate execution** -- after the write phase completed,
   `amo_state` toggled back to 0; if the AMO was still held in MEM by an unrelated
   stall (`~imem_ready` during an in-flight I$ fetch), it re-entered the read phase
   and the whole AMO ran twice.  OpenSBI's boot-hart lottery `amoadd.w` ran
   0->1->2, so the single hart "lost" and span forever in `_wait_for_boot_hart`.
   Fix: advance read->write once and HOLD the write phase (re-issuing the write is
   idempotent) until the AMO leaves MEM.  (`amo_state` is gated by `is_amo`, so it
   cannot leak to the next instruction -- unlike `mal_state`, which must still drop
   the cycle the access advances.)

### Caches-on stall/forward corruption (2026-06-05/06): two RTL bugs FIXED

The original "~140k crash" (a stack restore `ld ra,24(sp)` reading an unwritten
address, `ret` -> PC X) was root-caused to **two distinct RTL bugs**, both only
exposed by the I-cache's **mixed `imem_ready` hit/miss timing** (BRAM is always
ready, the cache-bypass IF path is always not-ready -- neither produces the mixed
freeze pattern).  Both are fixed in `rv_core.sv` and are provable no-ops when
`imem_ready=1` every cycle (all BRAM/unified-mem paths).  Full regression after
both: **RV64 117/117, RV32 88/88**, all `sim_*`, mini-SBI boots.  See CLAUDE.md
"RTL バグ修正履歴" for the detailed write-ups.

1. **EX-stall forward-source loss -> store address corruption** (ID/EX register).
   In `addi sp,-16; sd ra,8(sp); sd s0,0(sp)`, when `sd ra` asserts `dmem_wait`
   (store in flight) the whole pipeline freezes; `sd s0` is frozen in EX needing
   `sp` forwarded from MEM/WB.  The freeze **bubbles MEM/WB** (load-corruption
   protection), dropping the `addi sp`->`sp` forward source, so `sd s0` reverts to
   its stale ID/EX `sp` and stores to the wrong slot.  Fix: while held in EX, latch
   the forwarded operands (`id_ex_rs1/rs2_data <= fwd_rs1/rs2_data`, + FP).
   Reproducer: `src/software/boot/stack_test.S` (`make stack_test`).

2. **Held MEM/WB load re-written from a younger load's `dmem_rdata`** (WB stage).
   In `ld ra,40(sp); ld s0,0(sp)`, `ld ra` sits in MEM/WB while an IF miss freezes
   the pipeline; MEM/WB **holds** (to keep the forward source), but `wb_data` for a
   load is computed from **live `dmem_rdata`**, which now reflects the **younger
   `ld s0` re-issuing from the frozen MEM stage** -> `ra` gets `ld s0`'s data.  Fix:
   latch `dmem_rdata` on the load's FRESH WB cycle (`mem_wb_fresh`) into
   `dmem_rdata_held` and use `dmem_eff` for `dmem_shifted`/`mal_wide`.

### THIRD bug FIXED (2026-06-06): JAL/JALR link-write lost via flush_ex

The infinite libfdt alias recursion (`fdt_path_offset("/cpus")` returning -5) was
root-caused to a **lost JAL link-register write**, NOT a load/forward corruption.
A `jal sbi_memchr` right after `sd s6,off(sp)` resolved its redirect while the
store's `dmem_wait` still held EX (`stall_ex=1`, `imem_ready=1`).  The old
`flush_ex = ((load_use && !stall_ex) | redir_eff) & imem_ready` fired (imem_ready=1)
and **cleared the jal from ID/EX**, but `stall_ex` prevented EX/MEM from capturing
it -> the jal (and its `ra` write) vanished.  PC still redirected to memchr, but
`ra` stayed stale, so the matching `ret` returned to the wrong address -> libfdt
treated "/cpus" as an alias -> deep recursion -> -5 -> `_start_hang`.  Conditional
branches survive this (no writeback); only JAL/JALR are harmed.  Fix in
`rv_core.sv`: gate the redirect flush by `~stall_ex` (the exact advance condition):
`flush_ex = (load_use_hazard | redir_eff) & ~stall_ex` (`~stall_ex` implies
`imem_ready`, so it is a no-op for BRAM/clean paths).  Found via the EXEC trace
showing `jal` at e2e4 with no `x1<=e2e8` writeback.  Non-regressive: RV64 117/117,
RV32 88/88, all `sim_*`.

How it was found (decisive instruments added to `tb_rv_boot_soc.sv`, all under
`BOOT_TRACE`): (1) **D-load-vs-DDR result check** (`[DLOAD BUG]`) proved every load
result matches the shared DDR -> not a load/D$/fix#2 bug; (2) **forwarded-operand-
vs-regfile check** (`[FWD BUG]`) proved stable-reg forwards match the regfile ->
not a fix#1-family forward bug; (3) the EXEC stream then showed the jal redirecting
without writing its link.  A `[RUNAWAY]` ring-dump (fetch_pc leaving the firmware)
locates the next failure.

### Final blocker RESOLVED (2026-06-06): harness/DTB memory-size mismatch (NOT a core bug)

After the flush_ex fix, the last failure was a runaway: at cy ~512k `x18 <=
0x82200000` (OpenSBI relocates the FDT there), then loads from `0x82200008`
returned **X** because the shared-DDR BFM was only **8 MiB** (`DEPTH(1<<23)`,
0x8000_0000-0x807F_FFFF) while the embedded DTB declares **256 MiB** of DRAM
(`memory@80000000 reg=<0x0 0x80000000 0x0 0x10000000>`, `docs/opensbi/rv_soc.dts`),
so OpenSBI relocated the FDT to ~34 MiB, out of the BFM's range -> X reads -> X
regs -> X jump target -> PC NOP-sled.  **Fix (harness, not core): enlarge the BFM
`DEPTH` to `1<<26` (64 MiB)** in `tb_rv_boot_soc.sv` to cover the relocation
target.  (Alternatively shrink the DTB `/memory` to the BFM size and rebuild via
`tests/opensbi/build.sh`; the BFM enlargement is the one-line option.)

With that, OpenSBI **boots fully to the S-mode payload + sentinel** (see "Bring-up
result" above).  What looked like a second libfdt "hang" after the banner was
**not a hang**: an EXEC trace of `fdt_next_node`/`fdt_next_tag` showed the FDT
offset advancing monotonically (0xd4 -> 0xe4 -> 0xf4 -> ...) and the node walk
returning cleanly -- libfdt was simply **slow** (the I$/D$ thrash on the dense
RVC libfdt code; a full boot is ~8M cycles).  The 3M-cycle / 2 MiB-cache earlier
runs just timed out mid-init.  `[DLOAD BUG]`/`[FWD BUG]`/`[RUNAWAY]` never fired.
Resolution: the boot harness now defaults to **16 KiB I$/D$ (512 sets)** and a
**12M-cycle** cap; no RTL change was needed.

Debug entry points (all in `tb_rv_boot_soc.sv`, Makefile passthroughs; gated, no-op
by default) -- kept for the next bring-up phase (Linux payload):
- `BOOT_TRACE=1` -- enables the divergence instruments (`[RUNAWAY]` ring-dump when
  `fetch_pc` leaves the firmware, `[X]` on `fetch_pc->X`, `[DLOAD BUG]`
  load-result-vs-shared-DDR, `[FWD BUG]` forwarded-operand-vs-regfile, `[IMIS]`
  I$-vs-DDR, `[DUP]` double EX->MEM capture).  All print only on a detected fault.
- `BOOT_EXEC=1 [BOOT_EXEC_LO=<cyc>]` -- committed-instruction + WB + MEM stream
  (bound the log with `BOOT_EXEC_LO`).  This is what showed the FDT offset
  advancing (i.e. proved "slow, not stuck").
- `BOOT_WIN=<cyc>` -- 30-cycle per-cycle pipeline-state dump.
- `BOOT_HANG_PC=<decimal>` / `BOOT_DUMP_AT=<cyc>` -- one-shot dumps at a PC / cycle
  (pass DECIMAL for the PC; a `'` in `64'h..` breaks the docker `sh -c` recipe).
- `BOOT_ICACHE_SETS=N` / `BOOT_DCACHE_SETS=N` -- override the L1 sizes per run.
- `BOOT_VCD=1` -- opt-in VCD dump (off by default: dumping the 64 MiB BFM array at
  t=0 bloats the VCD and slows the run; `wave_boot` sets this automatically).
- fw_payload.hex is at `tests/opensbi/work/fw_payload.hex` (gitignored; rebuild via
  `tests/opensbi/build.sh`).

Next phase (toward Linux): set the payload to a Linux `Image` (`earlycon=sbi`
first, then the 8250 console via DTB), and consider a bigger / faster cache or a
shorter DTB to keep the multi-million-cycle sim tractable.

## Sample device tree

A starting `rv_soc.dts` matching the SoC memory map (CLINT 0xC000_0000, UART
0xC001_0000, GPIO 0xC002_0000, PLIC 0xC010_0000, DRAM at 0x8000_0000) is provided
at `docs/opensbi/rv_soc.dts`.  Set `bootargs`, `timebase-frequency` (CLINT mtime
rate), and the `memory` size to match the board; fix the UART `compatible`/driver
per the console caveat.

## Next steps toward Linux

1. ✅ UART 16550 compatibility (OpenSBI/Linux console driver works -- done).
2. ✅ Real OpenSBI `fw_payload` boots fully in `sim_boot` -- banner + platform info
   + M->S transition + S-mode payload over the SBI console + sentinel (done).
3. Payload = Linux `Image`; `earlycon=sbi` first, then the 8250 console via DTB.
4. Move to FPGA: PS DDR via S_AXI_HP (`boards/*/vivado`), DTB matching the map.

See also `docs/cache.md`, `docs/axi_ddr.md`, and the `linux-boot-roadmap` memory.
