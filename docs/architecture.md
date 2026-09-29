# Architecture Overview

> Canonical, always-current detail lives in `CLAUDE.md` (root) and `src/rtl/ARCHITECTURE.md`.
> This file is a high-level summary.

## Processor Core

The RISC-V core is a classic 5-stage in-order pipeline:

```
IF (Fetch) -> ID (Decode) -> EX (Execute) -> MEM (Memory) -> WB (Writeback)
```

- Data forwarding (EX/MEM, MEM/WB), load-use hazard stalls.
- Branch/jump resolved in EX; variable-length fetch (2/4 bytes) for the C extension.
- Trap / interrupt handling with M/S/U privilege and Sv32/Sv39 MMU.

### Design Principles

- **Parameterized XLEN**: every module uses `rv_pkg::XLEN` to build both RV32 and RV64
  (RV64 = pass `-DRV_XLEN_64` to iverilog).
- **Modular extensions**: M (`rv_muldiv`), A (`rv_amo`), F/D (`rv_fpu*`), C (`rv_cdecode`),
  Zicsr/privilege (`rv_csr`), MMU (`rv_mmu`).
- **Simulation first**: all modules build with iverilog (v12 and v13 verified) and Vivado.
- **Clean memory interface**: simple synchronous bus today (BRAM); upgradable to AXI4 for
  on-board DDR (see the Linux roadmap in `CLAUDE.md`).

## Implemented ISA

RV32GC / RV64GC = **I, M, A, F, D, C, Zicsr** + Supervisor (Sv32/Sv39 MMU).
Compliance: **RV64 117/117**, **RV32 88/88** (riscv-tests p-variants).
Not implemented: illegal-instruction trap, PMP, V (vector). See `CLAUDE.md` for the full table.

## Module Hierarchy

```
rv_soc                     (SoC top-level; production or ACT_MODE)
├── rv_core                (5-stage pipeline)
│   ├── rv_cdecode         (C-extension: 16-bit -> 32-bit expander)
│   ├── rv_decode          (instruction decoder)
│   ├── rv_regfile         (32 x XLEN integer registers)
│   ├── rv_fregfile        (32 x 64-bit FP registers, F/D)
│   ├── rv_alu             (ALU, RV32/64I + W-type)
│   ├── rv_branch          (branch/jump resolution)
│   ├── rv_muldiv          (M extension)
│   ├── rv_amo             (A extension AMO)
│   ├── rv_fpu (+ rv_fpu_add/mul/div/sqrt/misc[_d]) (F/D extension)
│   ├── rv_forward         (forwarding unit)
│   ├── rv_hazard          (load-use hazard)
│   └── rv_csr             (M/S CSRs, traps, interrupts)
├── rv_mmu                 (TLB + page-table walker, Sv32/Sv39)
├── rv_imem / rv_dmem      (production BRAM) | rv_unified_mem (ACT_MODE)
└── Peripherals            rv_timer (CLINT), rv_uart, rv_gpio, rv_plic
```

## Memory Map (SoC, production mode)

| Region | Physical Address | Module |
|--------|-----------------|--------|
| IMEM   | 0x0000_0000 | rv_imem |
| DMEM   | 0x8000_0000 | rv_dmem |
| CLINT  | 0xC000_0000 | rv_timer |
| UART   | 0xC001_0000 | rv_uart |
| GPIO   | 0xC002_0000 | rv_gpio |
| PLIC   | 0xC010_0000 | rv_plic |

(ACT compliance mode uses a single `rv_unified_mem` at 0x8000_0000, no peripherals.)

## Target Boards

| Board | FPGA | On-board DRAM | Notes |
|-------|------|---------------|-------|
| Zybo Z7-20 | Zynq-7000 (XC7Z020) | 1 GB DDR3 (PS) | PL -> PS DDR via S_AXI_HP (planned) |
| KV260 | Zynq UltraScale+ (XCK26, K26 SOM) | 4 GB DDR4 | PL -> PS DDR via S_AXI_HP (planned) |

Boards currently instantiate `rv_soc` with on-chip BRAM (~16 KB). Using the board DDR via an
AXI4 master bridge is the key step toward Linux (see the Linux roadmap in `CLAUDE.md`).
