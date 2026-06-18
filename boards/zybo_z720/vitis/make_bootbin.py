#!/usr/bin/env python3
# =============================================================================
# make_bootbin.py - Assemble a Zynq-7000 BOOT.bin for the Zybo Z7-20 RISC-V SoC
#                   from the FSBL (prep-C), the implemented bitstream, and the
#                   RISC-V firmware .bin (re-linked to 0x0020_0000).
# =============================================================================
# Cross-platform (Windows / Linux), standard library only -- no venv / pip install.
# Partition order (firmware BEFORE bitstream) is fixed in the generated .bif so the
# firmware is resident in DDR before PL config releases the RISC-V core.
#
#   python make_bootbin.py                       # OpenSBI hello (default fw_payload_lo.bin)
#   python make_bootbin.py --firmware <fw.bin>   # any 0x200000-linked .bin
#
# NOTE: for a REAL boot the firmware must be rebuilt with the real-HW device tree
# (DTS=docs/opensbi/rv_soc_hw.dts: 25 MHz clocks / 57600 baud).  The default below
# points at the sim-DTS fw_payload_lo.bin (fine for validating the bootgen flow).
#
# bootgen is found via --bootgen, the BOOTGEN_BIN / XILINX_VITIS env vars, or PATH
# (run the Xilinx settings64 first).
# =============================================================================
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent      # boards/zybo_z720/vitis
REPO = HERE.parents[2]                       # repo root


def resolve_bootgen(explicit):
    names = ["bootgen.bat", "bootgen"] if os.name == "nt" else ["bootgen"]
    cands = []
    if explicit:
        cands.append(Path(explicit))
    for var in ("BOOTGEN_BIN", "XILINX_VITIS"):
        val = os.environ.get(var)
        if val:
            cands.append(Path(val))
            cands += [Path(val) / "bin" / n for n in names]
    for c in cands:
        if c.is_file():
            return str(c)
    for n in names:
        found = shutil.which(n)
        if found:
            return found
    sys.exit("Cannot find bootgen. Pass --bootgen <path>, set BOOTGEN_BIN/XILINX_VITIS, "
             "or add the Xilinx bin to PATH (settings64).")


def main():
    ap = argparse.ArgumentParser(description="Assemble a Zynq-7000 BOOT.bin for the Zybo Z7-20.")
    ap.add_argument("--firmware", default=str(REPO / "tests/opensbi/work/fw_payload_lo.bin"),
                    help="RISC-V firmware .bin linked at 0x200000")
    ap.add_argument("--out", default=str(HERE / "BOOT.bin"))
    ap.add_argument("--bootgen", help="path to bootgen(.bat); else env/PATH")
    args = ap.parse_args()

    fsbl = HERE / "ws/zybo_plat/export/zybo_plat/sw/boot/fsbl.elf"
    bit = REPO / "boards/zybo_z720/vivado/rv_riscv_zybo/rv_riscv_zybo.runs/impl_1/bd_riscv_wrapper.bit"
    firmware = Path(args.firmware)
    bootgen = resolve_bootgen(args.bootgen)

    for f in (fsbl, bit, firmware, Path(bootgen)):
        if not Path(f).is_file():
            sys.exit("missing input: %s" % f)

    # Concrete .bif (firmware BEFORE bitstream).  Forward slashes work on both OSes.
    bif = HERE / "boot.gen.bif"
    bif.write_text(
        "the_ROM_image:\n"
        "{\n"
        "    [bootloader] %s\n"
        "    [load=0x00200000] %s\n"
        "    %s\n"
        "}\n" % (fsbl.as_posix(), firmware.as_posix(), bit.as_posix()),
        encoding="ascii",
    )

    print("FSBL     : %s" % fsbl)
    print("Firmware : %s" % firmware)
    print("Bitstream: %s" % bit)
    print("BIF      : %s" % bif)

    rc = subprocess.run([bootgen, "-arch", "zynq", "-image", str(bif),
                         "-o", args.out, "-w", "on"]).returncode
    if rc != 0:
        sys.exit("bootgen failed (exit %d)" % rc)
    print("OK: wrote %s (%d bytes)" % (args.out, Path(args.out).stat().st_size))


if __name__ == "__main__":
    main()
