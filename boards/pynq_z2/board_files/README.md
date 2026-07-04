# Vendored TUL PYNQ-Z2 board files

These board files (`pynq-z2/A.0/{board.xml,part0_pins.xml,preset.xml}`) are
vendored verbatim from a community-maintained board-files repository so the
scripted Vivado build is reproducible without polluting the Vivado
installation. PYNQ-Z2 is manufactured by TUL, not Digilent, so it is not in
Digilent's `vivado-boards` repo.

- Source: https://github.com/xupsh/pynq-supported-board-file (`pynq-z2/A.0`)
- `board.xml` vendor/name: `tul.com.tw` / `pynq-z2` (all lowercase, same
  convention as Zybo's `digilentinc.com`/`zybo-z7-20`).
  `build_pynq_z2.tcl` still does NOT hardcode the board_part VLNV string --
  it resolves it at run time with `get_board_parts -filter {NAME =~
  "*pynq-z2*"}` against this repo path, for consistency with `build_pynq_z1.tcl`
  and robustness against any board-file revision changes.
- They are referenced by `build_pynq_z2.tcl` via `set_property
  board_part_repo_paths` (NOT copied into the Vivado install).

`preset.xml` carries the full PS7 preset for the PYNQ-Z2 (DDR3, MIO map,
125 MHz board oscillator -> IO PLL). `apply_bd_automation ...
apply_board_preset 1` uses it so the Processing System matches the real board
(required for the PS to boot and for PS DDR to be usable over S_AXI_HP).

Same chip as Zybo Z7-20 (`xc7z020clg400-1`), so the RTL/BD/timing target are
unchanged -- only the board preset (DDR/MIO/clock realization) and pin
constraints (no Pmod JC on PYNQ; UART is wired to Pmod JB) differ.
