# RISC-V SoC Architecture

## System Block Diagram

```
┌──────────────────────────────────────────────────────────────────────┐
│                        RISC-V System-on-Chip                          │
│                                                                        │
│  ┌────────────────────────────────────────────────────────────────┐   │
│  │                    rv_core (5-stage pipeline)                   │   │
│  │  • RV32I/RV64I base ISA                                        │   │
│  │  • M-extension (multiply/divide)                              │   │
│  │  • A-extension (atomics)                                      │   │
│  │  • Zicsr (Control/Status Register access)                     │   │
│  │  • Privilege levels: Machine (M) and Supervisor (S)           │   │
│  └────────────────────────────────────────────────────────────────┘   │
│                              ↓↑                                        │
│                      (virtual address)                                │
│  ┌────────────────────────────────────────────────────────────────┐   │
│  │                  rv_mmu (Memory Management)                    │   │
│  │  • Sv32 (32-bit) or Sv39 (64-bit) virtual paging             │   │
│  │  • TLB (16 entries for fast VA→PA translation)                │   │
│  │  • Page Table Walker (PTW) for TLB misses                     │   │
│  │  • Memory access control and fault detection                 │   │
│  └────────────────────────────────────────────────────────────────┘   │
│                              ↓↑                                        │
│                      (physical address)                               │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │          Address Decode & Bus Multiplexer                       │  │
│  │  Physical Address [31:16]:                                      │  │
│  │    0x0000 - 0x7FFF : IMEM  ─┐                                  │  │
│  │    0x8000 - 0xBFFF : DMEM  ─┤                                  │  │
│  │    0xC000          : Timer ─┼─→ req/we/addr/wdata/rdata       │  │
│  │    0xC001          : UART  ─┘                                  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│           ↓          ↓          ↓          ↓                           │
│  ┌─────────────┐ ┌────────┐ ┌────────┐ ┌──────┐                       │
│  │ rv_imem     │ │rv_dmem │ │rv_timer│ │rv_uart                       │
│  │(32KB, 8K x │ │(16KB,  │ │(CLINT) │ │(8N1) │                       │
│  │32-bit)     │ │4K x    │ │        │ │      │                       │
│  │            │ │32-bit) │ │mtime   │ │TX/RX │                       │
│  │Instruction │ │   +    │ │mtimecmp │ │      │                       │
│  │memory for  │ │ PTW    │ │        │ │Baud: │                       │
│  │boot &app   │ │access  │ │        │ │115k2 │                       │
│  └─────────────┘ └────────┘ └────────┘ │(125M)│                       │
│                                        │      │                       │
│                                        └──────┘                       │
│                                          ↓                            │
│                                    ┌──────────┐                       │
│                                    │uart_tx   │ ──→ Pmod JE[0]       │
│                                    │uart_rx   │ ←── Pmod JE[1]       │
│                                    └──────────┘                       │
│                                                                        │
│  Interrupts:                                                          │
│  • timer_irq_sig ──→ rv_core.timer_irq (MTIP)                       │
│  • uart_rx_irq   ──→ rv_core.ext_irq (MEIP via UART RX)             │
│  • (future: PLIC)  ──→ external interrupt controller                 │
│                                                                        │
└──────────────────────────────────────────────────────────────────────┘
         ↓
┌──────────────────────────────────────────────────────────────────────┐
│        zybo_z7_top (Zybo Z7-20 Board Top Module)                    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  Input:  sysclk (125MHz) ──→ clk                                    │
│          btn[0] (active-H) → rst_n (inverted)                       │
│          sw[3:0] → gpio_in                                          │
│          je[1] (uart_rx) → uart_rx                                  │
│                                                                        │
│  Output: led[3:0] ← gpio_out (status indicators)                    │
│          led5_r (red when reset), led5_g (green when running)      │
│          je[0] (uart_tx) ← uart_tx                                  │
│                                                                        │
└──────────────────────────────────────────────────────────────────────┘
```

## Memory Map

```
Virtual Address (from CPU)
        ↓
    [Page Table Walk via MMU]
        ↓
Physical Address (used by peripherals)

┌─────────────────────────────┐
│   IMEM (0x0000_0000)        │  32 KB instruction memory
│   • RV32I code              │  • 8K×32-bit words
│   • Reset vector @ 0x0      │  • Cacheable (TLB-backed)
│                             │
├─────────────────────────────┤
│   [UNMAPPED REGION]         │  0x2000_0000 - 0x7FFF_FFFF
│   • Triggers page fault     │
│   • (no physical memory)    │
│                             │
├─────────────────────────────┤
│   DMEM (0x8000_0000)        │  16 KB data memory
│   • RV32I stack/heap        │  • 4K×32-bit words
│   • PTW page tables         │  • Read-write
│                             │
├─────────────────────────────┤
│   [UNMAPPED REGION]         │  0x8001_0000 - 0xBFFF_FFFF
│                             │
├─────────────────────────────┤
│   TIMER (0xC000_0000)       │  Machine Timer (CLINT)
│   • mtime (64-bit)          │  • 16 bytes
│   • mtimecmp (64-bit)       │  • Combinational read
│   • timer_irq when mtime>=  │  • Level-triggered MTIP
│     mtimecmp                │
│                             │
├─────────────────────────────┤
│   UART (0xC001_0000)        │  8N1 Serial Port
│   • DATA, STAT, CTRL, DIV   │  • 16 bytes
│   • TX/RX state machines    │  • 115,200 bps @ 125MHz
│   • Interrupt flags         │
│                             │
├─────────────────────────────┤
│   [RESERVED FOR FUTURE]     │  0xC002_0000+
│   • GPIO (planned)          │  • Platform-Level IRQ
│   • PLIC (planned)          │    Controller
│                             │
└─────────────────────────────┘
```

## Data Path: Memory Access Flow

### Instruction Fetch (IF)
```
CPU (fetch) 
    ↓ (virtual addr)
MMU.if_port (TLB + PTW)
    ↓ (physical addr)
rv_imem
    ↓ (read data)
CPU (instruction)
```

### Data Load/Store (MEM)
```
CPU (load/store, virtual addr)
    ↓
MMU.mem_port (TLB + PTW if miss)
    ↓ (physical addr)
Address Decode
    ├──→ (0x0-0x7FFF_FFFF)  rv_imem
    ├──→ (0x8000-0xBFFF)    rv_dmem / PTW arbiter
    ├──→ (0xC000)           rv_timer
    └──→ (0xC001)           rv_uart
    ↓ (read data)
Data Mux
    ↓
CPU (load data)
```

## Bus Signals & Handshake

### Memory-Mapped Peripheral Protocol

```
Peripheral Write:
    req=1, we=1, addr[31:0], wdata[31:0], wstrb[3:0]
    Combinational: register is updated
    ready=1 (next cycle or same-cycle if combinational)

Peripheral Read:
    req=1, we=0, addr[31:0]
    Combinational: rdata[31:0] reflects selected register
    ready=1 (combinational for Timer/UART)

DMEM Access:
    req=1, we=0/1, addr[31:0], wdata[31:0], wstrb[3:0]
    Sequential: read/write completes in next cycle
    ready=0 until access complete
```

### Example: Timer Register Write

```
Cycle 1:
    is_timer_access = 1 (addr[31:16] == 0xC000)
    timer_req = 1, we = 1, addr = 0x00 (mtimecmp[31:0])
    wdata = 0x1000_0000
    ↓ (combinational)
    mtimecmp[31:0] ← wdata

Cycle 2+:
    ready = 1 (immediate)
    rdata reflects new mtimecmp value on next read
```

### Example: Timer Interrupt Generation

```
Each cycle:
    mtime ← mtime + 1 (free-running counter)
    if (mtime >= mtimecmp):
        timer_irq ← 1 (level signal)
    else:
        timer_irq ← 0

CPU sees timer_irq=1 and can take trap if MTIE=1 in mstatus
```

## Interrupt Handling Architecture

### Interrupt Sources
```
             ┌─────────────────────┐
             │  Interrupt Sources  │
             ├─────────────────────┤
Timer        │ • MTIP (mtime>=mtmp)│
(CLINT)  ───→│   (at 0xC000_0000)  │
             │                     │
UART RX      │ • MEIP (uart_rx_irq)│
(UART)   ───→│   (at 0xC001_0000)  │
             │                     │
Future       │ • Software IRQ      │
  PLIC   ───→│   (mip.MSIP)        │
             │                     │
             └────────┬────────────┘
                      ↓
            ┌─────────────────────┐
            │   rv_core.rv_csr    │
            ├─────────────────────┤
            │ • mip (interrupt    │
            │   pending)          │
            │ • mie (interrupt    │
            │   enable)           │
            │ • mideleg           │
            │   (M→S delegation)  │
            │ • mtvec (trap       │
            │   vector)           │
            └────────┬────────────┘
                     ↓
            ┌─────────────────────┐
            │   Trap Handling     │
            ├─────────────────────┤
            │ • Update MCAUSE     │
            │ • Update MEPC       │
            │ • Jump to mtvec     │
            │ • Delegate to S-mode│
            │   if mideleg[i]=1   │
            └─────────────────────┘
```

### Interrupt Priority (Machine Mode)
```
1. MEIP (Machine External) - interrupt number 11
2. MSIP (Machine Software) - interrupt number 3
3. MTIP (Machine Timer)    - interrupt number 7

4. SEIP (Supervisor External) - interrupt number 9 (if delegated)
5. SSIP (Supervisor Software) - interrupt number 1 (if delegated)
6. STIP (Supervisor Timer)    - interrupt number 5 (if delegated)
```

## Register Bit Widths by XLEN

```
Parameter: XLEN ∈ {32, 64}

32-bit Data Path (RV32):
    • General purpose registers: 32-bit
    • mtime: 64-bit (two 32-bit MMIO reads at 0xC000_0008/0x0C)
    • mtimecmp: 64-bit (two 32-bit MMIO writes at 0xC000_0000/0x04)
    • UART rdata: 32-bit (upper 24 bits zero on 8-bit reads)

64-bit Data Path (RV64):
    • General purpose registers: 64-bit
    • mtime: 64-bit (single 64-bit MMIO read at 0xC000_0008)
    • mtimecmp: 64-bit (single 64-bit MMIO write at 0xC000_0000)
    • UART rdata: 64-bit (upper 56 bits zero on 8-bit reads)
```

## Design Decisions

### 1. Address Decoding at Physical Level
- Decode happens AFTER MMU translation
- Allows same virtual address to map to different physical peripherals
- Maintains clean separation of concerns (paging vs. I/O)

### 2. Combinational Peripheral Access
- Timer/UART registers available in same cycle as req=1
- No wait states for peripheral access (ready=1 immediately)
- Different from DMEM (buffered, may take multiple cycles)
- Simplifies interrupt latency

### 3. Interrupt Line Assignments
- MTIP: Direct from Timer module (hardware interrupt #7)
- MEIP: UART RX interrupt (temporary assignment for testing)
- Future: PLIC will manage multiple external sources

### 4. Memory Arbitration
- PTW has priority over core DMEM access
- Core is already stalled (mmu_stall) when PTW active
- No complex arbitration logic needed
- Peripheral accesses bypass DMEM entirely

### 5. Extensibility
- 0xC000_0000 - 0xC000_FFFF: CLINT space (timer + potential IPI)
- 0xC001_0000 - 0xC001_FFFF: UART space (0xC001_0000 used, room for expansion)
- 0xC002_0000+: GPIO, PLIC, future peripherals

## Testing Strategy

### Unit Tests (Per-Module)
- Timer: Interrupt generation, register R/W, delegation
- UART: TX/RX state machines, error detection, interrupts

### Integration Tests (System-Level)
- Address decode: Verify peripheral selection by address
- Interrupt: Confirm timer_irq and uart_rx_irq reach CPU
- Bus arbitration: PTW priority over core DMEM access
- Board: Pin assignment verification on Zybo Z7-20

### Boot Tests (Phase 2+)
- M-mode firmware initialization
- OpenSBI bootloader operation
- Linux kernel boot sequence

