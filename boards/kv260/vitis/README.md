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
- `fsbl.py` here auto-generates BOTH `fsbl.elf` and `pmufw.elf` from a single
  `create_platform_component(cpu="psu_cortexa53_0", os="standalone", ...)`
  call (mirroring how the Zynq-7000 flow auto-generates `fsbl.elf` alone) --
  **confirmed against a real Vitis 2024.2 run (2026-07-04)**. One surprise:
  `pmufw.elf` does NOT land under `sw/boot/` alongside `fsbl.elf` as
  originally expected -- it lands under `sw/qemu/` instead (not a QEMU-only
  artifact despite the directory name; it's the real PMUFW for this
  platform). `bringup_jtag.tcl` already points at `sw/qemu/pmufw.elf`.
- **The KV260 Vision AI Starter Kit carrier card has NO boot-mode switch --
  it is factory hardware-locked to QSPI32.** Unlike Zybo/PYNQ (a physical
  jumper selects JTAG-only boot), KV260 unconditionally boots
  QSPI -> FSBL -> ATF/U-Boot -> SD -> Linux on every power-on, regardless of
  any switch. This was discovered the hard way (2026-07-04): the very first
  `targets` output after connecting showed Cortex-A53 cores already
  `(Running)` -- the stock OS had already booted before JTAG even attached.
  `bringup_jtag.tcl` now starts with a `boot_jtag` proc (AMD's own reference
  procedure, not improvised) that overrides the boot mode in software and
  forces a full system reset (`mwr 0xffca0010 0x0`; `mwr 0xff5e0200
  0x0100`; `rst -system`) so the boot ROM waits for JTAG instead of
  re-entering QSPI. **Skipping this step means everything downstream is
  fighting an already-running Linux instance** (confirmed: caused `stop` to
  fail with "Cannot halt processor core, timeout" before this fix).
- `bringup_jtag.tcl` otherwise mirrors AMD's documented "Option 1: Boot
  Using JTAG" sequence (`boot_jtag` -> unlock PMU security gate -> PMUFW ->
  FSBL -> firmware -> PL config) as closely as possible given our design's
  DDR4-before-PL-release constraint (see the file's own header comment for
  the full revision history and the one remaining deliberate deviation from
  AMD's reference ordering). **Treat it as a starting point for interactive
  xsct debugging, not a fully hardware-proven one-shot script** the way the
  Zybo/PYNQ equivalents are -- it has been revised multiple times against
  real hardware output already and may need more.

The Vivado/BD side (`../vivado/build_kv260.tcl`) does NOT have this problem --
`board_part`/`apply_board_preset`/DDR4 bring-up were empirically run and
validated (BD generation, no synth) before this port was written. It's
specifically the ARM-side boot chain that's new/uncertain territory here.

**If bring-up doesn't work as scripted, the fastest path is likely: run xsct
interactively, use the `targets` output the script prints at each stage, and
adjust the `targets -set -filter` lines / delays as needed.**

## ⚠️⚠️ Real-hardware finding (2026-07-04): raw JTAG `fpga -file` does NOT
## release the RISC-V core -- use the xmutil/fpgautil path below instead

A full run of `bringup_jtag.tcl` (after all the fixes above) completed with
**zero xsct/Tcl errors**: `boot_jtag` correctly forced a fresh JTAG-mode
reset, PMUFW and FSBL loaded and ran, DDR4 came up (JTAG could write/read it
correctly -- confirmed via `src/software/boot/liveness_hw.S`, a minimal
probe that needs only core-fetch + one AXI store), and the PL configured
without error. **But the RISC-V core never actually started running**: the
liveness probe's magic value/counter never appeared at 0x300000/0x300004 --
what was read back there was unrelated ARM64 code (leftovers from the
carrier's own already-running Linux), and the BD's address map (checked via
`get_bd_addr_segs`) confirmed 0x200000/0x300000 correctly fall inside
`HP0_DDR_LOW` at offset 0, so it's not an address-mapping bug either.

**Root cause (found via web research, not yet hardware-confirmed to fix
it)**: on Zynq UltraScale+, `pl_resetn0` (the PS-to-PL reset gating our
RISC-V core) is NOT a simple always-auto-released signal or a bit any
`ps7_init`-style script pokes directly -- it is controlled through a PS
**EMIO GPIO line** (reportedly Linux gpiochip line 173 in the typical
`[78:173]` PL-EMIO-GPIO range), which is normally driven by **Linux's
`zynqmp-fpga` driver / `fpga_manager` framework** as part of its standard
bitstream-load sequence. Loading the bitstream via raw JTAG `fpga -file`
completely bypasses that driver, so nothing ever asserts the GPIO line that
releases our core -- consistent with every symptom observed (PL configures
fine, DDR4 works fine via FSBL, but the RISC-V core just never runs).

**Recommended next path: load the bitstream through Linux's own supported
mechanism (`fpgautil`) instead of raw JTAG**, since the board already boots
to a working Ubuntu/PetaLinux anyway (see the boot-mode-lock note above) --
this makes the officially-supported driver handle the GPIO/reset sequencing
correctly instead of us guessing register addresses. See "xmutil / fpgautil
path" below. (The other option -- finding the exact GPIO controller
register/bit for line 173 via AMD's UG1087 register reference and writing
it directly over JTAG -- was not pursued since it needs a register
reference this script's author didn't have full confidence reconstructing
from web search alone.)

## xmutil / fpgautil path (recommended real-HW next step)

Two new files support this:
- `make_pl_bin.py` -- converts the built `.bit` into the header-stripped
  `.bit.bin` format `fpgautil`/Linux's `fpga_manager` expects (via bootgen's
  `-process_bitstream bin` mode -- the standard, documented conversion, not
  a guess).
- `rv_riscv_kv260_overlay.dts` -- a MINIMAL device-tree overlay (just a
  `fpga_full` fragment with `firmware-name`; no extra driver nodes, since
  our RISC-V core talks to its own AXI peripherals directly and Linux
  doesn't need to know about them).

Steps:
1. Build the bitstream (`build_all.py --stage fpga` if not already done),
   then convert it:
   ```
   python boards/kv260/vitis/make_pl_bin.py
   ```
   -> `rv_riscv_kv260.bit.bin` (gitignored).
2. Compile the overlay (any host with a device-tree-compiler; the repo's
   `linux-rv64` docker image already has one -- `tests/linux/Dockerfile`):
   ```
   docker run --rm -v "E:/work/git/RISC-V.git:/workspace" -w /workspace/boards/kv260/vitis \
     linux-rv64 dtc -@ -I dts -O dtb -o rv_riscv_kv260_overlay.dtbo rv_riscv_kv260_overlay.dts
   ```
   -> `rv_riscv_kv260_overlay.dtbo` (gitignored).
3. Copy BOTH `rv_riscv_kv260.bit.bin` and `rv_riscv_kv260_overlay.dtbo` to
   the board (scp if the board has network, or a USB drive / SD card).
4. On the board (over its own serial/SSH console, i.e. the ALREADY-RUNNING
   Linux -- not JTAG):
   ```
   sudo fpgautil -b rv_riscv_kv260.bit.bin -o rv_riscv_kv260_overlay.dtbo
   ```
5. The RISC-V core should now be running whatever was resident in DDR4
   @0x200000 at the time this loaded. If firmware isn't there yet (e.g. you
   haven't `dow`'d anything via JTAG this session), use `bringup_jtag.tcl`
   FIRST to load firmware into DDR4 via JTAG (its PMUFW/FSBL/DDR4-bring-up
   steps all work fine -- only the final `fpga -file` step doesn't release
   the core), then run `fpgautil` afterward to actually release it, without
   needing another JTAG `dow`.
6. Check for life the same way as before: watch the J2 Pmod UART (57600
   8N1, TX=E12/RX=D11), or re-attach JTAG and `mrd` the liveness probe /
   done-sentinel addresses.

**Not yet hardware-confirmed as of this writing** -- this is the
recommended next experiment, not a proven fix.

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
