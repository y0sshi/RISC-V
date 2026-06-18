# RISC-V コア 開発ロードマップ

最終更新: 2026-06-18

自作 RV64GC 5段パイプラインコア (educational) の到達点と今後の計画。
ISA/テスト詳細は `CLAUDE.md`、実機バグ史は memory `zybo-jalr-fetch-bug` / `docs/rtl_bug_history.md` を参照。

---

## 現状サマリ

**sim → 実機 Zybo Z7-20 で OpenSBI v1.2 フルブート + Linux 6.12 が userspace 到達
(`LINUX-USERSPACE-OK: init running`) を達成** (2026-06-18、`CONFIG_NET=n`)。
- compliance RV64 117/117・RV32 88/88、全ユニットテスト PASS。
- RV64GC + Zicsr + S-mode + Sv39 + トラップ委譲 + CLINT/UART(8250)/PLIC/GPIO。
- DDR over AXI (2 マスタ) + I/D キャッシュ、Verilator 高速 sim、JTAG bring-up。
- FPGA timing met @25 MHz (WNS=0.200ns)。

---

## 達成済み (Phase 0 → 実機 Linux)

| フェーズ | 内容 | 状態 |
|---|---|---|
| **0. CPU/MMU/ISA 基盤** | 5段パイプライン、I/M/A/F/D/C/Zicsr、M/S-mode、Sv32/Sv39、トラップ/割込優先度 | ✅ |
| **1. SoC 統合・ボード雛形** | CLINT/UART/PLIC/GPIO、`rv_soc`/`rv_soc_bram`/`rv_soc_act`、Zybo/KV260 トップ | ✅ |
| **2. メモリ拡張・キャッシュ** | BRAM → PS DDR over AXI4 (命令+データ/PTW 2マスタ)、I$/D$ + burst bridge | ✅ |
| **3. OpenSBI v1.2 フルブート** | 共有 DDR + fw_payload、16550 互換 UART、M→S、sim + **実機**で banner+payload | ✅ |
| **4. Linux 6.12 → userspace** | earlycon=sbi → ttyS0 切替 → PID1 → `LINUX-USERSPACE-OK`、sim + **実機** (NET=n) | ✅ |
| **5. FPGA timing収束・実機 bring-up** | muldiv 多サイクル化・cache BRAM 化・FPU パイプライン化で timing met、JTAG bring-up | ✅ |

到達までに実機固有バグ 2 件を発見 (下記「既知の実機バグ」)。

---

## 今後のロードマップ (優先度順)

依存構造: **①→②→③ はクリティカルパス (順に進める)**、**④⑤ は独立 (いつでも並行着手可)**。

| # | 項目 | 種別 | 工数 | リスク | 依存 |
|---|---|---|---|---|---|
| ① | atomic 整合性バグ修正 (CONFIG_NET=y) | 正当性 (基盤) | 中 | 中 | — |
| ② | 動作周波数向上 (25→50MHz+) | 加速 (基盤) | 中 | 中 | (①と並行可) |
| ③ | RootFS / Ubuntu 対応 | 本命 | 大 | 中 | ① (+② 実用性) |
| ④ | 他ボード対応 (PYNQ-Z1/Z2・KV260) | 横展開 | 小〜中 | 低 | 独立 |
| ⑤ | Vector (RVV) 拡張 | 新機能 | 大 | 中 | 独立 |

### ① atomic 整合性バグ修正 → CONFIG_NET=y (最優先・基盤)

実機 Linux が `inet_init → netlink_table_grab` で PID1 永久ブロック (`nl_table_users` が 0 に戻らない)。
sim では通過するため **実機固有** = straddle と同じクラス。netlink は atomic カウンタ + waitqueue
(LR/SC) を使うので、**実 DDR タイミング下の LR/SC・AMO・FENCE の整合性**が最有力。

- **なぜ最優先**: networking 単体でなく **コア正当性の問題**。RootFS の userspace は futex/atomic を酷使する
  ので、潰さないと ③ が不安定化する恐れ。`CONFIG_NET=n` で net 経路に切り分け済み。
- **初手**: 実機 ILA で `nl_table_users` の `atomic_dec` と `netlink_unlock_table` の wake を観測 →
  LR/SC 命令列の実機挙動を確認。straddle と同じ ILA 資産・手法が使える。
- **完了条件**: `CONFIG_NET=y` の Linux が実機で userspace 到達。

### ② 動作周波数向上 25→50MHz+ (基盤・加速)

現状 timing は WNS=0.200ns とタイト。クリティカルパス = 組合せ FPU + 単サイクル乗算。

- **なぜ早期**: 実機ブート ~5分 (soft lockup もこれ起因)。①③④ すべてこの「ブート税」を払うので、
  2倍速化は以降全作業への投資。①と独立なので並行可。
- **作業**: 乗算の多サイクル化 / FPU レジスタ挿入 → 再 timing 収束。
- **⚠️ リスク**: パイプライン化は「可変レイテンシ livelock」(CLAUDE.md #14/#15 クラス) を生みうる。
  **`NET=n` フル Linux ブートを回帰ゲート**にしながら進める。

### ③ RootFS / Ubuntu 対応 (本命)

**SD ブートと RootFS は別問題**。SD ブート = PS の起動利便性 (BOOT.bin) で、RootFS 置き場とは無関係。
本質は **PL 上のコアからアクセスできるストレージ**。段階:

1. **DDR 拡張** (現状 64MB マッピング → 実機 1GB を活用)。最初の必須前提。
2. **大きめ initramfs (Buildroot/Debian base) を拡張 DDR に** — 新ペリフェラル不要で「ちゃんとした
   userspace (shell/coreutils)」へ最短到達。まずここを目標。
3. **永続ストレージ** — PL に SD/SPI コントローラ IP、または PS-PL 共有メモリ経由の virtio-block
   (A9 をバックエンド) → 本物の Ubuntu RootFS。
- SD ブートは小工数の利便性 item、③ の必須ではない (並行で好きな時に)。

### ④ 他ボード対応 (横展開・並行可・低リスク)

- **PYNQ-Z1 / PYNQ-Z2 = Zynq-7000 で Zybo Z7-20 とほぼ同系**。RTL 不変、XDC ピン + ボードプリセット +
  DDR/クロックのみ。小工数の確実な勝ち。
- **KV260 = Zynq UltraScale+ (PS8/A53/DDR4)**。PS 初期化・FSBL・SmartConnect が別物で中工数。
- ①②③ に依存せず、いつでも差し込める。

### ⑤ Vector (RVV) 拡張 (新機能・最後)

ベクタレジスタファイル・レーン演算・`vsetvl` 等の大規模 RTL 追加。Linux/Ubuntu には不要 (RVV はオプション)。
他項目をブロックしない。プラットフォーム安定後の独立フィーチャーフェーズが最適。

### (リスト外) SMP / マルチハート

「本物の Linux」感を上げる大物だが、現状 LR/SC にコヒーレンシ無し → キャッシュコヒーレンシ機構が必要な
超大型項目。①の atomic 正当性を固めた後の、さらに先の検討対象。

---

## 既知の実機バグ

| バグ | 状態 | 対応 |
|---|---|---|
| **I$ straddle** (redirect 先 straddle の squash race / 実 S_AXI_HP 非アライン AXI) | ✅ 解決 | rv_icache 2-line 化 + S_BYPASS 全廃 (commit fd382da)。sim + 実機検証済 |
| **netlink/atomic ハング** (`nl_table_users` 不復帰、実 DDR 下 atomic 疑い) | ⚠️ 回避中 | `CONFIG_NET=n` で回避。根治は ロードマップ ① |

---

## リファクタリング方針 (このタイミングでの判断)

**構成は概ね良好。大規模リファクタは今やらない。** 理由: コードは実機 Linux 到達という hard-won な
known-good 状態 (RTL バグ #1-#16 修正済) で、構成がロードマップを阻害していない。検証済みパイプラインの
分割は #1-#16 と同クラスの subtle bug を再混入するリスクが高い。

- **今やる安全な hygiene**: `src/rtl/old/rv32i/` (どのビルドからも未参照のレガシー) の削除/退避、
  straddle 調査で増えた debug 計装の残骸確認 (済)。
- **driver が来たら局所的に**: `rv_core.sv` (1698 行の god module: pipeline + hazard + AMO/misaligned
  FSM + 可変長 fetch + redirect) の分割は、② (FPU/乗算が EX を触る) や ⑤ (RVV が EX/regfile を触る) で
  該当箇所に手を入れる時に、その範囲だけ surgical に。先回りの全面分割はしない。

---

## 関連ドキュメント

- `CLAUDE.md` — ISA/テスト状況・ビルド手順・設計判断・実機 bring-up の総合インデックス。
- `docs/architecture.md` — アーキテクチャ概要。
- `docs/axi_ddr.md` / `docs/cache.md` — メモリサブシステム・キャッシュ。
- `docs/opensbi_sim.md` / `docs/linux_sim.md` / `docs/verilator_sim.md` — ブート sim 環境。
- `docs/fpga_timing_bringup.md` — FPGA timing 収束・実機 bring-up。
- `docs/rtl_bug_history.md` — RTL バグ #1-#16 詳細。
- memory `zybo-jalr-fetch-bug` / `linux_boot_roadmap` — 実機バグ・Linux 起動の経緯。
