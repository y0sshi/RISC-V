# RISC-V Processor

A SystemVerilog RISC-V processor core designed for learning and FPGA implementation.

## Goals

- RV32I / RV64I base integer instruction set
- Standard extensions: M (Multiply/Divide), A (Atomic), C (Compressed), Zicsr
- Privilege architecture (M/S/U modes) with MMU for Linux support
- Compatible with **Vivado** (synthesis) and **iverilog** (simulation)

## Target Boards

| Board | FPGA | Status |
|-------|------|--------|
| Zybo Z7-20 | Zynq-7020 | In progress |
| KV260 | Zynq UltraScale+ K26 | Planned |

## Directory Structure

```
src/
├── rtl/
│   ├── include/        # Shared packages (rv_pkg.sv)
│   ├── core/           # CPU core (pipeline, decoder, regfile, branch)
│   ├── alu/            # Arithmetic Logic Unit
│   ├── ext/            # ISA extensions (M, A, C, Zicsr)
│   ├── memory/         # Instruction & data memory
│   ├── bus/            # Bus infrastructure
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
└── isa_progress.md     # ISA implementation tracking
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

1. **Phase 1**: RV32I base instruction set (single-cycle → pipeline)
2. **Phase 2**: Zicsr + Machine-mode trap handling
3. **Phase 3**: M extension (multiply/divide)
4. **Phase 4**: A extension (atomics)
5. **Phase 5**: C extension (compressed instructions)
6. **Phase 6**: RV64I support (parameterized XLEN)
7. **Phase 7**: Supervisor mode + MMU (Sv32/Sv39)
8. **Phase 8**: Peripherals (UART, CLINT, PLIC) + Linux boot

## License

See [LICENSE](LICENSE) for details.

