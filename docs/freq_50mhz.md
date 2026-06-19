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
