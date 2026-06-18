#!/usr/bin/env python3
# =============================================================================
# fsbl.py - Build the Zynq-7000 First-Stage Boot Loader (FSBL) for the Zybo
#           Z7-20 RISC-V SoC platform, from the exported XSA (prep-B).
# =============================================================================
# Vitis 2024.2 dropped the classic XSCT project flow ("-classic option is only
# supported by full Vitis installation"); the supported path is the Python client
# (vitis -s <script>).  This script creates a standalone platform from the XSA on
# ps7_cortexa9_0 and builds it.  Creating a Zynq-7000 standalone platform AUTO-
# GENERATES the boot FSBL (ps7_init + main/sd/qspi/image_mover) as a boot
# component -- no separate "Zynq FSBL" app is needed (and the stock app template
# fails here anyway because the platform BSP omits xilffs/xilrsa).
#
# Run in BATCH from PowerShell, NOT Bash/MSYS (its path translation breaks the
# Xilinx tools).  From the repo root (tool via $env:XILINX_VITIS or PATH):
#   & "$env:XILINX_VITIS\bin\vitis.bat" -s `
#       $PWD\boards\zybo_z720\vitis\fsbl.py `
#       *> $PWD\boards\zybo_z720\vitis\fsbl.log 2>&1
#
# Output FSBL ELF (workspace is gitignored):
#   boards/zybo_z720/vitis/ws/zybo_plat/export/zybo_plat/sw/boot/fsbl.elf
# =============================================================================
import os
import shutil
from pathlib import Path
import vitis

# Repo root derived from this script (boards/zybo_z720/vitis/fsbl.py -> 3 levels up).
# Fall back to the cwd (build_all.py runs vitis with cwd = repo root) if __file__
# is unavailable under the vitis interpreter.
try:
    REPO = Path(__file__).resolve().parents[3].as_posix()
except NameError:
    REPO = Path.cwd().as_posix()
XSA  = REPO + "/boards/zybo_z720/vivado/rv_riscv_zybo/rv_riscv_zybo.xsa"
WS   = REPO + "/boards/zybo_z720/vitis/ws"

PLATFORM = "zybo_plat"
DOMAIN   = "standalone_domain"

if not os.path.isfile(XSA):
    raise SystemExit("XSA not found: %s (run export_xsa.tcl first)" % XSA)

# Fresh workspace so re-runs are deterministic.
if os.path.isdir(WS):
    shutil.rmtree(WS, ignore_errors=True)
os.makedirs(WS, exist_ok=True)

client = vitis.create_client()
client.set_workspace(WS)

# ---- Standalone platform from the fixed XSA (carries ps7_init + bitstream) ----
platform = client.create_platform_component(
    name        = PLATFORM,
    hw_design   = XSA,
    cpu         = "ps7_cortexa9_0",
    os          = "standalone",
    domain_name = DOMAIN,
)
# Building the standalone platform also emits the boot FSBL under
# <ws>/zybo_plat/export/zybo_plat/sw/boot/fsbl.elf.
platform.build()

print("INFO: Platform + boot FSBL build complete. fsbl.elf locations:")
for root, _dirs, files in os.walk(WS):
    for f in files:
        if f == "fsbl.elf":
            print("  FSBL ELF: " + os.path.join(root, f))

vitis.dispose()
