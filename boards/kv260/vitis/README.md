# KV260 real-HW bring-up (Vitis / boot side)

Offline (no-board) preparation for booting the RISC-V SoC bitstream on real
KV260 hardware. The Vivado bitstream side is in `../vivado/`; this directory
holds the PS-side boot artifacts (XSA -> FSBL+PMUFW) and the JTAG bring-up
script.

## ⚠️ Read this before relying on the scripts here

Unlike `boards/zybo_z720/vitis/` and `boards/pynq_z{1,2}/vitis/` (Zynq-7000,
PS7), which this directory otherwise mirrors structurally, **the KV260's
Zynq UltraScale+ (PS8) boot flow is materially different and less validated
here**:

- **Zynq-7000 JTAG bring-up is a pure register-poke script** (`ps7_init.tcl`
  extracted from the XSA, sourced and called directly over JTAG -- no code
  ever runs on the ARM cores). This is what `fsbl.py` + `bringup_jtag.tcl` do
  for Zybo/PYNQ, and it was empirically proven to work there.
- **Zynq UltraScale+ has no equivalent register-poke-only path.** PS8
  bring-up over JTAG requires actually running an FSBL (on the APU,
  Cortex-A53) AND a PMU firmware image (PMUFW, on the separate MicroBlaze-
  based Platform Management Unit) -- confirmed via AMD's own documentation
  (see Sources below), not just assumed.
- `fsbl.py` here is expected to auto-generate BOTH `fsbl.elf` and
  `pmufw.elf` from a single `create_platform_component(cpu="psu_cortexa53_0",
  os="standalone", ...)` call (mirroring how the Zynq-7000 flow
  auto-generates `fsbl.elf` alone), but this has not been run against real
  Vitis 2024.2 output by the author of this port -- no KV260 hardware was
  available at authoring time. If `pmufw.elf` doesn't appear after
  `platform.build()`, you likely need an explicit second PMU domain -- see
  the comment block at the top of `fsbl.py`.
- `bringup_jtag.tcl` mirrors AMD's documented "Option 1: Boot Using JTAG"
  sequence (`fpga` -> `dow pmufw.elf` -> `dow fsbl.elf` -> `dow <app>.elf` ->
  `con`) as closely as possible, but omits two `mwr` register pokes from the
  reference example whose purpose wasn't independently confirmed, and the
  exact `targets` filter strings may need adjusting for your Vitis/hw_server
  version. **Treat it as a starting point for interactive xsct debugging,
  not a proven one-shot script** the way the Zybo/PYNQ equivalents are.

The Vivado/BD side (`../vivado/build_kv260.tcl`) does NOT have this problem --
`board_part`/`apply_board_preset`/DDR4 bring-up were empirically run and
validated (BD generation, no synth) before this port was written. It's
specifically the ARM-side boot chain that's new/uncertain territory here.

**If bring-up doesn't work as scripted, the fastest path is likely: run xsct
interactively, `targets` to see the real target list, and adjust the
`targets -set -filter` lines and/or add back the `mwr` register writes from
the reference tutorial (see Sources) one at a time.**

## Sources consulted for the above (2026-07-04, via web search)

- AMD Kria SOM docs, "Baremetal Flow Example" (`xilinx.github.io/kria-apps-docs`)
  -- Option 1: Boot Using JTAG, the `targets`/`dow`/`fpga`/`con` sequence this
  script is based on.
- AMD Kria SOM docs, "Custom Carrier Card Flow" examples -- board_part /
  board file structure background.
- Community: `tomverbeure/kv260_bringup`, various Kria bring-up blog posts.

## All Xilinx tools must run from PowerShell

Not Bash/MSYS (its path translation crashes Vivado synth and the Vitis
server). Find the tools via `$env:XILINX_VIVADO` / `$env:XILINX_VITIS` (or
PATH after `settings64.bat`); examples below run from the repo root, where
`$PWD\...` gives Vivado the absolute `-source` path it needs.

**One-shot (cross-platform):** `python boards/kv260/build_all.py` (Windows or
Linux, stdlib only) runs `bit -> fsbl` (use `--stage xsa fsbl` to reuse an
existing impl). There is no `bootbin` stage yet for KV260 (see below).
Retarget the PL clock first with `python ../set_pl_freq.py <MHz>`.

## No BOOT.bin / SD-card path yet (deferred)

Zybo/PYNQ's `make_bootbin.py` (bootgen `-arch zynq`) does not apply to
Zynq UltraScale+ as-is -- ZynqMP `BOOT.BIN` assembly (`bootgen -arch zynqmp`)
additionally needs the PMUFW image in the `.bif` alongside FSBL, bitstream
and firmware, and typically also involves signing/authentication options
that Zynq-7000 doesn't have. This is deferred as a follow-up (JTAG bring-up
is the recommended first path anyway, matching Zybo/PYNQ's own
recommendation) rather than shipped half-verified.

## prep-A/B (done offline)

- **prep-A** real-HW DTS: `docs/opensbi/rv_soc_hw.dts`, `tests/linux/rv_soc_linux_hw.dts`
  (shared across ALL board ports; re-run `set_pl_freq.py` for this board
  before building firmware, since the DTS reflects whichever board was last
  retargeted).
- **prep-B** export XSA from the built impl (no re-impl):
  ```
  & "$env:XILINX_VIVADO\bin\vivado.bat" -mode batch `
      -source $PWD\boards\kv260\vivado\export_xsa.tcl `
      *> $PWD\boards\kv260\vivado\export_xsa.log 2>&1
  ```
  -> `../vivado/rv_riscv_kv260/rv_riscv_kv260.xsa` (psu_init + bitstream). The
  full `build_kv260.tcl bit` flow now also emits the XSA automatically.

## prep-C: FSBL + PMUFW

```
& "$env:XILINX_VITIS\bin\vitis.bat" -s `
    $PWD\boards\kv260\vitis\fsbl.py *> $PWD\boards\kv260\vitis\fsbl.log 2>&1
```
Expected output (see the confidence note above for caveats):
`ws/kv260_plat/export/kv260_plat/sw/boot/{fsbl.elf,pmufw.elf}`.

## prep-D -- ready for the board

JTAG bring-up script `bringup_jtag.tcl` -- see the confidence note above.
Configures the PL first (holding the RISC-V core in reset), downloads
PMUFW + FSBL + the RISC-V firmware, then resumes all cores.

## On the board (P1 -- run these)

1. Power the KV260, connect USB-JTAG (the carrier's onboard FTDI JTAG/UART
   combo connector, per UG1089).
2. Wire a 3.3 V USB-UART to the **J2 Pmod header**: FPGA TX=**E12** -> adapter
   RX, FPGA RX=**D11** <- adapter TX, common GND (see
   `../vivado/kv260_uart.xdc` for the pin-sourcing caveat -- verify against
   your board revision / schematic before trusting this wiring).
3. JTAG path:
   ```
   & "$env:XILINX_VITIS\bin\xsct.bat" `
       $PWD\boards\kv260\vitis\bringup_jtag.tcl
   ```
   Expect the OpenSBI banner + `PAYLOAD: hello` on the UART. If it hangs,
   see the troubleshooting note above (interactive xsct + `targets`).

## Artifacts (all gitignored)

- `ws/` Vitis workspace + FSBL/PMUFW, `../vivado/rv_riscv_kv260/rv_riscv_kv260.xsa`,
  `*.log`.
