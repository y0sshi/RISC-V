# archive/

ビルド対象外の退避置き場。ここのコードは現行の sim / 合成 / テストフローから
**一切参照されない**（filelist / Makefile / tcl に登録しない）。歴史的参考のためだけに残す。

## old/

`old/rv32i/` — 初期の RV32I 単体プロジェクト一式（独自の Vivado tcl / HDL / mem.dat）。
現行コア (`src/rtl/`) の前身。2026-06-18 に `src/rtl/old/` から退避（どのビルドからも未参照だったため）。
復元が必要なら git 履歴（rename として記録）から取り出せる。
