# RISC-V コア 開発ロードマップ

最終更新: 2026-07-03

自作 RV64GC 5段パイプラインコア (educational) の到達点と今後の計画。
ISA/テスト詳細は `CLAUDE.md`、RTL バグ史 (#1〜#18) は `docs/rtl_bug_history.md` を参照。

---

## 現状サマリ

**実機 Zybo Z7-20 (50 MHz) で OpenSBI v1.2 フルブート + Linux 6.12 + Buildroot RootFS が
bash シェル到達 (`ROOTFS-BASH-OK`) を達成** (2026-07-03、sim/実機とも)。
- compliance RV64 117/117・RV32 88/88、全ユニットテスト PASS。RTL バグ #1〜#18 修正済み。
- RV64GC + Zicsr + S-mode + Sv39 + トラップ委譲 + CLINT/UART(8250)/PLIC/GPIO。
- DDR over AXI (2 マスタ) + I/D キャッシュ、Verilator 高速 sim、JTAG bring-up。
- FPGA timing met @50 MHz (WNS=+0.313ns, Failing Endpoints 0/74618。LUT 64.6%・DSP 26.8%)。

---

## 達成済みフェーズ

| フェーズ | 内容 | 状態 |
|---|---|---|
| **0. CPU/MMU/ISA 基盤** | 5段パイプライン、I/M/A/F/D/C/Zicsr、M/S-mode、Sv32/Sv39、トラップ/割込優先度 | ✅ |
| **1. SoC 統合・ボード雛形** | CLINT/UART/PLIC/GPIO、`rv_soc`/`rv_soc_bram`/`rv_soc_act`、Zybo/KV260 トップ | ✅ |
| **2. メモリ拡張・キャッシュ** | BRAM → PS DDR over AXI4 (命令+データ/PTW 2マスタ)、I$/D$ + burst bridge | ✅ |
| **3. OpenSBI v1.2 フルブート** | 共有 DDR + fw_payload、16550 互換 UART、M→S、sim + **実機**で banner+payload | ✅ |
| **4. Linux 6.12 → userspace** | earlycon=sbi → ttyS0 切替 → PID1 → `LINUX-USERSPACE-OK`、sim + **実機** | ✅ |
| **5. FPGA timing 収束・実機 bring-up** | muldiv 多サイクル化・cache BRAM 化・FPU パイプライン化・JTAG bring-up | ✅ |
| **① atomic 整合性バグ修正 (NET=y)** | 真因=`rv_soc` の IF-PTW が D$ wait を隠し AMO 書込喪失。修正+実機 4連続 userspace 到達 (2026-06-19) | ✅ |
| **② 動作周波数 25→50MHz** | step1〜11 (decoupled fetch/FTQ block fetch・muldiv/FPU 段化・load→branch interlock)。実機 50MHz timing met | ✅ |
| **③ RootFS (Buildroot bash)** | musl 静的 rootfs を initramfs 埋込 (`ROOTFS=buildroot`)。途中 #17 (fetch/PTW livelock)・#18 (faulting load の garbage retire) を根治し **sim+実機で `ROOTFS-BASH-OK`** (2026-07-03) | ✅ |

②③ の過程で RTL バグ #14〜#18 を発見・根治 (各 bare repro `src/software/boot/*_test.S` で回帰固定)。
詳細は `docs/rtl_bug_history.md`・`docs/freq_50mhz.md`。

---

## 今後のロードマップ (優先度順)

旧①②③ (atomic 修正・周波数・RootFS) は完了。残りは独立項目で、いつでも着手可能。

| # | 項目 | 種別 | 工数 | リスク | 依存 |
|---|---|---|---|---|---|
| ④ | 他ボード対応 (PYNQ-Z1/Z2・KV260) | 横展開 | 小〜中 | 低 | 独立 |
| ⑤ | Vector (RVV) 拡張 | 新機能 | 大 | 中 | 独立 |
| ⑥ | RootFS の発展 (永続ストレージ / より大きな userspace) | 発展 | 中〜大 | 中 | ③ (済) |

### ④ 他ボード対応 (横展開・低リスク)

- **PYNQ-Z1 / PYNQ-Z2 = Zynq-7000 で Zybo Z7-20 とほぼ同系**。RTL 不変、XDC ピン + ボードプリセット +
  DDR/クロックのみ。小工数の確実な勝ち。
  - **✅ スクリプト整備完了 (2026-07-04)**: `boards/pynq_z1/` `boards/pynq_z2/` に Zybo と同型の
    ビルド一式 (`build_all.py`/`set_pl_freq.py`/`vivado/build_pynq_z{1,2}.tcl`/`vitis/*`) を新設。
    board_files は `pynq-z1/1.0` (vendor `www.digilentinc.com`, 大文字混在の旧規約) /
    `pynq-z2/A.0` (vendor `tul.com.tw`) をコミュニティ配布元から vendoring (詳細は各
    `board_files/README.md`)。board_part VLNV はハードコードせず `get_board_parts -filter` で
    実行時解決 (旧規約の casing に非依存)。UART は Pmod JC が無いため **Pmod JB (JB1=W14
    uart_tx, JB2=Y14 uart_rx, 両ボード共通)** に配線。`vivado.bat -tclargs project` (BD 生成のみ、
    非synth) を両ボードで実行し board_part 解決 + BD 生成が無エラーで通ることを確認済み
    (`www.digilentinc.com:pynq-z1:part0:1.0` / `tul.com.tw:pynq-z2:part0:1.0` に解決)。
    同一チップ (`xc7z020clg400-1`) のため 50MHz timing closure は Zybo の結果がそのまま適用できる
    想定 (再計測不要)。**残作業 = 実機での bitstream 合成 (`build_all.py`) + JTAG bring-up
    (`vitis/bringup_jtag.tcl`) + `ROOTFS-BASH-OK` 到達確認** (実機所有者が実施)。
- **KV260 = Zynq UltraScale+ (PS8/A53/DDR4)**。PS 初期化・FSBL・SmartConnect が別物で中工数。

### ⑤ Vector (RVV) 拡張 (新機能)

ベクタレジスタファイル・レーン演算・`vsetvl` 等の大規模 RTL 追加。Linux には不要 (RVV はオプション)。
着手時は `rv_core.sv` の EX/regfile 周辺の surgical な分割を併せて検討 (下記リファクタリング方針)。

### ⑥ RootFS の発展

現状 = Buildroot musl 静的 (bash+busybox) を initramfs として Image に埋込。次の段階:
1. **initramfs の拡充** (coreutils/テストプログラム追加) — 新ペリフェラル不要。
2. **永続ストレージ** — PL に SD/SPI コントローラ IP、または PS-PL 共有メモリ経由の virtio-block
   (A9 をバックエンド) → 本物のディストリビューション RootFS (Debian/Ubuntu base)。
3. DDR マッピング拡張 (現状 64MB → 実機 1GB) は 2. と併せて。

### (リスト外) SMP / マルチハート

現状 LR/SC にコヒーレンシ無し → キャッシュコヒーレンシ機構が必要な超大型項目。
プラットフォーム安定後 (④⑤ より先送り) の検討対象。

---

## 解決済みの実機バグ (アーカイブ)

| バグ | 状態 | 対応 |
|---|---|---|
| **I$ straddle** (redirect 先 straddle の squash race / 実 S_AXI_HP 非アライン AXI) | ✅ 解決 (2026-06-18) | rv_icache 2-line 化 + S_BYPASS 全廃 (commit fd382da)。sim + 実機検証済 |
| **netlink/atomic ハング** (`nl_table_users` 1 固着 = AMO 書込喪失) | ✅ 解決 (2026-06-19) | 真因=`rv_soc.sv` IF-PTW が D$ wait を隠蔽。`ptw_for_if` ゲートで修正、実機 NET=y 4連続 userspace 到達。repro=`ptw_amo_test.S` |
| **step8 fetch skid** (FTQ head 先行 pop → 4 バイト skid → NULL deref) | ✅ 解決 (2026-06-30) | `ftq_pop` narrow 化 (commit 6335611)。repro=`skid_*_test.S`、`sim_cache_soc` で決定的再現 |
| **#17 fetch/PTW livelock** (demand-paged CALL 先 IF page fault) | ✅ 解決 (2026-07-02) | `fetch_dead_q` + ifpf take ゲート (commit 21094bb)。repro=`callfault_test.S` |
| **#18 faulting load の garbage retire** (MEM/WB ゲート漏れ) | ✅ 解決 (2026-07-03) | MEM/WB バブル条件に `mem_trap_enter` 追加 (commit 5e5d52d)。userspace 散発 SIGSEGV 根治 |

---

## リファクタリング方針 (2026-07-03 更新)

**構成は概ね良好。大規模リファクタは引き続きやらない。** コードは「実機 Linux + RootFS bash 到達」という
hard-won な known-good 状態 (RTL バグ #1〜#18 修正済) にあり、検証済みパイプラインの分割は同クラスの
subtle bug を再混入するリスクが高い。

- `rv_core.sv` (~2240 行) は stall/flush 条件が多いが、各条件に「なぜ・no-op 証明」のコメントが
  付いており、履歴は `docs/rtl_bug_history.md` と対応。**分割は ⑤ (RVV) 等で該当箇所を触るときに
  その範囲だけ surgical に**。先回りの全面分割はしない。
- `tb_rv_boot_soc.sv` のデバッグ計装 (`BOOT_*` ifdef 群) は「恒久検出器」と「バグ調査用の使い捨て」が
  混在。分類は TB 冒頭のコメント参照。削除は full Linux ゲート再実行とセットでのみ行う。
- マイクロアーキ変更は **full Linux boot (`ROOTFS-BASH-OK`) を必須ゲート** にする (CLAUDE.md 参照)。

---

## 関連ドキュメント

- `CLAUDE.md` — ISA/テスト状況・ビルド手順・設計判断・実機 bring-up の総合インデックス。
- `docs/architecture.md` — アーキテクチャ概要。
- `docs/axi_ddr.md` / `docs/cache.md` — メモリサブシステム・キャッシュ。
- `docs/opensbi_sim.md` / `docs/linux_sim.md` / `docs/verilator_sim.md` — ブート sim 環境。
- `docs/fpga_timing_bringup.md` — FPGA timing 収束・実機 bring-up (25MHz 期)。
- `docs/freq_50mhz.md` — 周波数 25→50MHz キャンペーンの記録 (冒頭にサマリ、以降は詳細ログ)。
- `docs/rtl_bug_history.md` — RTL バグ #1〜#18 詳細。
- memory `linux_boot_roadmap` / `freq-50mhz-roadmap2` — 経緯の要約。
