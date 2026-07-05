#!/usr/bin/env python3
# =============================================================================
# make_pl_bin.py - Convert the KV260 bitstream to the Linux fpga_manager .bin
#                  format (header-stripped, byte-swapped) for `fpgautil`.
# =============================================================================
# Raw JTAG `fpga -file design.bit` bypasses Linux's zynqmp-fpga driver, which
# is what normally releases pl_resetn0 (the PS-to-PL reset gating our RISC-V
# core) as part of its standard bitstream-load sequence -- see the
# confidence note in bringup_jtag.tcl and boards/kv260/vitis/README.md
# "xmutil / fpgautil path". Loading the SAME bitstream via `fpgautil` on the
# board's already-running Linux is the officially-supported alternative.
#
# `fpgautil -b <name>.bit.bin -o <name>.dtbo` expects the ".bit.bin" format:
# the raw bitstream with the .bit ASCII header stripped, generated here via
# bootgen's `-process_bitstream bin` mode (the standard/documented way to
# produce this format from a Vivado .bit, per AMD Kria firmware docs).
#
# Run from PowerShell (NOT Bash/MSYS):
#   python boards/kv260/vitis/make_pl_bin.py
#
# Output: boards/kv260/vitis/rv_riscv_kv260.bit.bin (gitignored, copy this +
# rv_riscv_kv260_overlay.dtbo to the board and run fpgautil there).
# =============================================================================
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent      # boards/kv260/vitis
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
    ap = argparse.ArgumentParser(description="Convert the KV260 .bit to fpga_manager .bin format.")
    ap.add_argument("--bit", default=str(REPO / "boards/kv260/vivado/rv_riscv_kv260"
                                          "/rv_riscv_kv260.runs/impl_1/bd_riscv_wrapper.bit"),
                    help="input .bit path")
    ap.add_argument("--out", default=str(HERE / "rv_riscv_kv260.bit.bin"))
    ap.add_argument("--bootgen", help="path to bootgen(.bat); else env/PATH")
    args = ap.parse_args()

    bit = Path(args.bit)
    if not bit.is_file():
        sys.exit("missing input bitstream: %s (build it first: build_all.py --stage fpga)" % bit)
    bootgen = resolve_bootgen(args.bootgen)

    # NOTE: no "bootloader" attribute here -- that marks a partition as an
    # FSBL image, which a plain PL bitstream is not; the correct (and only
    # necessary) attribute for -process_bitstream bin is destination_device=pl.
    bif = HERE / "convert_bin.bif"
    bif.write_text(
        "all:\n"
        "{\n"
        "    [destination_device=pl] %s\n"
        "}\n" % bit.as_posix(),
        encoding="ascii",
    )

    print("Input bitstream : %s" % bit)
    print("BIF             : %s" % bif)

    rc = subprocess.run([bootgen, "-image", str(bif), "-arch", "zynqmp",
                         "-process_bitstream", "bin", "-w", "on",
                         "-o", args.out]).returncode
    if rc != 0:
        sys.exit("bootgen failed (exit %d)" % rc)

    out = Path(args.out)
    if not out.is_file():
        # CONFIRMED on real hardware (2026-07-04): -process_bitstream bin
        # mode ignores -o entirely for the converted-bitstream filename --
        # bootgen always writes "<input .bit filename>.bin" in the SAME
        # DIRECTORY as the input .bit (e.g. bd_riscv_wrapper.bit.bin next to
        # bd_riscv_wrapper.bit), regardless of what -o says.
        actual = bit.parent / (bit.name + ".bin")
        if not actual.is_file():
            sys.exit("bootgen reported success but neither %s nor the expected "
                     "%s (bootgen's actual naming convention: <input>.bin next "
                     "to the input .bit) exist -- check the bootgen console "
                     "output above for the real output path." % (out, actual))
        actual.rename(out)
        print("NOTE: bootgen wrote %s (its own naming convention, ignoring -o); moved to %s"
              % (actual, out))

    print("OK: wrote %s (%d bytes)" % (out, out.stat().st_size))
    print("Next: compile the overlay and copy both files to the board -- see")
    print("      boards/kv260/vitis/README.md 'xmutil / fpgautil path'.")


if __name__ == "__main__":
    main()
