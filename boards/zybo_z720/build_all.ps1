# =============================================================================
# build_all.ps1 - One-shot FPGA build orchestrator for the Zybo Z7-20 RISC-V SoC.
# =============================================================================
# Runs the PowerShell-only flow (Vivado + Vitis MUST run from PowerShell; Bash/MSYS
# path translation crashes synth) end to end:
#
#   bit     -> Vivado build_zybo.tcl: synth + impl + bitstream (+ XSA)   [~30-40 min]
#   xsa     -> Vivado export_xsa.tcl: emit XSA from an existing impl     [~10 s]
#   fsbl    -> Vitis  fsbl.py:        standalone platform + boot FSBL    [~3-5 min]
#   bootbin -> make_bootbin.ps1:      FSBL + bitstream + firmware -> BOOT.bin
#
# Usage (from PowerShell):
#   .\build_all.ps1                         # all: bit -> fsbl -> bootbin (bit emits XSA)
#   .\build_all.ps1 -Stage xsa,fsbl,bootbin # reuse the existing impl (skip the long bit)
#   .\build_all.ps1 -Stage bootbin -Firmware <path-to-fw.bin>
#
# Vivado/Vitis are found via PATH (run the Xilinx settings64.bat first) or the
# XILINX_VIVADO/XILINX_VITIS env vars; override with -Vivado <vivado.bat> / -Vitis <vitis.bat>.
#
# The bash/docker side (firmware, sim, tests) is the top-level `make` instead.
# After this, bring up on the board with vitis/bringup_jtag.tcl (see vitis/README.md).
# =============================================================================
param(
    [ValidateSet("all","bit","xsa","fsbl","bootbin")]
    [string[]]$Stage = @("all"),
    [string]$Firmware,
    [string]$Vivado,
    [string]$Vitis
)

$ErrorActionPreference = "Stop"

# Paths are derived from this script's location -- no machine-specific absolutes in git.
# Script lives in boards/zybo_z720/, so the repo root is two levels up.
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if (-not $Firmware) { $Firmware = Join-Path $repo "tests\opensbi\work\fw_payload_hw.bin" }

# Locate a Xilinx tool: explicit param, then env var (VIVADO_BIN / XILINX_VIVADO etc.),
# then PATH.  Add the Xilinx bin to PATH (run settings64.bat) or pass -Vivado/-Vitis.
function Resolve-Tool([string]$Explicit, [string[]]$EnvVars, [string]$Exe) {
    $cands = @()
    if ($Explicit) { $cands += $Explicit }
    foreach ($v in $EnvVars) {
        $val = [Environment]::GetEnvironmentVariable($v)
        if ($val) { $cands += $val; $cands += (Join-Path $val "bin\$Exe") }
    }
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path } }
    $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "Cannot find $Exe. Pass it explicitly, set one of $($EnvVars -join '/'), or add the Xilinx bin to PATH (settings64.bat)."
}
$vivado = Resolve-Tool $Vivado @("VIVADO_BIN","XILINX_VIVADO") "vivado.bat"
$vitis  = Resolve-Tool $Vitis  @("VITIS_BIN","XILINX_VITIS")   "vitis.bat"
$bdir   = Join-Path $repo "boards\zybo_z720\vivado"
$vdir   = Join-Path $repo "boards\zybo_z720\vitis"

if ($Stage -contains "all") { $Stage = @("bit","fsbl","bootbin") }

function Invoke-Stage([string]$name, [scriptblock]$body) {
    Write-Host "==== [$name] start ====" -ForegroundColor Cyan
    & $body
    if ($LASTEXITCODE -ne 0) { throw "[$name] failed (exit $LASTEXITCODE)" }
    Write-Host "==== [$name] done ====" -ForegroundColor Green
}

foreach ($s in $Stage) {
    switch ($s) {
        "bit" { Invoke-Stage "bit" {
            & $vivado -mode batch -source (Join-Path $bdir "build_zybo.tcl") -tclargs bit `
                *> (Join-Path $bdir "build_zybo.log") 2>&1
        } }
        "xsa" { Invoke-Stage "xsa" {
            & $vivado -mode batch -source (Join-Path $bdir "export_xsa.tcl") `
                *> (Join-Path $bdir "export_xsa.log") 2>&1
        } }
        "fsbl" { Invoke-Stage "fsbl" {
            & $vitis -s (Join-Path $vdir "fsbl.py") *> (Join-Path $vdir "fsbl.log") 2>&1
        } }
        "bootbin" { Invoke-Stage "bootbin" {
            & (Join-Path $vdir "make_bootbin.ps1") -Firmware $Firmware `
                *> (Join-Path $vdir "bootgen.log") 2>&1
        } }
    }
}

Write-Host "ALL STAGES OK. Next: board bring-up via vitis\bringup_jtag.tcl (57600 8N1 on Pmod JC)." -ForegroundColor Green
