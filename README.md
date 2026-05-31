# RISC-V Processor

A SystemVerilog RISC-V processor core designed for learning and FPGA implementation.

## Status

**RV32GC / RV64GC** implemented and passing riscv-tests compliance:
**RV64 117/117**, **RV32 88/88** (p-variants). Builds with iverilog **v12 and v13** and Vivado.
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
│   │                   #   branch, csr(Zicsr/priv), muldiv(M), amo(A), mmu, forward, hazard
│   ├── alu/            # Arithmetic Logic Unit
│   ├── fpu/            # F/D extension (rv_fpu, rv_fpu_*[_d])
│   ├── memory/         # Instruction & data memory (BRAM) + unified mem (ACT mode)
│   ├── bus/            # Bus infrastructure (reserved for AXI4 bridge)
│   ├── peripherals/    # UART, GPIO, CLINT, PLIC
│   └── soc/            # SoC top-level integration
├── boards/
│   ├── zybo_z720/      # Zybo Z7-20 board files (top, XDC)
│   └── kv260/          # KV260 board files
├── sim/
│   ├── tb/             # Testbenches
│   └── Makefile        # iverilog simulation
└── software/
    ├── tests/          # ISA test programs
    └── link.ld         # Linker script

scripts/
└── vivado/             # Vivado TCL scripts (create, build, program)

docs/
├── architecture.md     # Architecture overview
├── isa_implemented.md  # Per-instruction ISA status
└── ROADMAP.md          # Linux-port roadmap (detail in CLAUDE.md)
```

## Quick Start

### Simulation (iverilog)

```bash
cd src/sim
make sim_alu       # Run ALU unit test
make sim_core      # Run core testbench
make wave_alu      # View ALU waveform in GTKWave
```

### Build Software (RISC-V toolchain required)

```bash
cd src/software
make all           # Cross-compile test programs to .hex
```

### FPGA Build (Vivado)

```bash
cd scripts/vivado
vivado -mode batch -source create_project.tcl -tclargs zybo_z720
vivado -mode batch -source build.tcl -tclargs zybo_z720
vivado -mode batch -source program.tcl -tclargs zybo_z720
```

## Development Roadmap

Done ✅: RV32I/RV64I base · Zicsr + M-mode traps · M · A · **F/D** · **C** · RV64
(parameterized XLEN) · Supervisor mode + MMU (Sv32/Sv39) · Peripherals (UART, CLINT,
PLIC, GPIO).

Next (toward Linux) — detail in [CLAUDE.md](CLAUDE.md) "Linux 対応ロードマップ":

1. **Memory**: replace on-chip BRAM with board DDR via an AXI4 master bridge (biggest blocker)
2. Illegal-instruction trap, `mcounteren`/`scounteren` + `time` CSR (for `rdtime`)
3. SBI firmware (OpenSBI) + device tree + Zynq PS integration (Vivado block design)
4. Optional I/D cache, then Linux boot

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

