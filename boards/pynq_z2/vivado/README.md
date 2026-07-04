# PYNQ-Z2 Vivado スクリプト一覧

すべて **PowerShell + 絶対パス**で起動すること (Bash/MSYS だと synth がクラッシュ; CLAUDE.md 参照):

```powershell
& "E:\Tools\Xilinx\Vivado\2024.2\bin\vivado.bat" -mode batch `
    -source $PWD\boards\pynq_z2\vivado\<script>.tcl *> $PWD\boards\reports\<script>.log 2>&1
```

通常のビルドはスクリプト直叩きではなく `python boards/pynq_z2/build_all.py` (bit→fsbl→bootbin) を使う。
周波数変更は先に `python boards/pynq_z2/set_pl_freq.py <MHz>`。

Zybo Z7-20 / PYNQ-Z1 と**同一チップ** (`xc7z020clg400-1`) なので RTL/BD/タイミング目標は共通
(`docs/freq_50mhz.md` の 50MHz timing closure がそのまま適用できる想定)。差分はボードプリセット
(DDR/MIO/クロック実現値) と UART ピン (PYNQ に Pmod JC は無く JB を使用; PYNQ-Z1 と物理ピン番号は同一) のみ。

## ビルド系 (プロジェクト生成・impl・成果物)

| スクリプト | 役割 |
|---|---|
| `build_pynq_z2.tcl` | 本番ビルド本体。プロジェクト+BD (PS7+SmartConnect+S_AXI_HP) 生成から bitstream まで。ステージ引数 (`bd`/`synth`/`impl`/`bit`) で途中まで/再利用実行。timing summary を `boards/reports/` に出力 |
| `export_xsa.tcl` | ビルド済み impl_1 から XSA (ps7_init + bitstream) をエクスポート。FSBL/BOOT.bin 生成 (Vitis) への hand-off |
| `rv_soc_wrap.v` | Zybo/PYNQ-Z1 と共通 (ボード非依存、byte-identical コピー) |
| `pynq_z2_uart.xdc` | Pmod JB (JB1=W14 uart_tx, JB2=Y14 uart_rx) UART ピン制約 (PYNQ-Z1 と同一ピン) |

## board_part の解決について

`build_pynq_z2.tcl` も PYNQ-Z1 と同様に **board_part VLNV を直接ハードコードせず**、
`get_board_parts -filter {NAME =~ "*pynq-z2*"}` で実行時に解決している (vendored された
`board.xml` の vendor は `tul.com.tw` で Zybo と同じ全小文字規約だが、一貫性とボードファイル
改版への頑健性のため PYNQ-Z1 と同じ方式にしてある。詳細は `../board_files/README.md`)。
