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

実機 Linux が `inet_init → ip_fib_init → __netlink_kernel_create → netlink_table_grab` で PID1 永久ブロック
(`nl_table_users` が 0 に戻らない)。sim では通過するため **実機固有** = straddle と同じ「sim クリーン/実機 fail」
クラス (ただし straddle 自体とは別バグ。straddle は解消済)。

- **✅ 2026-06-18 JTAG 切り分けで根本原因クラス確定** (詳細メモリ [[zybo-netlink-atomic-bug]]):
  - **間欠的なレース** — 同一 NET=y fw で **boot#1 は userspace 到達、boot#2 は同じ netlink site で hang**。
  - 決定的データ: RISC-V の PS DDR を A9 から `mrd` で直読 (`boards/zybo_z720/vitis/inspect_netlink.tcl`)。
    `nl_table_users` (atomic_t, HW PA `0x0191d9f8`) が **1 に固着**・`jiffies_64` は前進 (カーネル生存・真の待機)。
  - = `netlink_unlock_table` の `atomic_dec_and_test` (`amoadd.w -1`) の **dec が喪失** (counter 破損)。値が巨大
    ゴミでなく**ちょうど 1** = 「stale read→ゴミ書込」でなく **AMO 書込フェーズが落ちた (dec が実行されず)**。
    → #15/#16 と同族の「可変レイテンシ × flush/IRQ × AMO/atomic retire 衝突」。sim BFM (低レイテンシ) は窓を開かない。
  - 容疑 = `rv_core.sv` AMO 2-phase 書込コミット / `rv_dcache.sv` write-through / burst bridge の read/write 交錯。
    inspection 上 AMO は flush/IRQ から保護されて見える (書込中 `dmem_wait=1`→`flush_ex_mem` 不可) ので、レースは
    より微妙で波形観測が要る。
- **なぜ最優先**: networking 単体でなく **コア正当性の問題**。RootFS の userspace は futex/atomic を酷使する
  ので、潰さないと ③ が不安定化する恐れ。`CONFIG_NET=n` で net 経路に切り分け・workaround 済 (`kernel_fragment.config`)。
- **次の手**: (a) focused sim 再現 (amoadd inc/dec を IRQ+AXI 遅延+IF/data 競合下で叩き counter 不復帰を Verilator
  で再現; 遅延ノブ `BOOT_AR_DELAY` 等を `tb_rv_boot_soc`/`src/sim/Makefile` に追加済) → 出れば波形デバッグ。
  (b) 実機 ILA: data-write AXI を `nl_table_users` PA でトリガし落ちる dec の AMO FSM/flush/bridge 信号を捕捉。
- **完了条件**: `CONFIG_NET=y` の Linux が実機で **複数回連続** userspace 到達 (間欠ゆえ 1 回成功では不十分)。

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
| **netlink/atomic ハング** (間欠レース。`nl_table_users` が 1 固着 = `amoadd.w -1` の dec 喪失 = counter 破損。JTAG 切り分け済 2026-06-18) | ⚠️ 回避中 | `CONFIG_NET=n` で回避。根治は ロードマップ ① ([[zybo-netlink-atomic-bug]] / `inspect_netlink.tcl`) |

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
