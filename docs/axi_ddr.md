# AXI4 / DDR Memory Subsystem (Linux readiness: memory expansion)

Status as of this work increment. This is the **top-priority Linux blocker**:
moving the core's memory from on-chip BRAM (KB) to PS DDR (GB) via an AXI4
master bridge. See also CLAUDE.md "Linux 対応ロードマップ" and the
`linux-boot-roadmap` memory.

## Goal

Replace `rv_imem` / `rv_dmem` (production) and `rv_unified_mem` (ACT) with a
path to external DDR, by bridging the core's simple synchronous memory bus to
an **AXI4 master**. On Zynq this AXI master connects (via AXI SmartConnect) to
an **S_AXI_HP** port and thus to PS DDR (Zybo Z7-20: 1 GB DDR3; KV260: 4 GB
DDR4). The existing BRAM (production) and unified-mem (ACT) builds remain
intact; AXI is an **additive third configuration**.

## Where the bridge sits

The bridge sits on the **physical-address side**, i.e. AFTER the MMU. There
are three physical access sources, already exposed by `rv_soc`:

| Source            | Direction | Core/MMU signals (physical side)                 |
|-------------------|-----------|--------------------------------------------------|
| Instruction fetch | read      | `mmu_imem_pa`, `mmu_imem_req` -> `imem_rdata/ready` |
| Data load/store   | read/write| `mmu_dmem_pa`, `core_dmem_wdata/wstrb`, `mmu_dmem_we` -> `dmem_rdata/ready` |
| Page-table walk   | read      | `ptw_paddr`, `ptw_req` -> `ptw_rdata`, `ptw_ready` |

`rv_soc` already arbitrates PTW over the data port (PTW has priority). So the
AXI subsystem needs **two AXI masters**: one read-only (IF), one read/write
(data + PTW arbitrated). On real hardware these go through an AXI interconnect
to one or two HP ports; the read/write channels of a Zynq HP port are
independent, matching AXI.

## Variable-latency tolerance of the core (key finding)

DDR has variable latency. The core handles this per-port differently:

| Port | Latency tolerant today? | Mechanism |
|------|-------------------------|-----------|
| **IF**  | Designed-for, but **untested** | `stall_if` includes `~imem_ready`; `imem_addr` re-presents `fetch_pc` while stalled. **BUT** the BRAM models never deassert `imem_ready`, so this path has never actually run with a slow memory. |
| **PTW** | Yes | The PTW FSM in `rv_mmu` waits on `ptw_ready` (with `ptw_wait` to bridge the 1-cycle address-settle gap). |
| **Data load/store** | **No** | `dmem_ready` was **not used to stall** anywhere. The core issues the access in MEM and consumes `dmem_rdata` in WB at a fixed +1 offset. The AMO and misaligned 2-phase FSMs also assume 1-cycle memory. |

### Hazard discovered on the IF path (must solve before IF-over-AXI)

`stall_if`/`stall_id` freeze IF/ID and ID/EX, but `stall_ex` does **not** freeze
EX/MEM for the `~imem_ready` / `mmu_stall` / `redirect_settle` reasons. With
the always-ready BRAM, `~imem_ready` never fires, so this is never exercised.
Under a slow IF memory, an instruction held in ID/EX (because `stall_id` froze
it) while EX/MEM keeps advancing would be **re-issued to EX/MEM every stalled
cycle** -> duplicated MEM/WB side effects (repeated stores, repeated rd writes).
In practice this is masked today because `mmu_stall` only occurs right after a
redirect (pipeline behind is mostly bubbles). IF-over-AXI stalls on *every*
fetch, so it would surface. **Fix needed:** when IF stalls for "fetch not
ready", insert a bubble into EX/MEM after the EX instruction advances once
(standard "stall stages 1..N, bubble stage N+1"), without breaking branch/trap
resolution in EX (see the existing `redirect_settle` comments in `rv_core.sv`
for why `stall_ex` must not naively freeze EX during redirects).

## The `dmem_wait` core contract (implemented)

A new input was added to `rv_core`:

```
input wire dmem_wait;   // high while a MEM-stage data access is in flight
```

- Threaded into `stall_if`, `stall_id`, `stall_ex` (`| dmem_wait`), and guards
  the `amo_state` / `mal_state` FSM advance and the MEM/WB register advance
  (`&& !dmem_wait`).
- **Provably a no-op when tied to 0**: every added term reduces to its original
  form. All non-AXI instantiations (`rv_soc` both modes, and the direct-core
  testbenches `tb_rv_pipeline/intr/mal/fpu_pipe`) tie `dmem_wait = 1'b0`.
- Semantics: the data memory asserts `dmem_wait` while servicing the MEM access
  and drops it on the completion cycle. EX/MEM stays frozen (load held in MEM)
  until completion; on completion the load advances to WB and reads the held
  `dmem_rdata`. The bridge must **hold `dmem_rdata` stable** from completion
  through the following (WB) cycle.

### Known follow-up for `dmem_wait`

- Simple (non-crossing, non-AMO) loads/stores are handled correctly.
- **AMO**: the read-phase result is consumed one cycle after read completion
  (phase 1), which lines up with the bridge's registered `dmem_rdata`. Believed
  correct but needs simulation confirmation.
- **Misaligned (mal) 2-phase**: `mal_first_data <= dmem_rdata` capture timing
  was designed for 1-cycle memory. Under variable latency the capture of the
  phase-0 word vs. the start of the phase-1 access needs rework (the
  `if (!dmem_wait)` guard currently skips the capture during the phase-1 wait).
  RV32 FLD/FSD always cross a word boundary, so this path is heavily used in
  RV32 D programs. **This is the main remaining data-path item.**

## New RTL / sim modules (this increment)

- `src/rtl/bus/rv_axi_bridge.sv` - simple-bus <-> AXI4 master, single-beat,
  single-outstanding FSM. Params: `ADDR_WIDTH`, `DATA_WIDTH`, `ID_WIDTH`,
  `READ_ONLY`. Exposes `s_req/s_we/s_addr/s_wdata/s_wstrb` in,
  `s_rdata/s_ready/s_busy/s_wait` out. `s_ready` is a 1-cycle completion pulse;
  `s_wait = s_busy & ~s_ready` is the hold signal for the data port's
  `dmem_wait`; `s_rdata` is registered and held until the next transaction.
- `src/sim/tb/rv_axi_slave_bfm.sv` - AXI4 slave memory model with RUNTIME
  programmable per-channel latency / backpressure (`ar/r/aw/w/b_delay`) and a
  byte-addressed backing store. `ALIGN=1` (data port, aligns to `DATA_WIDTH/8`),
  `ALIGN=0` (instruction port, exact byte offset like `rv_unified_mem` port A).
- `src/sim/tb/tb_rv_axi_bridge.sv` - unit testbench; write-then-read across
  latency profiles 0/1/3/7 and a per-transaction-varying profile.
  **Result: 17/17 PASS on iverilog v12.0 and v13.0.**
- `src/sim/tb/tb_rv_axi_core.sv` - integration testbench: `rv_core`'s DATA port
  routed through `rv_axi_bridge` + `rv_axi_slave_bfm` at **randomized per-cycle
  latency** (IF stays behavioral / always-ready so the IF-stall path is not
  exercised). Runs the proven pipeline programs (forwarding, load-use, branch
  fall-through, SW->LW round-trip, back-to-back loads).
  **Result: 11/11 PASS on v12.0 and v13.0** -- the `dmem_wait` data path yields
  identical architectural results under variable latency.

- `rv_soc` **`AXI_MODE`** (third build mode, `ifdef AXI_MODE`): data + PTW go out
  an exposed AXI4 master (`m_axi_*`); instruction fetch uses an internal
  always-ready `rv_unified_mem` (INIT_FILE). PTW is arbitrated onto the same
  master with priority; `core_dmem_wait` is driven by the bridge `s_wait`
  (suppressed during a PTW transaction -- the pending data access is held by the
  MMU's `mem_stall`). Existing ACT/production modes are unchanged
  (`core_dmem_wait = 0`).
- `src/sim/tb/tb_rv_axi_soc.sv` - SoC-level integration: `rv_soc` (AXI_MODE) +
  `rv_axi_slave_bfm`. Runs a loop (sum 1..10, branch-heavy) from internal IF
  memory and stores the result to the DDR model over AXI at randomized latency.
  **Result: PASS on v12.0 and v13.0.**

Run: `cd src/sim && make sim_axi` (bridge unit) / `make sim_axi_core` (core data
path) / `make sim_axi_soc` (SoC AXI_MODE)

## Verification status

- `make sim_axi` : 17/17 PASS (v12 + v13) -- bridge protocol vs latency profiles.
- `make sim_axi_core` : 14/14 PASS (v12 + v13) -- **data port over AXI at
  randomized latency, real pipeline programs (incl. boundary-crossing LW and
  crossing SW->LW), results match the BRAM path.**
- `make sim_axi_ifetch` : 22/22 PASS (v12 + v13) -- **instruction fetch over AXI
  at variable latency: sequential, JAL, BEQ, JALR, backward loop, load-use+branch.**
- `make sim_axi_soc` : PASS (v12 + v13) -- **rv_soc AXI_MODE with BOTH masters:
  branch-heavy loop fetched over the IF AXI master AND data stored over the data
  AXI master (instructions AND data in the DDR model).**
- **Full regression after the IF-over-AXI core changes (v13): RV64 117/117, RV32
  88/88** riscv-tests; all sim_* units; `make sim_soc` (production) 3/3 -- the IF
  redirect-latch + full-freeze changes are non-destructive (no-op when
  imem_ready=1 every cycle, which holds for every BRAM/unified-mem path).
- `dmem_wait` no-op proof (v13): `sim_pipeline` 19/19, `sim_intr` 9/9,
  `sim_fpu_pipe` 7/7, `sim_mal` 13/13, `sim_alu` 14/14, `sim_rv64i` 12/12,
  `sim_fpu` 94/94, `sim_fpu_d` 33/33, `sim_amo` 29/29, `sim_amo64` 38/38,
  `sim_csr` 16/16, `sim_mmu` 28/28, `sim_mmu64` 11/11, `sim_cdecode(64)` PASS.
- ACT path (rv_soc + dmem_wait=0): `riscv-tests-run GROUPS="rv64ua-p rv64ui-p"`
  = 73/73 PASS (atomics + base I, incl. ma_data misaligned).
- v12 native: `sim_mal` 13/13, `sim_pipeline` 19/19 compile + run clean.
- TODO before closing: full RV64 117 / RV32 88 + arch-test I/M/A/C (expected
  green by the no-op property; run to formally confirm).

## Bug fixed (this increment): bridge `s_wait` must rise on the request cycle

First version computed `s_wait = s_busy & ~s_ready` with `s_busy = (state != IDLE)`.
On the cycle a data access first enters MEM the bridge FSM is still IDLE
(`s_busy = 0`), so `dmem_wait` was 0 and the load advanced to WB **before the
transaction even started** -> garbage data. Fixed to
`s_wait = (s_req | s_busy) & ~s_ready` so the hold rises combinationally the same
cycle `s_req` appears and drops on the completion cycle. Caught by `tb_rv_axi_core`.

## Remaining integration plan (next increments)

- ✅ **Data port over AXI (variable latency)** -- proven by `tb_rv_axi_core`.
- ✅ **IF-over-AXI hazards solved** -- see "IF-over-AXI: problems and fixes" below.
  Proven by `tb_rv_axi_ifetch` (branches/loops) + non-destructive full regression.
- ✅ **`rv_soc` `AXI_MODE`** -- now TWO masters: instruction fetch (read-only,
  32-bit, `m_axi_if_*`) AND data + PTW (read/write, XLEN, `m_axi_*`).
  **Instructions AND data both in DDR**, proven by `tb_rv_axi_soc`.
- ✅ **Vivado scripted BD flow** -- `boards/{kv260,zybo_z720}/vivado/*.tcl`
  (PS + SmartConnect[2 SI] + S_AXI_HP; both masters), see `boards/vivado_README.md`.
- ✅ **Misaligned 2-phase data capture over AXI** -- `mal_first_data` now latched
  at the FIRST cycle of phase 1 (see below), proven by `tb_rv_axi_core` crossing
  LW / crossing SW->LW at variable latency.
1. **PTW-over-AXI** + **traps under IF latency** soak: the EX-stage trap/MRET CSR
   update is not yet gated by imem_ready, so a trap that resolves while the IF
   fetch is mid-flight could double-update mstatus under non-zero IF latency.
   Harmless today (no traps in the AXI sims; compliance runs at imem_ready=1),
   but gate `trap_enter/mret_en/sret_en/retire_en` by the advance cycle before
   trap-heavy IF-AXI workloads.
2. **Shared-memory dual-port AXI BFM** + run a full riscv-test hex over AXI
   (single shared DDR image) and compare signature to the ACT result.
3. **Full arch-test (RISCOF I/M/A/C)** re-confirm on v12+v13.
4. Board bring-up: bitstream, DDR preload, boot.
5. (later) I/D caches for throughput; bursts in the bridge.

## Misaligned 2-phase capture under variable latency

A boundary-crossing load/store runs a 2-phase FSM (`mal_state`): phase 0 accesses
the first aligned word, phase 1 the second; for a load the WB stage combines the
phase-0 word (`mal_first_data`) with the phase-1 word (`dmem_rdata`). RV32 FLD/FSD
*always* cross (8 bytes on a 4-byte bus). The original capture
`if (mal_cross && mal_state && mem_read) mal_first_data <= dmem_rdata` was gated by
`!dmem_wait`; under AXI that fired at the phase-1 *completion* (dmem_rdata = the
SECOND word) -> wrong. Fix: capture at **`mal_phase1_start` = the first cycle of
phase 1** (`mal_state` just went 0->1), ungated by dmem_wait. On that cycle
dmem_rdata holds the phase-0 word for both memories -- a 1-cycle memory has it
valid the cycle after the phase-0 issue (== now), and the AXI bridge holds it in
`rdata_q` until the phase-1 read completes. Timing-equivalent for a 1-cycle memory
(phase 1 is a single cycle there), so non-destructive: `sim_mal` 13/13, RV64
ud+ui 66/66, RV32 ud+ui 52/52 (rv32ud = all-crossing FLD/FSD).

## IF-over-AXI: problems and fixes

Putting instructions in DDR means `imem_ready` deasserts during a multi-cycle
fetch -- a path the BRAM/unified-mem models never exercise (they are always
ready). Three coupled bugs surfaced (caught by `tb_rv_axi_ifetch`), each fixed
so the change is a NO-OP when `imem_ready=1` every cycle (all existing paths):

1. **Stale instruction capture.** The bridge's `s_rdata` was registered (valid
   one cycle *after* `s_ready`). The data port samples in WB (one cycle later) so
   that was fine, but the IF port captures `imem_rdata` in the *same* cycle as
   `imem_ready=1` -> it got stale data. Fix: `s_rdata = read_done ? m_axi_rdata :
   rdata_q` -- present AXI read data combinationally on the completion cycle, and
   keep the registered copy for the late (data-port) sampler.
2. **Redirect loss.** A branch/trap resolves in EX for one cycle; `flush_ex`
   clears it from ID/EX immediately, but the redirect to `imem_addr` was gated by
   `!stall_if` and `stall_if` is high during the in-flight fetch -> the redirect
   was lost. Fix: a **latched pending redirect** (`redir_pend_q`/`redir_pend_tgt_q`)
   applied at the next fetch boundary; `fetch_pc` now advances only on
   `imem_ready` (stable during a transaction so the AXI bridge fetches a
   consistent address and `if_id_pc` tags it correctly); `flush_id = redir_eff &
   imem_ready` keeps wrong-path fetches killed through the pending window.
3. **Duplication.** `stall_id` froze ID/EX while `stall_ex` did not freeze EX/MEM
   (or MEM/WB), so a held instruction was re-committed every stalled cycle
   (e.g. `add x1,x1,x2` self-forwarded into a runaway accumulation). Fix: a
   **full pipeline freeze** during the fetch -- `~imem_ready` added to `stall_ex`,
   and `imem_ready` gates the MEM/WB advance and the flushes. EX/MEM and MEM/WB
   hold (state preserved -> forwarding intact, no re-commit); the branch stays in
   EX (frozen) and commits its rd (JAL link) exactly once on the completion
   cycle. (Bubbling instead of freezing was tried first and broke forwarding for
   sequential code, since it wiped the EX/MEM forward source mid-stall.) Unlike
   `mmu_stall`, the IF fetch uses its own AXI master, so freezing EX/MEM does not
   conflict with the data port.

## Vivado Block Design (board integration, Phase 3)

**Scripted (no GUI) -- see `boards/vivado_README.md`.** The reproducible TCL
flow lives at `boards/kv260/vivado/build_kv260.tcl` (PS8) and
`boards/zybo_z720/vivado/build_zybo.tcl` (PS7):

```sh
vivado -mode batch -source boards/kv260/vivado/build_kv260.tcl -tclargs bit
```

Each script creates the project, adds the `rv_soc` (AXI_MODE) sources with the
`AXI_MODE` (+ `RV_XLEN_64`) defines, builds a block design (PS + AXI
SmartConnect + S_AXI_HP), connects `rv_soc.m_axi` (AXI master inferred from the
`m_axi_*` ports) to the HP port, wires clock/reset, assigns addresses, makes the
wrapper, and (optionally) runs synth/bitstream. **Address-map caveat**: in
AXI_MODE the program's data addresses must target PS DDR (not the repo default
`0x8000_0000`); see the README.

Target: connect the PL RISC-V (as AXI master) to PS DDR via S_AXI_HP.

Conceptual steps (now automated by the scripts above):
1. Create a Vivado project; add `rv_soc` (AXI_MODE) + the two `rv_axi_bridge`
   AXI master interfaces packaged as an IP, or instantiate in a top-level BD
   wrapper.
2. Add the Zynq Processing System IP:
   - **Zybo Z7-20**: `processing_system7` (PS7). Enable one **S_AXI_HP** port
     (e.g. S_AXI_HP0, 64-bit). Enable a PL clock (FCLK_CLK0, e.g. 50-100 MHz)
     and `FCLK_RESET0_N`.
   - **KV260**: `zynq_ultra_ps_e` (PS8). Enable an **S_AXI_HP** port
     (HP0, up to 128-bit). Enable a PL clock (pl_clk0) and `pl_resetn0`.
3. Insert an **AXI SmartConnect** (or AXI Interconnect): the two core masters
   (IF, data) on the slave side; the PS HP port on the master side. If using a
   single HP port, both masters fan into the SmartConnect.
4. Set the HP port address range to cover the DRAM region used by the program
   (must match `RST_ADDR`, the linker layout, and the DTB `memory` node).
5. Connect `pl_clk0`/FCLK to `clk` (core + bridges) and the PS reset to `rst_n`.
   Hook UART/GPIO to PMOD or EMIO as today (`kv260_top.sv` / `zybo_z7_top.sv`).
6. Validate BD, generate wrapper, set the `.xdc` constraints, build bitstream.
7. Boot/load flow (Phase 2): preload OpenSBI + kernel + rootfs into DDR
   (JTAG or PS U-Boot), with a DTB whose memory/CLINT/PLIC/UART nodes match the
   SoC memory map (CLINT 0xC000_0000, UART 0xC001_0000, GPIO 0xC002_0000,
   PLIC 0xC010_0000).

Current board tops (`kv260_top.sv`, `zybo_z7_top.sv`) only instantiate `rv_soc`
with BRAM (`IMEM_DEPTH/DMEM_DEPTH`). The `// TODO: Add AXI interface` in
`kv260_top.sv` is where the AXI_MODE wiring + PS BD integration lands.
