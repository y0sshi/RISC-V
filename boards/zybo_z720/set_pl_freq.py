#!/usr/bin/env python3
# =============================================================================
# set_pl_freq.py - Retarget the Zybo Z7-20 RISC-V SoC to a new PL clock.
# =============================================================================
# A PL-clock change is NOT a single edit: the bitstream timing target, the PS
# clock generator (ps7_init), the device-tree timebase/UART-clock, the 8250 baud
# divisor and the firmware images are all coupled.  Get one wrong and real HW
# boots with a garbled console or a 25x-off timer.  This script rewrites every
# SOURCE place from one frequency argument, and (post-build) refreshes the
# generated ps7_init from the freshly built XSA.
#
# How the PS realizes the clock:
#   FCLK_CLK0 = IO_PLL / divisor,  IO_PLL = 1000 MHz (Zybo board preset),
#   divisor   = round(1000 / requested_MHz)  (integer, 1..63),
#   so the ACTUAL clock = 1000 / divisor MHz, which usually differs from the
#   request (e.g. req 30 -> div 33 -> 30.303 MHz; req 40 -> div 25 -> 40.0; req
#   50 -> div 20 -> 50.0).  The DT timebase / UART-clock / baud MUST follow the
#   ACTUAL realized clock, not the request -- this script computes it.
#
# Usage:
#   python set_pl_freq.py <freq_mhz> [--baud 57600]   # rewrite all source files
#   python set_pl_freq.py --refresh-ps7               # post-build: pull ps7_init
#                                                     #   from the XSA + verify
#
# Full retarget flow (from the repo root):
#   python boards/zybo_z720/set_pl_freq.py 40              # 1. edit sources
#   python boards/zybo_z720/build_all.py --stage bit ...   # 2. re-synth (~40min)
#   python boards/zybo_z720/set_pl_freq.py --refresh-ps7   # 3. ps7_init <- XSA
#   make fw-opensbi-hw fw-linux-hw                         # 4. firmware <- new DT
# Then bring up with boards/zybo_z720/vitis/bringup_jtag.tcl (Pmod JC, baud).
#
# NOTE: no XDC edit is needed -- the timing constraint (and the OOC xdc) are
# auto-derived from PCW_FPGA0_PERIPHERAL_FREQMHZ, i.e. from PL_FREQMHZ below.
# =============================================================================

import argparse
import os
import re
import sys
import tempfile
import zipfile

IO_PLL_MHZ = 1000.0  # Zybo board-preset IO PLL that feeds FCLK_CLK0

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

BUILD_TCL   = os.path.join(REPO, "boards", "zybo_z720", "vivado", "build_zybo.tcl")
DTS_LINUX   = os.path.join(REPO, "tests", "linux", "rv_soc_linux_hw.dts")
DTS_OPENSBI = os.path.join(REPO, "docs", "opensbi", "rv_soc_hw.dts")
BRINGUP_TCL = os.path.join(REPO, "boards", "zybo_z720", "vitis", "bringup_jtag.tcl")
PS7_VITIS   = os.path.join(REPO, "boards", "zybo_z720", "vitis", "ps7_init.tcl")
XSA         = os.path.join(REPO, "boards", "zybo_z720", "vivado",
                           "rv_riscv_zybo", "rv_riscv_zybo.xsa")

FCLK_REG = "0XF8000170"  # SLCR FPGA0_CLK_CTRL (DIVISOR1[25:20], DIVISOR0[13:8])


def realized(req_mhz):
    """Return (divisor, actual_MHz, actual_Hz) the PS will realize for req_mhz."""
    div = max(1, round(IO_PLL_MHZ / req_mhz))
    actual_mhz = IO_PLL_MHZ / div
    actual_hz = round(IO_PLL_MHZ * 1e6 / div)
    return div, actual_mhz, actual_hz


def baud_divisor(actual_hz, baud):
    """8250 divisor (round, as OpenSBI/Linux compute it) + realized baud + error%."""
    bdiv = max(1, round(actual_hz / (16 * baud)))
    actual_baud = actual_hz / (16 * bdiv)
    err = (actual_baud - baud) / baud * 100.0
    return bdiv, round(actual_baud), err


def sub_in_file(path, subs, label):
    with open(path, "r", encoding="utf-8", newline="") as f:
        text = f.read()
    n_total = 0
    for pat, repl in subs:
        text, n = re.subn(pat, repl, text, flags=re.M)
        n_total += n
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    print("  %-28s %d edit(s)" % (label + ":", n_total))
    return n_total


def apply_freq(req_mhz, baud, dry_run=False):
    div, actual_mhz, actual_hz = realized(req_mhz)
    bdiv, actual_baud, err = baud_divisor(actual_hz, baud)
    mhz_s = ("%.3f" % actual_mhz).rstrip("0").rstrip(".")

    print("== retarget PL clock ==")
    print("  request        : %g MHz" % req_mhz)
    print("  IO PLL / div    : 1000 MHz / %d" % div)
    print("  realized FCLK   : %s MHz  (%d Hz)" % (mhz_s, actual_hz))
    print("  baud %d         : divisor %d -> %d baud (%+.2f%%)"
          % (baud, bdiv, actual_baud, err))
    if abs(err) > 2.5:
        print("  WARNING: baud error %+.2f%% exceeds ~2.5%% 8N1 margin; pick a"
              " baud that divides %s MHz more cleanly." % (err, mhz_s))
    if dry_run:
        print("== dry-run: no files edited ==")
        return div
    print("== editing source files ==")

    # 1) build_zybo.tcl: the request drives PCW (and hence all timing/ps7_init).
    sub_in_file(BUILD_TCL,
                [(r"^set PL_FREQMHZ \d+", "set PL_FREQMHZ %d" % int(req_mhz))],
                "build_zybo.tcl")

    # 2) device trees: timebase + UART clock follow the ACTUAL FCLK; baud divisor
    #    is recomputed.  Inline comments carry the live math (header is generic).
    dt_subs = [
        (r"(timebase-frequency = )<\d+>;[^\n]*",
         r"\g<1><%d>;  /* mtime = PL/MTIME_DIV = %s MHz/1 */" % (actual_hz, mhz_s)),
        (r"(clock-frequency = )<\d+>;[^\n]*",
         r"\g<1><%d>;  /* = PL clock; sets the 8250 divisor */" % actual_hz),
        (r"(current-speed = )<\d+>;[^\n]*",
         r"\g<1><%d>;  /* %se6/(16*%d)=%d, %+.2f%% */"
         % (baud, mhz_s, bdiv, actual_baud, err)),
    ]
    for path, lbl in ((DTS_LINUX, "rv_soc_linux_hw.dts"),
                      (DTS_OPENSBI, "rv_soc_hw.dts")):
        sub_in_file(path, dt_subs, lbl)

    # 3) bring-up script comments (FCLK + the "<x> MHz / <baud>" device-tree note).
    sub_in_file(BRINGUP_TCL,
                [(r"FCLK_CLK0 = [\d.]+ MHz", "FCLK_CLK0 = %s MHz" % mhz_s),
                 (r"with the [\d.]+ MHz /", "with the %s MHz /" % mhz_s)],
                "bringup_jtag.tcl")

    print("== next steps ==")
    print("  python boards/zybo_z720/build_all.py --stage bit --vivado <vivado.bat>")
    print("  python boards/zybo_z720/set_pl_freq.py --refresh-ps7")
    print("  make fw-opensbi-hw fw-linux-hw")
    return div


def read_xsa_divisor():
    """Pull ps7_init.tcl from the built XSA and return its FCLK divisor (div0*div1)."""
    if not os.path.isfile(XSA):
        sys.exit("XSA not found: %s (run build_all.py --stage bit first)" % XSA)
    with zipfile.ZipFile(XSA) as z:
        data = z.read("ps7_init.tcl").decode("utf-8", "replace")
    m = re.search(r"mask_write %s 0x[0-9A-Fa-f]+ (0x[0-9A-Fa-f]+)" % FCLK_REG, data)
    if not m:
        sys.exit("FCLK register %s not found in XSA ps7_init.tcl" % FCLK_REG)
    val = int(m.group(1), 16)
    div0 = (val >> 8) & 0x3F
    div1 = (val >> 20) & 0x3F
    return data, div0 * div1


def refresh_ps7():
    """Copy ps7_init.tcl out of the new XSA into vitis/, and report the FCLK."""
    data, div = read_xsa_divisor()
    actual_mhz = IO_PLL_MHZ / div
    with open(PS7_VITIS, "w", encoding="utf-8", newline="") as f:
        f.write(data)
    print("== refreshed %s from XSA ==" % os.path.relpath(PS7_VITIS, REPO))
    print("  FCLK divisor    : %d  ->  %.3f MHz" % (div, actual_mhz))
    print("  Verify the DT timebase/clock-frequency == %d Hz." % round(actual_mhz * 1e6))


def main():
    ap = argparse.ArgumentParser(description="Retarget the Zybo PL clock frequency.")
    ap.add_argument("freq_mhz", nargs="?", type=float,
                    help="target PL clock in MHz (e.g. 40)")
    ap.add_argument("--baud", type=int, default=57600,
                    help="console baud for the DT current-speed (default 57600)")
    ap.add_argument("--refresh-ps7", action="store_true",
                    help="post-build: copy ps7_init.tcl from the XSA + report FCLK")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the realized FCLK / baud for <freq_mhz> without editing")
    args = ap.parse_args()

    if args.refresh_ps7:
        refresh_ps7()
        return
    if args.freq_mhz is None:
        ap.error("give a target frequency in MHz, or --refresh-ps7")
    apply_freq(args.freq_mhz, args.baud, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
