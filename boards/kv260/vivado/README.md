# KV260 Vivado スクリプト一覧

すべて **PowerShell + 絶対パス**で起動すること (Bash/MSYS だと synth がクラッシュ; CLAUDE.md 参照):

```powershell
& "E:\Tools\Xilinx\Vivado\2024.2\bin\vivado.bat" -mode batch `
    -source $PWD\boards\kv260\vivado\<script>.tcl *> $PWD\boards\reports\<script>.log 2>&1
```

通常のビルドはスクリプト直叩きではなく `python boards/kv260/build_all.py` (bit→fsbl→bootbin) を使う。
周波数変更は先に `python boards/kv260/set_pl_freq.py <MHz>`。

## Zybo/PYNQ (Zynq-7000) との違い

KV260 は K26 SOM (**Zynq UltraScale+ PS8**, `xck26-sfvc784-2LV-c`) を Vision AI Starter Kit
キャリアカードに載せた構成で、Zybo/PYNQ の Zynq-7000 PS7 とは別アーキテクチャ。RTL (`rv_soc` 以下) と
ビルドスクリプトの段階分離構造 (project/synth/impl/bit) は共通だが、以下は PS8 固有:

| 項目 | Zybo/PYNQ (PS7) | KV260 (PS8) |
|---|---|---|
| board_part | 自前 vendoring 必須 | **Vivado 2024.2 インストールに同梱済み** (`xilinx.com:kv260_som:part0:1.4`)。vendoring 不要 |
| DDR | DDR3 (Zybo/PYNQ 共に SOM 上) | DDR4 (K26 SOM 上) |
| PS master AXI | `zynq_ultra_ps_e` の `S_AXI_HP0_FPD` | 同系だがポート名/CONFIG キーが異なる (`PSU__SAXIGP2__DATA_WIDTH` 等) |
| PL クロック生成 | IO PLL / 整数分周 (`FCLK_REG` で読み戻し可) | PS8 の CRL_APB PLL 群 (Zybo/PYNQ の分周計算式は流用不可。`../set_pl_freq.py` 参照) |
| ブート | JTAG のみで `ps7_init` 一発 (FSBL 不要) | **JTAG でも FSBL+PMUFW の実行が必要** (`../vitis/README.md` 参照、Zybo より重い) |

## board_part の検証 (2026-07-04 実施)

`set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]` の後、
`apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"}`
のみ (kv260_carrier の board_connections 無し) で **DDR4 64bit 構成が CRITICAL WARNING 無しで適用される**
ことを実機無し (BD 生成のみ、非 synth) で確認済み。UART は Vivado のボードインターフェース自動配線を
使わず Zybo/PYNQ と同じ手動 XDC 方式にしているため、carrier 側の board_part/board_connections は不要
と判断した。

実際に `build_kv260.tcl -tclargs project` を実行 (exit code 0) して以下も確認済み:
- **想定内の無害な WARNING 2件** (PS8 特有、Zybo/PYNQ の DQS skew 警告に相当):
  `WARNING: [BD 41-237] Bus Interface property AWUSER_WIDTH/ARUSER_WIDTH does not match
  between /zynq_ps/S_AXI_HP0_FPD(1) and /axi_smc/M00_AXI(0)` — ZynqMP の HP ポートが持つ
  coherency 用 USER サイドバンド信号 (幅1) を SmartConnect 側が持たないことによる幅不一致警告。
  ACP/コヒーレントポートを使わない本設計では実害無し (Vivado が自動でゼロ埋め/切り詰め処理)。
- `validate_bd_design` まで CRITICAL WARNING 無し、ERROR 無し、`INFO: project ready` に到達。

## ビルド系 (プロジェクト生成・impl・成果物)

| スクリプト | 役割 |
|---|---|
| `build_kv260.tcl` | 本番ビルド本体。プロジェクト+BD (PS8+SmartConnect+S_AXI_HP0_FPD) 生成から bitstream まで。ステージ引数 (`bd`/`synth`/`impl`/`bit`) で途中まで/再利用実行。timing summary を `boards/reports/` に出力 |
| `export_xsa.tcl` | ビルド済み impl_1 から XSA (psu_init + bitstream) をエクスポート。FSBL+PMUFW/BOOT.bin 生成 (Vitis) への hand-off |
| `rv_soc_wrap.v` | Zybo/PYNQ と共通 (ボード非依存、byte-identical コピー) |
| `kv260_uart.xdc` | J2 Pmod 互換ヘッダ (E12=uart_tx, D11=uart_rx) UART ピン制約。**ピン出所の確度についての注記あり、実配線前に要確認 (ファイル内コメント参照)** |
