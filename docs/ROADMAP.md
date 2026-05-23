# RISC-V Linux移植ロードマップ

**プロジェクト全体進捗: 65% (Phase 0完了、Phase 1完了)**

---

## Phase 0: CPU/MMU基盤構築 ✅ **100% 完了**

CPU、メモリ管理、基本的な割り込みシステムの実装。

| 項目 | 進捗 | 説明 |
|---|---|---|
| **RV32I/RV64I基本命令セット** | ✅ 100% | 5段パイプラインで完全実装 |
| **M拡張（乗算・除算）** | ✅ 100% | rv_muldiv.sv、MUL/DIV/REM対応 |
| **A拡張（アトミック操作）** | ✅ 100% | rv_amo.sv、LR/SC/AMO* 実装 |
| **C拡張（圧縮命令）** | ⏸ 0% | 未実装（RV32C/RV64Cの展開デコーダ） |
| **Zicsr拡張（CSR命令）** | ✅ 100% | rv_csr.sv で Machine/Supervisor CSR 完全実装 |
| **MMU (Sv32/Sv39)** | ✅ 100% | rv_mmu.sv、TLB(16entry)、ページングフル対応 |
| **M-mode トラップハンドリング** | ✅ 100% | mtvec/mepc/mcause/mstatus 実装 |
| **S-mode トラップハンドリング** | ✅ 100% | stvec/sepc/scause/sstatus 実装 |
| **割り込み優先度** | ✅ 100% | MEIP(11) > MSIP(3) > MTIP(7) > SEIP(9) > SSIP(1) > STIP(5) |
| **機械タイマー（MTIP）** | ✅ 100% | rv_timer.sv、mtime/mtimecmp レジスタ |
| **スーパーバイザータイマー（STIP）** | ✅ 100% | mideleg経由で委譲可能 |
| **テストベンチ** | ✅ 100% | tb_rv_csr.sv / tb_rv_timer.sv / tb_rv_supervisor.sv（全 PASS） |

**成果物:**
- `rv_core.sv`: 5段パイプラインCPU (XLEN=32/64 切り替え可)
- `rv_csr.sv`: CSR実装（machine/supervisor privilege）
- `rv_mmu.sv`: MMU + PTW（ページテーブルウォーカー）
- `rv_timer.sv`: CLINT互換タイマー周辺機器

---

## Phase 1: SoC統合・周辺機器 ⏳ **60% 進行中**

CPU + メモリ + I/O周辺機器の統合、ボード対応。

### Phase 1a: 周辺機器実装 ✅ **100%**

| 周辺機器 | 進捗 | 説明 |
|---|---|---|
| **UART（8N1）** | ✅ 100% | rv_uart.sv、TX/RX状態機、ボーレート可変 |
| **タイマー** | ✅ 100% | rv_timer.sv（既述） |
| **GPIO入出力** | ✅ 100% | rv_soc.sv で 4-bit GPIO バス |
| **割り込みコントローラ（PLIC）** | ✅ 100% | rv_plic.sv 実装済み (8src/2ctx) |
| **シリアルドライバ（CLINT）** | ✅ 100% | 機械タイマー+割り込みトリガ |

**成果物:**
- `rv_uart.sv`: メモリマップ UART（DATA/STAT/CTRL/DIV レジスタ）
- `rv_timer.sv`: mtime/mtimecmp レジスタ、MTIP生成

### Phase 1b: SoC統合 ✅ **100%**

| 項目 | 進捗 | 説明 |
|---|---|---|
| **SoC トップモジュール** | ✅ 100% | rv_soc.sv（CPU+MMU+Mem統合） |
| **UART統合** | ✅ 100% | rv_uart.sv 統合（0xC001_0000） |
| **タイマー統合** | ✅ 100% | rv_timer.sv 統合（0xC000_0000） |
| **GPIO統合** | ✅ 100% | rv_gpio.sv 統合（0xC002_0000、OUT/IN/DIR/IRQ_EN） |
| **PLIC統合** | ✅ 100% | rv_plic.sv 統合（0xC010_0000、8src/2ctx、Claim/Complete） |
| **メモリレイアウト** | ✅ 100% | 確定：IMEM@0x0, DMEM@0x8000_0000, Timer@0xC000_0000, UART@0xC001_0000, GPIO@0xC002_0000, PLIC@0xC010_0000 |

**統合内容:**
- 全周辺機器を物理アドレス [31:16] で選択、組み合わせ論理で即座にready
- Timer割り込み(MTIP) → rv_core.timer_irq
- UART RX/TX、GPIO変化 → PLICソース → rv_core.ext_irq（Mモード外部割り込み）
- PLICがSモードコンテキスト(ext_irq[1])も持ち、将来のmideleg委譲に対応

### Phase 1c: ボード対応 ✅ **100%**

| ボード | 進捗 | 説明 |
|---|---|---|
| **Zybo Z7-20** | ✅ 100% | zybo_z7_top.sv（rv_soc 接続） |
| **Kria KV260** | ✅ 100% | kv260_top.sv（rv_soc 接続） |
| **XDC制約** | ✅ 100% | clock/button/LED/Pmod UART定義 |

**成果物:**
- `boards/zybo_z720/zybo_z7_top.sv`: Zybo Z7-20 トップ
  - sysclk (125MHz) → clk
  - btn[0] (active-H) → rst_n (active-L)
  - sw[3:0] → gpio_in、gpio_out → led[3:0]
  - Pmod JE[0]=UART_TX, JE[1]=UART_RX
- `boards/kv260/kv260_top.sv`: Kria KV260 トップ

---

## Phase 2: ブートシーケンス ⏹ **0% (未開始)**

FPGA初期化、リセットからLinuxカーネル起動まで。

| 項目 | 進捗 | 説明 |
|---|---|---|
| **ブートローダー（OpenSBI）** | ⏹ 0% | M-mode ファームウェア、ページングセットアップ |
| **デバイスツリー（.dts）** | ⏹ 0% | RISC-V CPU/MMU/UART/Timer定義 |
| **ブートプロトコル** | ⏹ 0% | kernel entry @ 0x80200000、a0=hartid, a1=fdt |
| **メモリレイアウト（最終）** | ⏹ 0% | OpenSBI @ 0x80000000, Kernel @ 0x80200000, DTB, Rootfs |
| **システムクロック** | ⏹ 0% | 125MHz（Zybo）or PL clock（KV260） |

**必要な作業:**
1. OpenSBI をコンパイル・カスタマイズ
2. Device Tree Compiler（DTC）でボード用 .dts 作成
3. 初期化コード（CRT0）：M-mode 割り込みハンドラ、page table setup

---

## Phase 3: Linuxカーネル移植 ⏹ **0% (未開始)**

Linux 5.x以上の RISC-V ポート活用・ビルド。

| 項目 | 進捗 | 説明 |
|---|---|---|
| **カーネルソース** | ⏹ 0% | linux-riscv リポジトリ clone |
| **コンフィグ** | ⏹ 0% | .config（RISC-V, MMU, 32/64-bit選択） |
| **.ko ビルド** | ⏹ 0% | defconfig or custom config → bzImage/vmlinux |
| **デバイスドライバ** | ⏹ 0% | UART driver（既存 8250 利用 or カスタム） |
| **割り込みハンドラ** | ⏹ 0% | Linux PLIC driver（if needed） |
| **ページング** | ⏹ 0% | Sv32/Sv39 サポート確認 |
| **システムコール** | ⏹ 0% | glibc ABI 互換 |

**必要な作業:**
1. `make ARCH=riscv defconfig` で基本設定
2. UART, MMU デバイス有効化
3. `make ARCH=riscv CROSS_COMPILE=riscv64-unknown-elf- -j8`

---

## Phase 4: ユーザースペース・ルートFS ⏹ **0% (未開始)**

Linuxアプリケーション環境構築。

| 項目 | 進捗 | 説明 |
|---|---|---|
| **ツールチェーン** | ⏹ 0% | riscv64-unknown-elf-gcc/binutils（既存使用） |
| **glibc** | ⏹ 0% | RISC-V glibc ビルド |
| **BusyBox** | ⏹ 0% | initramfs 用ミニシェル・ユーティリティ |
| **ルートファイルシステム** | ⏹ 0% | ext4/initramfs で / 構築 |
| **ブートスクリプト** | ⏹ 0% | /etc/init.d/rcS で UART init |

---

## Phase 5: 検証・最適化 ⏹ **0% (未開始)**

パフォーマンス、スケーラビリティ。

| 項目 | 進捗 | 説明 |
|---|---|---|
| **性能測定** | ⏹ 0% | dhrystone/coremark ベンチマーク |
| **マルチコア** | ⏹ 0% | 現在はシングルコア |
| **仮想化（KVM）** | ⏹ 0% | Hypervisor 実装 |

---

## 現在地：Phase 1 完了 → Phase 2 (ブートローダー) 開始へ

```
Phase 0:  ████████████████████ 100% ✅  CPU/MMU基盤
Phase 1a: ████████████████████ 100% ✅  周辺機器実装 (Timer/UART/GPIO/PLIC)
Phase 1b: ████████████████████ 100% ✅  SoC統合 (アドレスデコード+割り込み)
Phase 1c: ████████████████████ 100% ✅  ボード対応 (Zybo Z7-20)
---
Phase 2:  ░░░░░░░░░░░░░░░░░░░░ 0%   ⏹  ブート (OpenSBI + DTB)
Phase 3:  ░░░░░░░░░░░░░░░░░░░░ 0%   ⏹  Linux カーネル
Phase 4:  ░░░░░░░░░░░░░░░░░░░░ 0%   ⏹  ユーザー空間
Phase 5:  ░░░░░░░░░░░░░░░░░░░░ 0%   ⏹  最適化

全体: █████████████░░░░░░░ 65%
```

### フルSoCメモリマップ（確定版）
| 物理アドレス | 周辺機器 | 説明 |
|---|---|---|
| 0x0000_0000 | IMEM | 命令メモリ（最大32KB） |
| 0x8000_0000 | DMEM | データメモリ（最大16KB） |
| 0xC000_0000 | Timer/CLINT | mtime/mtimecmp (MTIP) |
| 0xC001_0000 | UART | 8N1 115200bps DATA/STAT/CTRL/DIV |
| 0xC002_0000 | GPIO | OUT/IN/DIR/IRQ_EN (LED/SW) |
| 0xC010_0000 | PLIC | 8src/2ctx Priority/Pending/Enable/Threshold/Claim |

---

## 次の優先タスク（Phase 2: OpenSBIブートローダー）

1. **OpenSBI ビルド環境構築** (medium) ⏳ **次のステップ**
   - riscv-gnu-toolchain（既インストール）を確認
   - OpenSBI リポジトリのclone・ビルド
   - Zybo Z7-20 プラットフォーム設定作成

2. **Device Tree (.dts) 作成** (medium)
   - CPUノード（RV32I + M/A/Zicsr拡張、Sv32ページング）
   - メモリノード（IMEM@0x0, DMEM@0x8000_0000）
   - Timer/CLINT、UART、GPIO、PLICのデバイス記述
   - Zybo Z7-20 ボード用 .dtsi 作成

3. **ブートプロトコル実装** (large)
   - リセットエントリー (0x0) → M-modeファームウェア
   - OpenSBI @ 0x8000_0000 → カーネルに委譲
   - a0=hartid, a1=DTBアドレスの受け渡し

**完了したタスク（Phase 1）:**
- ✅ Timer統合（0xC000_0000）, UART統合（0xC001_0000）
- ✅ GPIO統合（0xC002_0000、LEDとスイッチ対応）
- ✅ PLIC統合（0xC010_0000、M/Sモード2コンテキスト）
- ✅ ユニットテスト：121/121 全パス
- ✅ フルSoCコンパイル：0エラー

---

## 必要な外部リソース

- **RISC-V ISA仕様**: https://riscv.org/technical/specifications/
- **OpenSBI**: https://github.com/riscv-software-src/opensbi
- **Linux RISC-V**: https://github.com/torvalds/linux (arch/riscv)
- **Device Tree**: https://devicetree.org/
- **RISC-V Tools**: riscv-gnu-toolchain (既インストール: riscv64-unknown-elf-gcc)

---

## リスク・制約

| リスク | 影響 | 対策 |
|---|---|---|
| **XLEN 32/64の自動切り替え不安定** | Medium | 32-bit 固定でLinux 32-bit版を目指す |
| **PLIC未実装** | Medium | ひとまず割り込みなしで起動、後付け |
| **C拡張未実装** | Low | Linux自体は使用するが、ユーザーアプリには影響小 |
| **FPU（浮動小数点）未実装** | Low | ソフトウェアFP で対応 |
| **外部割り込み（PLIC）** | Medium | MMIO レジスタで手動制御（開発段階） |

---

## 参考：他のRISC-V Linux実装例

- **Rocket Chip（UC Berkeley）**: フル64-bit RISC-V、Berkeley Boot ROM + Linux
- **SiFive HiFive**（商用）: SoC実装、Linux対応
- **VexRISCV（LiteX SoC）**: オープンソース、Linuxベースシステム

本プロジェクトは SiFive 相当の規模を目指しているが、単一の小コアのため性能は低め。
