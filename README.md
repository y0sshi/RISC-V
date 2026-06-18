# RISC-V Processor

A SystemVerilog RISC-V processor core designed for learning and FPGA implementation.

## Status

**RV32GC / RV64GC** implemented and passing riscv-tests compliance:
**RV64 117/117**, **RV32 88/88** (p-variants) + RISCOF I/M/A/C 107/107 vs Spike.
Builds with iverilog **v12 and v13**, **Verilator 5.x**, and Vivado.

**Boots real Linux on real hardware.** On a Zybo Z7-20 (Zynq-7000) the core boots
**OpenSBI v1.2 fully** and a **RV64 Linux 6.12 kernel to userspace**
(`LINUX-USERSPACE-OK: init running`) over PS-DDR via **AXI4** (2 masters) with **I/D caches** —
verified both in sim (Verilator, ~100x faster) and **on the board over JTAG**. Networking is
currently disabled (`CONFIG_NET=n`) pending one real-HW atomic bug.
See **[docs/ROADMAP.md](docs/ROADMAP.md)** for the prioritized plan and [CLAUDE.md](CLAUDE.md)
for the always-current detailed status.

## Goals

- RV32I / RV64I base integer instruction set (parameterized `XLEN`)
- Standard extensions: **M** (Multiply/Divide), **A** (Atomic), **F/D** (Floating-point),
  **C** (Compressed), **Zicsr**
- Privilege architecture (M/S/U) with **Sv32/Sv39 MMU** (toward Linux support)
- Compatible with **Vivado** (synthesis) and **iverilog** (simulation)

## Target Boards

| Board | FPGA | On-board DRAM | Status |
|-------|------|---------------|--------|
| Zybo Z7-20 | Zynq-7000 (XC7Z020) | 1 GB DDR3 (PS) | ✅ Real HW: OpenSBI + Linux to userspace (PS-DDR via AXI, timing met @25 MHz) |
| KV260 | Zynq UltraScale+ (XCK26, K26 SOM) | 4 GB DDR4 | Board top + scripted BD; not yet brought up on HW |
| PYNQ-Z1 / Z2 | Zynq-7000 | 512 MB DDR3 | Planned (Zynq-7000, near-identical to Zybo) |

## Directory Structure

```
src/
├── rtl/
│   ├── include/        # Shared package (rv_pkg.sv)
│   ├── core/           # CPU core: pipeline, decode, cdecode(C), regfile/fregfile,
│   │                   #   csr(Zicsr/priv), mmu, forward, hazard; rv_cpu (core+mmu)
│   ├── exec/           # EX-stage units: rv_alu, rv_muldiv(M), rv_amo(A), rv_branch
│   ├── fpu/            # F/D extension (rv_fpu, rv_fpu_*[_d])
│   ├── memory/         # Instruction & data memory (BRAM) + unified mem (ACT mode)
│   ├── bus/            # AXI4 bridges (single-beat + burst/line-fill)
│   ├── cache/          # I/D caches (rv_icache, rv_dcache; in rv_soc)
│   ├── peripherals/    # UART(NS16550), GPIO, CLINT, PLIC + rv_periph
│   └── soc/            # SoC wrappers: rv_soc (DDR/AXI), rv_soc_bram, rv_soc_act
├── boards/
│   ├── zybo_z720/      # Zybo Z7-20 board files (top, XDC, vivado/ TCL BD)
│   └── kv260/          # KV260 board files (top, XDC, vivado/ TCL BD)
├── sim/
│   ├── tb/             # Testbenches
│   ├── Dockerfile / Dockerfile.verilator   # iverilog:13.0 / verilator:5.020 images
│   └── Makefile        # iverilog + Verilator simulation
└── software/
    ├── tests/          # ISA test programs
    └── boot/           # mini-SBI stand-in (sbi_boot.S) + RTL-bug regression firmware (*_test.S)

tests/
├── compliance/         # riscv-tests runner (Docker)
├── riscof/             # RISCOF arch-test (vs Spike)
├── opensbi/            # build.sh: real OpenSBI v1.2 fw_payload
└── linux/              # build.sh: minimal RV64 Linux Image -> fw_payload

boards/
├── zybo_z720/          # Zybo Z7-20: top, XDC, vivado/ BD, vitis/ (FSBL, JTAG bring-up), build_all.ps1
└── kv260/              # KV260: top, XDC, vivado/ BD

archive/                # retired, out-of-build code (legacy RV32I project)

docs/   # ROADMAP.md, architecture.md, isa_implemented.md, axi_ddr.md, cache.md, opensbi_sim.md,
        # verilator_sim.md, linux_sim.md, fpga_timing_bringup.md, rtl_bug_history.md, next_session_prompt.md
```

## Quick Start

Commands are split into **two entry points** (a hard constraint: Vivado/Vitis must run from
PowerShell, everything else is bash/docker):

- **Top-level `Makefile`** (bash/docker) — firmware, sim boots, tests, dependencies. Run `make help`.
- **PowerShell** — FPGA bitstream and on-board bring-up (`boards/zybo_z720/build_all.ps1`).

### Entry points — top-level `make` (run from repo root)

```bash
make help                 # list every target
make images               # build docker images (iverilog / verilator / act / gcc / linux-rv64)
make deps                 # fetch pinned OpenSBI + arch-test-suite (no submodule)

# Firmware (docker).  -lo = 0x200000 sim base, -hw = 0x200000 real-HW DTS (25 MHz / 57600):
make fw-opensbi[-lo|-hw]  # OpenSBI hello fw_payload
make fw-linux[-lo|-hw]    # Linux fw_payload (kernel cached after first build)

# Boot in simulation (Verilator):
make boot                 # mini-SBI stand-in (fast sanity)
make boot-opensbi         # real OpenSBI hello   (needs fw-opensbi-lo)
make boot-linux           # real Linux to userspace (needs fw-linux-lo; ~8 min)

# Tests:
make compliance           # riscv-tests RV64 (compliance32 for RV32)
make riscof               # arch-test vs Spike
make sim-<name>           # delegate to any src/sim target, e.g. make sim-pipeline
```

### Simulation (iverilog) — direct, from `src/sim`

```bash
cd src/sim
make sim_alu       # Run ALU unit test
make sim_pipeline  # Most comprehensive pipeline test
make wave_alu      # View ALU waveform in GTKWave
```

### Boot firmware / Linux in sim

```bash
cd src/sim
make sim_boot                          # mini-SBI stand-in on rv_soc (shared DDR, caches)
make image_verilator                   # build the verilator:5.020 image (once)
make vl_boot BOOT_HEX=<fw_payload.hex>  # ~100x faster; real OpenSBI ~8s (see docs/verilator_sim.md)
# RV64 Linux to userspace (LINUX-USERSPACE-OK):
make vl_boot BOOT_HEX=../../tests/linux/work/fw_payload_linux.hex BOOT_MAX=480000000 BOOT_MTIME_DIV=64
```

### Build Software (RISC-V toolchain required)

```bash
cd src/software
make all           # Cross-compile test programs to .hex
```

### FPGA build & real-HW bring-up (Vivado/Vitis)

The build is a cross-platform Python orchestrator (`build_all.py`, stdlib only — no venv)
that runs on Windows and Linux. The Xilinx tools are found via the `XILINX_VIVADO` /
`XILINX_VITIS` env vars (or `PATH` after the Xilinx `settings64`):

```bash
# Linux / bash:
export XILINX_VIVADO=/opt/Xilinx/Vivado/2024.2     # adjust to your install
export XILINX_VITIS=/opt/Xilinx/Vitis/2024.2
python boards/zybo_z720/build_all.py               # all: bit -> FSBL -> BOOT.bin
python boards/zybo_z720/build_all.py --stage xsa fsbl bootbin   # reuse the existing impl
```
```powershell
# Windows / PowerShell ($env: instead of export; build_all.ps1 is a thin shim that forwards here):
$env:XILINX_VIVADO = "C:\Xilinx\Vivado\2024.2"
$env:XILINX_VITIS  = "C:\Xilinx\Vitis\2024.2"
python boards\zybo_z720\build_all.py        # or the shim:  .\boards\zybo_z720\build_all.ps1
```

Then bring up on the board over JTAG (loads firmware to PS-DDR, configures the PL, prints to
UART at 57600 8N1) — OpenSBI then Linux: see **[boards/zybo_z720/vitis/README.md](boards/zybo_z720/vitis/README.md)**.

## Development Roadmap

Done ✅: RV32I/RV64I base · Zicsr + M/S-mode traps · M · A · **F/D** · **C** · RV64
(parameterized XLEN) · Supervisor mode + MMU (Sv32/Sv39) · peripherals (UART/NS16550,
CLINT, PLIC, GPIO) · illegal-instr trap · `counteren`/`time` CSR · **BRAM->DDR over AXI4**
(2 masters) · **I/D caches** · **real OpenSBI v1.2 full boot** · **RV64 Linux to userspace** —
all verified in sim (Verilator) **and on real Zybo Z7-20 hardware** · **Verilator** fast sim.

Next — prioritized plan in **[docs/ROADMAP.md](docs/ROADMAP.md)** (detail in [CLAUDE.md](CLAUDE.md)):

1. **atomic correctness -> `CONFIG_NET=y`** — fix a real-HW-only netlink/atomic hang (suspected
   LR/SC / memory-ordering under real DDR; networking is disabled until then).
2. **Clock frequency** — pipeline the FPU / multiplier to push past 25 MHz.
3. **RootFS / Ubuntu** — DDR expansion + a block device (larger initramfs first).
4. **More boards** — PYNQ-Z1/Z2 (easy, Zynq-7000), KV260 (Zynq US+).
5. **Vector (RVV)** extension.

### Compliance / test commands
```bash
cd tests/compliance
make riscv-tests-build      # build RV64 test ELFs (Docker)
make riscv-tests-run        # RV64 117/117
make riscv-tests-build32    # build RV32 test ELFs
make riscv-tests-run32      # RV32 88/88
```

## License

See [LICENSE](LICENSE) for details.

