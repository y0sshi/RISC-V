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
非破壊、full Linux NET=y gate PASS 済)。→ commit `2e2aecc` 済。

## 12. step 5 = 組合せ FPU misc 経路の 2 段レジスタ化 (第13セッション; `rv_fpu.sv` のみ)

### 精密ターゲット (第12で特定済 — 当初の「single→2cyc」想定とは違う)
step 1+2 後の worst (`report_worst_b2.log`, 36.37ns) の実体は `int_a (fwd_rs1_data, ライブ forward mux 出力)
→ u_misc 組合せ (FCVT.S.W/L・FMV.W.X の整数入力) → 出力 mux → ex_mem_fpu_result_f`。
- **add/mul/fma は既に内部 1-cycle pipeline 済** (`mul_result_q` 等)。残る組合せは **`rv_fpu_misc(_d)` (完全
  `always_comb`) + 出力 mux** で、これらに register が無く operand→misc→mux→ex_mem が 1 サイクル ~36ns。
- 「misc 出力のみ登録」では front-end の `D$→forward→misc compute` (~29ns) が残る → 不十分。よって **misc 入力
  オペランドの登録 (stage A) + misc 出力の登録 (stage B) の 2 段**が必須。

### 設計 (rv_fpu.sv 内に局所完結; busy プロトコル不変 = rv_core 無改変)
2 つの free-running レジスタ段を FPU 内に挿入:
- **stage A** = `fa_q/fb_q/int_a_q <= fa/fb/int_a` (forward 後のオペランドを登録)。`fa_s_q/fb_s_q` は登録値の
  NaN-box ビュー。u_misc は `fa_s_q/fb_s_q/int_a_q`、u_misc_d は `fa_q/fb_q/int_a_q` を読む。
- **stage B** = `misc_result_f_q/misc_result_i_q/misc_fflags_q` (+ D 版) <= 組合せ misc 出力。出力 mux は `_q` 版を選ぶ。
  FMV.X.W の直接 `fa` 読み出しも `fa_q` に差し替え (mux 内で他の登録結果と整合)。
- **free-running が安全 = レイテンシ無追加の根拠**: 全 FP compute op は COMB_LAT=2 の busy 窓 (T+1,T+2 busy,
  T+3 capture) で EX に滞在し、rv_core は stall 中 `id_ex_*_data <= fwd_*_data` (`rv_core.sv:733`) でオペランドを
  毎サイクル refresh → 窓全体で安定。よって stage A は T+1 で確定、stage B は T+2 で確定し T+3 capture に間に合う
  (`mul_result_q` と同じ流儀)。div/sqrt/mul/add/fma はライブオペランドのまま不変。
- **3 区間に分割**: `D$→forward→operand_q` (front, ~11ns) / `operand_q→misc→misc_q` (misc compute, ~18ns) /
  `misc_q→出力 mux→ex_mem` (~5ns)。worst は misc compute ~18ns へ低下する見込み。

### コスト/非破壊
- **レイテンシ追加ゼロ** (COMB_LAT=2 据置、busy/result_valid/comb_done 不変、rv_core 1 行も触らず)。
- **TB 修正 1 箇所** (`tb_rv_fpu.sv` の inline FCVT.S.W): 旧 TB は `result_valid` を待たず valid 解除直後に
  `result_f` を即サンプリングしていた (組合せ misc が即結果を出すのに依存)。misc 正規多サイクル化で他テスト
  (check_i/check_f) 同様 `wait_result(60)` を要するよう修正。RTL バグではなく TB 側の非代表的サンプリング。

### 検証 (第13セッション; 全 PASS)
- **FPU ユニット**: sim_fpu 94/94・sim_fpu_d 33/33・sim_fpu_pipe 7/7。
- **全ユニット (非FP)**: pipeline/intr/dcache(64)/amo(64)/mmu(64)/csr/cdecode(64)/icache(64)/cache_soc(64)/sv(64)/
  mext(64) 全 PASS (bit 一致)。
- **compliance FP**: rv64uf 11・rv64ud 12・rv32uf 11・rv32ud 10 = 44/44。
- **full Linux NET=y gate**: `LINUX-USERSPACE-OK` + HARM=0 + amo_prem=0 + chars=11428 (~480M cyc, baseline bit 一致;
  Linux は FP 未使用)。

### ✅ 実 impl 測定 (第13セッション; FPU misc 経路は切れ、worst は整数 MUL へ移動)
`build_step5` (25MHz=40ns; `boards/reports/build_step5.log` / `report_worst_step5.log`):
**timing met (WNS=5.774 / WHS=0.017, 0 failing endpoints)**。step 1+2 の WNS=2.782 から **+2.99ns 改善**
(worst data path ~37.2→34.2ns)。

- **✅ FPU misc 経路は worst から消失**: step 1+2 の worst (`...→u_fpu u_misc→ex_mem_fpu_result_f`, 36.37ns) が
  消え、2 段化が効いた。
- **新 worst = 整数 MUL (単サイクル DSP 乗算)** (33.509ns, logic 15.9ns/47% + route 17.6ns/53%, 30 levels,
  DSP48E1=4 + CARRY4=13):
  ```
  D$ data read (gen_dcache data_reg -> dc_c_rdata) -> u_periph periph_rdata
    -> wb_data[25] (整数 regfile writeback) -> fwd_rs2_data[25] (MEM/WB->EX forward)
    -> u_muldiv (prod_ss = signed-signed 乗算 DSP cascade + 符号補正 CARRY4) -> ex_mem_alu_result_reg[56]/D
  ```
  = **整数 load 結果が MUL/MULH 命令へ forward され、単サイクル DSP 乗算が ex_mem_alu_result に確定する経路**。
  FPU misc と同族 (D$ load→forward→組合せ compute→ex_mem) だが、今度は `rv_muldiv` の MUL (CLAUDE.md: MUL=
  single-cycle DSP、DIV/REM は既に多サイクル radix-2)。

**結論 = step 5 達成 (FPU 経路除去・+2.99ns)。binding constraint は単サイクル整数 MUL 経路へ移った。**
→ **次段 (step 6) = 単サイクル MUL の段化** (DSP48E1 の内部 pipeline レジスタ MREG/PREG を活かし、MUL/MULH/MULW を
1-2 サイクル化して muldiv の busy プロトコルへ統合; DIV 同様)。20ns まではあと ~13ns、複数段が必要。

## 13. step 6 = 単サイクル整数 MUL の段化 (第13セッション; `rv_muldiv.sv` + `rv_core.sv`)

### 設計 (DSP を入力+出力レジスタで挟む正準パイプライン構成; DIV と同じ busy プロトコル)
step 5 後の worst (`report_worst_step5.log`, 33.5ns) = `rsN_data (load forward) → 64x64 乗算 (+MULH 加算木) →
result → ex_mem_alu_result`。MUL を DIV/FPU と同じ多サイクル化:
- **stage A** = `rs1_q/rs2_q <= rs1_data/rs2_data` (DSP 入力レジスタ)。products (prod_ss/su/uu) は registered
  operand から組合せ算出。**stage B** = `prod_*_q <= prod_*` (DSP 出力レジスタ)。`mul_result` は registered products
  から選択 (low half は符号非依存 → MUL/MULW は prod_uu_q)。
- **busy 統合**: `mul_cnt` カウンタ (MUL_LAT=2)、`mul_busy=(mul_cnt!=0)`。出力 `div_busy = div FSM busy | mul_busy`。
  D_IDLE は `valid_in && is_div_op` でのみ divider 起動 (MUL は mul_cnt が処理)。`rv_core`: `muldiv_valid_in` の
  `muldiv_is_divide` ゲートを除去 → MUL も start_stall + busy 経路を通る。**busy/start_stall/was_busy/done は
  divider と完全共有** = restart-livelock 対策 (#14) も MUL に自動適用。
- **free-running が安全**: オペランドは stall 中 id_ex で安定 (step 5 と同根)、両 stage は capture cycle (busy 立下り)
  までに確定。**結果等価性で検証** (no-op ではなくレイテンシ変更)。

### コスト
- **MUL レイテンシ = 1→約4 サイクル** (start + MUL_LAT busy + capture)。Linux userspace 到達 433M→442M cyc =
  **+9M (+2.1%)**。MUL は load/branch より低頻度なので許容。
- **TB 修正 1 箇所** (`tb_rv_mext.sv`): MUL も busy ハンドシェイクを持つので multiply 分岐を divide と同じ
  valid_in/div_busy 待ちに統一 (旧は `#1` 即サンプル = 組合せ前提)。`sim_mdrand`(busy 対応済) は無修正で PASS。

### 検証 (第13セッション; 全 PASS)
- **M ユニット**: sim_mext 29/29・sim_mext64 40/40・sim_mdrand 200K・sim_mdrand64 400K (vs golden)。
- **統合**: sim_pipeline・sim_intr PASS。**compliance**: rv64um 13/13・rv32um 8/8。
- **full Linux NET=y gate**: `LINUX-USERSPACE-OK` + HARM=0 + amo_prem=0 + chars=11428 (+2.1% cyc; restart-livelock
  /オペランド安定性 問題なし)。

### ✅ 実 impl 測定 (第13セッション; MUL 経路は切れ、worst は I$ 内部へ)
`build_step6` (25MHz=40ns; `boards/reports/build_step6.log` / `report_worst_step6.log`):
**timing met (WNS=7.859 / WHS=0.022, 0 failing)**。step 5 の WNS=5.774 から **+2.085ns 改善** (worst ~34.2→30.7ns)。
step 1+2 起点では **WNS 2.782→7.859 = 累計 +5.08ns** (step5 FPU + step6 MUL)。

- **✅ 整数 MUL 経路は worst から消失**: step 5 の worst (`...→u_muldiv prod_ss→ex_mem_alu_result`, 33.5ns) が消え、
  入力+出力レジスタ化が効いた。
- **新 worst = I$ 内部のフィルタグ経路** (30.689ns, logic 29%/route 71%, 38 levels, **CARRY4=23**):
  ```
  gen_icache.u_ic/addr_q_reg (I$ 登録フェッチアドレス) -> fill_tag CARRY4 チェーン (×23, アドレス/タグ演算)
    -> gen_icache.u_ic/line_reg ADDRARDADDR (I$ line BRAM 読出アドレスポート)
  ```
  = **I$ の登録フェッチアドレスから、fill_tag (フィル時タグ/アドレス算術) を経て line BRAM の index へ至る経路**。
  これまでの「D$ load→forward→組合せ compute→ex_mem」族とは異なり、**I$ ルックアップ内部**の経路。route 71% 支配。

**結論 = step 6 達成 (MUL 経路除去・+2.085ns)。binding constraint は I$ 内部 (fill_tag→line BRAM index) へ移った。**
20ns まではあと ~10.7ns。→ **次段 (step 7) = I$ ルックアップ経路の段化** (fill_tag 算術 / addr_q→line BRAM index の
分割)。I$ はフェッチ critical path 上で step 1+2 で既に再構成済 = delicate、慎重設計要。route 71% 支配は floorplan も検討。

## 14. step 7 解析: 真の binding path = IF フェッチ変換ループ (第14セッション)

### §13 サマリの訂正 (重要)
`report_worst_step6.log` の worst を §13 は「I$ 内部 fill_tag→line BRAM index」と要約したが、これは
**Vivado の中間ネット名による誤読**。フルパスを精読すると実体は **IF フェッチ変換ループ全体** (単サイクル):

```
I$ addr_q (登録PA)
  -> I$ hit/straddle 判定 (tg_next 53bit incrementer 含む)   [FF 3.6 -> 15.9ns]
  -> c_ready = imem_ready  (fo=81 大ファンアウト)
  -> rv_core: imem_addr=core_imem_va (advance mux, VA) 選択    [15.9 -> 21.4ns]
  -> rv_mmu: if_va -> if_pa (組合せ 16-way TLB lookup, ~10ns)  [21.4 -> 31.3ns]
  -> mmu_imem_pa (PA) -> I$ c_addr -> { rd_set->line BRAM, addr_q<=c_addr } [31.3 -> 33.8ns]
```

結線: `rv_core.imem_addr=core_imem_va`(VA) -> MMU `if_va`; MMU `if_pa=({ppn}<<12)|va[11:0]`(下位12bit=
ページオフセット素通り) -> `rv_cpu.imem_addr=mmu_imem_pa` -> `rv_soc`: `u_ic.c_addr=mmu_imem_pa`,
`u_ic.c_ready=imem_ready` (ループに戻る)。= **addr_q(reg) -> hit -> imem_ready -> VA -> MMU -> PA -> addr_q(reg)**
の register-to-register 単サイクル経路 (~30.7ns, route 71%)。

### 試行1: 1エントリ登録 micro-ITLB (rv_mmu のみ) -> full Linux で Oops、revert
16-way TLB をループから外すため、直近フェッチページの変換を1エントリ登録 (`ifx_vpn/ifx_ppn`)、同一ページは
`{ifx_ppn,off}` concat で高速ヒット、ページ跨ぎのみ1サイクル refresh stall (= mmu_stall、16-way TLB から
再 capture)。**ユニット全 PASS (sim_mmu/mmu64/sv/sv64/icache/cache_soc/pipeline/intr/...) + compliance 8/8
(rv64uc-p straddle/rv64si-p ma_fetch 含む)**。しかし **full Linux NET=y で 0.007s に Oops -> panic**:
`Unable to handle kernel paging request at tk_core` / `Fatal exception in interrupt` (タイマ割込ハンドラ内で
PC が tk_core データへジャンプ = 制御フロー破壊)。
- 真因: refresh stall の `if_req_out=0` (1サイクル) が、I$ の **EXTRA-2 addr_q 再アーム** (priv 遷移時の
  フェッチ補正、`c_req=1` 必須) と **FIFO wrong-path push / redirect_settle 整合** と**位相不整合**。
  「presented address についての stall」と「I$ の1サイクル遅れ配信」がずれ、割込/SBI の S<->M 遷移で誤フェッチ。
- 教訓: refresh stall を後付けすると I$/core の既存フェッチ機構 (TLB-miss=多サイクル前提) と噛み合わない。
  I$ との co-design 必須。-> revert (第14セッションで方針Bへ)。

### 試行2予定: 2段 VIPT フェッチ (ユーザ選択、第14)
- **VIPT**: I$ BRAM の index は VA[10:5] (= PA[10:5]、4KB ページオフセット内 = 未変換) で引く。tag は **登録PA**。
- **登録変換**: MMU `if_pa` を登録 (`if_pa_q`)。I$ は `c_vaddr`(VA, index・combinational) と `c_paddr=if_pa_q`
  (登録PA, tag) を別ポートで受ける。serve サイクルで `vaddr_q`(=前サイクルの c_vaddr) と `c_paddr`(=その VA の
  登録変換) が整合 -> hit。**1サイクルレイテンシ・スループット不変** (index は VA で combinational、seq_pc も
  imem_rdata=line_q reg から combinational なのでバブル無)。
- 変更範囲: rv_mmu (if_pa/req/fault 登録) + rv_cpu (VA+登録PA を渡す) + rv_soc (結線) + **rv_icache (index/tag
  分離 = 要 rewrite、straddle/EXTRA-2 と整合)** + rv_core (登録 req/fault のタイミング調整)。delicate・多ファイル。

### ⚠️ 重要な timing 上限の発見 (2段 VIPT 単独では 20ns に届かない)
2段 VIPT で MMU は BRAM-index 経路から消えるが、**binding loop は別経路に残る**:
```
Path B: {regs} -> I$ hit -> imem_ready -> core_imem_va(次VA) -> MMU translate -> if_pa_q (register)
        ~= hit(~12) + core fetch(~5.5) + MMU(~10) = ~27ns
```
= 次フェッチ VA (`core_imem_va`) が `imem_ready`(現 hit) に依存し (advance mux: `fetch_hold=~imem_ready|...`)、
その VA を MMU が変換して登録するため、**MMU が依然 imem_ready の後ろ**。よって 2段 VIPT は **~27ns (~36MHz)
で頭打ち**。20ns へは **step 8 = フェッチアドレス生成を imem_ready から分離** (next-PC 投機 + miss 時 replay の
decoupled fetch、または same-page 投機変換) が追加で必要。campaign は元々「複数段必要」。
- step 7 (2段 VIPT) = 31->~27ns の正攻法な1段。step 8 (fetch decouple) で ~27->~20ns。
- 補助: straddle `tg_next` 53bit incrementer 除去 (hit 前段の数 ns)、imem_ready fo=81 削減、floorplan (route 71%)。

## 15. step 8 設計: decoupled fetch (imem_ready を imem_addr から分離) — 第14セッション方針

### 目的 (§14 の binding loop を断つ)
真の 20ns 阻害は `{regs} → I$ hit → imem_ready → core_imem_va(次VA) → MMU → if_pa_q` の loop。
**imem_addr が imem_ready に依存しなくなれば MMU は登録駆動アドレスで叩かれ loop から外れる** (推定 ~15ns 経路へ)。

### 中核変更 (2 つ、協調必須)
1. **rv_core `imem_addr` select から `~imem_ready` を除去**: `fetch_hold = ~imem_ready | redirect_stall |
   fetch_full` → imem_addr 用は `redirect_stall | fetch_full` のみ。I$ miss 中 (`~imem_ready`) は
   `imem_addr = seq_pc` (= `fetch_pc + len(直近 imem_rdata)` = 次の逐次 PC、登録駆動)。fetch_pc の前進は
   従来通り `imem_ready` ゲート (miss 中は保持)、FIFO push も `imem_ready` ゲート → **重複なし**
   (§11(C) の over-stall 重複は「SELECT 登録」由来; ここは登録せず除去なので over-stall しない)。
2. **rv_icache EXTRA-2 (`S_FILL & m_done & c_req` の addr_q 再アーム) を除去/改修**: 除去すると addr_q は
   fill 中 held → S_FILL2/再 lookup が missed PC を正しく供給。core が miss 中に imem_addr=seq_pc へ進めても
   I$ は自前 addr_q を保持するので非干渉。delivery 後 `addr_q <= c_addr(=translate(seq_pc))` で両者 seq_pc に整合前進。

### ⚠️ 設計上のハザード (各々 full Linux gate 必須; §11 / micro-ITLB Oops の教訓)
- **(H1) 投機 seq_pc の命令ページフォールト**: miss 中に seq_pc を MMU へ提示 → seq_pc が未マップ页なら
  `if_fault` 偽発火 → ifpf が未コミットの投機アドレスでトラップ = 誤り。**対策**: ifpf_take を「コミット済
  フェッチ (= imem_ready の delivery、または fetch_pc に対応する fault のみ)」にゲート。投機 seq_pc の fault は抑止。
- **(H2) priv 遷移の EXTRA-2 喪失**: EXTRA-2 は MRET/SRET で同一 fetch_pc の PA が fill 中に変わる件を救済
  (core が fetch_pc を c_addr に保持する前提)。decoupled 化で core は保持しない → EXTRA-2 は別機構が要。
  **仮説**: step 2 の登録 redirect + redirect_settle(2cyc) が priv 確定後に target を提示するので EXTRA-2 不要に
  なる可能性 → 要検証 (rv64si 系 + full Linux)。不足なら I$ 側で「fill 中の priv/satp 変化検出 → 再 lookup」を実装。
- **(H3) 投機 seq_pc の spurious PTW**: miss 中の seq_pc が TLB miss なら PTW 起動 (次ページ prefetch 相当)。
  I$ fill と並行 (別ポート) で機能的には可だが、PTW×fill×割込の衝突 (#15/#16 族) に注意。HARM=0/amo_prem=0 で監視。
- **(H4) redirect/flush 整合**: redir_eff の squash 窓と seq_pc 投機の wrong-path push 抑止 (ff_push は imem_ready
  ゲート済) の整合を icache straddle/redirect テスト + Linux で確認。

### 検証順序
sim_icache(64)/sim_pipeline (重複・基本) → sim_mmu(64)/sim_sv(64) (H2 priv) → sim_cache_soc(64) →
compliance rv64uc-p(straddle)/rv64si-p(ma_fetch/icache-alias/priv) → **full Linux NET=y (H1-H4 総合;
LINUX-USERSPACE-OK + HARM=0 + amo_prem=0 + chars=11428)** → 実 impl で worst 再測定 (MMU が loop から外れ
~27→~20ns 圏か、新 worst (D$/seq_pc/I$ 内部) へ移ったか)。

### 期待効果
imem_addr 登録駆動化で `imem_ready→VA→MMU` が切れ、MMU は `{regs}→MMU→I$/addr_q` の短経路へ。
2段 VIPT (§14) と併用すれば BRAM-index も VA 化でき更に短縮。20ns 圏を狙える唯一の正攻法 (campaign 最難関)。

### ⚠️⚠️ 重要訂正 (実装着手で判明): 可変長フェッチでは「中核変更1 (~imem_ready 除去)」は不成立
miss 中は `imem_rdata` が無効 (`c_ready=0`) なので `seq_pc = fetch_pc + len(imem_rdata)` は **garbage**。
RVC 可変長では「次 PC = 現命令長依存」のため、**missed 命令を取得するまで次 PC を計算できない** → imem_addr は
miss 中 fetch_pc を再提示 (hold) せざるを得ず、**`~imem_ready` 依存は本質的に除去不能**。投機 seq_pc 提示は
garbage アドレスを MMU に流す (spurious fault/PTW) = H1 が致命的。**= §11 がぶつかった可変長フェッチの結合の核**。

#### 正しい decoupled fetch の前提 = ブロック整列フェッチ + アライナ (大規模)
imem_addr の前進を**データ非依存**にするには、**32bit 整列ブロックを PC&~3 で取得し +4 固定前進** + 別 ALIGN
段で 2/4byte 命令をブロック列から抽出 (ブロック跨ぎ命令も結合) する方式が必須。+4 は命令長非依存なので miss 中も
block_pc+4 (有効アドレス) を投機提示でき、Fetch Target Queue が outstanding ブロックを追跡・replay。
= **IF 段の本格再設計** (新アライナ + ブロック FIFO/FTQ)。専用セッション規模。

#### 代替 (より低リスク、要 impl 実測): 2段 VIPT + front-end trim
§14 の「~27ns 上限」見積りは **hit→imem_ready を 12ns (straddle tg_next 53bit incrementer + fo=81 route 込)**
とした悲観値。**straddle incrementer 除去 + imem_ready fanout 削減**で hit→imem_ready を ~5-6ns に縮めれば、
2段 VIPT 後の loop `hit(5) + select + core(5.5) + MMU(10) = ~21ns`、floorplan (route 71%) 併用で 20ns 圏も
あり得る (analytical には route 支配で不確実、**impl 実測が唯一の信頼信号**)。block-fetch 大改造を避けられる
可能性。**判断: まず 2段 VIPT + trim を実装し impl 実測 → 20ns 未達なら block-fetch decoupled へ**、が現実的。

**第14セッション結論**: 真 critical path=IF フェッチ変換ループを確定。micro-ITLB 試行は unit/compliance PASS だが
Linux Oops (refresh×EXTRA-2 位相不整合) で revert。decoupled fetch の「~imem_ready 除去」は可変長フェッチで
不成立 (要 block-fetch+aligner=大規模)。**現実解 = 2段 VIPT (登録変換+VIPT index) + straddle/fanout trim を実装し
impl 実測で 20ns 可否を判定**。全解析・設計・ハザードは §14-15 に集約。ツリーは clean。

## 16. step 7 実装: full VIPT (BRAM read index を VA 化) = 機能検証完了 (第14セッション)
§15 の「2段 VIPT + trim」のうち **VIPT 部分を実装・全検証 PASS**。設計の核 (再確認):
- I$ の BRAM read index `rd_set` は唯一 MMU(`c_addr=mmu_imem_pa`) に依存していた箇所。index bits [OFFW+IDXW-1:OFFW]
  はページオフセット内=未変換なので **VA から引ける** → `rd_set = c_vaddr[OFFW+:IDXW]` (= 同一 index、ただし
  MMU 非依存)。BRAM read setup から MMU が外れる。
- **⚠️ minimal 版 (addr_q=PA のまま rd_set だけ VA) は TLB miss/fault で破綻**: その時 `c_addr=if_pa=0` だが
  `c_vaddr=VA` → rd_set(VA) と addr_q(=c_addr=0) の idx が不一致 → 誤ライン。実際 **full Linux で init SIGSEGV**
  (userspace 到達後 6.0s に "Attempted to kill init exitcode=0xb")。
- **full VIPT で修正**: `addr_q` に **VA** を登録 (index/offset; rd_set=c_vaddr と常に整合、TLB miss でも一致) +
  新 `paddr_q` に **PA** を同 enable で登録 (tag/hit/line_base/fill)。`tg=paddr_q[tag]`, `line_base=paddr_q`。
  変更: rv_cpu (imem_vaddr 出力) + rv_soc (mmu_imem_va 配線, I$ .c_vaddr) + rv_icache (addr_q=VA, paddr_q=PA) +
  tb_rv_icache (.c_vaddr=c_addr)。
- **✅ 機能検証 (全 PASS, baseline 完全一致)**: sim_icache(64) 50 / cache_soc(64) 6 / pipeline 19 / mmu(64) /
  sv(64) / intr 10 / amo64 / dcache64 / csr / cdecode64 / fpu_pipe + compliance rv64uc-p 1 + rv64si-p 7 +
  **full Linux NET=y LINUX-USERSPACE-OK chars=11428 pc=0x1016a HARM=0 amo_prem=0 (baseline 完全一致)**。
- **⚠️ 期待 timing 利得は小 (~2.5ns, BRAM tail のみ)**: §15 の通り MMU は依然 binding loop (hit→imem_ready→
  core_imem_va→MMU→paddr_q) に残る (paddr_q の tag を hit が使い、その PA は MMU 由来、core_imem_va は imem_ready
  依存)。VIPT は BRAM-index 経路から MMU を外すのみ。**実 impl 測定中 (build_vipt.log)**。
- **次**: impl で新 worst を確認 → trim (straddle tg_next 53b incrementer 除去・imem_ready fo=81 削減) を新 worst
  狙いで追加 → 更なる短縮。20ns には最終的に decoupled fetch (block, §15) が必要。

### ✅ 実 impl 測定 (build_vipt, 30.303MHz=33ns): VIPT は timing 利得ゼロ (予測通り)
**WNS 3.478→3.413ns (placement noise 内、実質不変)**。VIPT が外した BRAM-index 経路は **binding でなかった**
(binding = フェッチループの paddr_q/line BRAM enable 捕捉)。worst (`report_worst_vipt.log`, 28.417ns@33ns 制約,
**route 75.7%**/logic 24.3%, 29 levels, CARRY4=11):
```
gen_icache.u_ic/addr_q_reg[6] (I$ VA 登録, fo=96 route 2.3ns)
  -> fetch_pc hit 比較 -> imem_ready (fo=81, route 2.07ns)        [3.6 -> 15.1ns]
  -> u_core ff_tail/ff_count -> addr_q (core fetch) -> ... -> MMU -> line_reg ENARDEN (I$ BRAM enable)
```
= §14 と同じ IF フェッチループ。VIPT で endpoint は ADDRARDADDR→ENARDEN・CARRY4 23→11 に変化したが**ループ
不変・MMU 依然内在**。**route 75.7% 支配** (高 fanout: addr_q fo=96/imem_ready fo=81/p_9_in fo=62 が各 ~2ns route)。

### 第14セッション最終結論 (step 7)
- **VIPT = 機能的に正しい (baseline 完全一致) が単独 timing 利得ゼロ**。binding は IF フェッチループ (MMU 内在)、
  **route 75.7% 支配**。
- **route 支配 = floorplan が最有力の次手** (I$ logic + line BRAM + core fetch + MMU を pblock で近接配置 → 高 fanout
  net の route 短縮)。RTL 無改変=機能リスク 0。trim (straddle incrementer/fanout) は route 支配下では効果限定的。
- **論理ループ (MMU) を割るには decoupled fetch (block, §15) が必要** (20ns の本命、大規模)。
- VIPT は decoupled fetch (VA index 化) の foundation でもある。単独利得 0 なので keep/revert は方針次第。

### ❌ floorplan (pblock) は非viable = 設計が xc7z020 に対して大きすぎる (第14セッション、実測で確定)
route 75.7% 支配を pblock で攻める案を検証 (`validate_pblock*.tcl` を routed dcp に適用、util 実測):
- **CPU complex (u_cpu+I$+D$) = LUT 33134 (xc7z020 の 53200 の 62%)**。clustering に有効な領域 (SLICE_X0Y0:X75Y124)
  に入れると **LUT 119.19% = 溢れる**。fit する大きさ (~85%) では現状の ~100% spread と大差なく clustering 無効。
- **targeted (fetch loop = u_core−FPU + u_mmu + I$) でも LUT 124.94% / DSP 120%** (SLICE_X0Y0:X55Y124)。
  内訳: u_core(all) 27895 LUT (u_fpu 10097 / u_muldiv 3756 除いても ~14K) + u_mmu 1236 + I$ 2526 = ~20K LUT、
  DSP 48 (>40)。compact 領域に入らない。
- **結論: RV64GC コア (62% LUT) は xc7z020 に対して大きく、pblock で clustering すると congestion (>100%) になる。
  route 支配は device に対する設計サイズが本質的原因で、floorplan では解消不能**。
- → **20ns の残る現実的な道は decoupled fetch (§15、論理ループを割れば route があっても経路長が短くなる) のみ**。
  他: aggressive phys_opt/impl strategy で高 fanout net の route を自動最適化 (低リスク、数 ns 期待、要 impl 実測)。

## 17. step 8 確定設計: block-aligned fetch + aligner (第15セッション; 実装着手前レビュー対象)

§15/§16 で残った唯一の 20ns 到達路 = **decoupled block fetch**。第15セッションで設計を以下に確定する。
**⚠️ これは最高リスク改造 (フェッチ path 全書換)。実装着手前にユーザレビュー必須。**

### 17.1 中核の洞察 = 「命令境界処理を I$ からコア内アライナへ移す」(変更は rv_core.sv 局所)

§14 で確定した binding loop の本質:
```
imem_addr = fetch_hold ? fetch_pc : seq_pc      // 組合せ mux
  fetch_hold = ~imem_ready | redirect_stall | fetch_full   // ← imem_ready が mux に入る
  seq_pc     = fetch_pc + len(imem_rdata)                  // ← imem_rdata(データ)に依存
```
imem_addr が **(a) ~imem_ready (mux select) と (b) imem_rdata (seq_pc の命令長)** の双方に組合せ依存し、
その imem_addr を MMU が変換するため **MMU が loop に内在**。§15 の結論: 可変長 RVC では「次 PC = 現命令長依存」
なので、命令長計算 (= imem_rdata 消費) を imem_addr 生成から外せない限りこの依存は切れない。

**解 = フェッチ粒度を「2-byte 整列 PC の 32bit 窓」から「4-byte 整列ワードの +4 固定前進」へ変える**:
- `imem_addr = redir ? (target & ~3) : bpc` (bpc = word-aligned block PC、**レジスタ**)。`bpc <= bpc + 4`
  は **命令長非依存・imem_rdata 非依存**の固定前進 (enable=imem_ready の単なる flop)。
- 命令境界の抽出 (2/4byte 判定・ワード跨ぎ結合) は I$ の **後段** = コア内 **アライナ**へ移す。アライナは
  imem_rdata を消費するが **imem_addr へフィードバックしない** ので loop の外。
- → imem_addr は **完全にレジスタ駆動** (redir_pend_tgt_q または bpc)。MMU は register-to-register の
  `bpc → MMU → I$ addr_q/line BRAM` 短経路 (~15ns 目標) になり **loop から外れる**。

**決定的な副次効果 = I$ は無改変で済む**:
- bpc が word 整列 (`bpc[1:0]=00`) ゆえ I$ に渡る `c_addr` も常に word 整列。I$ の **straddle** は
  `boff == LINE_BYTES-2` (32B ラインで boff=30、4の倍数でない) でのみ発火 = **word 整列アドレスでは絶対に発火しない**。
  → I$ は常に `window = line_q[boff*8 +: 32]` の in-line word を返すだけ。**straddle 経路は dead (未使用) になるが、
  rv_icache.sv のコードは変えない** (機能的に到達しなくなるだけ)。ワード跨ぎ 4byte 命令の結合は**アライナが担う**。
- → **rv_icache.sv / rv_mmu.sv / rv_cpu.sv / rv_soc.sv は無改変**。変更は **rv_core.sv の IF 段のみ**。
  micro-ITLB/VIPT (I$+MMU+cpu+soc を触り Linux で破綻) より遥かに小さい blast radius。

### 17.2 データパス (rv_core.sv 内、3 ブロック)

**(1) block fetch エンジン** (現 imem_addr/seq_pc/fetch_pc を置換):
```
bpc        : word 整列 block PC (register)。reset = RST_ADDR & ~3。
imem_addr  = redir_pend_q ? (redir_pend_tgt_q & ~XLEN'(3)) : bpc       // 完全レジスタ駆動
bpc 前進   : if (imem_ready & ~redir_eff & ~hwbuf_full) bpc <= bpc + 4  // 固定+4、enable のみ
           : if (redir applied)                          bpc <= target & ~3
bfpc       : = 現 fetch_pc 相当。imem_ready 時に imem_addr を捕捉 (= imem_rdata 上のワードの先頭アドレス)。
```
`fetch_hold` の `~imem_ready ? fetch_pc : seq_pc` 組合せ mux は**消滅**。~imem_ready 中は bpc flop が
enable されず imem_addr=bpc が同値を保持 (I$ 再 lookup 用) = レジスタ保持であり組合せ依存ではない。

**(2) halfword buffer (skid FIFO)** = 現 instruction FIFO (ff) を置換:
- 各エントリ = `{hw[15:0], hw_pc[XLEN-1:0], fault}` (halfword 単位)。深さ HW_DEPTH (例 8 = 4 word 分)。
- **push**: imem_ready & ~flush で 1 ワード = 2 halfword を一括 push、各々 hw_pc = bfpc / bfpc+2 を付与。
  redirect 直後の最初の word は `target[1]==1` なら **低位 halfword をスキップ** (高位のみ push)。
- `hwbuf_full` (registered occupancy) → bpc 前進と push を backpressure (現 fetch_full と同役割、ff_count 相当の
  レジスタ由来なのでデータ stall は flop 経由でのみ imem_addr に届く = §11 で確立した分割が維持される)。

**(3) アライナ (buffer 先頭の組合せ抽出)** → 直接 IF/ID を駆動:
```
h0     = head halfword, h0_pc = その pc, h0_fault
is_comp = (h0[1:0] != 2'b11)
命令成立条件:
  compressed : count>=1                       -> inst32={16'hX, h0}, pc=h0_pc, 消費 1 halfword
  full       : count>=2 && h1_pc==h0_pc+2     -> inst32={h1, h0},    pc=h0_pc, 消費 2 halfword
  不成立 (full だが count<2)                  -> bubble (if_id_valid=0)、次 word 待ち
if (!stall_id && 成立) IF/ID <= {pc, inst32, valid=1}; head を 1 or 2 進める
```
decode 側は**無改変**: `decode_inst = id_is_compressed ? expand(if_id_inst[15:0]) : if_id_inst` がそのまま動く
(compressed は inst32[1:0]!=11 で判定、上位 16bit は don't-care)。ワード跨ぎ 4byte 命令は h0/h1 が別ワード由来でも
hw_pc 連続性 (`h1_pc==h0_pc+2`) で結合 = アライナがハンドル (旧 I$ straddle の役目)。

### 17.3 redirect / flush / fault (ハザード H1-H5 の具体機構)

- **redirect (branch/trap/MRET/SRET/SATP)**: 既存の登録 redirect (redir_pend_q/redir_pend_tgt_q、step 2/4) を流用。
  適用時に **halfword buffer を flush** (ff_flush 相当)、bpc <= target&~3。target[1] でアライナ初期オフセット決定。
  redirect target は 2-byte 整列 (word 内 mid 可) → 17.2(2) の「最初の word の低位スキップ」で対応。
  → **redirect_settle の「X 命令が seq_pc を破壊する」防止役は不要化** (bpc は +4 固定で imem_rdata 非依存)。
  priv 遷移ブリッジ役 (H2) のみ残すので redirect_settle は保守的に**維持**。
- **(H1) 投機ワードの命令ページフォールト**: bpc を +4 投機前進 → 未マップ页に踏み込むと if_fault。
  **対策 = fault marker**: 投機ワードが faulting なら halfword buffer に `fault=1` マーカを push (データ無効)。
  そのマーカが **head に到達し decode が消費しようとした時のみ** ifpf_take (pc=hw_pc)。先行の redirect/branch で
  flush されれば marker は head 到達せず → 投機 fault は**発火しない** (精密)。投機は buffer 深さ分 (~4 word) に
  bounded ゆえ页境界跨ぎは数ワードのみ。代替 = 页境界で bpc 前進を buffer drain まで gate (throughput 損、保険)。
  ⚠️ 現 ifpf は `if_fault && !redir_eff` で**即発火** (fetch_pc)。block 投機で fault がより投機的になるため
  marker 化は**必須の変更点** (今設計の H1 中核)。
- **(H2) priv 遷移 (MRET/SRET) の EXTRA-2**: I$ EXTRA-2 (fill 中 priv 変化で addr_q 再アーム) は**無改変で維持**。
  block 化で c_addr=bpc は fill 中レジスタ保持 (安定) ゆえ EXTRA-2 のトリガ条件 (redirect が fill 中着地) は従来同。
  仮説: 登録 redirect + redirect_settle(2cyc) が priv 確定後に target 提示 → 整合。**rv64si-p (ma_fetch/
  icache-alias/dirty) + full Linux で要検証** (micro-ITLB の Oops はここの位相不整合が原因だった)。
- **(H3) 投機 bpc の spurious PTW**: 投機ワードが TLB miss なら PTW 起動 (次页 prefetch 相当)。I$ fill と別ポート
  並行で機能可だが PTW×fill×割込衝突 (#15/#16 族) に注意。**HARM=0 / amo_prem=0 で監視**。H1 の marker は PTW 後の
  fault も head 到達時のみ taken にするので精密性は保たれる。
- **(H4) ワード跨ぎ命令 × redirect × miss の同時**: flush 時 halfword buffer 全クリア + bpc=target&~3 で leftover
  は消える (別レジスタの leftover を持たず buffer 内 halfword 連続性で結合する設計ゆえ整合は buffer flush に集約)。
- **(H5) IPC コスト**: アライナはワード跨ぎ 4byte 命令で 2 ワード必要 → 第2ワード未 buffer 時のみ 1cyc bubble
  (通常は先読みで buffer 済 → 0)。redirect 直後の最初の跨ぎのみ稀に bubble。**userspace 到達サイクルを baseline
  442M と比較**して劣化 <数% を確認。

### 17.4 非 no-op 性と risk bound

- これは §12/§13 (latency/busy 追加で imem_ready=1/vm off no-op 還元できた) と違い、**フェッチ機構の置換** =
  構造的 no-op 証明は不可。**等価性は機能検証 (compliance bit 一致 + full Linux 完全一致 chars=11428) で担保**。
- ただし **imem_ready=1 (BRAM/全 hit) では bpc が毎サイクル +4 前進し buffer が常に充足** → アライナは毎サイクル
  1 命令供給 = 旧経路と同 throughput に還元 (bubble 0)。可変レイテンシ (I$ miss/PTW) 下のみ buffer drain で前進。
- **fault は marker 化で「コミット時のみ taken」** = 投機の precise exception を構造保証 (H1)。

### 17.5 検証順序 (各段で前進確認、最後に必ず full Linux gate)

1. `sim_icache(64)` / `sim_pipeline` : アライナ基本 (compressed/full/ワード跨ぎ)・重複なし・bubble 妥当。
2. `sim_mmu(64)` / `sim_sv(64)` : priv 遷移 (H2)・PTW (H3)。
3. `sim_cache_soc(64)` / `sim_intr` / `sim_amo64` : 統合・割込×フェッチ。
4. compliance `rv64uc-p` (RVC corner) / `rv64si-p` (ma_fetch=2byte境界 JALR / icache-alias / priv)。
5. **full Linux NET=y** (`LINUX-USERSPACE-OK` + `HARM=0` + `amo_prem=0` + `chars=11428` + pc=0x1016a)。**H1-H5 総合**。
6. 実 impl で worst 再測定: MMU が loop から外れ ~20ns 圏か / 新 worst (D$ / アライナ / 別 I$ 経路) へ移ったか。

### 17.6 §15 sketch からの設計変更点 (簡素化)

- **FTQ 不要**: miss replay は既存 I$ (c_ready=0 で hold→再 lookup) + bpc レジスタ保持が既に担う。PC 連携は
  halfword への hw_pc タグで足りる。専用 FTQ は追加しない (§15 の FTQ 案を簡素化)。
- **I$ 無改変**: §15 は「EXTRA-2 除去/改修」を挙げたが、word 整列化で I$ は無改変のまま straddle が dead 化する
  だけ。EXTRA-2 は維持 (H2 保険)。blast radius を rv_core.sv に閉じる。
- **block 幅 = 1 word (4byte)**: decode 1-wide ゆえ 4byte/cyc で十分。広 block (8byte) は buffer/aligner 複雑化
  に見合わず採らない。

### 17.7 工数・fallback

- 規模: rv_core.sv の IF 段 (現 ~L330-571) をアライナ + halfword buffer + block engine で書換 (~150-200 行 net)。
  decode 以降・I$・MMU・cpu・soc 無改変。**専用セッション 1 本想定** (all-or-nothing、増分検証しにくい)。
- fallback: full Linux で詰まり切らない / IPC 劣化大なら revert (ツリーは clean 起点)。低リスク代替 = aggressive
  phys_opt / impl strategy (RTL 無改変、~40分、30→35MHz 程度の可能性、20ns 不達) を先に試す選択肢も残す (§16 末尾)。

**⚠️ 第15セッション: ここまで設計確定。実装は本 §17 のユーザレビュー承認後に着手する。**

### 17.8 ⚠️⚠️ 実装着手時の重大発見: §17.1-7 の「rv_core 局所・FTQ 不要」は throughput 制約で不成立

ユーザ承認後、実装直前に rv_core/rv_icache/rv_mmu の信号レベル精査で **§17 設計の前提が崩れる**ことが判明
(prompt の教訓「フェッチ path は設計無しの実装で必ず失敗」が的中)。core 状態機械を変えずに済むと考えていたが、
**「imem_addr を imem_ready から外す」と「フェッチ throughput を保つ」が同時に成立しない**ことが分かった。

#### 根本のジレンマ (throughput vs ループ切断)
- I$ は **1サイクルヒット**契約: cycle N に c_addr=A を提示 → N+1 に word@A + imem_ready。full throughput
  (1 命令/cyc) には **word@A が届く N+1 に即「次アドレス」を提示**せねばならない。
- 「次アドレス即提示」は「現フェッチ完了 (imem_ready)」を**組合せで**知る必要がある。原設計
  `imem_addr = fetch_hold(~imem_ready) ? fetch_pc : seq_pc` の `~imem_ready` はまさにこれ = **throughput のための
  組合せ前進**。これを除くと imem_addr がレジスタ値 (bpc) を 1 サイクル余分に保持 → **各アドレス 2 サイクル提示 =
  half throughput** (実測前から致命)。reset/bootstrap も `imem_addr=bpc+4` だと初回 RST_ADDR を飛ばす。
- block +4 で `seq_pc` のデータ依存 (imem_rdata) は消せるが、**imem_ready 依存 (throughput 前進) は消せない**。
  → §17.2 の「imem_addr=bpc+4 でレジスタ駆動」は **half-throughput か bootstrap 破綻**のいずれか。**設計欠陥**。

#### 正しい解 = (A) 2段レジスタ翻訳 block fetch、または (B) FTQ。いずれも rv_core 局所でない
- **(A) 2段翻訳パイプライン (有力)**: `bpc(VA reg, +4 データ非依存) → MMU(組合せ) → if_pa_q(PA reg) → I$`。
  imem_addr=if_pa_q (登録 PA) で **MMU は bpc(reg) と if_pa_q(reg) の間** = imem_ready の組合せ経路外
  (imem_ready は bpc/if_pa_q flop の **enable** のみ = setup path、ループ非内在)。2段パイプライン (translate→I$)
  で miss 時は両段 freeze (in-flight アドレスはレジスタが保持 = FTQ 不要)、hit 列で 1/cyc。**= §16 VIPT/登録翻訳と
  同型だが、VA が +4 データ非依存になった点が決定的に異なる** (§16 は seq_pc データ依存ゆえループ残存で利得 0 だった;
  block 化で初めて登録翻訳が効く可能性)。⚠️ ただし **rv_cpu/rv_mmu/rv_icache を改変** (if_pa 登録・I$ の PA 受け)
  = §16 と同じ blast radius。+ rv_core に block front-end + aligner + halfword buffer。**= 大規模・多ファイル**。
- **(B) FTQ (アドレス先行生成)**: gen_pc が +4 を **毎サイクル**生成し FTQ に充填 (imem_ready 非依存)、I$ は FTQ head
  (reg) を消費。imem_addr=FTQ[head] (reg array read) でループ外。throughput 維持。だが FTQ + halfword buffer +
  aligner で **最も複雑**。
- いずれも §17.6「FTQ 不要・I$ 無改変・rv_core 局所」は**誤り**。aligner + halfword buffer は両案で必要。

#### §16 の route 支配との関係 (利得の不確実性)
§16 は VIPT (登録翻訳) を実装したが **実 impl 利得 0** (WNS 3.478→3.413)。理由は「ループ残存」(seq_pc データ依存) と
**route 75.7% 支配 (device サイズ起因、floorplan 非viable)**。案 (A) は block 化でループを真に切るので §16 と違い
利得が出る**可能性**はあるが、**route 支配が残れば利得限定的**のリスク (analytical 不能、impl 実測のみが信号)。

#### 第15セッション結論 (実装は保留、設計再確定)
- **ツリー無改変** (RTL 一切触らず)。本 §17.8 の発見のみ記録。承認された §17.1-7 設計は throughput 制約で
  実装不可と判明 → 正しくは案 (A) 2段登録翻訳 block fetch (大規模・多ファイル・利得不確実) が必要。
- **ユーザ判断待ち**: (A) 案で本格実装に進む / 先に低リスクな aggressive phys_opt を実 impl 実測 / 30.303MHz 確定で
  ロードマップ③へ。50MHz は案 (A) 実装 + route 支配次第。
- **→ phys_opt 実測を選択 (§18 へ)。これが §14-17 の前提を覆す。**

## 18. ⚠️⚠️⚠️ 重大ピボット: fetch ループは 50MHz の binding ではない (第15セッション、実 impl 実測で確定)

§14-16 は「真の binding = IF フェッチ変換ループ、20ns の唯一の道 = decoupled fetch (case A)」と結論したが、
**これは 33ns 緩制約での worst-path 測定アーティファクトだった**ことが、タイト制約での実 impl 実測で判明。

### 実測 (synth dcp を open_checkpoint + clk_fpga_0 を手動 create_clock; `build_physopt.tcl`)
| 制約 | strategy | post-route WNS | worst path | Fmax | binding path |
|------|----------|----------------|-----------|------|--------------|
| 33ns | default (= baseline 実機) | **+3.478** | ~29.5ns | ~34MHz | (緩制約で未 push) |
| 20ns | default (build_zybo と同フロー) | **-1.863** | **21.89ns** | **45.7MHz** | FPU add `u_core/u_fpu/u_add/sum_q[25]` |
| 20ns | aggressive (ExtraNetDelay_high place + AggressiveExplore route) | **-1.374** | **21.38ns** | **46.8MHz** | FPU FMA-D `u_fpu/u_fma_add_d/sum_q[56]` |

両 worst path とも **source=`ex_mem_rd_addr_reg` → dest=FPU 加算器の `sum_q` レジスタ**、logic 38 levels
(CARRY4 18)、**route ~70%**。fetch ループ (addr_q→MMU→I$) は **binding から消失** (タイト制約下で placer/router が
<21ns に詰めた)。

### 結論 (campaign の方向を変える)
1. **50MHz の binding は FPU 加算器** (`u_add` / `u_fma_add_d` の `sum_q` 第1段組合せ = 倍/単精度仮数加算の
   CARRY4 チェーン + operand mux)、**fetch ループではない**。§14-17 の case-(A)/(B) decoupled fetch
   (最高リスク・多ファイル・大規模) は **不要**。
2. **支配要因はタイト制約**: 緩い 33ns では placer が緩むため worst が ~29.5ns に膨らみ「fetch ループが binding」に
   見えていた。20ns で push すると **default でも ~21.9ns** に収束し、binding が FPU へ移る。aggressive は default に
   **+0.5ns (~1MHz) しか上乗せしない** → strategy より**制約タイト化**が効く。
3. **現 RTL 無改変で ~45-46MHz の worst path が達成可能** (ただし 20ns では WNS 負 = まだ ~1.4-1.9ns 不足)。
   timing MEET (WNS≥0) する最大周波数は ~40-45MHz 圏 (要中間制約実測)。**baseline 30→40MHz 級は RTL 無改変で射程**。
4. **20ns (50MHz) MEET には FPU 加算器 path (~21.4ns) を <20ns へ**: route ~70% 支配だが logic も CARRY4×18 と重い。
   対策候補 = FPU add/FMA の **sum_q 第1段をさらに段化** (step5/6 で misc/mul を段化したのと同型、局所・低リスク) +
   制約タイト化。fetch 全書換より遥かに小さい。
5. route ~70% は §16 の「device に対し設計が大 (LUT 62%)」と整合 (floorplan 非viable は不変)。だが logic 段化で
   logic 6.6ns を削れば総 path が縮む余地あり。

### ⚠️ 測定上の注意 / 次手
- 本実測は **open_checkpoint + 手動 create_clock(clk_fpga_0)** の簡易プローブ。実 build_zybo フロー (launch_runs
  impl_1 + BD 制約) と worst path は同じ (intra-fabric clk_fpga_0) のはず。**実 target 確定は build_zybo.tcl の
  PL_FREQMHZ を上げて launch_runs で WNS≥0 を確認**する (本物の制約セット)。
- `build_physopt.tcl` (period/mode 引数化) を残す: `... -tclargs <period> <aggr|def>`。post-route phys_opt は
  WNS<-0.5 で無効 (Vivado 警告) かつ exit 116 crash の原因のため skip。
- **次の現実的ロードマップ**: ① RTL 無改変で MEET する最大周波数を中間制約で確定 (例 24/22ns) → build_zybo +
  実機検証 (40-45MHz 級) → ② 更に上を狙うなら FPU sum_q 段化 (局所・低リスク) で FPU path を削り 50MHz へ。

### ✅ 18.1 実機 40MHz 達成 (第15セッション、RTL 無改変)
ユーザ判断 = 「40MHz 安全重視」。`set_pl_freq.py 40` (build_zybo.tcl PL_FREQMHZ=40 / 両 hw.dts timebase=
40000000・baud div 43=58140 (+0.94%) / bringup コメント / ps7_init 再抽出 div25) → `build_all.py --stage bit`
(実 default flow)。
- **✅ timing met WNS=+0.172ns** (clk_fpga_0 25.000ns=40.000MHz、0 failing endpoints)。⚠️ **薄 margin**:
  Vivado は met 時点で最適化停止するため 25ns 制約では worst 24.83ns で止まる (20ns probe では限界 21.89ns まで押した)
  = **設計実力 ~45MHz だが default@40MHz は早期停止で +0.172ns**。
- **✅ 実機検証 PASS (TeraTerm, Pmod JC 57600 8N1)**: OpenSBI v1.2 フルブート (`aclint-mtimer @ 40000000Hz`) →
  Linux 6.12 (`sched_clock: 64 bits at 40MHz`) → **NET=y** (PF_NETLINK/PF_INET/PF_INET6 全登録 = [[zybo-netlink-atomic-bug]]
  箇所通過) → console sbi0→ttyS0 → **`LINUX-USERSPACE-OK: init running`**。**+0.172ns 薄 margin が実機で持ちこたえた**。
- **= baseline 30.303MHz → 40MHz (+32%) を RTL 無改変で達成。case-(A) decoupled fetch 大改造を完全回避**。
- **次 (任意)**: 更に上 (44-45MHz/50MHz) を狙うなら (a) Performance strategy で 40MHz の margin を厚く / より高い
  周波数を met させる、(b) FPU `sum_q` 第1段の段化 (step5/6 同型・局所・低リスク) で FPU path を削り 50MHz へ。
  あるいはロードマップ③ (RootFS) へ移行。`build_physopt.tcl` で任意周波数を impl 実測可能 (probe; 真の build は
  build_zybo)。

## 19. ✅ step 7 = FPU 加算器オペランドのレジスタ化 (第16セッション; `rv_fpu.sv` のみ・実装+検証完了)

§18 が確定した 50MHz binding = FPU 加算器 (`u_add`/`u_fma_add_d` の `sum_q` 第1段) を、step5/6 と同型の
**オペランド・レジスタ化**で除去した。

### 19.1 変更 (rv_fpu.sv のみ、レイテンシ中立)
4 加算器が EX forward mux から**生で**読んでいたオペランドを、レジスタ済みに差し替え:
| 加算器 | 変更前 | 変更後 |
|--------|--------|--------|
| `u_add` (S FADD) | `fa_s`/`fb_s` | `fa_s_q`/`fb_s_q` (既存) |
| `u_add_d` (D FADD) | `fa`/`fb` | `fa_q`/`fb_q` (既存) |
| `u_fma_add` (S FMADD) | `fc_s` | `fc_s_q` (新規) |
| `u_fma_add_d` (D FMADD) | `fc` | `fc_q` (新規) |
`fc_q` を free-running 登録 (fa_q/fb_q と同所)、`fc_s_q` は NaN-box S-view。**COMB_LAT 不変・rv_core 無改変**。
- レイテンシ中立の根拠: FADD はレジスタ操作で結果が T+1→**T+2** に遅れるが capture は T+3 (busy 立下り) のままで
  間に合う。FMADD は積 (`mul_*_result_q`, T+2) が律速ゆえ、より早く揃う `fc_q` (T+1) は無影響。step5 (misc が
  `fa_s_q` を読む) と完全同型。binding path 前半 (`ex_mem_rd_addr → fwd_frs3_sel → fpld_data → 加算器`) を
  レジスタ境界で切る。

### 19.2 検証 (全 PASS・非破壊)
- ユニット: sim_fpu 94/94, sim_fpu_d 33/33, sim_fpu_pipe 7/7 (FMADD rs3 fwd・FP load-use stall 含む),
  sim_pipeline 19/19, sim_intr 10/10。
- compliance FP: RV64 23/23 (uf 11 + ud 12) + RV32 21/21 (uf 11 + ud 10) — fadd/fmadd/ldst/move/structural。
- **full Linux NET=y**: `LINUX-USERSPACE-OK` + HARM=0 + amo_prem=0 + **chars=11428** (baseline 完全一致)。

### 19.3 実 impl 効果 (20ns aggr probe; 再synth 後)
| | step7 前 (aggr 20ns) | step7 後 (aggr 20ns) |
|---|---|---|
| post-route WNS | -1.374ns | **-0.454ns** (+0.92ns) |
| post-route + phys_opt | (未到達) | **+0.021ns (MEET)** |
| worst path | FPU FMA-D `u_fma_add_d/sum_q[56]` (21.38ns) | **I$ フェッチループ** `u_ic/addr_q→line BRAM` (19.845ns) |

**FPU 加算器は top-10 worst から完全消失** (top-10 すべて I$ フェッチループへ移行)。
- **50MHz default 本番ビルド (Performance なし)**: **WNS -2.458ns** (worst 21.4ns, 2091 failing, 同 I$ ループ)。
  default strategy は net-delay aware place も post-route phys_opt も行わないため、この動作点で aggr との差が ~2ns。
- **結論**: 50MHz の唯一の残 binding は **I$ フェッチループ**。aggr+physopt なら +0.021ns で MEET (margin 薄) /
  Performance strategy で本番 50MHz は可能だが実機 margin 不安。default で 50MHz は I$ ループが壁 (~46MHz)。

## 20. step 8 確定設計: FTQ 型 block fetch (第16セッション設計確定; 実装は専用セッション)

§18 で棚上げした fetch ループが step7 後の**唯一の 50MHz binding** として復活。§17→§17.8 の経緯を踏まえ、
**正しい解は案 (B) FTQ 型**であることを現行 RTL (step1-7) の信号レベルで再確認した。**実装は専用セッション** (ユーザ判断)。

### 20.1 現行 fetch ループの実体 (step1-7 後、§17.1 と同型)
`rv_core.sv` IF 段:
```
imem_addr = redir_pend_q ? tgt : (fetch_hold ? fetch_pc : seq_pc)   // 組合せ mux
  seq_pc     = fetch_pc + (if_is_compressed ? 2 : 4)   // imem_rdata(命令長) 依存
  fetch_hold = ~imem_ready | redirect_stall | fetch_full  // imem_ready 依存
```
= imem_addr が `~imem_ready` (mux select) と `imem_rdata` (seq_pc 命令長) の両方に組合せ依存。
ループ: `I$ addr_q(reg) → hit → imem_ready/imem_rdata → rv_core seq_pc/fetch_hold → imem_addr → MMU →
c_addr → addr_q(reg)`。decoupled FIFO (ff_*, step4) は**データ stall (dmem_wait) を fetch から分離済み**だが
**fetch ループ自体は未分割**。

### 20.2 §17.8 の throughput ジレンマ (再確認済み = 設計の核心)
「imem_addr をレジスタ駆動 (bpc+4)」+「imem_ready で enable」は **half-throughput**:
I$ は N 提示→N+1 配信の 1cyc 契約ゆえ、bpc が imem_ready (N+1 着) を待って前進すると次提示が N+2 にずれ、
1命令/2cyc になる。full throughput には「現フェッチ完了を組合せで知り即次提示」= 切りたい imem_ready 組合せ前進が要る。
→ 素朴な bpc レジスタ化は不可。bpc 投機前進 (毎cyc +4) は miss 時に未配信アドレスを飛ばす (roll-back 必要)。

### 20.3 解 = FTQ 型 (案 B; imem_addr をレジスタ配列読みに)
```
gen_pc (word 整列 reg) : 毎サイクル +4 を生成し FTQ に push (imem_ready 非依存、FTQ-not-full で gate)
FTQ (アドレス reg 列)  : 先行生成アドレスのキュー
imem_addr = FTQ[head]  : レジスタ配列読み = ループ外 (imem_ready は head pop ポインタ更新のみ)
  I$ hit (imem_ready)  → FTQ head pop (次の先行生成アドレスへ = 1/cyc throughput 維持)
  I$ miss (~imem_ready)→ head 保持 = 同アドレス replay
bpc(=FTQ head) → MMU → c_addr → addr_q : register-to-register (MMU がループから外れる)
```
+ **halfword buffer**: 到着 word を 2 halfword 単位で push (各 hw_pc タグ付与)。
+ **アライナ**: buffer 先頭の組合せ抽出で命令境界 (2/4byte・ワード跨ぎ結合 = 旧 I$ straddle の役) → IF/ID 直接駆動。
  decode 以降は無改変 (`decode_inst = is_compressed ? expand(...) : inst32`)。
+ **fault marker**: 投機 word の命令ページフォールトは marker を push、**head 到達 (コミット時) のみ** taken = precise。
+ **redirect**: 既存登録 redirect (redir_pend_q) 流用、適用時に FTQ + halfword buffer を flush、gen_pc=target&~3。
- **I$ 無改変**: word 整列ゆえ straddle (boff==LINE_BYTES-2) は不発 = dead 化 (コードは変えない)。MMU/cpu/soc も
  imem_addr=FTQ head が VA レジスタなら従来結線で register-to-register 化 (§14 の登録翻訳と同型だが VA が +4
  データ非依存になった点が決定的; §16 VIPT は seq_pc データ依存で 0 利得だった)。

### 20.4 リスク・検証 (専用セッション)
- **規模**: rv_core IF 段全書換 (~200 行)。all-or-nothing (増分検証困難)。前例 = micro-ITLB は full Linux で
  panic (§14 試行1)、§17 設計も実装直前に throughput 欠陥発覚 (§17.8)。
- **利得不確実**: worst は **route 61-66% 支配** (device 混雑・LUT 62%、§16)。ループ2分割で各 cone が縮み route 減の
  見込みはあるが、**§16 VIPT は 0 利得**の前科。**切っても 50MHz 未達の可能性が残る** (実 impl 実測のみが信号)。
- **検証順** (§17.5 準拠): sim_icache(64)/sim_pipeline (アライナ基本) → sim_mmu/sv (priv/PTW) →
  sim_cache_soc/intr/amo64 (統合・割込×fetch) → compliance rv64uc-p (RVC corner)/rv64si-p (ma_fetch) →
  **full Linux NET=y** (`LINUX-USERSPACE-OK`+HARM=0+amo_prem=0+chars=11428+pc=0x1016a) → 実 impl 20ns probe で
  I$ ループ消失 + 新 worst 確認 → set_pl_freq.py 50 + build_all bit で本番 WNS≥0。
- **fallback**: full Linux で詰む / IPC 劣化大 / 利得不足なら revert (ツリー clean 起点)。worktree 推奨。

## 21. step 8 実装結果: FTQ block fetch 完成 + フェッチスキップバグ修正 (第17セッション)

§20 の FTQ 型 block fetch を**実装完了**。`rv_core.sv` IF 段を全書換 (FTQ + halfword buffer + aligner +
ifpf latch/drain)、`rv_icache.sv` の EXTRA-2 (`state==S_FILL && m_done && c_req` の addr_q 再アーム) を除去、
`rv_cpu.sv` に `imem_gnt`(=`mmu_imem_req`) を rv_core へ接続。imem_addr が完全レジスタ駆動 (redir_pend_q /
fetch_hold(bfpc) / ftq[head] の mux、全オペランドがレジスタ) になり 50MHz fetch ループ (§20.1) を遮断。

### 21.1 実装中に潰した PTW×FTQ corner 3 件 (いずれも redirect/imem_gnt 絡み)
1. **icache-alias**: mret redirect 先の PTW で redir_pend_q が早期クリア→FTQ が target をスキップ。
   修正 = `ftq[0] <= reload_addr` (target 自身を head に保持)。
2. **d000 (逐次ページ境界 PTW)**: TLB-miss でブロック中 (if_req_out=0) に FTQ head が暴走前進→mis-tag。
   修正 = `ftq_pop` を `imem_gnt` (= MMU forward 時) でゲート。
3. **handler 二重フォルト**: ifpf latch の `~redir_eff` 欠落→handler フェッチで spurious page fault。
   修正 = ifpf latch/take を `~redir_eff` ガード (旧 immediate-take 設計と同型)。

### 21.2 ⭐ 本命バグ = I$ フィル完了アドレスの serve スキップ (`rv_icache.sv`, full Linux NET=y で発覚)
**症状**: ~65.2M cyc で `security_task_fix_setgroups` の `jalr a5` が PC=0 へ (NULL deref, instruction page
fault)。逆追跡で **`security_task_alloc` 呼出 (`auipc ra; jalr -1328(ra)` @0x...f25c/f260) の `jalr` (word
@f260, 0xad0080e7) が完全スキップ**され、次 word @f264 (`mv s9,a0`=0x8caa) のデータが **PCタグ f260 で**取り込ま
れていた (aligner の PCタグ⇄データ desync)。これがデコードを 2byte ずらし→phantom branch→`ret` が
mid-instruction 0x...725c へ→auipc スキップ→a5 ガベージ→`jalr 0`。

**真因** (毎サイクル IF トレースで確定): I$ が word A (f260) のラインフィル中に、**FTQ が 1 つ先行提示した次
アドレス B (f264) の IF-TLB-miss PTW** が走り、MMU が c_req を取り下げ (`imem_gnt=0`)→I$ の `req_q` 脱落。A の
フィルは完了 (line に jalr が載る) するが、`req_q=0` のため post-fill S_LOOKUP が serve できない。B の PTW 完了で
`imem_gnt` 復帰時、I$ の **resume-prime** (`addr_q_en` の `state==S_LOOKUP && c_req && !req_q` 項) が `addr_q` を
A→B に上書き = **A (f260) の serve をスキップ**。さらにコアの `bfpc` は `imem_ready` でしか進まないため A のまま
残り、B のデータを A タグで `hb_push` (desync)。
- **step8 固有**: step7 以前は fetch ループが A を hold 再提示するため imem_addr=A のまま (resume-prime も A)→
  スキップ不発。FTQ が「1 つ先行」(imem_addr=B while A in-flight) にした結果、resume-prime が B を掴んだ。
- **検出器が沈黙した理由**: ICMIS (imem_rdata==mem[addr_q]) は I$ 内部整合ゆえ不発、HBGAP (bfpc word 単調性) は
  word 境界では崩れず、P1 (リンク値) も実バイトは正常ゆえ不発。**aligner の PCタグ⇄データ desync は専用検出が要**。

**修正** (`rv_icache.sv`, 非破壊): `fill_unserved` レジスタフラグを追加。フィル完了 (`state==S_FILL && m_done`)
でセット、addr_q serve (`c_ready`) でクリア。`addr_q_en` の resume-prime 項を `&& !fill_unserved` でゲート
= **フィル完了済み未 serve のアドレスを resume-prime が飛ばさない**。これにより A が先に serve され (bfpc=A 一致)、
次サイクルで B が正しく serve (bfpc=B)。lockstep 回復。**EXTRA-2 は再導入せず** (live c_addr 依存=ループ復活を
避ける)、fill_unserved はレジスタ→50MHz ループ遮断を維持。**厳密 no-op** (フィル完了×req_q 脱落×resume-prime の
稀ケースのみ作用、通常フィルは即 serve で fill_unserved 即クリア、BRAM/ACT は I$ 非搭載で無関係)。

### 21.3 検証 (第17セッション、全 PASS)
- 単体: sim_icache(64) 50/50・pipeline 19/19・mmu64 11/11・intr 10/10、他全ユニット (前セッション継続)。
- compliance: rv64uc-p 1/1・rv64si-p 7/7 (icache-alias/ma_fetch 含む)、**RV64 117/117**・RV32 88/88。
- **✅ full Linux NET=y → `LINUX-USERSPACE-OK: init running` (chars=11428, pc=0x1016a, ~450M cyc, vpe=160)**。
  全 450M+ cyc で fetch 異常検出器 (ICMIS/HBGAP/JMP0/MIDX) すべて 0 発火 = フェッチ完全クリーン。

### 21.4 ✅✅ 50MHz timing 達成 = フェッチループ worst から消失 (build_physopt 20ns aggr)
再 synth (`build_zybo.tcl synth`, 0 Critical/0 Error) → `build_physopt.tcl 20.0 aggr` (50MHz, ExtraNetDelay place +
AggressiveExplore route):
- **post-route WNS = +0.491ns = MEET @ 50MHz** (physopt は WNS≥0 でスキップ)。
- **step7 比 +0.945ns** (step7 同 aggr probe = post-route -0.454 / physopt +0.021、binding=I$ フェッチループ ~19.8ns
  = ~46MHz 壁)。**step8 でフェッチループが top worst から完全消失** = §20 の主目的達成。
- **新 worst path (MET, +0.491ns)**: `u_fpu/u_fma_add_d/sum_q_reg[13] → ex_mem_fpu_result_f_reg[37]`
  (19.363ns, logic 6.55 / **route 12.8=66%**, Logic Levels 34, CARRY4=15) = **FPU FMA-D 加算器の第2段 (sum_q)→出力**。
  step7 は FMA-D 加算器の*オペランド* (`fc_q`) を登録したが、加算器内部の `sum_q→output` 経路が残存し新 binding 化。
  だが 50MHz で MEET。route 66% 支配は §16 の device サイズ起因と整合。
- **結論**: step8 (FTQ block fetch + fill_unserved 修正) で **I$ フェッチループ遮断 → aggr 50MHz MEET (+0.491ns)**。
  §18 の「現 RTL ~45MHz 射程・fetch ループは binding でない」は緩制約のアーティファクトで、step7 後はフェッチループが
  真の binding (~46MHz) だった事を step8 が実証 (除去で +0.945ns)。
- **❌ default flow 本番 50MHz = NOT MET (-0.494ns)**: `set_pl_freq.py 50` → `build_all.py --stage bit` (default
  strategy) の post-route = **WNS -0.494ns, 16 failing endpoints, TNS -2.121ns** (hold OK +0.026ns; bitstream は生成
  されるが timing dirty)。binding (default routed, `..runs/impl_1/bd_riscv_wrapper_timing_summary_routed.rpt`) =
  `u_muldiv/rs1_q → u_fpu/misc_d_result_f_q[56]` (-0.494) / `fa_q → misc_d_result_i_q[9]` (-0.466) = **FPU misc-D /
  FMA-D の第2段組合せ tail** (route ~66%)。aggr-default gap は ~1ns (step7 の ~2ns より縮小 = step8 効果) だが default
  では未達。
- **ユーザ方針 = 実機ビットストリームは default strategy 固定** (Performance に逃げない)。→ **第18セッション = FPU
  misc-D/FMA-D 第2段を step5/7 同型で段化し default 50MHz を WNS≥0 化** (`docs/next_session_prompt.md`)。step5 は misc
  出力 (`misc_*_q`)、step7 は加算器オペランド (`fa_q/fb_q/fc_q`) を登録済 → 残る compute→出力 tail を更に分割。route
  66% 支配ゆえ段化後は default+aggr 両方を impl 実測 (logic を割っても route 支配なら worst が別経路へ移るだけ; §16)。

## 22. ✅ step 9 = FPU misc-D 第2段の段化 (第18セッション; `rv_fpu_misc_d.sv` を 2 段パイプライン化)

§21 の default 50MHz binding (`u_muldiv/rs1_q → misc_d_result_f_q` 等 = **FCVT.D.W / FCVT.W.D の第2段組合せ
tail**) を、step5/7 と同型の**内部レジスタ 1 段挿入**で段化した。**FPU を worst から完全除去**。

### 22.1 変更 (`rv_fpu_misc_d.sv` を combinational→2 段化、`rv_fpu.sv` は clk/rst_n 結線のみ)
`rv_fpu_misc_d` はこれまで「rv_fpu の stage A 演算子レジスタ (`fa_q/int_a_q`) → **単一組合せ cloud** →
stage B 結果レジスタ (`misc_d_result_*_q`)」の 1 アークだった。この cloud の最長 = FCVT.D.W (int→double: 2'scomp+
LZC64+バレルシフト+丸め+組立 → 指数ビット `result_f[56]`) と FCVT.W.D (double→int: 117bit バレルシフト+丸め+符号補正
→ `result_i[9]`)。**内部 free-running レジスタ 1 段**で 2 ステージに分割:
- **stage 1**: 安価 op (FSGNJ/FMINMAX/FCMP/FCLASS/FMV) 全算出、FCVT.D.W の重い部分 (mag+LZC+シフト+GRS 抽出)、
  FCVT.W.D の special-case 検出 (nan/inf/zero/exp<0/overflow → 結果+flag を先に確定)、FCVT.S.D / FCVT.D.S 全算出。
- **stage 2** (登録 `s1_*` から組合せ): FCVT.D.W の丸め+組立、FCVT.W.D の in-range normal (シフト+丸め+符号補正+
  クランプ)、出力 mux。両 FCVT のバレルシフトが別ステージに分かれ各ステージ ~1 シフト分でバランス。
- **レイテンシ中立 = COMB_LAT 不変 (=2)**: 旧 misc 経路は capture に 1 cycle slack (結果 valid T+2 / capture T+3)
  があった。内部 1 段で結果は T+3 valid になり capture T+3 = ちょうど一致 (slack を消費)。stage A→s1→stage B の
  3 レジスタ境界で旧 1 アークを 2 アークに分割。**rv_core 無改変・FMADD/FADD 経路 (adder) も無改変** (adder は
  別 binding でなくなった → §22.3)。`fa_q` は busy 窓で hold される free-running ゆえ stage1 が cycle T+1 で正値を読む。

### 22.2 検証 (全 PASS・非破壊)
- ユニット: sim_fpu 94/94, sim_fpu_d 33/33, sim_fpu_pipe 7/7, sim_pipeline 19/19, sim_intr 10/10。
- compliance FP: RV64 uf 11 + ud 12 = 23/23, RV32 uf 11 + ud 10 = 21/21 (FCVT/FMV/FCMP/FCLASS/FADD/FMADD/ldst)。
- **full Linux NET=y**: `chars=11428` (baseline ビット一致)・HARM=0・amo_prem=0・ICMIS/HBGAP/JMP0/MIDX 0 発火・
  pc=0x1016c (userspace idle)。FP-only ゆえ Linux はビット一致。

### 22.3 実 impl 効果 (20ns default probe = `build_physopt.tcl 20.0 def`; 再 synth 後)
| | step8 (misc-D 未段化) | step9 (misc-D 2 段化) |
|---|---|---|
| default post-route WNS | **-0.494ns** | **-0.203ns** (+0.291) |
| 失敗エンドポイント | 16 | **4** |
| TNS | -2.121ns | **-0.475ns** |
| binding | FPU misc-D / FMA-D 第2段 | **load→branch→flush (非 FPU)** |

- **FPU は top-10 worst から完全消失** (FMA-D `sum_q` 第2段 = step8 aggr binding も -0.203 以下に沈み、§19/§21 で
  「次は adder sum_q を split」と見込んだ adder 段化は**不要**だった)。
- post-route phys_opt 1 発で +0.089ns (MET) まで到達するが、これは default flow 外の追加ステップ。
- **新 binding (4 EP, 全て -0.203ns, 単一経路族)**: `gen_dcache.u_dc/data_reg (D$ BRAM) → dc_c_rdata →
  load 整形 (fpld_data_q / byte_offset / funct3 符号拡張, u_periph 領域に配置) → MEM/WB forward (fwd_rs2_data) →
  u_branch 比較 (CARRY4×4) → branch_taken_ex → redir_eff/flush_ex → id_ex_csr_addr_reg[6]/CE`。
  19.736ns, **logic 30% / route 70%**, 19 levels。= **同期 BRAM ロード→整形→MEM/WB フォワード→分岐解決→flush**
  の単一サイクル経路。FPU 非依存ゆえ FPU 段化では削れない。
- **次セッション課題 (別タスク化)**: この load→branch→flush 経路を RTL で詰める = ロード結果のレジスタ化
  (+1 load-use レイテンシ) か branch-resolve/flush の再構成。マイクロアーキ変更ゆえ **full Linux NET=y 必須再ゲート** +
  IPC 影響注意。route 支配 (§16) ゆえ logic 分割の利得は不確実 → 実 impl 実測必須。gap は -0.203ns / 単一経路族のみ。

### 22.4 コミット範囲 (第18セッション)
`src/rtl/fpu/rv_fpu_misc_d.sv` (2 段化) + `src/rtl/fpu/rv_fpu.sv` (u_misc_d に clk/rst_n) のみ。board 設定 (50MHz)
は §21 で適用済 (本コミットでは RTL のみ)。実機 bring-up は load→branch 経路 closure 後。
