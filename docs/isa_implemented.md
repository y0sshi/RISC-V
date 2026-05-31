# ISA Implementation Status

> Last updated: 2026-05-31.
> **Canonical, always-current status is in `CLAUDE.md` (root).** This file keeps the
> detailed per-instruction tables for the base/M/A/Zicsr/privilege parts.
>
> Since 2026-05-22 the following were added and are now fully implemented (see CLAUDE.md
> for detail): **F / D extensions (RV32 & RV64)** via `rv_fpu*` + `rv_fregfile`, and the
> **C extension (RV32C / RV64C)** via `rv_cdecode` + variable-length fetch in `rv_core`.
>
> Compliance (riscv-tests p-variants): **RV64 117/117**, **RV32 88/88**.

---

## RV32I / RV64I Base Integer

### Integer Register-Immediate (OP_IMM / OP_IMM_W)

| Instruction | Encoding | Status | Notes |
|-------------|----------|--------|-------|
| ADDI | I-type | ✅ | |
| SLTI | I-type | ✅ | signed compare |
| SLTIU | I-type | ✅ | unsigned compare |
| XORI | I-type | ✅ | |
| ORI  | I-type | ✅ | |
| ANDI | I-type | ✅ | |
| SLLI | I-type (funct7=0000000) | ✅ | shamt: 5b RV32, 6b RV64 |
| SRLI | I-type (funct7=0000000) | ✅ | |
| SRAI | I-type (funct7=0100000) | ✅ | |
| ADDIW | OP_IMM_W, funct3=000 | ✅ | RV64 only |
| SLLIW | OP_IMM_W, funct3=001 | ✅ | RV64 only |
| SRLIW | OP_IMM_W, funct3=101 | ✅ | RV64 only |
| SRAIW | OP_IMM_W, funct3=101 | ✅ | RV64 only |

### Integer Register-Register (OP_REG / OP_REG_W)

| Instruction | funct7 | funct3 | Status |
|-------------|--------|--------|--------|
| ADD  | 0000000 | 000 | ✅ |
| SUB  | 0100000 | 000 | ✅ |
| SLL  | 0000000 | 001 | ✅ |
| SLT  | 0000000 | 010 | ✅ |
| SLTU | 0000000 | 011 | ✅ |
| XOR  | 0000000 | 100 | ✅ |
| SRL  | 0000000 | 101 | ✅ |
| SRA  | 0100000 | 101 | ✅ |
| OR   | 0000000 | 110 | ✅ |
| AND  | 0000000 | 111 | ✅ |
| ADDW | 0000000 | 000 | ✅ RV64 |
| SUBW | 0100000 | 000 | ✅ RV64 |
| SLLW | 0000000 | 001 | ✅ RV64 |
| SRLW | 0000000 | 101 | ✅ RV64 |
| SRAW | 0100000 | 101 | ✅ RV64 |

### Upper Immediate

| Instruction | Status |
|-------------|--------|
| LUI | ✅ (ALU_PASS_B of imm) |
| AUIPC | ✅ (PC + imm) |

### Jumps

| Instruction | Status | Notes |
|-------------|--------|-------|
| JAL | ✅ | PC-relative, 2-cycle flush |
| JALR | ✅ | (rs1 + imm) & ~1, ctrl.jalr flag |

### Branches

| Instruction | funct3 | Status |
|-------------|--------|--------|
| BEQ  | 000 | ✅ |
| BNE  | 001 | ✅ |
| BLT  | 100 | ✅ signed |
| BGE  | 101 | ✅ signed |
| BLTU | 110 | ✅ unsigned |
| BGEU | 111 | ✅ unsigned |

### Loads (OP_LOAD)

| Instruction | funct3 | Status | Notes |
|-------------|--------|--------|-------|
| LB  | 000 | ✅ | sign-extend byte |
| LH  | 001 | ✅ | sign-extend halfword |
| LW  | 010 | ✅ | sign-extend word (RV64 sign-extends to 64b) |
| LD  | 011 | ✅ | RV64 only, 64-bit |
| LBU | 100 | ✅ | zero-extend byte |
| LHU | 101 | ✅ | zero-extend halfword |
| LWU | 110 | ✅ | RV64: zero-extend word |

Sub-word loads use byte-lane shifting in WB (`mem_wb_byte_offset` → `dmem_shifted`).

### Stores (OP_STORE)

| Instruction | funct3 | Status | Notes |
|-------------|--------|--------|-------|
| SB | 000 | ✅ word-aligned only* | |
| SH | 001 | ✅ word-aligned only* | |
| SW | 010 | ✅ | |
| SD | 011 | ✅ | RV64 only |

> **⚠ Known limitation**: `dmem_wdata` is the unshifted register value. `dmem_wstrb` selects the correct byte lane in the memory. For SB/SH at non-zero byte offsets within a word (e.g., `SB rs2, 1(rs1)`), the value written to the upper byte lane comes from `wdata[15:8]` which is zero (not from rs2[7:0]). Only byte-offset-0 SB/SH are correct.

### System / FENCE

| Instruction | Status | Notes |
|-------------|--------|-------|
| FENCE | ✅ | NOP (safe for simple in-order core) |
| ECALL | ✅ | traps with EXC_ECALL_{U,S,M} based on cur_priv |
| EBREAK | ✅ | traps with EXC_BREAKPOINT, mtval = PC |

---

## Zicsr — Control and Status Register Instructions

| Instruction | funct3 | Status |
|-------------|--------|--------|
| CSRRW  | 001 | ✅ read-old / write |
| CSRRS  | 010 | ✅ read-old / set bits |
| CSRRC  | 011 | ✅ read-old / clear bits |
| CSRRWI | 101 | ✅ immediate variant |
| CSRRSI | 110 | ✅ immediate variant |
| CSRRCI | 111 | ✅ immediate variant |

### Implemented CSRs

**Machine-level:**

| CSR | Address | RW | Notes |
|-----|---------|-----|-------|
| mstatus | 0x300 | RW | MIE, MPIE, MPP, SIE, SPIE, SPP, SUM, MXR |
| misa | 0x301 | RO | I, S, U bits set |
| medeleg | 0x302 | RW | exception delegation |
| mideleg | 0x303 | RW | interrupt delegation |
| mie | 0x304 | RW | MSIE, MTIE, MEIE + S-mode bits via mask |
| mtvec | 0x305 | RW | direct (mode=0) only; vectored mode stored but not dispatched |
| mscratch | 0x340 | RW | |
| mepc | 0x341 | RW | LSB always 0 |
| mcause | 0x342 | RW | |
| mtval | 0x343 | RW | |
| mip | 0x344 | RO | driven by timer_irq/sw_irq/ext_irq external inputs |
| mcycle | 0xB00 | RO | 64-bit counter (both halves accessible from RV32) |
| minstret | 0xB02 | RO | retires on mem_wb_valid |
| mhartid | 0xF14 | RO | = HARTID parameter |

**Supervisor-level:**

| CSR | Address | RW | Notes |
|-----|---------|-----|-------|
| sstatus | 0x100 | RW | restricted view of mstatus (SIE, SPIE, SPP, SUM, MXR) |
| sie | 0x104 | RW | S-mode bits of mie (SSIE, STIE, SEIE) |
| stvec | 0x105 | RW | |
| sscratch | 0x140 | RW | |
| sepc | 0x141 | RW | |
| scause | 0x142 | RW | |
| stval | 0x143 | RW | |
| sip | 0x144 | RO | S-mode bits of mip |
| satp | 0x180 | RW | Sv32/Sv39 mode + PPN |

---

## M Extension — Multiply / Divide (RV32M / RV64M)

All operations are single-cycle combinational in `rv_muldiv.sv`.

| Instruction | op code | Status | Corner cases handled |
|-------------|---------|--------|----------------------|
| MUL    | MDU_MUL    | ✅ | overflow wraps |
| MULH   | MDU_MULH   | ✅ | signed × signed upper |
| MULHSU | MDU_MULHSU | ✅ | signed × unsigned upper |
| MULHU  | MDU_MULHU  | ✅ | unsigned × unsigned upper |
| DIV    | MDU_DIV    | ✅ | div-by-zero → -1; INT_MIN/-1 → INT_MIN |
| DIVU   | MDU_DIVU   | ✅ | div-by-zero → MAX_UINT |
| REM    | MDU_REM    | ✅ | div-by-zero → dividend; INT_MIN/-1 → 0 |
| REMU   | MDU_REMU   | ✅ | div-by-zero → dividend |
| MULW   | MDU_MULW   | ✅ | RV64, result sign-ext to 64b |
| DIVW   | MDU_DIVW   | ✅ | RV64 |
| DIVUW  | MDU_DIVUW  | ✅ | RV64 |
| REMW   | MDU_REMW   | ✅ | RV64 |
| REMUW  | MDU_REMUW  | ✅ | RV64 |

---

## A Extension — Atomic Memory Operations (RV32A / RV64A)

Two-phase AMO FSM in `rv_core.sv`; compute logic in `rv_amo.sv`.

| Instruction | AMO op | Status | Notes |
|-------------|--------|--------|-------|
| LR.W / LR.D | AMO_LR | ✅ | sets reservation register |
| SC.W / SC.D | AMO_SC | ✅ | writes only on reservation match; returns 0/1 |
| AMOSWAP | AMO_SWAP | ✅ | |
| AMOADD  | AMO_ADD  | ✅ | |
| AMOXOR  | AMO_XOR  | ✅ | |
| AMOAND  | AMO_AND  | ✅ | |
| AMOOR   | AMO_OR   | ✅ | |
| AMOMIN  | AMO_MIN  | ✅ | signed |
| AMOMAX  | AMO_MAX  | ✅ | signed |
| AMOMINU | AMO_MINU | ✅ | unsigned |
| AMOMAXU | AMO_MAXU | ✅ | unsigned |

W-type (32-bit) and D-type (XLEN-bit) variants both supported via `funct3` in `rv_amo.sv`.

---

## Privilege Architecture

| Feature | Status | Notes |
|---------|--------|-------|
| M-mode | ✅ | default after reset |
| S-mode | ✅ | entered via medeleg/mideleg trap delegation |
| U-mode | ✅ | CSR priv_level tracking |
| MRET | ✅ | restores mstatus.MIE←MPIE, priv←MPP |
| SRET | ✅ | restores mstatus.SIE←SPIE, priv←SPP |
| Machine interrupts (MTIP/MSIP/MEIP) | ✅ | via timer_irq/sw_irq/ext_irq inputs |
| Supervisor interrupts (STIP/SSIP/SEIP) | ✅ | via mideleg delegation |
| Interrupt priority | ✅ | MEIP>MSIP>MTIP>SEIP>SSIP>STIP |
| Exception delegation (medeleg) | ✅ | |
| Interrupt delegation (mideleg) | ✅ | |
| SFENCE.VMA | ✅ | flushes TLB (1-cycle pulse tlb_flush_out) |

---

## MMU (rv_mmu.sv)

| Feature | Status | Notes |
|---------|--------|-------|
| Sv32 (RV32) | ✅ | 2-level page table walk |
| Sv39 (RV64) | ✅ | 3-level page table walk |
| TLB (fully-associative, 8-entry) | ✅ | |
| TLB flush (SFENCE.VMA) | ✅ | |
| SUM / MXR bits | ✅ | supervisor user-memory / make-executable-readable |
| Page fault exceptions | ✅ | inst/load/store page faults reported via trap |

---

## Not Implemented

| Feature | Notes |
|---------|-------|
| Illegal-instruction trap | ✅ Implemented (unknown opcode / bad shamt / RV32 W-form / illegal RVC -> cause=2, mtval=instr). rv32mi `shamt` passes; rv*mi `illegal` still needs vectored mtvec + TSR/TVM/TW |
| Physical Memory Protection (PMP) | ⚠️ CSRs only (pmpcfg/pmpaddr 16 entries, WARL); rv*mi `pmpaddr` passes. Access enforcement deferred to the arch-test phase |
| mtvec vectored mode | Stored but trap always goes to base address |
| CLINT memory-mapped mtime/mtimecmp -> `time` CSR (U/S) | `timer_irq` input used; `time`/`mcounteren` not wired (needed for Linux `rdtime`) |
| V (vector) extension | Not implemented |
| Debug (JTAG/DMI) | Not implemented |

(C and F/D are now implemented — removed from this list. See header / CLAUDE.md.)

---

## Test Coverage Summary

| Area | Unit test | Pipeline / Integration test |
|------|-----------|----------------------------|
| ALU ops (RV32I) | `sim_alu` ✅ | `sim_pipeline` ✅ |
| ALU W-type (RV64I) | `sim_rv64i` ✅ | — |
| All branches + JAL/JALR | — | `sim_pipeline` ✅ |
| EX/MEM forwarding | — | `sim_pipeline` ✅ |
| MEM/WB forwarding | — | `sim_pipeline` ✅ |
| Double forwarding (same reg both operands) | — | `sim_pipeline` ✅ |
| Load-use stall | — | `sim_pipeline` ✅ |
| Load/store (LB/H/W/BU/HU, SB/H/W) | — | `sim_pipeline` ✅ |
| LUI / AUIPC | — | `sim_pipeline` ✅ |
| CSR in pipeline (CSRRW/RS/RC) | — | `sim_pipeline` ✅ |
| ECALL trap (mepc/mcause written) | `sim_csr` ✅ | `sim_pipeline` ✅ |
| MRET | `sim_csr` ✅ | `sim_intr` ✅ |
| S-mode CSRs + delegation | `sim_sv` ✅ | — |
| SRET | `sim_sv` ✅ | — |
| M-extension | `sim_mext` ✅ | — |
| A-extension (AMO compute) | `sim_amo` ✅ | — |
| LR/SC pipeline integration | — | (via tb_rv_core hex) |
| Timer interrupt (MTIP) | `sim_timer` ✅ | `sim_intr` ✅ |
| External interrupt (MEIP) | — | `sim_intr` ✅ |
| Software interrupt (MSIP) | — | `sim_intr` ✅ |
| Interrupt priority (MEIP>MSIP>MTIP) | — | `sim_intr` ✅ |
| Interrupt masked (MIE=0) | — | `sim_intr` ✅ |
| MRET re-enables interrupts (MPIE→MIE) | — | `sim_intr` ✅ |
| MMU / TLB | `sim_mmu` ✅ | — |
| UART | `sim_uart` ✅ | — |
| GPIO | `sim_gpio` ✅ | — |
| PLIC | `sim_plic` ✅ | — |
