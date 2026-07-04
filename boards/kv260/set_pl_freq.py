#!/usr/bin/env python3
# =============================================================================
# set_pl_freq.py - Retarget the KV260 RISC-V SoC to a new PL clock.
# =============================================================================
# ---- Confidence note (read before use) ----
# boards/zybo_z720/set_pl_freq.py and boards/pynq_z{1,2}/set_pl_freq.py compute
# the ACTUAL realized clock from a known formula (Zynq-7000's single "IO PLL /
# integer divisor" SLCR register, FCLK_REG=0xF8000170) and use that to rewrite
# the device-tree timebase/UART-clock/baud constants automatically. Zynq
# UltraScale+ (KV260, PS8) uses a materially more complex clock-generation
# tree (multiple PLLs -- IOPLL/RPLL/APLL/DPLL/VPLL -- feeding the CRL_APB
# PL-clock dividers), and this script's author does not have a verified
# register-level formula for it. So THIS script:
#   - DOES rewrite the PL_FREQMHZ knob in build_kv260.tcl (mechanical text
#     substitution, no clock-math involved -- this part is solid).
#   - Does NOT auto-compute the realized clock / rewrite the DTS for you.
#     Read the ACTUAL realized PL0 clock from Vivado after a BD/synth run
#     (e.g. `get_property CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ
#     [get_bd_cells zynq_ps]` reports the REQUESTED value, not necessarily
#     the exact achieved one -- check the Vivado GUI's PS8 customization
#     "Clock Configuration" tab, or the generated PS8 summary report, for the
#     "Actual Freq (MHz)" Vivado computed) and pass it to --set-realized
#     before building firmware.
#
# Usage:
#   python set_pl_freq.py <freq_mhz>                    # rewrite PL_FREQMHZ only
#   python set_pl_freq.py <freq_mhz> --set-realized <hz> --baud 57600
#       # ALSO rewrite the (shared) device trees using a realized clock YOU
#       # supply (read from Vivado/hardware, not computed by this script)
#
# Full retarget flow (from the repo root):
#   python boards/kv260/set_pl_freq.py 50                        # 1. edit PL_FREQMHZ
#   python boards/kv260/build_all.py --stage bit ...              # 2. re-synth (~40min)
#   #  read the ACTUAL realized PL0 clock from Vivado (see note above), then:
#   python boards/kv260/set_pl_freq.py 50 --set-realized 50000000 # 3. rewrite DTS
#   make fw-opensbi-hw fw-linux-hw                                 # 4. firmware <- new DT
# Then bring up with boards/kv260/vitis/bringup_jtag.tcl (J2 Pmod, baud).
#
# NOTE: no XDC edit is needed -- the timing constraint (and the OOC xdc) are
# auto-derived from PCW_FPGA0_PERIPHERAL_FREQMHZ, i.e. from PL_FREQMHZ below.
# NOTE: the device trees (DTS_LINUX/DTS_OPENSBI) are SHARED with the other
# board ports (Zybo, PYNQ-Z1/Z2) -- they encode whichever board's PL clock
# was last retargeted. Re-run this script for KV260 before rebuilding
# firmware if you were last working on a different board.
# =============================================================================

import argparse
import os
import re
import sys

REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

BUILD_TCL   = os.path.join(REPO, "boards", "kv260", "vivado", "build_kv260.tcl")
DTS_LINUX   = os.path.join(REPO, "tests", "linux", "rv_soc_linux_hw.dts")
DTS_OPENSBI = os.path.join(REPO, "docs", "opensbi", "rv_soc_hw.dts")
BRINGUP_TCL = os.path.join(REPO, "boards", "kv260", "vitis", "bringup_jtag.tcl")


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


def apply_freq(req_mhz, realized_hz, baud, dry_run=False):
    print("== retarget PL clock (KV260) ==")
    print("  request (PL_FREQMHZ)   : %g MHz" % req_mhz)
    if dry_run:
        print("== dry-run: no files edited ==")
        return
    print("== editing source files ==")

    # 1) build_kv260.tcl: the request drives the PS8 PL0 clock property.
    sub_in_file(BUILD_TCL,
                [(r"^set PL_FREQMHZ \d+", "set PL_FREQMHZ %d" % int(req_mhz))],
                "build_kv260.tcl")

    if realized_hz is None:
        print("== NOTE: --set-realized not given; device trees NOT edited. ==")
        print("   Read the ACTUAL realized PL0 clock from Vivado (see the")
        print("   confidence note at the top of this script), then re-run:")
        print("     python boards/kv260/set_pl_freq.py %g --set-realized <hz>" % req_mhz)
        return

    mhz_s = ("%.3f" % (realized_hz / 1e6)).rstrip("0").rstrip(".")
    bdiv, actual_baud, err = baud_divisor(realized_hz, baud)
    print("  realized FCLK (given)  : %s MHz  (%d Hz)" % (mhz_s, realized_hz))
    print("  baud %d               : divisor %d -> %d baud (%+.2f%%)"
          % (baud, bdiv, actual_baud, err))
    if abs(err) > 2.5:
        print("  WARNING: baud error %+.2f%% exceeds ~2.5%% 8N1 margin; pick a"
              " baud that divides %s MHz more cleanly." % (err, mhz_s))

    # 2) device trees: timebase + UART clock follow the realized FCLK you
    #    supplied; baud divisor is recomputed. NOTE: shared with other boards.
    dt_subs = [
        (r"(timebase-frequency = )<\d+>;[^\n]*",
         r"\g<1><%d>;  /* mtime = PL/MTIME_DIV = %s MHz/1 */" % (realized_hz, mhz_s)),
        (r"(clock-frequency = )<\d+>;[^\n]*",
         r"\g<1><%d>;  /* = PL clock; sets the 8250 divisor */" % realized_hz),
        (r"(current-speed = )<\d+>;[^\n]*",
         r"\g<1><%d>;  /* %se6/(16*%d)=%d, %+.2f%% */"
         % (baud, mhz_s, bdiv, actual_baud, err)),
    ]
    for path, lbl in ((DTS_LINUX, "rv_soc_linux_hw.dts"),
                      (DTS_OPENSBI, "rv_soc_hw.dts")):
        sub_in_file(path, dt_subs, lbl)

    # 3) bring-up script comments (best-effort; format may not match exactly
    #    since bringup_jtag.tcl for KV260 doesn't carry the same "FCLK_CLK0 =
    #    X MHz" comment pattern as Zybo/PYNQ -- edit manually if needed).
    sub_in_file(BRINGUP_TCL,
                [(r"FCLK_CLK0 = [\d.]+ MHz", "FCLK_CLK0 = %s MHz" % mhz_s)],
                "bringup_jtag.tcl (best-effort)")

    print("== next steps ==")
    print("  python boards/kv260/build_all.py --stage bit --vivado <vivado.bat>")
    print("  make fw-opensbi-hw fw-linux-hw")


def main():
    ap = argparse.ArgumentParser(description="Retarget the KV260 PL clock frequency.")
    ap.add_argument("freq_mhz", type=float,
                    help="target PL clock in MHz (e.g. 50) -- rewrites PL_FREQMHZ")
    ap.add_argument("--set-realized", type=float, default=None, metavar="HZ",
                    help="ALSO rewrite the shared device trees, using this realized "
                         "clock in Hz that YOU read from Vivado/hardware (this script "
                         "does not compute it -- see the confidence note above)")
    ap.add_argument("--baud", type=int, default=57600,
                    help="console baud for the DT current-speed (default 57600)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print what would change without editing files")
    args = ap.parse_args()

    apply_freq(args.freq_mhz, args.set_realized, args.baud, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
