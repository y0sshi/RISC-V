#!/usr/bin/env python3
# =============================================================================
# build_all.py - Cross-platform one-shot FPGA build orchestrator for the Zybo
#                Z7-20 RISC-V SoC.  Runs the Vivado + Vitis flow end to end:
#
#   bit     -> Vivado build_zybo.tcl : synth + impl + bitstream (+ XSA)   [~30-40 min]
#   xsa     -> Vivado export_xsa.tcl : emit XSA from an existing impl     [~10 s]
#   fsbl    -> Vitis  fsbl.py        : standalone platform + boot FSBL    [~3-5 min]
#   bootbin -> make_bootbin.py       : FSBL + bitstream + firmware -> BOOT.bin
# =============================================================================
# Works on Windows AND Linux: it drives the tools via subprocess (no Git-Bash/MSYS
# path translation, which is what crashes Vivado synth -- so this replaces the old
# PowerShell-only entry point).  Standard library only -- no venv / pip install.
#
# Usage (from anywhere; paths are derived from this script's location):
#   python boards/zybo_z720/build_all.py                          # all: bit -> fsbl -> bootbin
#   python boards/zybo_z720/build_all.py --stage xsa fsbl bootbin # reuse the existing impl
#   python boards/zybo_z720/build_all.py --stage bootbin --firmware <fw.bin>
#
# Vivado/Vitis are found via --vivado/--vitis, the XILINX_VIVADO / XILINX_VITIS env
# vars, or PATH (run the Xilinx settings64 first).
#
# The bash/docker side (firmware, sim, tests) is the top-level `make` instead.
# After this, bring up on the board with vitis/bringup_jtag.tcl (see vitis/README.md).
# =============================================================================
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent      # boards/zybo_z720
REPO = HERE.parents[1]                      # repo root
BDIR = HERE / "vivado"
VDIR = HERE / "vitis"


def resolve_tool(explicit, env_vars, exe):
    """Locate a Xilinx tool: explicit path, env var(s), then PATH (OS-aware: .bat on Windows)."""
    names = [exe + ".bat", exe] if os.name == "nt" else [exe]
    cands = []
    if explicit:
        cands.append(Path(explicit))
    for var in env_vars:
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
    sys.exit("Cannot find %s. Pass --%s <path>, set %s, or add the Xilinx bin to PATH (settings64)."
             % (exe, exe, " / ".join(env_vars)))


def run_stage(name, argv, log):
    print("==== [%s] start ====" % name, flush=True)
    # Stream the child's output through a pipe THIS process owns and write it to the
    # log ourselves, instead of handing Vivado/Vitis an inherited disk-file handle
    # for stdout.  Passing a disk-file handle down the EDA tool's process tree breaks
    # its spawned children intermittently on Windows (a child fails to read an
    # internal .tcl with "couldn't read file ...: No error"; adding a print before
    # the call merely shuffled fd allocation enough to dodge it).  stdin=DEVNULL so
    # batch tools never inherit / block on the console stdin.
    with open(log, "w", encoding="utf-8", errors="replace") as fh:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                cwd=str(REPO), text=True, bufsize=1)
        for line in proc.stdout:
            fh.write(line)
            fh.flush()
        rc = proc.wait()
    if rc != 0:
        sys.exit("[%s] failed (exit %d); see %s" % (name, rc, log))
    print("==== [%s] done ====" % name, flush=True)


def main():
    ap = argparse.ArgumentParser(description="One-shot FPGA build for the Zybo Z7-20 RISC-V SoC.")
    ap.add_argument("--stage", nargs="+", default=["all"],
                    choices=["all", "bit", "xsa", "fsbl", "bootbin"])
    ap.add_argument("--firmware", help="firmware .bin for the bootbin stage (default: real-HW OpenSBI)")
    ap.add_argument("--vivado", help="path to vivado(.bat); else env/PATH")
    ap.add_argument("--vitis", help="path to vitis(.bat); else env/PATH")
    args = ap.parse_args()

    # Vivado/Vitis child processes break under an MSYS/Git-Bash environment (paths
    # turn into "couldn't read file ... : No error").  On Windows, demand a native
    # shell (PowerShell or cmd) -- this is NOT solved by invoking via Python.
    if os.name == "nt" and os.environ.get("MSYSTEM"):
        sys.exit("Refusing to run under MSYS/Git-Bash (MSYSTEM=%s): the Xilinx tools' child\n"
                 "processes fail there (\"couldn't read file ... : No error\").  Run this from\n"
                 "PowerShell or cmd instead." % os.environ["MSYSTEM"])

    stages = ["bit", "fsbl", "bootbin"] if "all" in args.stage else list(args.stage)
    firmware = args.firmware or str(REPO / "tests/opensbi/work/fw_payload_hw.bin")

    vivado = vitis = None
    if any(s in stages for s in ("bit", "xsa")):
        vivado = resolve_tool(args.vivado, ["VIVADO_BIN", "XILINX_VIVADO"], "vivado")
    if "fsbl" in stages:
        vitis = resolve_tool(args.vitis, ["VITIS_BIN", "XILINX_VITIS"], "vitis")

    for s in stages:
        if s == "bit":
            run_stage("bit", [vivado, "-mode", "batch",
                              "-source", str(BDIR / "build_zybo.tcl"), "-tclargs", "bit"],
                      BDIR / "build_zybo.log")
        elif s == "xsa":
            run_stage("xsa", [vivado, "-mode", "batch", "-source", str(BDIR / "export_xsa.tcl")],
                      BDIR / "export_xsa.log")
        elif s == "fsbl":
            run_stage("fsbl", [vitis, "-s", str(VDIR / "fsbl.py")], VDIR / "fsbl.log")
        elif s == "bootbin":
            run_stage("bootbin", [sys.executable, str(VDIR / "make_bootbin.py"),
                                  "--firmware", firmware], VDIR / "bootgen.log")

    print("ALL STAGES OK. Next: board bring-up via vitis/bringup_jtag.tcl (57600 8N1 on Pmod JC).")


if __name__ == "__main__":
    main()
