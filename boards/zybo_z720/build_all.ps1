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
# The bash/docker side (firmware, sim, tests) is the top-level `make` instead.
# After this, bring up on the board with vitis/bringup_jtag.tcl (see vitis/README.md).
# =============================================================================
param(
    [ValidateSet("all","bit","xsa","fsbl","bootbin")]
    [string[]]$Stage = @("all"),
    [string]$Firmware = "E:\work\git\RISC-V.git\tests\opensbi\work\fw_payload_hw.bin"
)

$ErrorActionPreference = "Stop"
$repo   = "E:\work\git\RISC-V.git"
$vivado = "E:\Tools\Xilinx\Vivado\2024.2\bin\vivado.bat"
$vitis  = "E:\Tools\Xilinx\Vitis\2024.2\bin\vitis.bat"
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
