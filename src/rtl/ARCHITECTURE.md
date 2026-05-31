/**
@page ARCHITECTURE Module Architecture and Dependency Graph

@section module_overview Module Overview

The RISC-V processor is organized into five major hierarchical layers:

@dot
digraph module_hierarchy {
    rankdir=LR;
    size="12,8";
    
    // Define nodes with colors
    node [shape=box, style="rounded,filled"];
    
    // Top-level
    rv_soc [label="rv_soc\n(SoC Top)", fillcolor="#FFE6E6"];
    
    // CPU & Memory subsystem
    rv_core [label="rv_core\n(5-Stage Pipeline)", fillcolor="#FFB3B3"];
    imem [label="rv_imem\n(Instruction Memory)", fillcolor="#CCFFCC"];
    dmem [label="rv_dmem\n(Data Memory)", fillcolor="#CCFFCC"];
    
    // CPU Internal
    ifetch [label="IF Stage\n(Program Counter)", fillcolor="#FFCCCC"];
    decode [label="rv_decode\n(Instruction Decoder)", fillcolor="#FFCCCC"];
    alu [label="rv_alu\n(ALU)", fillcolor="#FFCCCC"];
    forward [label="rv_forward\n(Data Forwarding)", fillcolor="#FFCCCC"];
    hazard [label="rv_hazard\n(Hazard Detection)", fillcolor="#FFCCCC"];
    branch [label="rv_branch\n(Branch Logic)", fillcolor="#FFCCCC"];
    regfile [label="rv_regfile\n(Register File)", fillcolor="#FFCCCC"];
    
    // CPU Extensions
    cdecode [label="rv_cdecode\n(C Extension)", fillcolor="#FFD9B3"];
    muldiv [label="rv_muldiv\n(M Extension)", fillcolor="#FFD9B3"];
    amo [label="rv_amo\n(A Extension)", fillcolor="#FFD9B3"];
    fpu [label="rv_fpu (+_d)\n(F/D Extension)", fillcolor="#FFD9B3"];
    fregfile [label="rv_fregfile\n(FP Registers)", fillcolor="#FFCCCC"];
    csr [label="rv_csr\n(Zicsr + CSRs)", fillcolor="#FFD9B3"];
    mmu [label="rv_mmu\n(MMU + TLB)", fillcolor="#FFD9B3"];
    
    // Peripherals
    timer [label="rv_timer\n(CLINT)", fillcolor="#B3D9FF"];
    uart [label="rv_uart\n(UART)", fillcolor="#B3D9FF"];
    gpio [label="rv_gpio\n(GPIO)", fillcolor="#B3D9FF"];
    plic [label="rv_plic\n(PLIC)", fillcolor="#B3D9FF"];
    
    // Edges
    rv_soc -> rv_core;
    rv_soc -> imem;
    rv_soc -> dmem;
    rv_soc -> timer;
    rv_soc -> uart;
    rv_soc -> gpio;
    rv_soc -> plic;
    
    rv_core -> ifetch;
    rv_core -> decode;
    rv_core -> alu;
    rv_core -> forward;
    rv_core -> hazard;
    rv_core -> branch;
    rv_core -> regfile;
    rv_core -> cdecode;
    rv_core -> muldiv;
    rv_core -> amo;
    rv_core -> fpu;
    rv_core -> fregfile;
    rv_core -> csr;
    rv_soc  -> mmu;
    
    rv_core -> imem;
    rv_core -> dmem;
}
@enddot

@section pipeline_stages Pipeline Stages

The processor implements a classic 5-stage in-order pipeline:

@dot
digraph pipeline {
    rankdir=LR;
    node [shape=box, style="rounded,filled", fillcolor="#FFE6E6"];
    
    IF [label="IF\nInstruction Fetch"];
    ID [label="ID\nDecode &\nRegister Read"];
    EX [label="EX\nExecute &\nBranch Eval"];
    MEM [label="MEM\nMemory Access"];
    WB [label="WB\nWrite Back"];
    
    IF -> ID -> EX -> MEM -> WB;
    
    // Data forwarding paths
    EX -> ID [style=dashed, label="EX/MEM forward"];
    MEM -> EX [style=dashed, label="MEM/WB forward"];
}
@enddot

@subsection if_stage IF Stage (Instruction Fetch)
- Presents PC to instruction memory (imem_addr)
- Waits for synchronous read response (imem_ready, imem_rdata)
- fetch_pc tracks which PC has pending read in BRAM
- Stalls on imem_ready=0 (memory latency or page fault)

@subsection id_stage ID Stage (Decode & Register Read)
- Decodes instruction via rv_decode module
- Generates control signals (alu_op, mem_read, mem_write, etc.)
- Extracts immediate values (sign-extended based on instruction type)
- Reads source operands (rs1, rs2) from register file
- Detects load-use hazards via rv_hazard module

@subsection ex_stage EX Stage (Execute)
- Execute ALU operations (arithmetic, logic, shift)
- Evaluate branch conditions and compute branch target
- Apply data forwarding from EX/MEM and MEM/WB registers
- Generate shift amount and ALU output
- Detect and handle interrupts (if enabled and pending)

@subsection mem_stage MEM Stage (Memory Access)
- Request DMEM for load/store operations
- Wait for synchronous read response (dmem_ready, dmem_rdata)
- Apply byte-lane shifting for sub-word loads

@subsection wb_stage WB Stage (Write Back)
- Write ALU result or loaded data back to register file
- Update program counter for next instruction

@section hazard_handling Hazard Handling

@subsection data_forwarding Data Forwarding
- **EX forwarding**: Forward EX/MEM result (1-instruction-old) to EX stage
- **MEM forwarding**: Forward MEM/WB result (2-instruction-old) to EX stage
- Implemented in rv_forward module
- Reduces stall penalties from 2 cycles to 1 cycle

@subsection load_use_hazard Load-Use Hazard
- Detected in ID stage by rv_hazard module
- Stalls IF and ID for 1 cycle when:
  - Instruction in EX stage is a load (mem_read=1)
  - Instruction in ID stage reads destination register of that load
- Enables MEM/WB forwarding to provide data in following cycle

@subsection branch_jump Branch/Jump Resolution
- Resolved in EX stage (branch_taken_ex, branch_target_ex)
- Causes 2-cycle pipeline flush:
  1. IF → ID bubble (fetch stall)
  2. ID → EX bubble (decode stall)
- New PC (branch target) presented at start of cycle 3

@section privilege_architecture Privilege Architecture

The processor supports three privilege levels:

@dot
digraph privilege_levels {
    rankdir=TB;
    node [shape=box, style="rounded,filled"];
    
    M [label="M-mode\n(Machine)\nFull privileges", fillcolor="#FFB3B3"];
    S [label="S-mode\n(Supervisor)\nVirtual memory\nException handler", fillcolor="#FFD9B3"];
    U [label="U-mode\n(User)\nApplication code", fillcolor="#B3FFB3"];
    
    M -> S [label="Trap delegation\n(medeleg/mideleg)", style=dashed];
    S -> U [label="Virtual address\ntranslation\n(Sv32/Sv39)", style=dashed];
    M -> M [label="MRET", style=dotted];
    S -> M [label="MRET", style=dotted];
    S -> S [label="SRET", style=dotted];
}
@enddot

**Transitions:**
- **Trap entry (M-mode)**: cur_priv ← M
- **Trap entry (S-mode, delegated)**: cur_priv ← S
- **MRET**: cur_priv ← mstatus.MPP, MIE ← mstatus.MPIE
- **SRET**: cur_priv ← mstatus.SPP, SIE ← mstatus.SPIE

@section interrupt_handling Interrupt Handling & Priority

@dot
digraph interrupt_priority {
    rankdir=LR;
    node [shape=box, style="rounded,filled"];
    
    MEIP [label="MEIP\n(M-mode External)", fillcolor="#FFB3B3"];
    MSIP [label="MSIP\n(M-mode Software)", fillcolor="#FFB3B3"];
    MTIP [label="MTIP\n(M-mode Timer)", fillcolor="#FFB3B3"];
    SEIP [label="SEIP\n(S-mode External)", fillcolor="#FFD9B3"];
    SSIP [label="SSIP\n(S-mode Software)", fillcolor="#FFD9B3"];
    STIP [label="STIP\n(S-mode Timer)", fillcolor="#FFD9B3"];
    
    MEIP -> MSIP -> MTIP -> SEIP -> SSIP -> STIP;
}
@enddot

**Masking:**
- Interrupt only delivered if corresponding bit in mie/sie is set
- Interrupts cleared only by returning from trap handler via MRET/SRET

@section isa_coverage ISA Coverage

@dot
digraph isa_extensions {
    rankdir=TB;
    node [shape=box, style="rounded,filled"];
    
    RV32I [label="RV32I Base\n(47 instructions)", fillcolor="#FFE6E6"];
    RV64I [label="RV64I Base\n(W-type, XLEN=64)", fillcolor="#FFE6E6"];
    
    M [label="M Extension\nMUL/DIV/REM\n(13 instructions)", fillcolor="#FFD9B3"];
    A [label="A Extension\nLR/SC/AMO\n(11 instructions)", fillcolor="#FFD9B3"];
    F [label="F Extension\nSingle-precision FP\n(rv_fpu)", fillcolor="#FFD9B3"];
    D [label="D Extension\nDouble-precision FP\n(rv_fpu_*_d)", fillcolor="#FFD9B3"];
    C [label="C Extension\nCompressed 16-bit\n(rv_cdecode)", fillcolor="#FFD9B3"];
    Zicsr [label="Zicsr Extension\nCSR access\n(6 instructions)", fillcolor="#FFD9B3"];
    
    S [label="S-mode Support\nVirtual Memory\nInterrupts", fillcolor="#B3FFB3"];
    
    RV32I -> M;
    RV32I -> A;
    RV32I -> F;
    F -> D;
    RV32I -> C;
    RV32I -> Zicsr;
    RV32I -> S;
    RV32I -> RV64I;
    
    M -> Zicsr;
    A -> Zicsr;
    Zicsr -> S;
}
@enddot

@note ISA coverage (2026-05-31): RV32GC / RV64GC = I, M, A, F, D, C, Zicsr + S-mode
(Sv32/Sv39). Compliance: RV64 117/117, RV32 88/88. Not implemented: illegal-instruction
trap, PMP, V. The canonical, always-current status is in `CLAUDE.md`.

@section module_dependencies Module Dependency Details

@subsection rv_core rv_core - Main CPU Core

**Dependencies:**
- rv_pkg.sv (type definitions, opcodes)
- rv_regfile.sv (32×XLEN register storage)
- rv_decode.sv (instruction decoder)
- rv_alu.sv (combinational ALU)
- rv_branch.sv (branch condition & target)
- rv_forward.sv (data forwarding)
- rv_hazard.sv (hazard detection)
- rv_muldiv.sv (multiply/divide)
- rv_amo.sv (atomic operations)
- rv_csr.sv (CSR & privilege handling)
- rv_mmu.sv (virtual address translation)

**Provides:**
- imem_addr, imem_req → IMEM
- dmem_addr, dmem_wdata, dmem_req, dmem_we → DMEM
- Control signals to peripherals

@subsection rv_decode rv_decode - Instruction Decoder

**Inputs:**
- inst (32-bit instruction word)

**Outputs:**
- ctrl (control_signals_t struct)
- imm (sign-extended immediate)
- rs1_addr, rs2_addr, rd_addr
- rs1_used, rs2_used (flags)

**Format Support:**
- R-type: ADD, SUB, SLL, SRA, etc.
- I-type: ADDI, LW, JALR, CSRRW, etc.
- S-type: SW, SH, SB
- B-type: BEQ, BNE, BLT, BGE, etc.
- U-type: LUI, AUIPC
- J-type: JAL

@subsection rv_forward rv_forward - Data Forwarding

**Inputs:**
- id_ex_rs1_addr, id_ex_rs2_addr (operand addresses in EX stage)
- ex_mem_rd_addr, ex_mem_reg_write (destination in MEM stage)
- mem_wb_rd_addr, mem_wb_reg_write (destination in WB stage)
- ex_mem_result, mem_wb_result (data values)

**Outputs:**
- fwd_sel_1, fwd_sel_2 (forwarding control: 2'b00/01/10)
- fwd_result_1, fwd_result_2 (forwarded data)

@subsection rv_hazard rv_hazard - Hazard Detection

**Inputs:**
- id_ex_mem_read (load instruction in EX)
- id_ex_rd_addr, if_id_rs1_addr, if_id_rs2_addr

**Outputs:**
- stall_if (pipeline stall signal)

@subsection rv_csr rv_csr - Control & Status Registers

**Implements:**
- Machine-mode: mstatus, mie, mepc, mcause, mtval, mtvec, misa, medeleg, mideleg, mscratch, mip, mcycle, minstret, mhartid
- Supervisor-mode: sstatus, sie, sepc, scause, stval, stvec, sscratch, sip
- satp (Sv32/Sv39 MMU control)

**Outputs:**
- trap_vector (PC for trap handler)
- cur_priv (current privilege level)
- irq_pending (interrupt pending flag)
- mstatus_sum, mstatus_mxr (permission bits)

@subsection rv_mmu rv_mmu - Memory Management Unit

**Addresses:**
- IF port: Virtual instruction addresses → Physical IMEM addresses
- MEM port: Virtual data addresses → Physical DMEM/peripheral addresses

**Features:**
- 16-entry fully-associative TLB
- Sv32 (2-level) or Sv39 (3-level) page table walk
- Page fault exception generation

@section timing_diagram Timing Example: Load-Use Stall

@verbatim
       Cycle:  1    2    3    4    5    6
       
IF:           LW      | stall | ADD  | ...
ID:                LW | stall | ADD  | ...
EX:                   | LW    | stall| ADD | ...
MEM:                  |       | LW   | x   | ...
WB:                   |       |      | LW  | x

Data path:
- Cycle 3: LW finishes DMEM read, data available in WB
- Cycle 4: ADD can use LW result via MEM/WB forwarding
@endverbatim

*/
