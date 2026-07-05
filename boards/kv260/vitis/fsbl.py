#!/usr/bin/env python3
# =============================================================================
# fsbl.py - Build the Zynq UltraScale+ First-Stage Boot Loader (FSBL) + PMU
#           firmware (PMUFW) for the KV260 RISC-V SoC platform, from the
#           exported XSA (prep-B).
# =============================================================================
# Vitis 2024.2 dropped the classic XSCT project flow; the supported path is
# the Python client (vitis -s <script>). This script creates a standalone
# platform from the XSA on psu_cortexa53_0 and builds it.
#
# ---- Confidence note (KV260-specific, read before relying on this) ----
# On Zynq-7000 (Zybo/PYNQ), creating a standalone platform on ps7_cortexa9_0
# auto-generates ONLY the FSBL as a boot component -- no other firmware is
# needed to bring up the PS via JTAG (see boards/zybo_z720/vitis/fsbl.py).
# Zynq UltraScale+ (KV260) is different: JTAG bring-up needs BOTH an FSBL
# (running on the APU, Cortex-A53) AND a PMU firmware image (PMUFW, running on
# the separate MicroBlaze-based Platform Management Unit) -- see
# ../README.md for why. Creating a standalone platform for psu_cortexa53_0
# DOES auto-generate both as platform boot components -- CONFIRMED against a
# real Vitis 2024.2 run (2026-07-04). The one surprise: pmufw.elf does NOT
# land under sw/boot/ alongside fsbl.elf as originally expected -- it lands
# under sw/qemu/ instead (not a QEMU-only artifact despite the directory
# name; it is the real PMUFW for this platform). bringup_jtag.tcl already
# points at sw/qemu/pmufw.elf accordingly.
#
# Run in BATCH from PowerShell, NOT Bash/MSYS (its path translation breaks the
# Xilinx tools). From the repo root (tool via $env:XILINX_VITIS or PATH):
#   & "$env:XILINX_VITIS\bin\vitis.bat" -s `
#       $PWD\boards\kv260\vitis\fsbl.py `
#       *> $PWD\boards\kv260\vitis\fsbl.log 2>&1
#
# Output ELFs (workspace is gitignored):
#   boards/kv260/vitis/ws/kv260_plat/export/kv260_plat/sw/boot/fsbl.elf
#   boards/kv260/vitis/ws/kv260_plat/export/kv260_plat/sw/qemu/pmufw.elf
# =============================================================================
import os
import shutil
from pathlib import Path
import vitis

# Repo root derived from this script (boards/kv260/vitis/fsbl.py -> 3 levels up).
# Fall back to the cwd (build_all.py runs vitis with cwd = repo root) if __file__
# is unavailable under the vitis interpreter.
try:
    REPO = Path(__file__).resolve().parents[3].as_posix()
except NameError:
    REPO = Path.cwd().as_posix()
XSA  = REPO + "/boards/kv260/vivado/rv_riscv_kv260/rv_riscv_kv260.xsa"
WS   = REPO + "/boards/kv260/vitis/ws"

PLATFORM = "kv260_plat"
DOMAIN   = "standalone_domain"

if not os.path.isfile(XSA):
    raise SystemExit("XSA not found: %s (run export_xsa.tcl first)" % XSA)

# Fresh workspace so re-runs are deterministic.
if os.path.isdir(WS):
    shutil.rmtree(WS, ignore_errors=True)
os.makedirs(WS, exist_ok=True)

client = vitis.create_client()
client.set_workspace(WS)

# ---- Standalone platform from the fixed XSA (carries psu_init + bitstream) ----
platform = client.create_platform_component(
    name        = PLATFORM,
    hw_design   = XSA,
    cpu         = "psu_cortexa53_0",
    os          = "standalone",
    domain_name = DOMAIN,
)
# Building the standalone platform is EXPECTED to also emit the boot FSBL +
# PMUFW under <ws>/kv260_plat/export/kv260_plat/sw/boot/ -- see the
# confidence note above if pmufw.elf does not appear.
platform.build()

print("INFO: Platform build complete. Boot ELF locations:")
for root, _dirs, files in os.walk(WS):
    for f in files:
        if f in ("fsbl.elf", "pmufw.elf"):
            print("  %s: %s" % (f, os.path.join(root, f)))

vitis.dispose()

# CONFIRMED (2026-07-04, real Vitis 2024.2 run): platform.build() DOES
# auto-generate both. fsbl.elf lands under sw/boot/ as expected, but
# pmufw.elf lands under sw/qemu/ instead of sw/boot/ (not the QEMU-only
# artifact the directory name suggests -- it is the real PMUFW for this
# platform). bringup_jtag.tcl points at sw/qemu/pmufw.elf accordingly.
