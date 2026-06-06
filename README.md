# RISC-V Processor

A SystemVerilog RISC-V processor core designed for learning and FPGA implementation.

## Status

**RV32GC / RV64GC** implemented and passing riscv-tests compliance:
**RV64 117/117**, **RV32 88/88** (p-variants) + RISCOF I/M/A/C 107/107 vs Spike.
Builds with iverilog **v12 and v13**, **Verilator 5.x**, and Vivado.

Toward Linux: BRAM->DDR over **AXI4** (2 masters) + **I/D caches** done; **real OpenSBI v1.2
boots fully** in sim (banner -> S-mode payload, see `docs/opensbi_sim.md`); a minimal RV64
**Linux kernel boots into early head.S / MMU-enable** (`docs/linux_sim.md`, in progress).
See [CLAUDE.md](CLAUDE.md) for the always-current detailed status and the Linux roadmap.

## Goals

- RV32I / RV64I base integer instruction set (parameterized `XLEN`)
- Standard extensions: **M** (Multiply/Divide), **A** (Atomic), **F/D** (Floating-point),
  **C** (Compressed), **Zicsr**
- Privilege architecture (M/S/U) with **Sv32/Sv39 MMU** (toward Linux support)
- Compatible with **Vivado** (synthesis) and **iverilog** (simulation)

## Target Boards

| Board | FPGA | On-board DRAM | Status |
|-------|------|---------------|--------|
| Zybo Z7-20 | Zynq-7000 (XC7Z020) | 1 GB DDR3 (PS) | Board top instantiates SoC on BRAM; PS-DDR via AXI planned |
| KV260 | Zynq UltraScale+ (XCK26, K26 SOM) | 4 GB DDR4 | Same; PS-DDR via AXI planned |

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
    └── boot/           # mini-SBI stand-in firmware (sbi_boot.S)

tests/
├── compliance/         # riscv-tests runner (Docker)
├── riscof/             # RISCOF arch-test (vs Spike)
├── opensbi/            # build.sh: real OpenSBI v1.2 fw_payload
└── linux/              # build.sh: minimal RV64 Linux Image -> fw_payload

docs/   # architecture.md, isa_implemented.md, axi_ddr.md, cache.md,
        # opensbi_sim.md, verilator_sim.md, linux_sim.md, next_session_prompt.md
```

## Quick Start

### Simulation (iverilog)

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
```

### Build Software (RISC-V toolchain required)

```bash
cd src/software
make all           # Cross-compile test programs to .hex
```

### FPGA Build (Vivado, scripted block design)

```bash
# PS + AXI SmartConnect + S_AXI_HP wired to rv_soc (2 AXI masters). See boards/vivado_README.md.
vivado -mode batch -source boards/zybo_z720/vivado/build_zybo.tcl   -tclargs bd    # or synth | bit
vivado -mode batch -source boards/kv260/vivado/build_kv260.tcl      -tclargs bit
```

## Development Roadmap

Done ✅: RV32I/RV64I base · Zicsr + M-mode traps · M · A · **F/D** · **C** · RV64
(parameterized XLEN) · Supervisor mode + MMU (Sv32/Sv39) · Peripherals (UART/NS16550,
CLINT, PLIC, GPIO) · illegal-instr trap · `counteren`/`time` CSR · **BRAM->DDR over AXI4**
(2 masters) · **I/D caches** · **real OpenSBI v1.2 full boot** in sim · **Verilator** fast sim.

Next (toward Linux) — detail in [CLAUDE.md](CLAUDE.md) and the `linux-boot-roadmap`:

1. **P0-1 (in progress)**: boot a minimal RV64 Linux kernel in sim to the earlycon banner;
   fix the early-boot core bugs (I-cache / MMU after Sv39 enable — see `docs/linux_sim.md`).
2. **P1 (FPGA)**: Vivado block design (PS7/PS8 + SmartConnect + S_AXI_HP), bitstream, DDR preload.
3. **P2/P3**: write-back/set-assoc D-cache, buildroot shell, PMP enforcement, vectored mtvec.

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

