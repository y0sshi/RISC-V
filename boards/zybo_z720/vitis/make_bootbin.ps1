# =============================================================================
# make_bootbin.ps1 - Assemble a Zynq-7000 BOOT.bin for the Zybo Z7-20 RISC-V SoC
#                    from the FSBL (prep-C), the implemented bitstream, and the
#                    RISC-V firmware .bin (re-linked to 0x0020_0000).
# =============================================================================
# Run from PowerShell:
#   .\make_bootbin.ps1                              # OpenSBI hello (default)
#   .\make_bootbin.ps1 -Firmware <path-to-fw.bin>  # any 0x200000-linked .bin
#
# Partition order (firmware BEFORE bitstream) is fixed in the generated .bif so the
# firmware is resident in DDR before PL config releases the RISC-V core.  See
# boot.bif for the rationale.
#
# NOTE: for a REAL boot the firmware must be rebuilt with the real-HW device tree
# (DTS=docs/opensbi/rv_soc_hw.dts: 25 MHz clocks / 57600 baud, see prep-A/E).  The
# default below points at the sim-DTS fw_payload_lo.bin, which is fine for
# validating the bootgen flow but will mis-clock the UART on hardware.
# =============================================================================
param(
    [string]$Firmware = "E:\work\git\RISC-V.git\tests\opensbi\work\fw_payload_lo.bin",
    [string]$Out      = "E:\work\git\RISC-V.git\boards\zybo_z720\vitis\BOOT.bin"
)

$ErrorActionPreference = "Stop"
$repo   = "E:\work\git\RISC-V.git"
$here   = Join-Path $repo "boards\zybo_z720\vitis"
$fsbl   = Join-Path $here "ws\zybo_plat\export\zybo_plat\sw\boot\fsbl.elf"
$bit    = Join-Path $repo "boards\zybo_z720\vivado\rv_riscv_zybo\rv_riscv_zybo.runs\impl_1\bd_riscv_wrapper.bit"
$bootgen= "E:\Tools\Xilinx\Vitis\2024.2\bin\bootgen.bat"

foreach ($f in @($fsbl, $bit, $Firmware, $bootgen)) {
    if (-not (Test-Path $f)) { throw "missing input: $f" }
}

# Generate a concrete .bif with resolved absolute paths (firmware BEFORE bitstream).
$gen = Join-Path $here "boot.gen.bif"
@"
the_ROM_image:
{
    [bootloader] $fsbl
    [load=0x00200000] $Firmware
    $bit
}
"@ | Set-Content -Encoding ascii $gen

Write-Host "FSBL     : $fsbl"
Write-Host "Firmware : $Firmware"
Write-Host "Bitstream: $bit"
Write-Host "BIF      : $gen"

& $bootgen -arch zynq -image $gen -o $Out -w on
if ($LASTEXITCODE -ne 0) { throw "bootgen failed ($LASTEXITCODE)" }
Write-Host "OK: wrote $Out ($((Get-Item $Out).Length) bytes)"
