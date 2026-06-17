# RTL バグ修正履歴・実装メモ

CLAUDE.md から分離 (2026-06-17 のシュリンク時)。コア/周辺/FPU の RTL バグ修正の詳細な切り分けと実装メモ。
要約・設計判断は CLAUDE.md の "Key Design Decisions"、起動環境は `docs/{opensbi_sim,linux_sim}.md` を参照。

---

### 実装メモ: C / RV32D / PMP / 不正命令 / iverilog クリーン化 (2026-05-31)
> 詳細は memory `project-riscv-status` と下記「Key Design Decisions」。ここは要点のみ。
- **C 拡張 (RVC→RVI 展開)**: `rv_cdecode.sv #(XLEN)` が 16bit を 32bit に純組合せ展開→既存 `rv_decode` へ。
  rv_core IF を**可変長フェッチ**化 (`fetch_pc` + `seq_pc=fetch_pc+(imem_rdata[1:0]!=11?4:2)`)。重大バグ=
  SRET/MRET の特権 1 サイクル遅延中に VA を物理フェッチ→X→PC 破壊 → **`redirect_settle`** で任意リダイレクト
  後 2 サイクル IF/ID 保持 (stall_if/id のみ、**stall_ex 厳禁**)。`is_compressed` で link=PC+2。前提=byte
  アドレッシング可能 IMEM (語固定 rv_imem の 4byte 跨ぎは未対応=範囲外、RVC compliance は ACT モード)。
- **RV32D (64bit FLD/FSD)**: RV32 dmem=32bit なので 2-word アクセス (必ず 4byte 境界跨ぎ→既存 mal FSM)。
  重大バグ=連続 FLD で MEM/WB が前命令を保持し live dmem_rdata 変化で二重書き → 保持を**バブル挿入**に。
- **PMP CSR (16 エントリ WARL)**: pmpcfg/pmpaddr 格納のみ。**アクセス強制は未実装** (arch-test フェーズ予定)。
- **不正命令例外**: `rv_decode.illegal` (未知 opcode/不正 shamt/RV32 の W 形)→ EX で cause=2, mtval=命令。
  圧縮は `rv_cdecode.illegal`。rv*mi-p-illegal は vectored mtvec/TSR/TVM/TW も要すため未 PASS。
- **iverilog v12/v13 クリーン化**: 連結内 enum・always_comb 内ローカル変数/for/case enum・正確な幅広 casez は
  両版で正常 (旧「iverilog 制約」コメントは誤り)。**幅広 LZC は `for`+last-write-wins** に統一 (memory
  `feedback-sim-env`)。RV32 ACT 経路整備 (TB の `.XLEN(rv_pkg::XLEN)`、rv_unified_mem の `d_boff`、rv_core の
  RV32 `amo_shift` ガード、Makefile XLEN_DEF/build32)。

### RTL バグ修正履歴 (要約; 詳細な切り分けは git 履歴 / `docs/{opensbi_sim,linux_sim}.md`)
**⚠️ 共通の真因 = 可変レイテンシ (I$ hit/miss 混在 stall・PTW・割込) でのみ顕在し、BRAM(常時 ready)/
bypass(常時 stall)/vm off では非発火。** 全修正は `imem_ready=1`/`dmem_wait=0`/vm off で厳密 no-op になる形で
入れ非破壊を構造保証。各 #N は `src/software/boot/*_test.S` で回帰。表記: 症状 → 修正 (ファイル)。

caches-on 可変レイテンシで OpenSBI/Linux が露見させた制御フロー/フォワード系 (主に `rv_core.sv`):
- **#1** EX 凍結中フォワード元喪失→ストアアドレス破壊 → ID/EX hold 中フォワード済みオペランドを毎サイクルラッチ。`stack_test.S`
- **#2** IF 凍結中 MEM/WB ロード再書込破壊 (新ロードが live `dmem_rdata` 変化) → `mem_wb_fresh` で `dmem_rdata_held` にラッチ
- **#3** JAL/JALR リンク書込喪失 (flush_ex が `& imem_ready` のみ) → `flush_ex = (load_use|redir_eff) & ~stall_ex` (前進条件一致)
- **#4** EX 段 CSR 書込/trap/MRET が stall_ex 中多重発火 (例外ストーム真因; `csrrw tp,mscratch,tp` が tp 喪失) → `csr_commit_ex=~stall_ex` で 4 信号+tlb_flush/fence_i+flush_ex_mem をゲート
- **#5** I$ がフィル中の変換変更で stale PA ライン serve (MRET bare→S 遷移; サイレント panic 真因) → 完了時 `addr_q<=c_addr` 再武装 + BYPASS serve を `req_q && addr_q==c_addr_q` でガード (`rv_icache.sv`)。`tb_rv_icache` translation-mid-fill 50/50
- **#6** SC が IF stall 中 reservation 自壊「書込成功なのに rd=失敗」(cmpxchg 永久失敗→printk 全滅) → reservation 更新を `!amo_stall&&!mal_stall&&!dmem_wait&&imem_ready` に。`atomic_test.S`
- **#7** LR/SC reservation が trap/xRET を生き延び割込ハンドラ AMO を握り潰す → `lrsc_kill`(コミットゲート済み trap/mret/sret/ifpf) でクリア。`lrsc_irq_test.S` (⚠️再武装は絶対スケジュール+素数 STEP 必須)
- **#11** AMO 2 相 FSM が変換待ち (`mem_stall`) を read 完了と誤認し stale data で write (refcount 破壊真因; vm 有効時のみ) → amo/mal/reservation/MEM-WB capture に `!mem_stall` 追加 (`rv_core.sv`)
- **#15 (mal restart-livelock; full Linux で発覚 2026-06-14)** misaligned 2 相アクセス FSM (`mal_state`) が phase1 (両ワードアクセス完了) まで進んでも、命令が `~imem_ready` (I$ ライン fill / **straddle-bypass** が毎サイクル ready でない) で **retire できない**サイクルに `mal_state` を**無条件で 0 リセット**→次サイクル `mal_stall` 再発→phase0 やり直し→`stall_if` 永久 high で**割込も取れず livelock**。`amo_state` (OpenSBI 期に `!amo_active` 保持で修正済) と完全同型だが **mal だけ未対策**だった (muldiv `#14`/`fpu_done` と同じ restart-livelock クラス)。**`afe5f4a` 以前から潜在**し、C-2a/C-2c の多サイクル化がパイプラインタイミングをずらして初めて露見 (C-2b BRAM は derail 地点を変えただけ=根本原因でない)。修正: phase1→idle リセットを **retire (`~stall_ex`) で gate** (`else if (mal_state && stall_ex) mal_state<=1;` で保持; `rv_core.sv`)。phase1 では `mal_stall=0` なので `stall_ex` は無関係 stall のみ反映。**BRAM/1-cycle mem では retire 時 `stall_ex=0` で厳密 no-op** (全 unit/compliance/mini-SBI でビット一致確認)。⚠️ `amo_state` 流の `!mal_cross` リセットは不可 (mal_state は全 load/store が参照し 1cy 遅れで次命令を mis-address する; retire 同期が必須)。発見=`[EX]` トレースで停止命令 (kernel PC `0x765a` の misaligned C.SD, straddle fetch `0x765e` と coincidence) が `mal=1` トグル+全多サイクル0 を示した。回帰=**full Linux boot が userspace "LINUX-USERSPACE-OK" 到達**で確認 (旧 RTL は devtmpfs 直後 ~76M で hang)。**bare repro = `src/software/boot/mal_cachemiss_test.S`** (`make mal_cachemiss_test` → `vl_boot BOOT_HEX=...mal_cachemiss_test.hex`): タイマ割込ハンドラ入口の cold-fetch I$ fill (`~imem_ready` 高) 下で misaligned 8byte store+load を回し、絶対スケジュール素数 STEP で位相 sweep。旧 RTL は handler で livelock (timeout)、修正 RTL は PASS。⚠️ 別件メモ (→ **#16 として解決済**): メインループ側で misaligned **load** を pre-fill 値と照合する変種が #15 修正後でも FAIL した件は #16 (下記) が真因だった。
- **#16 (misaligned LOAD の phase-0 語が flush_ex_mem で消失; 2026-06-15)** misaligned 8byte LOAD が MEM 段で正当に retire するサイクルに、**より若い EX 段命令にタイマ割込が取られる**と `flush_ex_mem` (本来 EX→MEM 遷移をバブル化し割込された EX 命令を squash する信号) が **mal FSM を無条件 reset**し、`mal_first_data` 捕捉サイクル (`mal_phase1_start`) に**0 クリア**→load は phase-1 (上位語) だけ書き戻し phase-0 (下位語) が 0 になる。D$ miss で phase-1 read が長引くと割込×retire の coincidence が頻発。**真因 = mal FSM (ex_mem=MEM 段の古い load に属す) を、より若い id_ex 命令の squash 用 `flush_ex_mem` で reset していた混同**。`mem_trap_enter` (load/store 自身の MEM フォルト) の時だけ reset すべき。修正 (`rv_core.sv`): reset 条件を `flush_ex_mem` → `mal_squash = mem_trap_enter & ~stall_ex` に。EX 割込/MRET/SRET/IF page fault では古い load を完走させ捕捉済み phase-0 語を保持。**`flush_ex_mem` は phase-1 retire サイクル (`stall_ex=0`→`dmem_wait=0`) でしか立たず mid-access では立たない**ので、MEM フォルト以外では else 分岐が retire 時に mal_state を idle 化+phase-0 捕捉するため**動作変化は「phase-0 語を 0 クリアしない」だけ**=厳密 no-op (mini-SBI vl_boot `IF=573 data=4` 不変)。発見=`mal_cachemiss_test` 作成中の別件として、`[MALCAP]`/`[MALBUG]` 一時計装で `flush_ex_mem & mal_phase1_start` 衝突時の 0 クリアを実測。**bare repro = `src/software/boot/mal_load_irq_test.S`** (`make mal_load_irq_test` → `vl_boot BOOT_HEX=...mal_load_irq_test.hex`): pre-fill した misaligned 8byte 値を割込 ON のホットループで load 照合 (絶対スケジュール素数 STEP で位相 sweep)。旧 RTL は phase-0 欠落で FAIL (例: i=17 loaded=`abcd000000000000` exp=`abcd000000000011`)、修正 RTL は PASS。`-DNOIRQ` 制御ビルドは旧 RTL でも PASS (round-trip 自体は正常)。回帰=full Linux boot `LINUX-USERSPACE-OK` 到達 + RV64 117/RV32 88 + 全 bare repro (#14/#15/atomic/lrsc)。

周辺/CSR/割込配信系 (タイマ割込ゼロ = idle 固着の真因群):
- **#8** CLINT 32-bit バス限定で OpenSBI の 64bit mtimecmp 書込が上位語喪失→MTIP 不発 → `rv_timer` XLEN 化 (wstrb 半語/全語) + `rv_periph` wstrb + 32bit 周辺 `wdata32` レーン補正
- **#9** S/U-mode 中の非委譲 M 割込が取られない → `m_irq_en = (priv==M)? mstatus_mie : 1'b1` (`rv_csr`)
- **#10** CSR existence/特権チェック無し→OpenSBI が Sstc 誤検出し幻の stimecmp へ set_timer → `csr_access_ok`+illegal 例外
- **#12** UART に TX FIFO 無く ttyS0 切替で 16→1 文字 → 16-byte TX FIFO (⚠️push はエッジ修飾必須; 凍結中 req レベル保持で重複)
- **#13** PLIC 非標準マップで Linux が S-context enable できず (userspace tty 喪失=P0-5 真因) → `rv_plic` を標準 SiFive マップに (enable@0x2000+ctx*0x80, claim@0x200000+ctx*0x1000) + `rv_periph` 窓 0xC010_0000..0xC03F_FFFF。`tb_rv_plic` 36/36
- **#13b** 共有 ext_irq の MEIP 横取り → `MEIP=ext_irq&~mideleg[9]` / `SEIP=ext_irq&mideleg[9]` (`rv_csr`)
- **(harness) `MTIME_DIV`** プリスケーラ (既定 1=no-op): mtime=+1/cy だと HZ=250 tick が tick_handle_periodic livelock → Linux は `BOOT_MTIME_DIV=64`

OpenSBI 初期 (2026-06-04): AMO 2 相二重実行 (書込相を `!amo_active` 保持) / rv_icache `addr_q` は `c_ready` 時のみ更新 /
rv_axi_burst_bridge 最終ビート `rdata_hold` / rv_timer 標準 SiFive CLINT 化 (msip→sw_irq) / rv_periph RV64 MMIO ロード全レーン複製。
旧 FPU/CSR (2026-05-28〜30): FDIV/FSQRT が FP reg 未書込 (`fpu_start_stall`) / 特殊ケースハング (`special_pending`) /
rv_fpu_div 2 倍余りドメイン化 / AMO 8byte ワード内オフセット / MHARTID X 伝播・mstatus64 UXL/SXL・CSR の EX/MEM フォワード。

### C-2a 多サイクル除算で見つけた #14 + Linux 回帰の最終判定 (2026-06-11/12)
- **#14 (restart livelock; 修正済)**: 除算完了サイクルに無関係 stall (`~imem_ready` I$ フィル等) が掛かると retire できず
  次サイクル `muldiv_valid_in` 再発火→除算が永久再起動。`muldiv_done` ラッチで抑止 (`rv_core.sv`)。`div_irq_test.S`。
- **✅ C-2a の full Linux boot 回帰は HW バグでないと確定 (2026-06-12)**: `dev_boot_phase` BUG_ON (`unregister_netdevice_many_notify`
  入口 ebreak) は分周器でも MMU でもなく **エントロピー依存のカーネル脆弱性 (RNG ルーレット)**。決定打 =
  `BOOT_MTIME_INSTR=1` (TB から mtime/mcycle を retire 累積で force 上書きし baseline/C-2a のエントロピーを命令単位で一致)
  で **baseline (単サイクル除算) も同じ BUG を踏む**。前任の「MMU PA[21] 反転」「lost store」「実 RTL バグ」診断は全て誤り
  (PTW は正常、`+0x200000` は OpenSBI カーネルロードオフセット)。詳細 memory [[linux-boot-roadmap]]。**→ C-2a 採用可。**

---

### D拡張 (2026-05-30) 実装時のバグ修正 (詳細は memory `project-riscv-status`)
- **FPU index 系**: FDIV.D 商抽出 [55]→[54]、FSQRT.D 基数配置 [111:59]→[110:58]/frac [55:4]→[54:3]、
  FSUB.D の LZC (真因=53bit casez の `?` ミスカウント→**ループ式 LZC に統一**)、FMUL.S サブノーマル多ビット正規化。
- **NaN-box / 変換**: FMV.X.W は生下位 32bit 転送、FCVT.S.D サブノーマル出力。
- **rv_hazard FP ロードユース f0 見逃し**: `!= '0` ガード削除 (FP の f0 は実レジスタ)。
- **MPRV + Sv39 superpage + MEM 変換ストール** (rv64si-p-dirty): mstatus.MPRV、データ実効特権 `priv_data`、
  Sv39 giga/megapage、**`mem_stall = vm_data & mem_req & !mem_tlb_hit & !mem_fault` を `stall_ex` に追加**
  (MEM の TLB ミス→PTW 中に store が消えるのを防ぐ)。**⚠️ IF ポート PTW (`mmu_stall`) は stall_ex に入れない**
  (EX の分岐/MRET/トラップ解決を凍結し制御フロー破壊。icache-alias がこの理由で一度回帰)。
- **ACT TB を rv_soc 化**: MMU 込みで VM テスト可能に。rv_core に `if_fault`/`mem_fault` (page fault 例外) 追加。
