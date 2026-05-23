# Architecture Overview

## Processor Core

The RISC-V core uses a classic 5-stage pipeline:

```
IF (Fetch) -> ID (Decode) -> EX (Execute) -> MEM (Memory) -> WB (Writeback)
```

### Design Principles

- **Parameterized XLEN**: All modules use `rv_pkg::XLEN` to support both RV32 and RV64
- **Modular Extensions**: Each ISA extension (M, A, C, Zicsr) is a separate module
- **Simulation First**: All modules are compatible with both iverilog and Vivado xsim
- **Clean Interfaces**: Simple memory bus for initial development, upgradable to AXI4

## Module Hierarchy

```
rv_soc                     (SoC top-level)
├── rv_core                (CPU core)
│   ├── rv_decode          (Instruction decoder)
│   ├── rv_regfile         (Register file: 32 x XLEN)
│   ├── rv_alu             (Arithmetic Logic Unit)
│   └── rv_branch          (Branch/jump resolution)
├── rv_imem                (Instruction memory)
├── rv_dmem                (Data memory)
└── Peripherals            (TODO)
    ├── UART
    ├── GPIO
    ├── CLINT (timer)
    └── PLIC (interrupts)
```

## Memory Map (Planned)

| Address Range         | Size  | Description            |
|-----------------------|-------|------------------------|
| 0x0000_0000 - 0x0000_FFFF | 64KB  | Instruction Memory     |
| 0x0001_0000 - 0x0001_FFFF | 64KB  | Data Memory            |
| 0x0200_0000 - 0x0200_FFFF | 64KB  | CLINT (Timer/IPI)      |
| 0x0C00_0000 - 0x0FFF_FFFF | 64MB  | PLIC                   |
| 0x1000_0000 - 0x1000_0FFF | 4KB   | UART                   |
| 0x1000_1000 - 0x1000_1FFF | 4KB   | GPIO                   |

## Target Boards

### Zybo Z7-20
- **FPGA**: Zynq-7020 (XC7Z020-1CLG400C)
- **Resources**: 53,200 LUTs, 106,400 FFs, 140 BRAMs
- **Clock**: 125 MHz system clock

### KV260
- **FPGA**: Zynq UltraScale+ (K26 SOM)
- **Resources**: 256,200 LUTs, 512,400 FFs, 144 BRAMs
- **Clock**: Configurable via PS
