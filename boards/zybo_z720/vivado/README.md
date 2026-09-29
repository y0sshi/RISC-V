# Zybo Z7-20 Vivado スクリプト一覧

すべて **PowerShell + 絶対パス**で起動すること (Bash/MSYS だと synth がクラッシュ; CLAUDE.md 参照):

```powershell
& "E:\Tools\Xilinx\Vivado\2024.2\bin\vivado.bat" -mode batch `
    -source $PWD\boards\zybo_z720\vivado\<script>.tcl *> $PWD\boards\reports\<script>.log 2>&1
```

通常のビルドはスクリプト直叩きではなく `python boards/zybo_z720/build_all.py` (bit→fsbl→bootbin) を使う。
周波数変更は先に `python boards/zybo_z720/set_pl_freq.py <MHz>`。

## ビルド系 (プロジェクト生成・impl・成果物)

| スクリプト | 役割 |
|---|---|
| `build_zybo.tcl` | 本番ビルド本体。プロジェクト+BD (PS7+SmartConnect+S_AXI_HP) 生成から bitstream まで。ステージ引数 (`bd`/`synth`/`impl`/`bit`) で途中まで/再利用実行。timing summary を `boards/reports/` に出力 |
| `export_xsa.tcl` | ビルド済み impl_1 から XSA (ps7_init + bitstream) をエクスポート。FSBL/BOOT.bin 生成 (Vitis) への hand-off |
| `rv_soc_wrap.v` / `zybo_uart.xdc` | BD 取込み用ラッパ / Pmod JC UART ピン制約 |

## タイミング調査系 (probe; bitstream を作らない)

| スクリプト | 役割 |
|---|---|
| `build_physopt.tcl <period_ns> <def\|aggr>` | 既存 synth_1 checkpoint を open_checkpoint し、指定周期の手動 create_clock で place/phys_opt/route のみ再実行 (~20-25分)。**達成不能なタイト制約を張って真の Fmax / binding path を観測する**軽量 probe (50MHz キャンペーンの主計測手段; `docs/freq_50mhz.md` §18) |
| `report_paths.tcl` | ルーティング済み impl_1 の worst setup path 上位 40 本 (unique endpoints) をレポート。再ビルド不要 |
| `report_worst.tcl` | routed checkpoint の worst path を full_clock_expanded で標準出力にダンプ (即席確認用) |

## レポート単体再生成

| スクリプト | 役割 |
|---|---|
| `report_util_only.tcl` | ビルド済み impl_1 を開いて utilization レポート (`boards/reports/build_zybo_util{,_hier}.rpt`) だけを再生成。build_zybo.tcl を再実行せずに利用率を確認したいときに使う恒久ユーティリティ |
