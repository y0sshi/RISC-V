# Verilator fast boot simulation

`iverilog` runs the OpenSBI full boot (~8M cycles) in ~15-20 min.  That is fine
for the unit/compliance tests but far too slow for the multi-10M..100M-cycle
Linux boot.  Verilator compiles the same RTL + the same `tb_rv_boot_soc.sv`
testbench to a native C++ model that runs the **identical** boot in **~8 s**
(~100-160x faster), which is what makes Linux early-boot bring-up tractable.

The Verilator path runs the *exact same* RTL and testbench as `sim_boot`; it is
not a separate model.  Cache statistics are bit-identical to iverilog (e.g. the
mini-SBI stand-in reports `IF line-fills=654, data reads=4` under both).

## Quick start

```sh
cd src/sim
make image_verilator                              # build verilator:5.020 image (once)
make vl_boot                                       # mini-SBI stand-in (default), ~0.1 s
make vl_boot BOOT_HEX=../../tests/opensbi/work/fw_payload.hex   # real OpenSBI, ~8 s
make vl_boot BOOT_HEX=<image.hex> BOOT_MAX=200000000           # Linux, longer cap
```

`make vl_boot` reuses **all** the `sim_boot` knobs (they are compile-time `-D`
defines, so changing one rebuilds the model -- the build is only ~7 s):
`BOOT_HEX`, `BOOT_MAX`, `BOOT_TRACE`, `BOOT_EXEC`/`BOOT_EXEC_LO`, `BOOT_WIN`,
`BOOT_HANG_PC`, `BOOT_DUMP_AT`, `BOOT_ICACHE_SETS`/`BOOT_DCACHE_SETS`,
`BOOT_NO_ICACHE`/`BOOT_NO_DCACHE`.  See `tb_rv_boot_soc.sv` and
`docs/opensbi_sim.md`.

## How it is wired (`src/sim/Makefile`)

- **Image** `verilator:5.020` (`src/sim/Dockerfile.verilator`): Ubuntu 24.04 ships
  Verilator 5.020; the image adds the host C++ toolchain (`build-essential`,
  `make`, `perl`, `ccache`) that Verilator needs to compile the generated model.
  (The `iverilog:13.0` image *has* verilator but no `g++`/`make`, so it cannot
  build the model -- hence a dedicated image.)
- **Build** `verilator --binary -j 0 --timing -Wno-fatal -O3 -CFLAGS -O2`
  `-DRV_XLEN_64 -DRISCV_FORMAL` over `$(BOOT_SRC) tb/tb_rv_boot_soc.sv`, top
  `tb_rv_boot_soc`, into `out/vl_boot/`.
  - `--timing` handles the testbench's `#`-delay clock (`always #5 clk`); the rest
    of the TB is edge-driven (`@(posedge clk)`), which Verilator likes.
  - `-Wno-fatal` keeps the known-benign WIDTH/LATCH lint warnings non-fatal.  The
    RTL is iverilog-clean; these are width-extends in the FPU/CSR and intentional
    combinational latches in `rv_fpu_misc_d`.
- **Run** executes `out/vl_boot/tb_rv_boot_soc` in the same container.

## RTL change required for Verilator (one, non-regressive)

Verilator rejects a **delayed (non-blocking) assignment to an array inside a for
loop** (`%Error-BLKLOOPINIT`).  The two caches reset/flush their `valid` bits with
`for (i..) valid[i] <= 0;`.  Fix: declare `valid` as a **packed vector**
(`logic [SETS-1:0] valid`) and reset/flush with a single `valid <= '0;`.  Bit
selects (`valid[idx]`, `valid[fill_idx] <= ..`) are unchanged.  This is cleaner SV,
synthesizes identically, and is bit-identical on iverilog (icache 42/42,
dcache 64/54, cache_soc 6/6, full boot `IF line-fills=654` all unchanged).
Files: `src/rtl/cache/rv_icache.sv`, `src/rtl/cache/rv_dcache.sv`.

## Validation

| firmware | iverilog | Verilator | result |
|----------|----------|-----------|--------|
| mini-SBI stand-in | ~minutes | **0.12 s** | identical console, PASS, IF fills=654 |
| real OpenSBI v1.2 fw_payload | ~15-20 min | **7.6 s** | identical banner + `PAYLOAD: hello`, sentinel 0xC0FFEE, 1764 chars |

## Next (toward Linux)

Bake a Linux `Image` into `fw_payload` (`tests/opensbi/build.sh` with
`FW_PAYLOAD_PATH=Image`, `FW_PAYLOAD_OFFSET>=0x200000`) and
`make vl_boot BOOT_HEX=.../fw_payload.hex BOOT_MAX=<large>` to reach the
`earlycon` banner.  See the `linux-boot-roadmap` memory and `docs/opensbi_sim.md`.
