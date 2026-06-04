# OpenSBI-style boot in simulation (shared DDR + fw_payload)

This sets up a simulation environment that boots an M-mode firmware image from a
**single shared DDR** through the cached AXI path -- the sim analogue of the real
board where the instruction and data masters fan into an AXI SmartConnect and
reach one PS DDR.  It is the harness a real **OpenSBI `fw_payload`** drops into,
and it is proven today by a small **mini-SBI stand-in firmware**.

## Components

| File | Role |
|------|------|
| `src/sim/tb/rv_axi_dualport_mem_bfm.sv` | One byte memory, two AXI slave ports (IF read-only + data read/write), burst reads, `$readmemh` init. = one shared DDR. |
| `src/sim/tb/tb_rv_boot_soc.sv` | Boots a firmware hex on `rv_soc` (I$/D$ on) with both masters into the shared DDR; deserializes the UART (8N1) to the console; detects completion via a tohost sentinel. |
| `src/software/boot/sbi_boot.S` | Mini-SBI stand-in firmware (OpenSBI essentials). |
| `src/software/boot/boot.ld` | Links the firmware flat at DDR base `0x8000_0000`. |

## Run the stand-in (works now)

```sh
cd src/software && make boot          # build boot/sbi_boot.hex (RV64, via docker gcc)
cd ../sim       && make sim_boot      # boot it on rv_soc (caches on), shared DDR
```

Expected console:

```
----- boot console (firmware: ../software/boot/sbi_boot.hex) -----
M: mini-SBI boot, PMP set, entering S-mode
S: hello from supervisor via SBI ecall console
BOOT OK
----- end of console (98 UART chars; IF line-fills=322, data reads=4) -----
tb_rv_boot_soc: PASS (firmware reached SBI done; sentinel=0x00c0ffee)
```

What the stand-in exercises -- exactly the integration OpenSBI needs, end to end
over the cached shared-DDR AXI path:
- M-mode entry at `RST_ADDR`, M trap vector, **PMP** opened (region 0 = all RWX).
- **M-mode UART console** (direct register poll/write).
- **M->S transition** via `MRET` (`mstatus.MPP=S`, `mepc`).
- **SBI console path**: S-mode `ECALL` -> M trap handler (`mcause=9`) -> UART
  putchar -> `MRET` back to S (the SBI `console_putchar` shape).
- **SBI "done"**: an `ECALL` whose handler writes the completion sentinel.

### Bug found & fixed by this harness

`rv_periph` returned a 32-bit MMIO register zero-extended on the low 32 bits.  On
**RV64** the core right-shifts a sub-XLEN load by `addr[2:0]*8` to pick the byte
lane of a 64-bit word, so a 32-bit register at a word offset with `addr[2]=1`
(e.g. UART `STAT` @ +4) was shifted out (`>>32`) and read as 0 -- the S-mode
console hung polling TXRDY.  Fix: replicate the register across every 32-bit lane
(`periph_rdata <= {(XLEN/32){reg32}}`).  RV32 is bit-identical (no regression);
RV64 MMIO loads now work.  This path was never exercised before (prior SoC tests
only did peripheral *writes* + CSR reads; `sim_bm` is RV32, where `addr[2]` is not
used for lane select).

## Dropping in real OpenSBI (`PLATFORM=generic` + `fw_payload`)

The generic OpenSBI platform is fully DTB-driven, so no custom C platform is
needed -- but see the **console caveat** below.

```sh
# 1. toolchain: riscv64-unknown-elf-  (repo's riscv_gcc docker image has it)
git clone --depth 1 https://github.com/riscv-software-src/opensbi
# 2. compile the SoC device tree (memory map must match rv_soc)
dtc -I dts -O dtb -o rv_soc.dtb docs/opensbi/rv_soc.dts     # sample DTS below
# 3. a payload (S-mode): a tiny test program or a Linux Image
#    (start with a bare S-mode .bin that prints via SBI ecall, then a kernel)
# 4. build fw_payload with the DTB embedded
make -C opensbi PLATFORM=generic CROSS_COMPILE=riscv64-unknown-elf- \
     PLATFORM_RISCV_XLEN=64 PLATFORM_RISCV_ISA=rv64gc PLATFORM_RISCV_ABI=lp64 \
     FW_PAYLOAD=y FW_PAYLOAD_PATH=payload.bin FW_FDT_PATH=rv_soc.dtb
# 5. convert to a base-relative verilog hex for the shared DDR BFM
riscv64-unknown-elf-objcopy -O binary \
     opensbi/build/platform/generic/firmware/fw_payload.elf fw_payload.bin
riscv64-unknown-elf-objcopy -I binary -O verilog \
     --set-start 0 --change-addresses 0 fw_payload.bin fw_payload.hex
#    (or: objcopy -O verilog --adjust-vma=-0x80000000 fw_payload.elf fw_payload.hex)
# 6. boot it in the same harness
cd src/sim && make sim_boot BOOT_HEX=/abs/path/fw_payload.hex
```

`rv_soc` resets to `RST_ADDR=0x8000_0000`; build OpenSBI's link/`FW_TEXT_START`
to match, and place the payload/DTB so the linked addresses land in the shared
DDR image (the BFM is base-relative to `0x8000_0000`).

### Console caveat (the one real blocker for a banner)

OpenSBI generic prints through a **DTB-described, driver-supported UART**
(`ns16550`/`uart8250`, `sifive,uart0`, etc.).  This SoC's `rv_uart` is a custom
register layout with **no OpenSBI driver**, so generic OpenSBI will not find a
console.  Two options:
1. **Make `rv_uart` 16550-register-compatible** (THR/LSR offsets + LSR.THRE bit),
   then the stock `uart8250` driver and the Linux `8250` driver both work.  (Recommended.)
2. Write a tiny OpenSBI platform/console driver for `rv_uart` (custom platform).

Until then, the mini-SBI stand-in above validates the entire *hardware* path
(shared DDR, caches, M/S, traps, SBI ecall console, PMP); the remaining OpenSBI
work is firmware-side (DTB + UART driver), de-risked by this harness.

## Sample device tree

A starting `rv_soc.dts` matching the SoC memory map (CLINT 0xC000_0000, UART
0xC001_0000, GPIO 0xC002_0000, PLIC 0xC010_0000, DRAM at 0x8000_0000) is provided
at `docs/opensbi/rv_soc.dts`.  Set `bootargs`, `timebase-frequency` (CLINT mtime
rate), and the `memory` size to match the board; fix the UART `compatible`/driver
per the console caveat.

## Next steps toward Linux

1. UART 16550 compatibility (unblocks both OpenSBI and Linux console).
2. Real OpenSBI `fw_payload` boots to its banner in `sim_boot` (this harness).
3. Payload = Linux `Image`; `earlycon=sbi` first, then the 8250 console via DTB.
4. Move to FPGA: PS DDR via S_AXI_HP (`boards/*/vivado`), DTB matching the map.

See also `docs/cache.md`, `docs/axi_ddr.md`, and the `linux-boot-roadmap` memory.
