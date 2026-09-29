# Vivado Block-Design flow (scripted / no GUI)

Reproducible, version-controllable Vivado scripts that build a project + block
design connecting the RISC-V SoC (**`rv_soc`** -- the AXI/DDR + peripherals SoC;
the default after the SoC file split) to the Zynq PS DDR through an AXI
SmartConnect and an **S_AXI_HP** port. No GUI is used.

| Board | Script | PS | Part (adjust to your install) |
|-------|--------|----|-------------------------------|
| Kria KV260 | `boards/kv260/vivado/build_kv260.tcl` | PS8 (`zynq_ultra_ps_e`) | `xck26-sfvc784-2LV-c` |
| Zybo Z7-20 | `boards/zybo_z720/vivado/build_zybo.tcl` | PS7 (`processing_system7`) | `xc7z020clg400-1` |

## Run

```sh
# Tested target: Vivado 2024.2 (E:\Tools\Xilinx\Vivado\2024.2\bin\vivado.bat)
vivado -mode batch -source boards/kv260/vivado/build_kv260.tcl                 # stop after BD
vivado -mode batch -source boards/kv260/vivado/build_kv260.tcl -tclargs synth  # + synthesis
vivado -mode batch -source boards/kv260/vivado/build_kv260.tcl -tclargs bit    # + bitstream
```

The project is created under `boards/<board>/vivado/rv_riscv_<board>/` (git-ignore it).

## What the script builds

```
  +-----------+   m_axi (AXI4)   +---------------+   +--------------------+
  |  rv_soc   |----------------->| AXI           |-->| PS  S_AXI_HP0      |--> DDR
  | (AXI_MODE)|  (data + PTW)    | SmartConnect  |   | (zynq_ps)          |
  +-----------+                  +---------------+   +--------------------+
       ^  clk = pl_clk0/FCLK_CLK0,  rst_n = proc_sys_reset/peripheral_aresetn
```

- `rv_soc` is added as an **RTL module reference**. Vivado infers the AXI master
  interface `m_axi` from the standard `m_axi_*` port names (awid/awaddr/.../rready).
- `rv_soc` selects the AXI/DDR SoC by module name (no build-mode define); for
  RV64, `RV_XLEN_64` (sets XLEN=64 and the AXI data width to 64).
- GPIO/UART inputs are tied off with `xlconstant`; outputs are left open (this is
  a headless DDR-datapath bring-up). Route them to PMOD/EMIO + an XDC when needed.

## IMPORTANT: address map

In `rv_soc`, non-peripheral data accesses have **no internal memory** -- every
DDR-region core data access
load/store (and PTW read) goes straight out `m_axi` to the HP port, which
forwards the address into the PS memory map. Therefore:

- The **program's data addresses** (and `rv_soc` `RST_ADDR` for the entry/data
  region as relevant) must target the **PS DDR** range:
  - Zynq-7000 (Zybo): DDR at `0x0000_0000`..`0x3FFF_FFFF` (1 GB).
  - ZynqMP (KV260): DDR low at `0x0000_0000`..`0x7FFF_FFFF` (and high above
    `0x8_0000_0000`).
- The repo's default data base of `0x8000_0000` is **not** PS DDR on either
  platform, so re-link the program (and pick `RST_ADDR`) into the DDR window, and
  make sure `assign_bd_address` produced an HP segment that covers it (the
  scripts call `assign_bd_address`; verify, or set it explicitly -- a commented
  example is in `build_kv260.tcl`).

## Current scope (this increment)

- **Data + PTW** travel over AXI to DDR (the proven path: `make sim_axi_core` /
  `make sim_axi_soc`).
- **Instruction fetch** uses the internal always-ready memory inside `rv_soc`
  (loaded via the `INIT_FILE` parameter). Putting instructions in DDR over AXI
  awaits the IF redirect-latch fix (see `docs/axi_ddr.md`); once done, a second
  read-only AXI master (`rv_axi_bridge` `READ_ONLY=1`) is added to the BD with
  the same SmartConnect/HP pattern.

## Caveats

These scripts follow standard Vivado 2024.2 BD conventions but were authored
without a Vivado run in this environment. You may need to adjust: exact `PART` /
board-part strings, a few `CONFIG.*` PS keys (use `apply_bd_automation` with the
installed board preset as an alternative -- commented in each script), and the
HP address segment name. The structure (PS + SmartConnect + HP + module-ref AXI
inference + clock/reset wiring) is the reusable part.
