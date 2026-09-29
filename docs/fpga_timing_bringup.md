# FPGA タイミング収束・実機 bring-up ロードマップ (C-1〜C-3)

CLAUDE.md から分離 (2026-06-17 のシュリンク時)。OOC 合成見積り→タイミング収束→実機対応 bitstream + bring-up 準備の全詳細。
現状の実機バグは `docs/next_session_prompt.md` / memory `zybo-jalr-fetch-bug`、実機手順は `boards/zybo_z720/vitis/README.md` を参照。
⚠️ Vivado/Vitis は PowerShell + 絶対パス必須 (Bash/MSYS だと synth クラッシュ)、input ポート `wire` 明示必須。

---

### ✅ C-1 完了 (2026-06-11): rv_soc OOC 合成 + 面積/タイミング見積り — `boards/report_area_timing.tcl`
RV64 / xc7z020-1 (Zybo) / 100 MHz 目標で OOC 合成 (`boards/reports/*.rpt`)。**実機の最大リスク = タイミングを定量化**:
- **WNS = -226.011 ns** (配線前; 失敗 EP 9320/99200)。クリティカルパス = `periph_rdata_reg[47]` →
  `ex_mem_alu_result_reg[60]`、遅延 236 ns、**Logic Levels 1111 のうち CARRY4 = 1084 = `rv_muldiv` の単サイクル
  組合せ 64bit 除算器 (DIV/REM)** のリプルキャリー鎖。実効 Fmax ≈ 4.2 MHz。**上位25パス全部この除算器**。
  → **「低クロックでまず動かす」は不成立** (配線後更に悪化 + 4 MHz Linux は実用外)。**C-2 第一手 = 除算(次いで
  単サイクル 64×64 乗算=51 DSP)の多サイクル逐次化** (既存 EX-stall FSM = AMO/mal/`fpu_busy` と同型、bare no-op で)。
  除算を直したら**再合成して 2 番手 (乗算 DSP カスケード→組合せ FADD/FCVT) を露出**させる順序。
- **面積 = LUT 60,527 (xc7z020 の 114% → Zybo 未収容)・FF 49,204・DSP 62・BRAM 0**。**キャッシュが BRAM 非推論**
  (RAMB36/18=0): 「1 サイクルヒット」設計のデータ配列**組合せ読み** (+RVC 窓 part-select) が同期読み前提の BRAM に
  載らず、I$/D$ で計 ~4 万 FF + 1.7 万 LUT に化けている (LUT 114% の主因)。モジュール別: rv_core glue 26k LUT /
  rv_csr 8.9k / rv_dcache 10.4k+20.2k FF / rv_icache 6.6k+20.1k FF / rv_fpu 3.7k+11 DSP / rv_muldiv 0.96k+51 DSP。
  → 収容策: (a) キャッシュ同期読み化で BRAM 化 (コアの 1 サイクル契約に踏み込む大改修) / (b) キャッシュ縮小 /
  (c) **KV260 (xck26-2LV: LUT 117k/DSP 1248/BRAM 144, -2 グレード) なら現状で収容 (~52%) + ~15-20% 速い** →
  **初回 bring-up は KV260 推奨** (収容を切り離す)。⚠️ **ボード変更は収容を救うがタイミングは救わない** (236 ns 不変)。
- ⚠️ 起動は **PowerShell 必須** (Bash/MSYS だと synth クラッシュ) + **input ポート `wire` 明示** (上記 vivado 環境節)。

### C-2 ロードマップ (タイミング収束 + 収容; C-1 の結論を受けて確定 2026-06-11)
ユーザー方針 = **C-2a → C-2b の順、ボードは Zybo Z7-20 本命**。
- **✅ C-2a 完了 (2026-06-11) `rv_muldiv` 除算の多サイクル逐次化**: DIV/DIVU/REM/REMU + W 形 8 種を
  **radix-2 restoring 逐次除算器** (`rv_muldiv.sv`) に。MUL 系は据置 (DSP, 単サイクル組合せ; C-2c で判断)。
  EX 段ストール `muldiv_busy_int`/`muldiv_start_stall`/`muldiv_was_busy` を `fpu_busy`/`fpu_start_stall`/
  `fpu_was_busy` と**完全同型**で新設 (`rv_core.sv`): 除算進入時 `muldiv_start_stall` が IF/ID を 1 cy 保持 (busy は
  次エッジで立つ NBA 遅延を吸収) + その開始サイクルは `ex_mem_valid` にバブル挿入、反復中 `muldiv_busy_int` で
  stall_if/id/ex、完了サイクル (busy 落ち) で EX/MEM が `result` を捕捉。`rv_muldiv` は radix-2 で N+3 cy
  (D_IDLE→D_RUN×width→D_CORR で符号補正/特殊上書き→D_DONE で結果提示)、`div_result` レジスタ出力。除算ハング
  防止に「busy 立つまで valid_in 保持」のハンドシェイク (tb 更新)。**唯一の機能変更=単サイクル→多サイクル**なので
  bare no-op にはならず、回帰は**結果一致**で確認。
  - **回帰全 PASS**: sim_mext 29/29・sim_mext64 40/40 (W 形 div0/overflow 特殊含む)、pipeline/intr/csr/sv(64)/
    mmu(64)/fpu_pipe/amo(64)/timer(64)/uart/plic/gpio、cache 全 (icache(64)/dcache(64)/cache_soc(64)/axi_burst)、
    **compliance RV64 117/117 (um 13/13)・RV32 88/88 (um 8/8)**、mini-SBI vl_boot **IF=573 data=4 不変** (基準一致)、
    Linux boot は clocksource/BogoMIPS 較正 (除算多用) を panic 無しで通過。
  - **🎯 再合成結果 (xc7z020-1, 100MHz目標, `boards/reports/*.rpt`)**: **WNS -226.0 → -54.2 ns**
    (Fmax ~4.2 → ~15.6 MHz)、**LUT 60,527 (114%) → 39,405 (74.07%) で Zybo 収容達成** (組合せ 64bit 除算器 8 種が
    最大の LUT 食い=合計 ~21k LUT だった; 逐次化で 1 共有除算器に)。FF 49,204→49,604 (+400=FSM state)、DSP 62 不変、
    BRAM 0 (C-2b 未着手)。**新クリティカルパス = `periph_rdata` → DSP48E1×3 (単サイクル 64×64 乗算カスケード) +
    CARRY4×53 → `u_csr/fflags` (組合せ FPU)** = 予測どおり乗算+組合せ FPU。→ C-2c の対象が確定。
- **✅ C-2b 完了 (2026-06-14) cache BRAM 化**: I$/D$ のデータ配列を**出力レジスタ型の同期読み** (`rdata<=mem[addr]`)
  に書換え、`(* ram_style="block" *)` 明示で RAMB36 を推論。tag/valid は fabric 据置 (組合せ lookup)。
  - **D$ (`rv_dcache.sv`)**: 2 次元 `data[SETS][WORDS]` を 1 次元 BRAM `data[SETS*WORDS]` (幅 XLEN、バイト we) に平坦化。
    読み = `rdata_q<=data[{idx,wsel}]` (rdata_q が BRAM 出力レジスタ=c_rdata)、書き = fill ビート + store hit 更新の
    バイト we。**fill 完了後の要求語捕捉 (旧 `if beat==fill_wsel: rdata_q<=m_rdata`) は不可**になるので、新状態
    **`S_RELOOKUP`** で held `{fill_idx,fill_wsel}` を 1 サイクル re-lookup (BRAM 書込と同サイクル読み不可のため;
    `c_wait` は S_FILL/S_RELOOKUP の間 high→ミスに +1 cy、ヒット 1 cy は不変)。
  - **I$ (`rv_icache.sv`)**: 256-bit ライン配列を BRAM 化。読み = `line_q<=line[rd_set]` (line_q が BRAM 出力レジスタ)、
    **CE = 既存の addr_q 更新 enable** (`addr_q_en`) に一致させ line_q を addr_q とロックステップに (=serve サイクルで
    `line_q==line[set(addr_q)]`、旧 async 読みとビット等価)。RVC 窓は BRAM 出力後の組合せ part-select
    `line_q[boff*8+:32]`。書き = S_FILL の per-word we ループ。fill 完了後は新状態 **`S_FILL2`** で `set(addr_q)` を
    re-read (BRAM 書込と同サイクル読み回避) → 次サイクル S_LOOKUP で hit serve (ミスに +1 cy)。**⚠️ addr_q hold 意味論と
    m_done 再武装 (バグ #5 stale-PA 防止) は不変**、tb_rv_icache の translation-mid-fill 50/50 で検証。
  - **回帰全 PASS**: sim_icache(64) 50・sim_dcache 64/dcache64 54・sim_cache_soc(64) 6、**mini-SBI vl_boot
    IF=573 data=4 不変** (キャッシュ挙動ビット一致=非破壊の証明)、compliance は rv_soc_act 経由で非依存 (RV64 117/RV32 88)。
    Verilator も BLKLOOPINIT 無しでビルド (per-word/byte we はビット選択ループなので可)。
  - **🎯 再合成 (xc7z020-1, 100MHz 目標)**: **RAMB36E1 = 5** (D$=1 [256deep×64], I$=4 [64deep×256])・**LUT 74.75→47.21%
    (39,766→25,114)・FF 47→16.08% (50,087→17,109、約 33k FF を BRAM へ追い出し)**=**Zybo に大余裕**。**WNS -20.566→
    -21.462 ns はほぼ横ばい** (BRAM 化は収容を救うがタイミングは救わず=予測どおり)。**新クリティカルパス =
    `ex_mem_alu_result_reg[5]` → (キャッシュ hit/miss 制御の高ファンアウト網, route 67.7%) → `u_ic/line_reg_*/ENARDEN`**
    (I$ BRAM のリードイネーブル)。**addr_q の CE 経路が BRAM ENARDEN に移っただけで高ファンアウト制御網は不変** = 次の一手は
    この**キャッシュ lookup 制御網の段数/ファンアウト削減** (C-2b 後継、もはや FPU でも storage でもなく制御ロジック)。
- **C-2c [進行中・タイミングの本命] FPU パイプライン化**: C-2a 再合成の **トップ25失敗パス = 全て倍精度組合せ FPU**
  (`u_fpu/u_mul_d` の FMUL.D DSP カスケード → `u_fma_add_d` 正規化/丸め → fflags)。**整数乗算はトップ25に不在**だった
  ため、本命は FPU。
  - **✅ C-2c 第一歩 (2026-06-12) FPU 2 段パイプライン化**: FMADD 系の乗算結果を**レジスタ化** (`rv_fpu.sv` の
    `mul_result_q`/`mul_d_result_q`) して乗算を stage 0・加算+丸めを stage 1 に分割。**全 FP 組合せ演算**
    (FADD/FSUB/FMUL/FMADD 系/FMISC/FCVT) を 2 サイクル化し、busy/start_stall/done ハンドシェイクを **FDIV/FSQRT・整数
    除算と完全同型**で実装 (`rv_fpu.sv` の comb FSM + `rv_core.sv`: `fpu_done` ラッチ新設=全 FP 多サイクル化で livelock
    防止が load-bearing に、`fpu_start_stall` を全 FP 演算へ一般化、EX/MEM バブル条件一般化)。レイテンシのみの変更で
    結果ビット一致 (no-op ではない)。ユニット TB `tb_rv_fpu.sv` を新ハンドシェイク (`result_valid` 待ち) に追従。
    - **回帰全 PASS**: sim_fpu 94・sim_fpu_d 33・sim_fpu_pipe 7・全 core/cache/周辺 sim・**compliance RV64 117/RV32 88**・
      mini-SBI vl_boot **IF=573 data=4 不変** (FP 未使用なので基準一致)。
    - **🎯 再合成 (xc7z020-1, 100MHz目標)**: **WNS -54.2 → -33.2 ns** (Fmax ~15.6 → ~23 MHz)、パス遅延 64→43 ns、
      **DSP がクリティカルパスから消滅** (Logic Levels 115→71, CARRY4 53→23)。新クリティカルパス = **単体 FADD.D/FSUB.D
      (および FMADD stage-2 加算) の正規化+丸め+fflags 鎖** (`u_add_d/...→u_csr/fflags`)。面積ほぼ不変
      (LUT 39,405→39,691=74.61%, FF +121, DSP 62 不変, BRAM 0)=Zybo 収容維持。パス遅延の 70% が route (配置前推定)。
  - **✅ C-2c 第二歩 (2026-06-12) FP 加算器の内部分割**: `rv_fpu_add.sv`/`rv_fpu_add_d.sv` を **`sum` 算出 (整列+加算)
    後・LZC+正規化+丸め+fflags 前で 2 段分割** = **1 サイクルレイテンシのパイプライン化ユニット**化 (clk/rst_n ポート追加、
    ステージ境界信号 `sum_q`/`sum_sign_q`/`el_q`/`sa_q`/`sb_q`/`a_nan_q`..`b_inf_q` を内部レジスタ経由に。精密な FP
    ロジックは不変、信号名のみ `_q`)。**comb FSM (rv_fpu) は変更不要**: FADD は op-in→T+1 で結果、FMADD は乗算レジスタ
    →加算器内部レジスタの 2 レジスタで T+2 にちょうど収まり、既存 2 サイクル予算で捕捉。内部レジスタは free-running
    (stale fill は捕捉されない)。結果ビット一致。回帰全 PASS (fpu 94/fpu_d 33/fpu_pipe・compliance RV64 117/RV32 88・
    mini-SBI IF=573 不変)。
    - **🎯 再合成: WNS -33.2→-23.2 ns (Fmax ~23→~30 MHz)・パス 43→33 ns・Logic Levels 71→41**。**C-2a 比で Fmax ほぼ
      2 倍 (15.6→30 MHz)**。面積ほぼ不変 (LUT 74.61→74.64%, FF +246=加算器パイプラインレジスタ, DSP 62, BRAM 0)。
      新クリティカルパス = **未分割の FMUL.D `mul_d` (DSP 積 + 正規化/丸め → fflags, DSP48E1×2 + CARRY4×8)**。
  - **✅ C-2c 第三歩 (2026-06-13) FMUL.D/FMUL.S の内部分割**: `rv_fpu_mul_d.sv`/`rv_fpu_mul.sv` を **DSP 積算出後・
    正規化/丸め前で 2 段分割** = **1 サイクルレイテンシのパイプライン化ユニット**化 (加算器と完全同型: clk/rst_n ポート
    追加、ステージ境界に `prod_q`/`exp_sum_q`/`sr_q` + 特殊フラグ `a_nan_q`..`b_zero_q` の free-running レジスタ。FP
    ロジック不変、信号名のみ `_q`)。**rv_fpu.sv の対応**: ① 乗算レジスタ `mul_result_q`/`mul_d_result_q` を
    **free-running 化** (乗算結果が T+1 で valid になるため、旧 start-cycle gated latch では stale を掴む。free-running
    なら FMADD add stage が T+2 に正しい積を読む)、② comb FSM を**カウンタ化** (`comb_cnt`、`COMB_LAT=2` busy サイクル)
    し capture を T+2→**T+3** に延長 (FMADD 深さ = mul 内部 reg + mul_result_q + add 内部 reg の 3 段になるため)。
    **rv_core 側は変更不要** (start_stall/fpu_done/バブルは全 FP 多サイクルで一般化済、レイテンシは rv_fpu 内部 busy 長
    で決まる)。**TB 追従**: `tb_rv_fpu_d.sv` の `run_op_comb` に `result_valid` 待ちを追加 (FMADD が T+3 capture に;
    旧 1 サイクル即読みでは FMADD が stale)。結果ビット一致。
    - **回帰全 PASS**: sim_fpu 94/fpu_d 33/fpu_pipe 7/pipeline/intr/csr/sv64/mmu64/amo64/mext64/mdrand64・cache 全・
      周辺全、**compliance RV64 117/117・RV32 88/88**、mini-SBI `vl_boot` **IF=573 data=4 不変**。
    - **🎯 再合成 (xc7z020-1, 100MHz 目標): WNS -23.2→-20.566 ns (Fmax ~30→~32.7 MHz)・パス 33→30.3 ns**。
      **FPU/DSP がクリティカルパスから完全消滅** (DSP Block=None、Logic Levels 41→45 だが **Net 72%/Logic 28% =
      ルート支配**に変質)。**新クリティカルパス = `ex_mem_alu_result_reg[5]` → (キャッシュ hit/miss 制御の高ファンアウト
      LUT 網, fanout 138-155) → `addr_q_reg[*]/CE`** (I$/D$ アドレスレジスタの clock-enable 経路)。面積ほぼ不変
      (LUT 74.64→74.75%, FF +~480=乗算パイプラインレジスタ, DSP 62, BRAM 0)=Zybo 収容維持。
  - **C-2c 第四歩 [次] = もはや FPU ではない**: クリティカルパスがキャッシュアドレス/制御経路 (ルート支配) に移ったため、
    FPU の更なるパイプライン化は WNS を改善しない。次の一手は **(a) キャッシュアドレス→`addr_q` 制御の高ファンアウト/段数
    削減** (lookup 制御の簡素化 or レジスタ挿入)、もしくは **(b) C-2b キャッシュ BRAM 化** (同期読み化で LUT 網を BRAM へ
    追い出す→経路自体を縮小)。整数乗算 (単サイクル 64×64 DSP) や FCVT 系は今回トップ25に**不在**なので後回し可。
    ⚠️ ルート 72% は OOC (配置前) の悲観値だが、高ファンアウト網 (155) は配置後も残る公算。
- **✅ C-2d 手1 完了 (2026-06-14) クリティカルパス高ファンアウト網の `max_fanout` 削減**: C-2b 後の新クリティカルパス
  = `ex_mem_alu_result_reg[5]` (登録済みデータアドレス) → 16-entry FA-TLB データ変換 (組合せ) → `mmu_dmem_pa`
  (**fo=883**: D$ の 64-set index デコード valid/tag mux を駆動) → D$ hit cone → `dmem_wait` → `stall_if`
  (**fo=201**) → trap/redirect → `fetch_pc` → IF-TLB 変換 → I$ `rd_en`/`line_reg/ENARDEN`。この **48-50 段の
  クロスモジュール組合せ連鎖** (route 67%) に対し、純合成ヒント `(* max_fanout = 64 *)` を 2 箇所に付与
  (`rv_dcache.sv` の index `idx` = fo883 の負荷、`rv_core.sv` の `stall_if`/`stall_id` = fo201)。**機能 no-op**
  (iverilog/Verilator は属性を無視 → 全 sim ビット一致、mini-SBI vl_boot `IF=573 data=4` 不変)。
  - **🎯 再合成 (xc7z020-1, 100MHz 目標)**: **WNS -21.462 → -20.246 ns (+1.216)**・Logic Levels 50→48・
    実効 Fmax ~31.8 → ~33.1 MHz (+4%)。fanout は cap どおり **883→64・201→33** に分割 (index は複製コピー
    `i___63_rep` 経由)。面積コスト = **LUT +274 (47.21→47.72%)**・FF/RAMB36(5)/DSP(62) ほぼ不変。
  - **結論 = ファンアウト削減は逓減**: パス構造は不変 (48 段)・route 67% は多数のネットに分散し、各高ファンアウト網
    (残る tlb_valid fo=95/54・`cur_priv` fo=128 等) を追っても 1 本 ~1ns 程度。**20ns ギャップは fanout 調整では
    閉じない**。設計は **既に Zybo 大余裕** (LUT 47.7%/FF 16%/BRAM 5/140) + **Fmax ~33 MHz は実機 bring-up に十分**。
    更なる WNS 改善の唯一の本命 = **手3 (MEM 段アクセスのパイプライン化 = D$ hit/c_wait を登録し 2-cycle D$ 化、
    `dmem_wait`→`stall_if`→I$ enable の組合せ結合を切る)** だが**高回帰リスク**で要明示合意。**→ 深追いせず C-3
    実機 bring-up へ進む方針**。
- **その後 C-3+ ボード bring-up**: Zybo PS7 BD (`boards/zybo_z720/vivado/build_zybo.tcl`) + S_AXI_HP、DDR プリ
  ロード。**最大の落とし穴 = firmware link 0x8000_0000 vs Zynq-7000 PS DDR (0x0 起点)** → S_AXI_HP オフセット or
  firmware/DTB 再リンクで整合 (`docs/axi_ddr.md`「IMPORTANT: address map」)。

### ✅ C-3 第一歩 完了 (2026-06-14): Zybo Z7-20 headless bitstream を timing closure で生成
`build_zybo.tcl` を **RV64 (`XLEN64=1`) + PL クロック 25 MHz** (`PL_FREQMHZ` 変数化) に編集し、`-tclargs bit` で
impl + write_bitstream まで完走。**bitstream = `boards/zybo_z720/vivado/rv_riscv_zybo/rv_riscv_zybo.runs/impl_1/
bd_riscv_wrapper.bit`** (gitignore 下、~4 MB)。headless (UART/GPIO はタイオフ: `uart_rx`=1/`gpio_in`=0、出力 open)。
- **🎯 実 P&R 結果 (xc7z020-1, 25 MHz / 40 ns 周期)**: **WNS = +0.227 ns (timing 収束、failing EP 0)**・WHS +0.013・
  「All user specified timing constraints are met」。**LUT 28,394 (53.37%)・FF 22,640 (21.28%)・BRAM 5 RAMB36
  (3.57%)・DSP 62 (28.18%)・BUFG 1**。OOC コアのみ (LUT 25,388) に対し +~3k LUT は SmartConnect + proc_sys_reset。
- **⚠️ 重要な乖離 = OOC 見積り ~33 MHz vs 実 P&R ~25 MHz**: WNS +0.227 @ 40 ns = 実パス ~39.8 ns = 実効 Fmax
  ~25.1 MHz。**OOC (`report_area_timing.tcl`) の route 67% は楽観値で、実配置のキャッシュ hit/miss 制御網は OOC 予測
  より長い**。30 MHz では閉じなかった公算 → **初回 25 MHz 選択が正解**。今後クロックを上げるなら手3 (MEM 段パイプ
  ライン化) 等の WNS 改善が前提。
- **BD/合成で潰した 4 つの落とし穴 (build_zybo.tcl/kv260 共通の潜在バグ; これまで BD を最後まで走らせていなかった)**:
  ① `create_bd_cell -reference` の前に **`update_compile_order`** (SV 階層認識)。② **SV ファイルを BD モジュール参照の
  top にできない** (`[filemgmt 56-195]`) → プレーン Verilog ラッパ **`rv_soc_wrap.v`** (1:1 passthrough、AXI I/F は
  同名ポートから推論) を新設し参照。③ **BD 経由の OOC 合成ランに `RV_XLEN_64` define が伝播せず** XLEN=32 で
  `rv_fpu_misc` の `int_a[63:0]` が範囲外 → **`synth_checkpoint_mode None`** (グローバル合成) でフラット化。④ それでも
  **BD のモジュール参照パラメータ探索が define 無しでラッパを評価し XLEN=32 を baked-in** → **`set_property CONFIG.XLEN
  64`** を BD セルに明示。①〜④で synth/impl 完走。**RTL は一切不変** (ラッパは passthrough なので sim 回帰不要)。
- **アドレスマップ未解決 (既知・bitstream には無害)**: `assign_bd_address` は HP0_DDR_LOWOCM を `0x0` 起点 512M に割当。
  RST_ADDR=0x8000_0000 はこの範囲外 (Zynq-7000 PS DDR は 0x0..0x3FFF_FFFF)。実 DDR ブートフロー (後続) で firmware
  再リンク or HP オフセットで整合が必要 (`docs/axi_ddr.md`「IMPORTANT: address map」)。
- **次 (C-3 後続)**: ① UART を PMOD/EMIO へ出し XDC pin 制約 (実機 OpenSBI バナー観測)。② DDR ブートフロー
  (PS FSBL → JTAG/SD で firmware を DDR ロード → PL reset 解除)。③ 実機で OpenSBI→Linux→shell を実 UART 確認。
- **✅ 再合成 (2026-06-15, RTL bug #15 + #16 修正込み)**: #16 (misaligned LOAD phase-0 語消失) と #15 (mal
  restart-livelock) の両修正を反映して OOC + Zybo bitstream を再生成し、**タイミング/面積は baseline と実質同一**である
  ことを実測確認 (予測どおり非影響: #16 は mal FSM reset 項を `flush_ex_mem`→`mem_trap_enter & ~stall_ex` に置換した
  だけで data path 外、#15 は phase1 hold の 1 段 mux 追加のみ)。
  - **OOC (xc7z020-1, 100 MHz 目標)**: WNS **-20.828 ns** (baseline -20.246、Fmax ~32.4 vs ~33.1 MHz、誤差範囲)・
    LUT **47.72%** (25,385)・FF **16.09%** (17,125)・RAMB36 **5**・DSP **62**。クリティカルパスは baseline と同一
    (`ex_mem_alu_result_reg[5]` → I$ `line_reg/ENARDEN`、49 段、route 67%)。
  - **Zybo 実 P&R sign-off (25 MHz / 40 ns)**: **WNS = +0.570 ns (baseline +0.227)・WHS +0.009・failing EP 0**・
    「All user specified timing constraints are met」。**LUT 28,037 (52.70%)・FF 22,636 (21.27%)・BRAM 5 (3.57%)・
    DSP 62 (28.18%)・BUFG 1**。bitstream = 4,045,676 bytes @ `impl_1/bd_riscv_wrapper.bit`。
  - 起動は **PowerShell 必須・スクリプトは絶対パスで `-source`** (相対パスだと vivado の cwd が repo root でなく
    `couldn't read file` で即失敗するケースあり)。

### ✅ C-3 第二歩 完了 (2026-06-15): 実機対応 BD (PS7 ボードプリセット + UART 物理ピン + DDR 域 RST_ADDR)
headless 雛形を**実機ブート可能な構成**に昇格。`build_zybo.tcl` を改修し timing closure で bitstream 再生成。
- **① Digilent ボードファイル vendor + PS7 ボードプリセット**: `boards/zybo_z720/board_files/zybo-z7-20/A.0/`
  (board/part0_pins/preset.xml を Digilent vivado-boards から取得し repo に格納)。`set_property board_part_repo_paths`
  で参照 (Vivado インストールは汚さない)。`apply_bd_automation -rule ...processing_system7 -config {make_external
  "FIXED_IO, DDR" apply_board_preset 1 ...}` で **PS7 を Zybo 実機構成** (DDR3 MT41K256M16 RE-125 / MIO / クロック) に
  し、**FIXED_IO (MIO/JTAG/clk/rst) と DDR を外部トップポート化**。→ PS が起動し PS DDR が S_AXI_HP 経由で使用可能に。
  **これで前回 100 個出ていた FIXED_IO の Critical Warning が 0 に** (デフォルト PS7 では PS が起動しなかった)。
  `assign_bd_address` は HP0_DDR_LOWOCM を **0x0 起点 1G** に割当 (preset で DDR=1GB 認識、前回 512M から拡大)。
- **② UART を Pmod JC へ + XDC**: `const_uart_rx` タイオフを撤去し `make_bd_pins_external` で `uart_tx`(出力)/`uart_rx`
  (入力) をトップポート化。`zybo_uart.xdc` (新規) で **uart_tx=V15 (Pmod JC1)・uart_rx=W15 (Pmod JC2)・LVCMOS33**
  に固定 (Digilent Zybo-Z7-Master.xdc 由来)。実機では USB-UART アダプタを JC に接続しコンソール観測。配線=FPGA TX(V15)
  →アダプタ RX、FPGA RX(W15)←アダプタ TX、共通 GND。impl の io_placed で両ピン FIXED 配置を確認済。
- **③ RST_ADDR を PS DDR 域へ (アドレスマップ整合)**: Zynq-7000 PS DDR=0x0..0x3FFF_FFFF、S_AXI_HP はアドレスを
  そのまま PS マップへ転送するため、firmware/RST_ADDR は **DDR 内**に置く必要 (sim 既定 0x8000_0000 は HP0 割当範囲外で
  DECERR)。`rv_soc_wrap.v` のパラメータ既定 **`RST_ADDR=0x0020_0000`** (2 MiB アライン=OpenSBI FW_TEXT_START 要件、
  低位 2 MiB を回避、HP0 1GB 窓内) を rv_soc へ伝達。**sim は rv_soc 直接インスタンスで既定 0x8000_0000 のまま=検証済
  baseline 非破壊** (HW firmware は別ベースで別ビルド)。⚠️ 64bit param を BD CONFIG 経由で渡すと truncate し得るため
  ラッパ既定で持たせる (0x200000 は 32bit に収まり BD が正しく bake)。`rv_soc.is_periph` は 0xC0xx のみ判定で 0x200000
  は AXI→HP0→DDR へ正しくルートすることを確認済。
- **🎯 実 P&R sign-off (xc7z020-1, 25 MHz / 40 ns)**: **WNS +0.377 ns・WHS +0.037・failing EP 0**・
  「All user specified timing constraints are met」・**Critical Warning 0**。**LUT 28,118 (52.85%)・FF 22,816 (21.44%)・
  BRAM 5 (3.57%)・DSP 62 (28.18%)・BUFG 1・Bonded IOB 2** (UART のみ PL ピン、DDR/MIO は PS 専用ピンで IOB 非計上)。
  bitstream = 4,045,676 bytes @ `impl_1/bd_riscv_wrapper.bit` (gitignore 下)。前回 headless (+0.227) と実質同等。
- **残: firmware/DTB 再リンク (ソフト側、実機検証ゲート)**: bitstream は RST_ADDR=0x200000 でリセットするので、実機
  ブートには firmware を同ベースへ再リンクして DDR へロードする。recipe:
  - **OpenSBI** (`tests/opensbi/build.sh`): `FW_TEXT_START=0x80000000` → **`0x00200000`** に変更し fw_payload 再ビルド。
  - **DTB** (`tests/linux/rv_soc_linux.dts`): `memory@80000000 { reg = <0x0 0x80000000 0x0 0x04000000>; }` →
    実機 1GB に合わせ **`memory@0 { reg = <0x0 0x0 0x0 0x40000000>; }`** (firmware は 0x200000 にあり OpenSBI が予約)。
    CLINT/UART/GPIO/PLIC ノード (0xC0xx) は不変。
  - 実 OpenSBI/Linux の**再リンクは sim で実証完了** (下記 2026-06-16 項; mini-SBI に加え実イメージそのものを 0x200000
    で起動確認)。残る**実機での HW 検証のみ実機が必要**。
- **✅ アドレスマップ再リンクの sim sanity-check 完了 (2026-06-15)**: mini-SBI (`sbi_boot.S`) を**再リンク可能化**
  (`FW_BASE`→TOHOST を base 相対化、`boot.ld` を `__BASE` defsym 化、Makefile に `FW_LINK_BASE`/`boot_lo` 追加;
  **すべて既定 0x8000_0000 で byte-identical** = 全 boot test hex 不変で非破壊確認)。`tb_rv_boot_soc.sv` に
  **`BOOT_MEM_BASE`** 上書き (MEM_BASE=RST_ADDR=BFM BASE_ADDR、既定 0x8000_0000)。検証: `cd src/software && make boot_lo`
  (→ `sbi_boot_lo.hex` を 0x0020_0000 にリンク) → `cd src/sim && make vl_boot BOOT_HEX=../software/boot/sbi_boot_lo.hex
  BOOT_MEM_BASE=2097152` → **PASS** (M→S→SBI ECALL コンソール→"BOOT OK"→sentinel 0xC0FFEE)、しかも **IF line-fills=573
  data reads=4 が 0x8000_0000 baseline とビット一致** = ブート挙動が base 非依存と実証。コアが 0x200000 でリセット→
  AXI/D$経由で DDR の firmware をフェッチ→PMP/MRET/tohost 全フロー正常。**実 firmware 再リンクの recipe を実機前に de-risk**。
- **✅ 実 OpenSBI / 実 Linux イメージの 0x200000 再リンクを sim 実証完了 (2026-06-16)**: mini-SBI に続き、**実機へ
  載せる実イメージそのもの** (実 OpenSBI v1.2 fw_payload と、それに包んだ実 Linux 6.12) を 0x0020_0000 へ再リンクし
  Verilator boot で起動確認。両 build.sh を **`FW_BASE` パラメータ化** (既定 `0x80000000` で従来挙動を完全再現 =
  非破壊; `FW_BASE=0x00200000` で再リンク)。base-matched DTS を新設 (`docs/opensbi/rv_soc_lo.dts`,
  `tests/linux/rv_soc_linux_lo.dts`、いずれも `memory@200000` 64 MiB = BFM DEPTH)。
  - **OpenSBI** (`tests/opensbi/{build.sh,payload.S,payload.ld}`): `payload.S` の TOHOST を `FW_BASE + 0x2000`、
    `payload.ld` の link を `FW_BASE + 0x200000` (`--defsym FW_LINK`) に base 相対化。`build.sh` は `FW_TEXT_START=$FW_BASE`、
    OpenSBI を `distclean` してから再リンク、`OUT` で hex 名を分離。検証: 既定版 = **Firmware Base 0x80000000 で PASS**
    (banner + `PAYLOAD: hello` + sentinel 0xC0FFEE)、lo 版 = **Firmware Base 0x200000 / Next Address 0x400000 で PASS**
    (同一コンソール)。コマンド: `FW_BASE=0x00200000 DTS=.../rv_soc_lo.dts OUT=fw_payload_lo bash build.sh` →
    `make vl_boot BOOT_HEX=.../fw_payload_lo.hex BOOT_MEM_BASE=2097152`。
  - **Linux** (`tests/linux/{build.sh,rv_soc_linux_lo.dts}`): カーネル Image は relocatable で **base 非依存**
    (OpenSBI wrapper + DTB だけが base 依存)。lo wrap 版を起動 → **`OpenSBI v1.2` → `Linux version 6.12.0` →
    `Run /init as init process` → `LINUX-USERSPACE-OK: init running` 到達** (`OF: reserved mem: 0x200000..0x23ffff
    mmode_resv0@200000` で firmware 予約・/memory・ロードベースが 0x200000 で整合)。⚠️ Linux は init.c が TOHOST
    sentinel を書かず idle するだけなので **TB は常に "FAIL (timeout)" を出す**が、これは想定どおりで成功判定は
    **コンソールの `LINUX-USERSPACE-OK` 文字列**。`make vl_boot BOOT_HEX=.../fw_payload_linux_lo.hex
    BOOT_MEM_BASE=2097152 BOOT_MAX=480000000 BOOT_MTIME_DIV=64` (~8 分、フル log を保存して grep)。
    ⚠️ `tests/linux/build.sh` は CRLF チェックアウトなので docker で `tr -d '\015' < build.sh | ... bash -s` で実行。
  - **→ 実機へ載せるイメージが新ベースで sim 起動することの確証。残るアドレスマップ整合作業は無し**、次は実機 bring-up。
  - **実機の 1GB `/memory` 化 (P2)**: `memory@0 reg=<0x0 0x0 0x0 0x40000000>` (1GB; firmware は 0x200000 で OpenSBI
    が予約)。0xC0xx 周辺ノードは不変。**bring-up 自体は 64 MiB DTS で十分** (上記 sim 検証済み構成をそのまま使える)。
- **次 (C-3 第三歩, 実機作業)**: ① PS FSBL/BOOT.bin で PS を起動 → ② JTAG (xsct/Vitis) で fw_payload(_linux) を DDR
  `0x200000` へロード → ③ PL bitstream コンフィグ + PL reset 解除 (core が 0x200000 からブート) → ④ Pmod JC の USB-UART で
  OpenSBI バナー→Linux→shell を観測。**最大の落とし穴は解消済** (RST_ADDR/firmware ベースを DDR 域に整合し sim 実証済)。

### ✅ C-3 第三歩 prep-A/B/C 完了 (2026-06-16): 実機 bring-up の事前準備 (実機不要・CLI 完結)
実機到着前にオフラインで潰せる準備を完了。ファイルは `boards/zybo_z720/{vitis/README.md, vivado/export_xsa.tcl}` +
実機 DTS 2 件。**Vivado/Vitis は PowerShell + 絶対パス必須**。
- **prep-A ⚠️ UART ボーレート + timebase 監査 (紙の上で潰した地雷; 最重要)**: 実機 PL=25 MHz・`MTIME_DIV=1` (mtime=25 MHz)
  が wrapper/SoC に焼かれている。16550 の bit period=`divisor*16` PL clk で 8250 ドライバが `divisor=clock-freq/(16*baud)`
  を書くため `actual_baud=25e6*baud/clock-freq` → **clock-frequency は PL clock に一致必須**。よって**実機専用 DTS**
  (`docs/opensbi/rv_soc_hw.dts`, `tests/linux/rv_soc_linux_hw.dts`) は sim `_lo.dts` と **3 定数のみ相違**: ①
  `timebase-frequency` 1000000→**25000000** (sim は `BOOT_MTIME_DIV=64` で mtime を遅くしているだけ。実機は override 無く
  mtime は実 25 MHz なので DT も 25 MHz にしないと時刻が 25 倍ずれ + HZ tick livelock 再燃)、② serial `clock-frequency`
  1843200→**25000000** (=PL clock、divisor 整合)、③ `current-speed` 115200→**57600** (25 MHz は 115200 を割り切れず
  divisor 13.56=±4% で不安定; 57600→divisor 27→25e6/432=57870 baud=**+0.47%** で安全)。**実機端末は 57600 8N1**。sim
  `_lo.dts` は TB 自己整合なので不変 (触らない)。
- **prep-B XSA エクスポート**: `export_xsa.tcl` (既存 impl_1 を `open_run` して `write_hw_platform -fixed -include_bit`
  → re-impl 無しで XSA 生成、~6s)。`build_zybo.tcl` の bit フローにも `write_hw_platform` を追加 (恒久化)。出力 =
  `rv_riscv_zybo/rv_riscv_zybo.xsa` (1.3 MB、`ps7_init.tcl/.c` + bitstream + hwh を内包、gitignore 下)。
- **prep-C FSBL + BOOT.bin**: ⚠️ **Vitis 2024.2 は classic XSCT プロジェクトフロー (`platform create`/`app create`) が
  「full Vitis installation」必須で本環境 (Vitis Standard) では不可** (`-classic option is only supported...` →
  接続タイムアウト)。→ **新 Python フロー `vitis -s fsbl.py`** に置換。**standalone platform を作るだけで FSBL が
  ブートコンポーネントとして自動生成**される (明示的 `create_app_component(template="zynq_fsbl")` は BSP が xilffs/xilrsa
  欠落で失敗するが不要)。FSBL = `ws/zybo_plat/export/zybo_plat/sw/boot/fsbl.elf` (579 KB、32-bit ARM、ps7_init+main/sd/
  qspi/image_mover でリンク)。BOOT.bin = `make_bootbin.ps1` が `.bif` を生成し bootgen 実行。**partition 構成を dump 検証**:
  FSBL(exec=OCM) → **firmware `[load=0x00200000]` exec_addr=0 (raw .bin なので A9 が RISC-V コードへハンドオフしない)** →
  bitstream **最後** (PL config で RISC-V がリセット解除される時点で firmware は DDR 常駐)。順序が肝 (firmware を bitstream
  より前に置く)。スモークテストは sim DTS の `fw_payload_lo.bin` で実施 (6.27 MB BOOT.bin 生成成功)。
- **✅ prep-E 完了 (2026-06-16)**: 実機 DTS で OpenSBI hello firmware を再ビルド → `tests/opensbi/work/fw_payload_hw.{elf,bin}`
  (entry=0x200000 を確認、DTB=1602B、25MHz/57600)。`.elf` は JTAG `dow` 用に build dir から `fw_payload_hw.elf` へ複製。
  `make_bootbin.ps1 -Firmware fw_payload_hw.bin` で **BOOT.bin を HW firmware で再生成** (6.27 MB)。
- **✅ prep-D 完了 (2026-06-16)**: JTAG bring-up スクリプト `boards/zybo_z720/vitis/bringup_jtag.tcl`。**XSDB デバッグ
  コマンド (`connect`/`targets`/`dow`/`fpga`/`mrd`/`rst`/`stop`/`con`) は本環境の xsct でも全て利用可**と確認済 (classic IDE
  プロジェクトフローだけが不可だった)。フロー = `connect`→A9 選択→`ps7_init`/`ps7_post_config` (DDR/MIO/clk)→`dow
  fw_payload_hw.elf` (0x200000 へロード、`mrd` で readback)→`fpga -file bd_riscv_wrapper.bit` (PL config→RISC-V が
  0x200000 からブート)。`ps7_init.tcl` は XSA から抽出 (gitignore、再抽出は zipfile ワンライナー、README 記載)。
- **残 = 実機作業のみ (P1)**: ① Zybo 電源 + JTAG ブートモード (or SD に BOOT.bin)、② Pmod JC に 3.3V USB-UART
  (TX=V15→アダプタ RX / RX=W15←アダプタ TX / GND 共通) を **57600 8N1** で接続、③ `xsct bringup_jtag.tcl` 実行 →
  OpenSBI バナー + `PAYLOAD: hello` 観測。詳細手順 = `boards/zybo_z720/vitis/README.md`。**実機が来ればワンショット**。
