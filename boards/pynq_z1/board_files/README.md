# Vendored Digilent PYNQ-Z1 board files

These board files (`pynq-z1/1.0/{board.xml,part0_pins.xml,preset.xml}`) are
vendored verbatim from a community-maintained board-files repository so the
scripted Vivado build is reproducible without polluting the Vivado
installation. Digilent's own `vivado-boards` repo does not carry PYNQ-Z1 (it
predates that repo's board list), so this uses the source PYNQ itself points
users to.

- Source: https://github.com/xupsh/pynq-supported-board-file (`pynq-z1/1.0`),
  mirrored from https://github.com/cathalmccabe/pynq-z1_board_files
- `board.xml` vendor/name: `www.digilentinc.com` / `PYNQ-Z1` (note the mixed
  case and `www.` prefix -- this is the historical PYNQ-Z1 board file, unlike
  the newer all-lowercase `digilentinc.com` convention used for Zybo).
  `build_pynq_z1.tcl` does NOT hardcode the board_part VLNV string for this
  reason -- it resolves it at run time with `get_board_parts -filter {NAME =~
  "*pynq-z1*"}` against this repo path, so the exact case is irrelevant.
- They are referenced by `build_pynq_z1.tcl` via `set_property
  board_part_repo_paths` (NOT copied into the Vivado install).

`preset.xml` carries the full PS7 preset for the PYNQ-Z1 (DDR3, MIO map,
125 MHz board oscillator -> IO PLL). `apply_bd_automation ...
apply_board_preset 1` uses it so the Processing System matches the real board
(required for the PS to boot and for PS DDR to be usable over S_AXI_HP).

Same chip as Zybo Z7-20 (`xc7z020clg400-1`), so the RTL/BD/timing target are
unchanged -- only the board preset (DDR/MIO/clock realization) and pin
constraints (no Pmod JC on PYNQ; UART is wired to Pmod JB) differ.
