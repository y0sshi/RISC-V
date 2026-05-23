# ISA Implementation Progress

## Phase 1: RV32I Base (Current)

### Instructions

| Category       | Instruction        | Status     |
|----------------|--------------------|------------|
| **Integer Imm**| ADDI               | Skeleton   |
|                | SLTI               | Skeleton   |
|                | SLTIU              | Skeleton   |
|                | XORI               | Skeleton   |
|                | ORI                | Skeleton   |
|                | ANDI               | Skeleton   |
|                | SLLI               | Skeleton   |
|                | SRLI               | Skeleton   |
|                | SRAI               | Skeleton   |
| **Integer Reg**| ADD                | Skeleton   |
|                | SUB                | Skeleton   |
|                | SLL                | Skeleton   |
|                | SLT                | Skeleton   |
|                | SLTU               | Skeleton   |
|                | XOR                | Skeleton   |
|                | SRL                | Skeleton   |
|                | SRA                | Skeleton   |
|                | OR                 | Skeleton   |
|                | AND                | Skeleton   |
| **Upper Imm**  | LUI                | Skeleton   |
|                | AUIPC              | Skeleton   |
| **Jump**       | JAL                | Skeleton   |
|                | JALR               | Skeleton   |
| **Branch**     | BEQ                | Skeleton   |
|                | BNE                | Skeleton   |
|                | BLT                | Skeleton   |
|                | BGE                | Skeleton   |
|                | BLTU               | Skeleton   |
|                | BGEU               | Skeleton   |
| **Load**       | LB/LH/LW          | Skeleton   |
|                | LBU/LHU            | Skeleton   |
| **Store**      | SB/SH/SW           | Skeleton   |
| **System**     | ECALL/EBREAK       | Skeleton   |
| **Fence**      | FENCE              | NOP        |

## Phase 2: Zicsr + Privilege Architecture
- [ ] CSR read/write (CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI)
- [ ] Machine-mode CSRs (mstatus, mtvec, mepc, mcause, mie, mip, ...)
- [ ] Trap handling (exceptions and interrupts)
- [ ] MRET

## Phase 3: M Extension (Multiply/Divide)
- [ ] MUL, MULH, MULHSU, MULHU
- [ ] DIV, DIVU, REM, REMU

## Phase 4: A Extension (Atomics)
- [ ] LR.W, SC.W
- [ ] AMO instructions

## Phase 5: C Extension (Compressed)
- [ ] 16-bit instruction decoding
- [ ] Instruction expansion

## Phase 6: RV64I
- [ ] XLEN=64 support
- [ ] Additional instructions (LWU, LD, SD, ADDIW, ...)

## Phase 7: Supervisor Mode + MMU
- [ ] S-mode privilege level
- [ ] Sv32 (RV32) / Sv39 (RV64) page table walk
- [ ] TLB
- [ ] SFENCE.VMA

## Phase 8: Linux Boot
- [ ] CLINT (timer + software interrupts)
- [ ] PLIC (external interrupts)
- [ ] UART (console I/O)
- [ ] Device tree
- [ ] OpenSBI + Linux kernel boot
