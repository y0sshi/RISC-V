# 50 MHz 化 (ロードマップ ②) — critical path 分析と設計

> 第8セッション着手。目標 = Zybo Z7-20 のコアを 25 MHz -> 50 MHz (20 ns 周期) へ。
> 完了条件 = 実機 OpenSBI + RV64GC Linux (NET=y) が複数回連続 userspace 到達 + timing met (WNS>=0)。

## 1. critical path (確定)

OOC 見積り (`boards/report_area_timing.tcl`, xc7z020-1, RV64) の `timing_worst_paths.rpt`:
top25 全てが**単一の支配的経路**(destination bit 違い):

```
u_core/ex_mem_alu_result[*]  (EX/MEM のデータアクセス VA)
  -> [u_core] アドレス carry chain (~4.5 ns)
  -> [u_mmu]  データ TLB hit 比較  mem_tlb_hit            (累積 ~10 ns)
  -> [u_dcache] ストアヒット/タグ比較 st_hit (carry chains)
  -> c_wait -> core_dmem_wait
  -> stall_if / stall_id                                  (累積 ~18 ns)
  -> [u_csr] トラップ要因 scause/sepc -> cur_priv -> fetch_pc
  -> [u_mmu]  命令側 TLB hit 比較 if_tlb_hit
  -> [u_icache] rd_en -> BRAM ENARDEN                     (累積 ~31 ns OOC)
```

- OOC 10 ns ターゲットで WNS=-20.8 ns (route はunplaced=不正確だが logic だけで 9.87 ns/49 levels, CARRY4=18)。
- 実機 25 MHz impl では WNS=1.519 ns @ 40 ns => 最長 ~38.5 ns。同一経路とみられる。
- 50 MHz=20 ns には ~2x の短縮が必要。

### 経路の二分割
`stall_if` (= `dmem_wait` を含む) を境に:
- **前半 ~17.9 ns**: ex_mem_alu_result -> データ TLB -> D$ タグ -> c_wait -> stall_if
- **後半 ~13.4 ns**: stall_if -> trap(scause/sepc) -> fetch_pc -> IF TLB -> I$ rd_en

どちらも単独なら 20 ns 未満。両者が `stall_if` 経由で 1 サイクルに直列連結されているのが本質。

### データ側 stall の組合せ寄与 (要レジスタ化)
core の `stall_if/id/ex` に入る、ex_mem_alu_result から組合せで届く遅い信号:
1. `core_dmem_wait` (= `dc_c_wait`): D$ `hit`(PA タグ比較, `rv_dcache.sv:118,143`) に依存。
2. `mmu_stall`/`mem_stall`: `mem_xlate_pending = vm_data && mem_req && !mem_tlb_hit`
   (`rv_mmu.sv:450,460`) = データ TLB 比較に依存。
3. `mem_fault`: TLB hit 時の権限違反 (`rv_mmu.sv` 494+) -> trap -> redirect -> imem_addr -> I$。
1 と 2 は直列 (MMU が PA を出し D$ がそれでタグ比較)。3 は trap 経由で fetch を redirect。

## 2. 方針 (ユーザ確定: データ側 D$ wait をレジスタ化)

MEM 段を実質 2 サイクル化する = 全データアクセスに**保証バブル 1 サイクル**を挿入し、
hit/miss/fault の組合せ判定を**レジスタに捕捉**、c_wait/mem_stall/fault を FSM-state 駆動(高速)にする。
これで `ex_mem_alu_result -> ... -> {hit_q, fault_q}` は register-to-register パスに収まり、
stall_if/fetch/I$ へ組合せで届かなくなる。

- core は既に多サイクル `dmem_wait`/`mem_stall` を許容(ミス時の挙動)するので**原則不変**。
  保証バブルは「毎アクセスが 1-cycle ミス相当」になるだけ。+1 cycle/アクセスの IPC コストは許容。
- **非破壊性**: D$/MMU が無い bram/act SoC や vm off では D$ 自体を通らない/`dc_c_wait=0`,
  `mmu_stall` は vm off で 0。コンプラ/ユニットは結果で判定するため +1 cycle でも PASS のはず。
- **restart-livelock 対策**: 新 wait は完了が別要因 stall と衝突して再起動しないよう、
  D$/MMU FSM 内で「判定済みフラグ」を持たせる (`*_done` ラッチ思想; #14/#15/#16 と同型)。

### 実装ステップ (この順, 各ステップで回帰)
1. **rv_dcache.sv**: S_LOOKUP を「present+register(hit)」と「decide+act」の 2 相に分割。
   c_wait を FSM-state のみの関数に。-> sim_dcache(64)/sim_cache_soc(64) -> 再合成で WNS 改善確認。
2. **rv_mmu.sv (データポート)**: mem_tlb_hit/perm を登録 lookup 化、mem_stall/mem_fault を
   登録/FSM 駆動に。-> sim_mmu(64)/sim_sv(64) -> 再合成。
3. **full Linux gate** (NET=n -> NET=y): `vl_boot` で LINUX-USERSPACE-OK, amo_prem=0。
   ピンポイント: `ptw_amo_test` (AMO write-loss 非再発)。
4. 残る critical path を再測定し iterate (後半の trap->fetch->I$ や IF TLB が次に出たら対処)。
5. クロック 50 MHz 化 (BD FCLK_CLK0=50MHz) + DT timebase + sim BOOT_MTIME_DIV 整合 -> 実機検証。

## 3. 進捗ログ
- (着手) critical path 確定、本ノート作成。
- **D$ 2 相化 実装済** (`rv_dcache.sv`): S_LOOKUP -> S_LOOKUP(phase1: hit を hit_q に登録) +
  S_LK2(phase2: 登録 hit_q で判定/動作)。c_wait を FSM-state+hit_q 駆動に。
  - 回帰 PASS: sim_dcache 64/64, sim_dcache64 54/54, sim_cache_soc 6/6, sim_cache_soc64 6/6。
  - full Linux (NET=y, vl_boot, 480M cyc) gate = 実行中 (~340M cyc で hang なし・タイマ割込稼働)。

### ⚠️ 重要な方法論的知見: OOC route 推定は使えない
OOC 合成 (`report_area_timing.tcl`) の timing は **route が unplaced (配線前) で遅延の ~71% を占め非現実的**。
- D$ 変更前後: WNS は OOC では ~30.8ns -> ~30.5ns とほぼ不変に見える。
- だが **logic levels 49->44, CARRY4 18->13** に減 = D$ タグ比較 (st_hit carry chains) は確実に除去。
- => **真の timing は P&R 済 (実 impl) でしか測れない**。OOC は logic-level/CARRY4 の proxy としてのみ使う。
- 実 worst-path 絶対遅延は P&R レポートで読める (BD は 25MHz のままでも `40ns - WNS` で算出可)。
  変更前 実機 @25MHz = WNS 1.519 @ 40ns => **38.5 ns**。これを 20ns 以下にするのが目標。

### D$ 後の新 critical path (OOC, logic 参考)
`ex_mem_alu_result -> u_mmu mem_tlb_hit(データTLB) -> periph_is_periph(翻訳PA領域デコード) ->
dc_c_req -> c_wait -> stall_if -> scause -> fetch_pc -> u_mmu if_tlb_hit(命令TLB) -> mmu_imem_pa -> I$`。
D$ タグは消えたが、c_wait はまだ「翻訳 PA の領域デコード経由で c_req」に依存 = **データ TLB がまだ stall_if に組合せ到達**。

### 残る切断 (多段; 各 Linux gate 必須)
50MHz(実 20ns) には実 38.5ns を ~半減 = 複数段の register 挿入が要る:
1. ✅ **D$ 2 相化** (st_hit carry を除去)。
2. **MMU データポート バブル化** (option b, core 不変): mem_tlb_hit/mem_pa/mem_perm_ok/mem_fault/mem_stall を
   登録 lookup 化。`vm_data` でゲート (bare/M-mode は passthrough のまま非バブル)。-> データ TLB を stall_if から分離。
   ⚠️ PTW FSM・IF/MEM TLB 共有・① の ptw_for_if と相互作用 = 高リスク。要 sim_mmu/sv + Linux gate。
3. **フロントエンド (IF) 側 decouple**: fetch_pc -> if_tlb_hit(命令TLB) -> I$ も常時 fetch 側にある。
   IF TLB / I$ 要求を register 段に分離 (#15/#16 領域 = 最高リスク)。
4. 各切断後に **実 impl で worst-path 絶対遅延を測定**し iterate。20ns 到達まで。
5. クロック 50MHz 化 (BD FCLK_CLK0=50MHz) + DT timebase + sim BOOT_MTIME_DIV 整合 -> 実機検証 (verify_nety_us.tcl)。

> 規模感: 2x 周波数は 1 段では届かず、データ側 + フェッチ側の複数段パイプライン化が必要 = 複数セッション規模。
> 各段を非破壊 (`dmem_wait=0`/`imem_ready=1`/`vm off` で no-op) かつ Linux gate で検証しながら進める。

## 4. ⚠️ in-place D$ 2 相化は失敗 (revert 済) — 重要教訓

第8セッションで D$ を内部 2 相化 (S_LOOKUP phase1 で hit_q 登録 + S_LK2 で判定) したが
**full Linux gate で回帰** (init が userspace pc=0x10144 で spinlock 無限ループ、`LINUX-USERSPACE-OK` 未到達)。
→ **revert 済** (`git checkout src/rtl/cache/rv_dcache.sv`)。

### 失敗の真因 = level-req バスでの c_wait 振動
- ユニット/cache_soc は PASS (アクセス間に c_req を落とす)。**Linux だけ hang** = 典型的な
  「可変レイテンシは full Linux gate でしか露見しない」(#14/#15/#16 と同型)。
- 簡易バスは **c_req が level-high でアクセス毎の strobe が無い**。D$ は「新規アクセス」と
  「unrelated stall で MEM に保持された完了済みアクセス」を区別できない。
- 強制 2 相 (S_LOOKUP->S_LK2) は、保持された load HIT に対し FSM が S_LK2->S_LOOKUP->S_LK2 と
  往復し **c_wait/dmem_wait が毎サイクル 0/1 振動**。これが core の AMO FSM (rv_core.sv:923
  `!dmem_wait` で read->write 前進) と LR/SC 予約・cmpxchg を破壊 → atomic 喪失 → spinlock 無限ループ。
- amo_prem 検出器 (tb_rv_boot_soc.sv:322 `u_dc.state==2'd1`) は enum 再番号で **偽陽性**化
  (`2'd1` が S_FILL->S_LK2 を指す)。検出器は真の hang 原因ではない (が、enum 値ハードコードは脆い)。

### 保持 vs 新規の区別には address 依存項が不可避 (in-place の限界)
- 「保持された同一 load (c_wait=0)」と「新規アクセス (c_wait=1 バブル)」の区別には、c_wait に
  **同一アクセス判定 (c_addr==addr_q 等値 or core からの strobe)** が必須。
- tag 比較を addr 等値に置換しても、**c_addr=翻訳 PA なのでデータ TLB は c_wait 経路に残る**。
  そもそも **主要因はデータ TLB**で tag 比較は副次的だった (D$ 変更後 OOC で logic 49->44, CARRY4
  18->13 と確かに減ったが、新 worst path は依然 mem_tlb_hit -> ... -> stall_if -> fetch -> I$)。

### 改訂方針 (次セッション)
in-place な wait 登録は不可。**core 協調 or より深い再構成**が要る。候補:
1. **core が per-access strobe を D$/MMU に供給**: core は EX->MEM 前進で「新規アクセスの先頭サイクル」を
   一意に知る。これを使えば D$/MMU が振動なく登録 lookup できる。ただし AMO/mal FSM が 1 命令で複数
   D$ アクセスを多重化するため strobe 生成は非自明。
2. **early-EX キャッシュ/TLB lookup**: アドレスを EX 末で得て tag/TLB を EX 段で引き、hit を EX/MEM に
   登録 = サイクル増無しで MEM 段クリティカルパスから除去。要 MMU 翻訳も EX 段化 = 中規模再構成。
3. **データ側 + フェッチ側の本格パイプライン化** (decoupled front-end / load-store unit)。最大規模。
- いずれも **データ TLB を最優先**で stall_if から分離すること (tag 比較より TLB が支配的)。
- **教訓**: 簡易 level-req バスに対し「FSM 強制 2 相」は振動を生む。新規アクセス境界は **core 側でしか
  一意に分からない**。必ず full Linux (NET=y) gate + ptw_amo_test で atomic 健全性を確認 (amo_prem 検出器は
  enum 非依存に直してから使う)。

## 5. approach (1) = core 協調 strobe (実装中; 第8セッション)

ユーザ確定。core が per-access STROBE `dmem_acc_new` を生成し D$ (将来 MMU も) に渡す:
- **rv_core**: `dmem_acc_new = (ex_adv_q & dmem_req) | amo_started | mal_phase1_start`。
  全て**レジスタ由来**(ex_adv_q=`~stall_ex` の登録, amo_started=amo_state 立上り, mal_phase1_start 既存)で
  c_wait からの組合せループ無し。新命令の先頭 MEM サイクル / AMO read->write / mal phase0->1 を一意にマーク。
  保持アクセスは ex_adv_q が落ちるので再 pulse しない = **振動しない**。
- **配線**: rv_core -> rv_cpu -> rv_soc -> D$ `c_new` (bram/act は未接続 = no-op)。
- **rv_dcache**: enum を `{S_IDLE,S_LK2,S_FILL,S_RELOOKUP,S_WRITE}` 化。`new_acc = c_req & (c_new | acc_pending_q)`。
  S_IDLE で new_acc 時のみ hit を hit_q 登録し S_LK2 へ。c_wait は FSM-state + 登録 hit_q 駆動 (tag 比較を除去)。
  `acc_pending_q` が strobe を PTW 越しにラッチ (PTW 中は c_req 抑制されるため)。
- **TB**: tb_rv_dcache に c_new=c_req 立上り、boot TB の amo_prem を `state==3'd2`(S_FILL) に修正。

### 回帰 (第8セッション)
- ✅ sim_dcache 64/64, sim_dcache64 54/54, sim_cache_soc 6/6, sim_cache_soc64 6/6。
- ✅ sim_pipeline 19, sim_amo 29, sim_amo64 38, sim_mmu 28, sim_mmu64 11, sim_sv 46, sim_sv64 46, sim_intr,
  sim_soc 3。Verilator mini-SBI boot PASS (data reads=4 基準一致)。
- ⏳ full Linux (NET=y) gate = 実行中。**振動が消えたか (前回 0x10144 spin 回帰) を判定。amo_prem=0 必須**。

### ⚠️ 重要: これは「振動を除いた正しい D$ 切断」= 足場
c_req は依然データ TLB に依存するので **TLB は c_wait に残る** = timing の主要因は未除去。
**次 = 同じ strobe を使った MMU データポートの登録 lookup** (TLB を stall_if から分離; 本当の timing win)。
その後に実 impl で worst-path 絶対遅延を測定。

### ❌ strobe 版も full Linux で回帰 (別の潜在 core デッドロックを露見)
- ✅ **amo_prem=0 達成** (atomic 喪失は解消) + **full kernel boot 成功** (全ドライバ初期化, "Run /init")。
- ❌ だが **userspace handoff (S->U の SRET) でデッドロック**。`LINUX-USERSPACE-OK` 未到達 (fetch_pc=0x10144 固定)。
- **真因 (BOOT_DCWIN トレースで特定)**: D$ は正常 (load 完了, rdq=正データ, st=S_IDLE)。デッドロックは core の
  redirect/SRET/priv 経路:
  ```
  SRET で fetch_pc<-0x10144(U-page) + priv<-U(commit 遅延)。priv=S のまま 0x10144 を評価
    -> if_fault/未転送 -> imem_ready=0 -> stall_ex=1 -> SRET が commit 不可 (csr_commit_ex=~stall_ex)
    -> priv が S 固着 -> 循環デッドロック。redirect_stall(redirect_settle) も any_redirect 固着で stuck。
  ```
  私の **+1 cycle が load retire を遅らせ、SRET commit サイクルを ~imem_ready=1 と衝突**させて潜在バグを露見
  (#14/#15/#16 と同族 = 可変レイテンシ依存)。トレース: `boards/reports/vl_boot_trace.log` の c420000000 付近
  (`sex=1 imrdy=0 dwait=0 rds=1 fpc=0x10144 priv=1 ifreq=0`)。

### 戦略的結論 (第8セッション)
+1 cycle D$ アプローチ (in-place / strobe いずれも) は **複数の潜在 core デッドロックを次々露見** (amo_prem ->
strobe で解消 -> 今度は SRET handoff)。しかも得られる timing 利得は **副次的な D$ tag 除去のみ** (主要因の
データ TLB は別途登録が必要で、それはさらに侵襲的に同種バグを露見させる公算大)。
=> **コスト/利得が見合わない。strobe work は stash で保全し tree は baseline に戻す**。
次の選択 (要ユーザ判断):
1. **core デッドロックを根治**して strobe を完成 (SRET/priv commit を post-redirect の ~imem_ready で
   ブロックさせない等; ifpf_take 風の bypass を SRET にも)。strobe は atomic 解消済で 95% 動作。高リスク core 手術。
2. **early-EX キャッシュ/TLB lookup へ pivot** (D$ レイテンシ不変 = この潜在デッドロック群を回避)。中規模再構成。
- strobe work の stash: `git stash list` で "freq50_strobe_*" を pop して再開可。

### ✅ SRET handoff デッドロック修正 (ユーザ判断 = 根治を選択; 第8セッション)
`rv_core.sv` の `redir_req` で **MRET/SRET の redirect を `~stall_ex` でゲート** (`ex_mret_en && ~stall_ex` /
`ex_sret_en && ~stall_ex`)。priv 変更 (rv_csr の mret_en/sret_en = `ex_*_en & csr_commit_ex`) と redirect を
**atomic** にし、commit 前に target(U-page)へフェッチして faulting する循環を断つ。held 中は redirect せず
fetch は sequential(fetch可能 S-page)に留まり imem_ready=1 → stall_ex 解消 → xRET commit。
**非破壊**: common case (xRET が stall_ex=0 で commit) はゲート=1 で従来同一。
- 回帰 PASS: sim_csr 16, sim_sv 46, sim_sv64 46, sim_intr, sim_pipeline, sim_dcache(64), sim_cache_soc(64),
  sim_amo 29/64, sim_soc 3。
- ✅ **full Linux (NET=y) gate PASS**: `LINUX-USERSPACE-OK: init running` 到達 (chars=11428, pc=0x1016a idle =
  **baseline と完全一致**)。**amo_prem=0, HARM=0**。SRET handoff デッドロック解消を確認。
- ✅ ptw_amo_test (① 回帰): **amo_prem=0, HARM=0** (AMO write-loss 非再発。"no sentinel" は focused repro が
  boot sentinel を持たないためで想定通り; 判定は amo_prem)。

## 6. 第8セッション 成果まとめ & 次の一手
**✅ 達成 (機能的に完全動作・非破壊検証済)**:
- core 協調 per-access strobe (`dmem_acc_new`) + D$ 登録 2相 lookup (振動なし) = **データ側 D$ tag を c_wait
  から除去** (level-req バスの振動問題を strobe で解決)。
- 副産物: **潜在 core デッドロック (SRET handoff) を発見・根治** (`redir_req` の MRET/SRET を `~stall_ex` ゲート)。
  これは可変レイテンシ一般で踏みうる real bug (baseline でも別タイミングなら踏みうる)。
- 全ユニット + full Linux NET=y userspace + ① ptw_amo_test で検証。

**⚠️ ただし timing 利得は副次的 (D$ tag のみ; logic 49->44, CARRY4 18->13)**。主要因の **データ TLB は未着手**。

**次の一手 (本当の 50MHz timing win)**:
1. **MMU データポートの登録 lookup** = 同じ strobe (`dmem_acc_new`) を MMU に渡し、mem_tlb_hit/mem_pa/
   mem_perm_ok/mem_fault/mem_stall を登録判定化 (vm_data ゲート、bare は passthrough)。これでデータ TLB を
   stall_if から分離 = critical path の主要因を切る。strobe 基盤は実証済なので振動は出ない。⚠️ PTW FSM/IF・MEM
   TLB 共有/① の ptw_for_if 相互作用 + **同種の commit-gate デッドロックが再発しうる** (各変更後に full Linux gate)。
2. **実 impl で worst-path 絶対遅延を測定** (OOC route は無効; P&R で `40ns - WNS` を読む)。38.5ns -> ? を定量化。
3. フェッチ側 (IF TLB) の decouple が次に critical なら対処。
4. クロック 50MHz 化 (BD FCLK) + DT timebase + sim BOOT_MTIME_DIV + 実機 verify_nety_us.tcl。

**コミット**: strobe(rv_core/cpu/soc/dcache) + redirect-gate(rv_core) + TB(tb_rv_dcache c_new, tb_rv_boot_soc
amo_prem `3'd2`) は機能完成・非破壊。ユーザがコミット。

### 着手前の実 impl 確認 (第9セッション)
step-1 (D$ tag 登録) commit `0238beb` の `build_zybo.log` (Jun 20, 25MHz=40ns) 最終 route:
**WNS=0.370 / WHS=0.021** (worst path ~39.6ns)。baseline WNS=1.519 (~38.5ns) と比べ改善なし
(配置ノイズ範囲)。= 設計予測「D$ tag 利得は副次的・主要因はデータ TLB」を impl が裏付け。データ TLB 切断が本丸。

## 7. MMU データポート登録 lookup (第9セッション 実装)

ユーザ確定の方針 1 を実装。**データ TLB compare を stall_if クリティカルパスから分離**する。

### 設計 (直列2段: MMU 翻訳 → D$ タグ; 各々独立サイクル)
- **strobe 配線**: rv_core の生 strobe (`dmem_acc_new`) を rv_cpu 内で `core_dmem_acc_new` に改名し
  **MMU の新 input `mem_acc_new`** へ。MMU は登録翻訳が valid になるサイクルに **遅延 strobe `mem_acc_new_out`**
  を出し、これを rv_cpu の `dmem_acc_new` 出力 = D$ の `c_new` にする (**rv_soc/rv_core は無改変**; D$ の
  c_addr=`mmu_dmem_pa`/c_req=`mmu_dmem_req`/c_new=`dmem_acc_new` が全て rv_cpu 出力経由のため自動で直列2段化)。
- **rv_mmu MEM ポート登録化** (`vm_data` ゲート):
  - `mem_new_strobe = vm_data & mem_req & mem_acc_new`。
  - `mem_can_capture = vm_data & mem_req & mem_tlb_hit & (mem_new_strobe | mem_pend)` — TLB hit が出た時
    (strobe 直後 or PTW fill 後) に翻訳結果を `mt_ppn/mt_perm/mt_we/mt_voff` へ捕捉、`mt_valid<=1`。
  - `mem_pend` = strobe 受領済だが未捕捉 (TLB miss→PTW の間ラッチ; D$ の acc_pending と同型)。
  - `mem_reg_ready = vm_data & mt_valid & ~mem_new_strobe` — fresh strobe のサイクルは必ずバブル (capture cycle)、
    翌サイクルから登録値を present。
  - **MEM port 出力**: `mem_reg_ready` 時は登録値 (mt_pa_xlat/mt_perm) を駆動、それ以外 (capture バブル/PTW 中)
    は req_out=0 + mem_stall。PTW page fault は従来通り register-driven (`ptw_fault_r`)。
  - `mem_stall = vm_data & mem_req & ~mem_reg_ready & ~mem_fault` — **登録値駆動** (live TLB compare を除去)。
  - `mem_acc_new_out = vm_data ? (登録 mem_can_capture pulse) : mem_acc_new`。
- **コスト**: VM データアクセス毎に **+1 cycle** (capture バブル; D$ の +1 と直列で計 +2 vs 全組合せ baseline)。
  IPC コスト許容。**非破壊**: vm off (bare/M-mode/bram/act) は組合せ passthrough = 厳密 no-op、strobe も素通し。
- **振動なし**: capture は core strobe (+pend) でゲート、level mre_req では無い (第8セッション strobe 基盤の踏襲)。
- **PTW/launch は不変** (combinational `!mem_tlb_hit` で起動 = register 終端なので critical path 外)。

### 検証 (第9セッション)
- ✅ 全ユニット: sim_mmu 28, sim_mmu64 11, sim_sv 46, sim_sv64 46, sim_dcache 64/54, sim_cache_soc 6/6,
  sim_amo 29/64, sim_pipeline 19, sim_csr 16, sim_intr 9, sim_soc。
  - tb_rv_mmu: 新 strobe を `mem_req` 立上りで自動生成 + MEM テストを +1 cycle/再アクセス化 ([8])。
- ✅ ptw_amo_test (① AMO 回帰): **amo_prem=0, HARM=0** (AMO write-loss 非再発)。
- ⏳ full Linux NET=y gate: 実行中 (`vl_boot_mmureg.log`)。LINUX-USERSPACE-OK + amo_prem=0 を判定。
- ⏳ rv64si-p (page fault trap 系)。
- 次: gate PASS なら **実 impl 再合成で worst-path 絶対遅延を再測定** (38.5ns -> ? = データ TLB 切断の効果)。

## 8. ⚠️ 第9セッション: full-system 回帰 = 登録 MEM ポートは複数の correctness バグを露見

ユニットは全 PASS だが **full Linux NET=y / rv64si-p-icache-alias が回帰**。3 つの別個バグを露見 (handoff
が予告した「mem_fault/mem_stall 登録遅延 → commit-gate デッドロック」領域そのもの):

1. **eviction → spurious data PTW (= HARM / ストア喪失)** [修正済]: in-flight な提示済アクセス (mt_valid=1) の
   データ TLB エントリを、**並行する IF-PTW の round-robin fill が evict** → live `mem_tlb_hit` が 0 に落ちる →
   PTW_IDLE が同一アクセスへ **spurious data 再翻訳 PTW** を起動 → これが `core_dmem_wait` をマスク (rv_soc)。
   baseline は live `!mem_tlb_hit` 由来の mem_stall で再ホールドしたが、**登録版 mem_stall は mt_valid 駆動なので
   再ホールドせず** → held store が S_WRITE 完了前に retire = **ストア喪失** (Linux で HARM=746, userspace 未到達)。
   → 修正: PTW のデータ起動条件を `&& !mem_reg_ready` でゲート (提示済アクセスは captured PA 固定で再翻訳不要)。
2. **stale mt_valid** [修正済]: `mt_valid`/`mem_pend` が `!mem_req` でクリアされず張り付く → 次アクセスに漏れる。
   → 修正: クリア条件を `if (!vm_data || !mem_req)` に拡張。
3. **登録 mem_fault の commit-gate デッドロック (= SRET handoff と完全同型)** [修正済]: rv64si-p-icache-alias の
   `sw x0,(x0)` は **意図的なストアページフォルト** (mtvec_handler が cause==15 を確認して `jr a2` で復帰する仕組み;
   ソース確認済)。私の登録 mem_fault は **+1 サイクル遅延** (strobe 時 bubble → 翌サイクル提示) するため、その
   bubble サイクル (stall_ex=1) に **先行する younger 命令 (illegal, EX 段) のトラップ redirect が mtvec=0x80000004
   へ発火 (redir_req が ~stall_ex 非ゲート)** → priv=S のまま M-mode ハンドラを翻訳フェッチ → IF-PTW で
   imem_ready=0 → stall_ex 固着 → `csr_commit_ex=~stall_ex=0` でトラップ commit 不可 → priv が S 固着 → 無限ループ。
   **baseline は store fault が bubble 無しで即 commit するため priv→M が先行し、ハンドラを M-mode で
   passthrough フェッチ**。トレース: `tb_rv_act_debug` cyc 159-160 (mem_trap=1 だが sex=1/commit=0 固着)。
   → **修正 (`rv_core.sv` redir_req)**: `(ex_trap_enter || mem_trap_enter)` の trap redirect を **`~stall_ex` でゲート**
   (SRET 修正と同思想)。held 中 (stall_ex=1) は redirect せず hold (younger branch の横取りも明示 hold で抑止)、
   stall_ex が落ちた提示サイクルで **priv commit と redirect を atomic** に。**非破壊**: 通常 (trap が stall_ex=0 で
   commit) はゲート=1 で従来同一。→ icache-alias で priv→M 遷移確認・**rv64si-p 7/7 PASS**。

### 評価 (第9セッション)
- **登録 MEM ポートが露見した 3 バグはすべて可変レイテンシ依存** (eviction race / stale state / commit-gate
  deadlock)。#1/#2 は MMU 内で、#3 は **redir_req のトラップ redirect を `~stall_ex` ゲート** (SRET と同型の
  core 手術) で根治。全て **vm off / 即 commit の baseline では厳密 no-op**。
- **検証**: 全ユニット (mmu/sv/csr/intr/pipeline/dcache/cache_soc/amo) + rv64si-p 7/7 PASS。
  rv64mi-p は **13/17 で baseline と不変** (breakpoint/csr/illegal/instret_overflow は **baseline でも fail =
  既存; breakpoint は baseline 単発でも `TEST FAILED testnum=2` を確認**。CLAUDE.md の "14/17" は breakpoint を
  漏らした記載ミス)。= 非破壊確認。
- **教訓**: 登録 mem_fault/mem_stall の +1 遅延は、トラップ/priv-commit が「誤 priv で redirect target を
  フェッチ→fault→stall_ex 固着→commit 不可」の **commit-gate デッドロック** (#SRET 族) を必ず誘発する。
  redirect を `~stall_ex` でゲートして commit と atomic 化するのが定石。

### ✅ 実 impl 測定 (第9セッション; データ TLB 登録の効果 = critical path が移動)
`build_zybo` (25MHz=40ns, 全フロー synth→impl→bit) 最終 route:
- **WNS=1.130 / WHS=0.026** (worst path = 40-1.130 = **38.87ns**)。step-1 baseline WNS=0.370 (39.63ns) から
  **+0.76ns 改善**。
- **routed checkpoint の worst-path 詳細** (`report_worst.tcl`): **critical path が完全に移動した**:
  - 旧 (step-1): `ex_mem_alu_result → データTLB → ... → stall_if → trap → fetch → IF TLB → I$`。
  - **新**: `gen_dcache.u_dc/data_reg (D$ load データ BRAM 読出レジスタ) → ... →
    u_core/ex_mem_fpu_result_f_reg[29]/D` (datapath 38.151ns; logic 10.455ns/route 27.696ns=72%; 45 levels,
    CARRY4=14)。= **D$ load データ → FP フォワード → ex_mem_fpu_result** 経路。
  - => **データ TLB 登録は意図通り「`ex_mem_alu_result → データTLB → stall_if`」を critical path から除去**。
    だが並行して同程度に長い **load データ → FPU フォワード経路**が残っていたため全体 WNS 改善は小。
- **次の一手 (第10セッション候補)**: 新 critical path = **D$ load データ rdata_q → FP フォワード →
  ex_mem_fpu_result_f レジスタ** (route 72% = FPGA 横断の長い組合せチェーン)。FP load-use フォワードの
  レジスタ段挿入 or FPU 入力フロップ化で切る。その後また再測定 (次の path へ iterate)。20ns 到達には依然
  複数段が必要 (data TLB / load-fwd / IF-side TLB ... を順に切る複数セッション規模; 第8セッションの見立て通り)。

### 第9セッション成果まとめ
- **MMU データポート登録 lookup を機能完成 + 非破壊検証** (全ユニット / rv64si-p 7/7 / full Linux NET=y
  userspace HARM=0 amo_prem=0 baseline 一致)。露見した 3 バグ (#1 eviction-PTW / #2 stale-mt_valid /
  #3 trap commit-gate deadlock) を全て根治。
- **実 impl で「データ TLB を critical path から除去」を実証** (path が D$-load→FPU フォワードへ移動)。
  WNS 0.370→1.130。50MHz には次 path (load-fwd) 以降の段も要 = 継続。

## 9. FP-load 遅延 writeback (第10セッション; 新 critical path = D$-load→FP フォワードを切る)

ユーザ確定の方針 = **「FP load のみ遅延」+「1 段だけ確実に切る」**。第9で移動した新 critical path
(`D$ data_reg → wb_freg_data → FP datapath → ex_mem_fpu_result_f`, 38.15ns, route 72%) を切る。

### 設計 (構造の本質: D$-read データを core 境界でレジスタ捕捉)
精査で判明: `wb_freg_data` (= FP-load データ, dmem_shifted 由来) は **2 つの組合せ sink** に入る ―
① FP forward mux (MEM/WB tier) と ② `rv_fregfile` の write-through (`rd_data`→WT→`rs_data`)。
→ **FP forward だけをレジスタ化しても WT 経路に同じ D$→core の長配線が残る**。よって route を切るには
**FP-load データを core 境界の register に捕捉する = FP load の writeback を 1 サイクル遅延**させるのが構造的に必須。

- **`rv_core` fpld レジスタ**: FP load の値 (`wb_freg_data`) をその FRESH WB サイクル (`mem_wb_fresh &
  mem_wb_valid & freg_write & fp_load`) に `fpld_we_q/fpld_rd_q/fpld_data_q` へ捕捉。
  これが**唯一 dmem_shifted が FP datapath に入る点**で、ここで route が分割される
  (`data_reg`(D$, BRAM 近傍) → `fpld_data_q`(core 内 flop) が cycle1、以降が cycle2)。
  `fpld_we_q` は 1 サイクルパルス。FP load は既に retire 済なので **flush でキャンセルしない** (post-commit writeback)。
- **`rv_fregfile` 第2 write port (B)**: 遅延 FP-load writeback 専用 (WT 付き)。on-time port (A) は **FP 計算結果
  のみ** (`mem_wb_fpu_result_f` = register; dmem 経路を完全排除)。FP load は A より 1 サイクル遅いので同一 freg
  への同サイクル衝突がありうる → program order で load が古い → **A が優先** (commit/WT とも last-assign で A 勝ち)。
- **`rv_forward`**: FP MEM/WB forward から **fp_load を除外** (`&& !mem_wb_ctrl.fp_load`)。最低優先の
  **fpld tier (sel 2'b11)** 追加 ― より若い FP producer (EX/MEM, MEM/WB) が無いときのみ `fpld_data_q` を forward。
- **`rv_hazard`**: FP-load を **MEM 段でも検出** (`ex_mem_ctrl.fp_load`)。FP load-use は **N=1 で 2 stall・N=2 で
  1 stall** に延長 (load が WB に達するまで consumer を保持; その後 fpld forward(EX, T+3)/WT(ID, T+3)/regfile で供給)。
- **タイミング検証** (T=FLW EX): FLW WB=T+2(fresh, fpld 捕捉)、fpld_we_q=T+3。consumer は EX@T+3 (N≤2 は stall で
  到達) で fpld forward(sel11)、ID@T+3 (N=4) は port-B WT、ID≥T+4 は regfile。在順 + port 優先で WAW/上書きも正。

### コスト/非破壊
- **整数 load の IPC コスト 0** (FP-only)。FP load-use のみ +1 cycle stall (FP-heavy コードのみ影響)。
- **非破壊**: fpld は FP load 時のみ active、整数/AMO/MMU/regfile 経路は無改変。Linux は FP 未使用 →
  **Linux gate は bit 一致** (実測: userspace 425M cyc = 第9 baseline と同一、chars=11428/pc=0x1016a, HARM=0,
  amo_prem=0)。FP 正しさは FP ユニット + RV32/RV64 compliance で担保。

### 検証 (第10セッション; 全 PASS)
- ✅ FP: sim_fpu_pipe 7/7 (load-use stall T4・FMADD rs3 fwd T5 含む), sim_fpu 94, sim_fpu_d 33, sim_pipeline 19。
- ✅ compliance FP 実コード: rv64uf-p 11 / rv64ud-p 12 / rv32uf-p 11 / rv32ud-p 10 (ldst・fmadd・move・
  structural・RV32 mal_wide FLD 含む = FP load-use の実プログラム網羅)。
- ✅ 非破壊: sim_dcache(64) 64/54, sim_cache_soc(64) 6/6, sim_amo 29/64, sim_mmu(64) 28/11, sim_csr 16,
  sim_intr 9, sim_sv(64) 46/46。
- ✅ **full Linux NET=y gate**: `LINUX-USERSPACE-OK: init running`, HARM=0, amo_prem=0, userspace 425M cyc
  = baseline 完全一致。
### ✅ 実 impl 測定 (第10セッション; FP-load forward 経路の除去 = critical path が I$ 側へ移動)
`build_zybo` (25MHz=40ns, 全フロー synth→impl→bit) 最終 route:
- **WNS=2.968 / WHS=0.030** (worst path = 40-2.968 = **37.03ns**)。第9 baseline WNS=1.130 (38.87ns) から
  **+1.84ns 改善** (予測 ~1ns を上回る)。
- **routed checkpoint の worst-path 詳細** (`report_worst.tcl` → `report_worst_fpld.log`): **FP path は完全消滅**:
  - 旧 (第9): `gen_dcache.u_dc/data_reg → ... → ex_mem_fpu_result_f_reg` (D$-load→FP forward, 38.15ns)。
  - **新**: `u_core/ex_mem_alu_result_reg[0] → (sc_success0 → core_dmem_req → u_csr periph_rdata/lcr 群) →
    gen_icache.u_ic/line_reg_2_1/ENARDEN` (datapath 35.679ns; logic 7.292ns/route 28.387ns=**80%**; Slack MET
    2.989ns)。= **データアクセス VA/制御 → I$ line BRAM の enable (ENARDEN)** 経路。
  - => FP-load forward の除去は意図通り。新 worst は **データアクセス系信号が I$ line_reg の write/read enable に
    組合せ到達**する経路 (第9 で「I$ line_reg 35.9-37.9ns で続く」と予告した群が worst 化)。route 80% は不変
    (FPGA 横断の物理距離が依然支配)。
- **次の一手 (第11セッション)**: 新 worst = `ex_mem_alu_result → core_dmem_req → u_csr periph デコード
  (periph_rdata/lcr; UART LCR 等 MMIO read mux) → I$ line_reg ENARDEN`。① u_csr の periph read 経路が
  ex_mem_alu_result に組合せ依存している点を調査・分離、② I$ の line_reg enable をデータ系信号から decouple。
  route 80% なので register 段挿入が要。20ns には更に IF-side TLB / 整数 load-fwd 等を順に切る複数セッション規模。

### 第10セッション成果まとめ
- **FP-load 遅延 writeback を機能完成 + 非破壊検証** (FP ユニット全 + RV32/RV64 FP compliance + full Linux NET=y
  userspace HARM=0 amo_prem=0 baseline 完全一致)。整数 load の IPC コスト 0。
- **実 impl で「D$-load→FP forward を critical path から除去」を実証** (path が I$ line_reg へ移動)。
  WNS 1.130→2.968 (+1.84ns)。50MHz には次 path (I$ line_reg) 以降の段も要 = 継続。

## 10. ❌ 第11セッション: データ側 stall のレジスタ化は袋小路 (revert 済み — 重要教訓)

第10 後の実 worst-path (routed DCP, `report_worst_fpld.log`) を 3 等分で確認:
- **① データ側 (5→17ns)**: `ex_mem_alu_result -> sc_success0(SC 予約アドレス比較) -> core_dmem_req ->
  periph 領域デコード/D$ new_acc -> dc_c_wait`。
- **② redirect/PC mux (17→27ns)**: `dc_c_wait -> stall -> trap/redirect target mux(sepc/cur_priv/redir_pend) -> fetch_pc(imem_addr)`。
- **③ IF-TLB+I$ (27→38ns)**: `imem_addr -> IF TLB 16-way compare -> mmu_imem_req -> I$ addr_q_en -> line_reg ENARDEN`。
- route 80%。三等分はほぼ等長 (~11-12ns ずつ)。**1 段の register では 20ns に届かず** (どこで割っても片側 >20ns)。

**狙い**: ① の `dc_c_wait`(live, データ領域) を `stall_if` から外し、**登録信号 `data_acc_freeze`** に置換して
データ領域→IF の長配線を flop で分断する。`data_acc_freeze = data_acc_first | mem_occ` (両方 register 由来,
sc_success 非依存):
- `data_acc_first` = アクセスの MEM 進入サイクル (`ex_adv_q & (mem_read|mem_write|is_amo) | amo_started | mal_phase1_start`)。
- `mem_occ` = SET(進入)/HOLD/CLEAR(`~stall_ex`=retire) ラッチ。**uncached/I$-fill で dmem_wait が進入後に遅れて
  立ち上がる**ケース (ロードが ~imem_ready で凍結中に bus アクセスが後から wait を上げる) も全期間カバー
  (単純な `dmem_wait_q` 1サイクル履歴では取りこぼし → under-stall → 命令喪失 = cache_soc uncached で corruption)。

**結論 = あらゆる変種が破綻 (revert 済み)**。登録 stall は本質的に **+1 over-stall** (立ち下がりが register で 1
サイクル遅れる) を生み、それが:
1. **`stall_if/id` のみ置換 (decouple)**: `stall_id`(IF/ID・ID/EX gate) が `stall_ex`(EX/MEM gate) と発散し、
   over-stall サイクルで **保持された ID/EX を前進中の EX/MEM が再キャプチャ = 命令重複** (`sim_cache_soc` で値
   corruption。`[DUP]` 検出器で確認: 同一 pc が EX/MEM へ 2 連続 advance)。BRAM では冪等命令に当たり PASS する
   ことがあるが HW では危険。
2. **+ `flush_ex` で重複防止**: `flush_ex` は ID/EX をバブル化するが、**多サイクル EX 演算 (FDIV/divide) を計算前に
   EX→MEM へ早期排出** → 結果未計算 (`sim_fpu_pipe` T6 で FDIV→FSW の f8=X。t=575 で FSW f7 が MEM 在席中に
   `data_acc_first`→flush_ex が FDIV(pc=0x48) を MEM へ排出)。D$ 経路は entry が `stall_ex=1` で flush_ex 抑止
   され retire のみ発火するため非発火だが、BRAM(no-wait)経路で発火。
3. **3 stall 全て置換 (lockstep, flush_ex 無)**: `stall_ex` にも over-stall が入り **全データアクセスに EX バブル**
   → load データ capture / forwarding / load-use タイミングが破壊 (`sim_fpu_pipe` 0/7, `sim_pipeline` 15/19,
   `sim_cache_soc` 失敗)。

= **データ側 stall 操作は本質的に「登録 stall の +1 over-stall ↔ パイプラインの多サイクル EX 段 / 厳密 load
タイミング」と非互換**。`stall_if/id/ex` を触る方向は放棄。

**次の方向 (候補)**:
- **(B) IF 2 段化 (= 元の approach a)**: `imem_addr` を真のパイプライン register 段にし、③(IF-TLB→I$) を独立
  サイクルへ。stall/EX 相互作用に触れず redirect-latch(#15/#16 既存機構)で flush。**最高リスクだが stall 袋小路
  を回避**。ただし 1 段では ①②(~22ns)が残るので、② も別途切る必要 = 複数段。
- **(C) imem_addr mux SELECT のみ登録 + fetch_pc を live stall で gate** (stall 本体は不変)。stall の dup/EX
  問題に触れない。代償 = stall 中に I$ が seq_pc を無駄フェッチ (IF/ID 凍結で無害)。I$ addr_q トラッキング
  (fetch_pc 同期) との相互作用が要検証 (中リスク)。
- ⚠️ いずれも IF 側 = #15/#16 領域。着手前にユーザ確認推奨。

### ❌ approach (C) も over-stall 重複の壁 (第11セッション後半; revert 済み)
`imem_addr` の SELECT を `imem_hold`(= stall_if の dmem_wait を登録 `data_acc_freeze` に置換)で駆動し、stall 本体
(stall_if/id/ex)は live のまま不変にした。狙い通り **stall の dup/EX 問題には触れない**(パイプラインは baseline 動作、
FDIV も無傷)。しかし `imem_hold ⊇ stall_if` の **+1 over-stall** サイクルで `imem_addr=fetch_pc` を保持したまま
パイプラインが前進(stall_id=0)→ **IF/ID が in-flight 命令を再フェッチ・再キャプチャ = 重複フェッチ**。
- **flush_id で殺そうとすると数が合わない**: 1 サイクル flush(`imem_hold & ~stall_id`)は **全機能テスト PASS**
  (pipeline 19/cache_soc 6/fpu_pipe 7、uncached corruption 含む)だが `[DUP]` 検出器で残存重複(pc=0x08 等;
  多くが偶然冪等=add rd,rs,rs/SPIN/flushed でテストは通る)。2 サイクル flush(`held_dup_q` 追加)は **過剰 flush で
  実命令喪失**(pipeline 17/19)。
- **真因 = 重複スパンがメモリレイテンシモデル依存**: pipeline は `rv_soc_bram`(I$ 無し)で imem_rdata(M+1) も
  stale → 重複 2 サイクル。`rv_soc`(I$ 有り)は rv_icache FSM(addr_q/c_ready)依存で 1 サイクル。**単一の flush 数では
  両モデルを正しく殺せない** → 精密な flush は fetch/I$ パイプライン状態の完全モデル化が必要 (#15/#16 の深部)。

### 第11セッション結論 = データ側/SELECT 登録は共に over-stall 重複で袋小路 → 残るは IF 2 段化のみ
**登録した fetch 制御信号は本質的に +1 over-stall(登録ゆえ live の立ち下がりに 1 サイクル遅れる)を生み、その +1 が
重複(EX 段 or IF/ID 段)を作る。重複を精密に殺すのは pipeline/memory レイテンシ依存で困難**。= ①データ側 stall も
③SELECT 登録も同根で破綻。**route(長配線)を割るには route 上に register を置くしかなく、それは imem_addr→I$ 経路の
register = IF 2 段化(B)**(over-stall 近似でなく真のパイプライン段。redirect-latch で flush、stall 過近似が無いので
重複しない)。次セッションは **(B) を本腰で設計するか、50MHz を一旦保留して他ロードマップ項目**を選ぶ。worst=37.03ns
で 20ns には B でも複数段(①②も別途)要 = 大規模。

## 11. (B) IF 2 段化 = decoupled fetch (フェッチバッファ) 設計 (第12セッション着手予定)

### 課題: imem_addr 単純登録は可変長 RVC フィードバックを壊す
現行 fetch は **単一 `fetch_pc` + 組合せ `seq_pc = fetch_pc + (imem_rdata[1:0]==2'b11 ? 4 : 2)`** の 1 サイクル
フィードバックループ (`rv_core.sv` IF 段)。worst path ① (データ stall→`stall_if`→`imem_addr` select) を切るために
`imem_addr` を登録 (`imem_addr_q`→I$) すると、**rdata が 1 サイクル遅れ、次アドレス計算 (seq_pc は現命令の length に
依存) が間に合わず、命令毎にフェッチ 2 サイクル化 = スループット半減** (+100% IPC、不可)。= 「fetch ループに register
を挿入すると、可変長フィードバックがループ遅延を許容できない」。real RVC コアと同じ問題。

### 解 = decoupled fetch (フェッチを I$ と自由走行させ、FIFO で decode stall を吸収)
フェッチループ (~13ns, 1 命令/cyc) は**現行のまま据え置き**、データ stall を**フェッチ経路から完全に外す**:
- **フェッチエンジン (自由走行)**: `imem_addr = redir_eff ? redir_eff_tgt : (fetch_full ? fetch_ptr : seq_pc)`。
  **`stall_if`(=データ stall ①)を含まない**。hold は `fetch_full`(FIFO 満杯 = ローカル登録信号, 高速)のみ。
  `fetch_ptr`(現 `fetch_pc` 相当) は imem_ready で advance。可変長 `seq_pc` は据え置き (フィードバック維持)。
- **フェッチ FIFO (2-4 段)**: I$ から来る `{pc, inst, if_fault}` を push。`fetch_full` で backpressure。
  redirect で flush (全 valid クリア + `fetch_ptr<=tgt`)。straddle/RVC 窓・`redir_pend`/`redirect_settle` は
  フェッチエンジン側に温存 (#15/#16 の既存修正を壊さない)。
- **デコード境界 (IF/ID)**: FIFO head を `~stall_id` で pop → 現 `if_id_*` レジスタへ。データ stall (`stall_id`) は
  **FIFO pop を止めるだけ** (FIFO が埋まり `fetch_full`→フェッチ backpressure)。→ **データ stall は FIFO/decode
  ローカル信号にのみ到達、`imem_addr`→IF-TLB→I$ の長配線には来ない = ① 切断**。
- **redirect**: EX 解決 (branch/trap/xRET) は従来通り `redir_eff`。フェッチエンジンを redirect + FIFO flush。
  FIFO 内の wrong-path 命令は valid クリアで破棄。`redir_pend`(多サイクル IF 跨ぎ) は据え置き。

### 効果と残課題
- **① (データ→stall→imem_addr) が I$ 経路から消える**。新 worst は ② (redirect mux→imem_addr→I$, CSR reg 起点) か
  seq_pc フィードバック (~13ns) 近辺へ。再 impl 測定で確認。20ns には ② も別途切る必要 (複数段) は不変。
- **IPC**: FIFO がフェッチ/デコードを分離するので throughput は不変 (stall 中もフェッチ先行 → むしろ向上余地)。
  redirect penalty は FIFO flush 分 +α (要計測)。
- **リスク = 最高 (#15/#16)**: fetch/redirect/straddle/RVC 窓の全面改修。**full Linux NET=y + rv64uc(C 拡張) +
  rv64si(trap/redirect) を必須ゲート**。straddle (`zybo-jalr-fetch-bug`) と redirect squash を壊さないこと。
- **実装ステップ案**: (1) FIFO + fetch_full backpressure を挿入し `imem_addr` から `stall_if` を除去 (機能等価=
  全ユニット PASS を確認、まだ timing 効果は出ない)。(2) full Linux gate。(3) 再 impl で ① 消失を測定。(4) 残 worst
  (②) を次段へ。各ステップ非破壊検証。

### ✅ step 1 実装完了 = decoupled fetch FIFO (第11セッション; rv_core.sv +60/-4 行)
`rv_core.sv` のみ改変。**フェッチエンジン (fetch_pc/seq_pc/redirect_settle/redir_pend/ifpf) は温存**し:
- `imem_addr` の hold select を `stall_if` → **`fetch_hold = ~imem_ready | redirect_stall | fetch_full`** に変更
  (= フェッチ領域のみ。データ stall dmem_wait を含まない)。⚠️ **`~imem_ready` は必須** (I$ fill / 初回フェッチで
  fetch_pc 保持。I$ 出力=短配線でデータ leak でない)。最初の実装で抜かして pipeline 全滅 → 追加で解決。
- **フェッチ FIFO (depth 4, 循環)**: `ff_push = imem_ready & ~redir_eff & ~redirect_stall & ~fetch_full` で
  `{fetch_pc, imem_rdata}` を push、`ff_pop = ~stall_id & ~ff_empty` でデコードへ、`ff_flush = redir_eff & imem_ready`
  で wrong-path 破棄 (head/tail/count リセットのみ、配列クリアせず=Verilator NBA-in-loop 回避)。`fetch_full =
  (ff_count==4)`。**`fetch_full` は ff_count レジスタ由来** → データ stall は `stall_id→ff_pop→ff_count(reg)→
  fetch_full→imem_addr` と **必ず flop を経由** = ① の組合せ leak 切断。重複なし (バッファ済の実命令、再フェッチ複製でない)。
- **IF/ID レジスタ**: `imem_rdata` 直接でなく **FIFO head を pop** (`ff_empty` 時 bubble)。`stall_if` は割込注入
  (`irq_pending && !stall_if`, line 1322) でのみ残存=正当。
- **✅ 検証 (全 PASS)**: 全ユニット (pipeline 19/cache_soc(64) 6/dcache(64)/amo(64)/mmu(64)/sv(64)/csr/intr/
  fpu_pipe 7/fpu_d/**icache(64)=straddle/RVC/redirect**/cdecode(64)) + compliance **rv64uc-p-rvc** (C 拡張 fetch) +
  **rv64si-p 7/7** (csr/dirty/icache-alias/**ma_fetch**/sbreak/scall/wfi) + **full Linux NET=y `LINUX-USERSPACE-OK`
  HARM=0 amo_prem=0 chars=11428**。
- **IPC コスト**: userspace 到達 425M→**444M cyc (+4.5%)** (FIFO 1 段 = branch penalty +1)。許容範囲。

### ⚠️ step 1 の実 impl 測定 = timing 不変 (① を切っても ② が並行で残る; 重要)
`build_b_step1` (25MHz=40ns): **WNS 2.968→2.819 (worst 37.03→37.18ns) = placement noise 内で実質不変**。
worst path は依然 `ex_mem_alu_result_reg[2] → ... → gen_icache.u_ic/line_reg_2_1/ENARDEN` (35.95ns, logic
8.67ns/route 27.27ns=76%; logic levels 39→44, route 28.4→27.3)。中間 net で **経路が ① から ② へ移動**を確認:
```
ex_mem_alu_result -> sc_success -> core_dmem_req -> dc_c_req -> dc_c_wait -> core_dmem_wait
  -> stall_if -> [割込注入 irq_pending && !stall_if (rv_core.sv:1326) -> ex_trap_enter -> redir_req]
  -> redir_eff_tgt -> fetch_pc -> u_mmu IF-TLB -> I$ line_reg ENARDEN
```
= **step 1 は `stall_if -> imem_addr の hold select` (①) を確かに切った**が、worst は **`stall_if -> 割込注入 ->
ex_trap_enter -> redir_req -> redir_eff (imem_addr の redirect select) -> imem_addr -> IF-TLB -> I$`** (②) へ移動。
**imem_addr には 2 つの late select (`fetch_hold`=①, `redir_eff`=②) があり、データ源 (ex_mem_alu_result) は両方へ
並行に届く**。① だけ登録化しても ② が同長で残るので worst 不変。

**結論 = step 1 単独では timing 利得ゼロ + IPC +4.5% (純コスト)。利得には step 2 (② = imem_addr の redirect select の
登録化) が必須**。step 1 は機能的に正しく非破壊だが、**② とセットで初めて意味を持つ**。
- **step 2 案 = imem_addr の redirect 入力を登録駆動に**: redir_req (EX の trap/branch/割込, データ依存・組合せ) が
  redir_eff 経由で imem_addr の select を叩くのを断つ。redir_req を常時ラッチ (`redir_pend` 機構を全 redirect に拡張)
  し、**imem_addr は登録済 redirect (redir_pend_q) のみ参照**。FIFO が wrong-path を flush するので redirect +1 cyc 化は
  branch penalty +α のみ。⚠️ commit-gate atomicity (#3/SRET) と redirect_settle の整合が要 (最高リスク; full Linux gate)。
  割込注入の `!stall_if` も登録 stall か `~stall_ex` 起点へ。
- **判断事項**: step 1 を foundation としてコミットし step 2 を次段で行うか、step 2 まで step 1 を未コミット保持するか
  (単独では純コストのため)。

### ✅ step 2 実装完了 = imem_addr の redirect select を登録化 (第12セッション; rv_core.sv のみ)
**狙い**: `imem_addr` の redirect 入力 (②) を登録駆動にし、データ依存・組合せの `redir_req` が
`imem_addr → IF-TLB → I$` に到達するのを断つ。step 1 で `fetch_hold` は既に登録駆動 (①済) なので、redirect
select も登録化すれば **`imem_addr` は完全に登録/I$-local 駆動 → データ源 `ex_mem_alu_result` が IF へ leak しない**。

実装 (最小 3 変更、`rv_core.sv` IF 段):
1. **`imem_addr` select を登録 redirect のみに**: 旧 `redir_eff ? redir_eff_tgt : ...` → 新
   `redir_pend_q ? redir_pend_tgt_q : (fetch_hold ? fetch_pc : seq_pc)`。`redir_eff`/`redir_eff_tgt` (組合せ
   `redir_req` 含む) は imem_addr から外す。`redir_eff_tgt` wire は削除。
2. **`redir_pend_q` ラッチを「arm → 次 fetch 境界で apply」に変更**: 旧は `imem_ready && redir_eff` で同サイクル
   consume (= fast path で pend が立たず imem_addr が組合せ redir_req を要した)。新:
   ```
   if (redir_req) redir_pend_tgt_q <= redir_tgt;          // 最新ターゲット捕捉
   if (redir_pend_q && imem_ready) redir_pend_q <= redir_req; // 適用; 同サイクル新 req なら re-arm
   else if (redir_req)             redir_pend_q <= 1'b1;      // 次境界へ arm
   ```
3. **`redir_eff = redir_req | redir_pend_q` は squash 専用に温存**: `flush_id`/`flush_ex`/`ff_flush`/`ff_push`/
   `ifpf` gate が使用。登録化で `redir_eff` が **2 サイクル (N: redir_req, N+1: redir_pend_q)** 高くなり、+1 した
   wrong-path フェッチ (N+1 に imem_rdata へ出る seq_pc 命令) の push 抑止/fault 抑止 (ifpf gate) を**自動でカバー**。

非破壊性 (構造保証):
- **CSR commit は不変**: trap_enter/mret_en/sret_en/csr_we は `csr_commit_ex = ~stall_ex` ゲートで cycle N に commit
  (redir_pend_q 非依存)。priv 変更は N、fetch redirect は N+1 に適用 → **priv 変更後に target を新 priv で fetch**
  = #3/SRET handoff の inversion なし (むしろ登録化で redirect が stall_ex 非依存になり安全側)。
- **redirect_settle (2cyc hold) が target を保持**: 登録化で redirect は +1cyc 遅れて適用されるが、`fetch_hold` が
  settle 窓中 `fetch_pc` を re-present し、`ff_push` は `~redirect_stall` で抑止 → settle クリア後に target を push。
  step 1 と同じ「hold して保持」機構が +1cyc 分も自然にカバー (target ロスなし)。
- **+1cyc penalty は `imem_ready=1` の redirect 解決サイクルのみ** (fast path)。`~imem_ready` で解決 (I$ miss) なら
  旧と完全同一 = strict no-op (miss が +1 を吸収)。`flush_ex_mem = trap_or_mret & ~stall_ex` は EX 命令依存で N+1 は
  EX=bubble → trap_or_mret=0 → 二重 squash なし。

**✅ 機能検証 (全 PASS、第12セッション)**:
- 全ユニット: pipeline 19、icache(64) 50/50、intr 10、csr 16、cdecode(64)、sv(64) 46/46、mmu 28/mmu64 11、
  amo 29/amo64 38、dcache 64/54、cache_soc(64) 6/6、fpu_pipe 7/7、fpu_d 33。
- compliance: rv64uc-p 1/1 (C-ext fetch)、rv64si-p **7/7** (ma_fetch/icache-alias/dirty/csr/sbreak/scall/wfi)。
- **full Linux NET=y**: `LINUX-USERSPACE-OK: init running` 到達 (~434M cyc)、`HARM=0`・`amo_prem=0`・`chars=11428`、
  panic/Oops/BUG なし = ゲート PASS。

### ✅ step 1+2 実 impl 測定 (第12セッション; ① ② は切れたが WNS 不変 = FPU 組合せ経路が新たな壁)
`build_b_step2` (25MHz=40ns; `boards/reports/build_b_step2.log` / `report_worst_b2.log`):
**timing met (WNS=2.782 / WHS=0.038)**。step 1 の WNS 2.819 から実質不変 (placement noise)。

- **✅ ① ② は構造的に切れた**: worst path から **`ex_mem_alu_result → imem_addr → IF-TLB → I$ line_reg`** (step 1 の
  worst, 35.95ns) が**完全に消失**。imem_addr は登録/I$-local 駆動になり、EX データ源は IF へ leak しなくなった。
- **❌ WNS は改善せず**: 下に隠れていた **同長の FPU 組合せ経路** (36.37ns, route 76%, 34 levels) が露見:
  ```
  D$ data BRAM read (gen_dcache data_reg DOBDO -> dc_c_rdata) -> dmem_eff (load 結果)
    -> wb_data[*] (整数 regfile writeback) -> id_ex_rs1_data (MEM/WB->EX forward)
    -> u_fpu (u_misc/u_fma_add/u_div/u_fma_add_d の組合せ FP compute, ~23ns)
    -> ex_mem_fpu_result_f_reg[30] (EX/MEM FP 結果レジスタ)
  ```
  = **integer-load 結果が FPU 命令 (FMV.W.X/FCVT.S.W/L 等, 整数 rs1 入力) へ forward され、single-cycle 組合せ FPU
  が結果を ex_mem_fpu_result_f に確定する経路**。front-end (D$ read→forward) は ~11ns、**残り ~23ns は FPU の
  operand→result 組合せ compute そのもの** (u_misc の FCLASS/FMV/FCVT/min-max + fma/div の結果 mux を縦断)。

**結論 = step 1+2 の goal (IF leak ① ② の除去) は達成。だが binding constraint は FPU 組合せ result 経路へ移った。**
step 10 が対処したのは FP-load→FP-forward (FLW/FLD データ→FP regfile)。今回のは **整数 load→整数 forward→FPU 整数
入力 op** で別物。かつ front-end を全部消しても FPU compute ~23ns + operand ~2ns = ~25ns で **20ns 未達**。
→ **次段 (step 5) = 組合せ FPU の段化 (single-cycle FP 演算 = FADD/FMUL/FMA/FCVT/FSGNJ/FMIN-MAX/FCMP を 2 サイクル
レジスタ化; FDIV/FSQRT は既に多サイクル)** が 20ns 到達に必須。これは forward/hazard/stall に波及する大改造 →
ユーザ方針確認の上で着手。route 76% 支配は floorplan も要 (FPU/D$/I$/regfile が物理的に散在)。

**step 1+2 の扱い (判断事項)**: 単独では timing 利得ゼロ + IPC コスト (step1 +4.5%, step2 は taken redirect +1cyc)。
但し **FPU 段化後に IF leak が再び worst に浮上するため、必要な foundation**。コミットして残すのを推奨 (機能的に正しく
非破壊、full Linux NET=y gate PASS 済)。
