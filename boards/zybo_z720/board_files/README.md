# Vendored Digilent Zybo Z7-20 board files

These board files (`zybo-z7-20/A.0/{board.xml,part0_pins.xml,preset.xml}`) are
vendored verbatim from Digilent's public board-files repository so the scripted
Vivado build is reproducible without polluting the Vivado installation.

- Source: https://github.com/Digilent/vivado-boards (`new/board_files/zybo-z7-20/A.0`)
- Board part VLNV: `digilentinc.com:zybo-z7-20:part0:1.2`
- They are referenced by `build_zybo.tcl` via `set_property board_part_repo_paths`
  (NOT copied into the Vivado install).

`preset.xml` carries the full PS7 preset for the Zybo Z7-20 (DDR3 MT41K256M16
RE-125, MIO map, clocks). `apply_bd_automation ... apply_board_preset 1` uses it
so the Processing System matches the real board (required for the PS to boot and
for PS DDR to be usable over S_AXI_HP).
