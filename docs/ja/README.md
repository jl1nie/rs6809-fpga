[English](../../README.md) | 日本語

# rs6809-fpga

[rs6809](https://github.com/jl1nie/rs6809) の機械を Sipeed Tang Nano 20K（Gowin GW2AR-18）で動かし、rs6809 の ICE から FPGA 上の実 CPU をデバッグする。

| 機械 | CPU | メモリ | 装置 | ソフト |
|---|---|---|---|---|
| Multicomp09 互換 | cpu09p（6809、デバッグ用ポート付き） | ブート ROM 8KB、Multicomp MMU の先に SDRAM の RAM 1MB | 6850 ACIA（コンソール）、SD 制御、50Hz タイマー | SD カードから NitrOS-9 Level 1（Level 2 は MMU と 1MB はあるが未確認） |
| Tiny68K 互換 | fx68k（68000）、8MHz | SDRAM の RAM 8MB、ブート ROM `$FF0000` | MC68681 DUART（コンソール、GPIO に 2 本目）、SD カード上の IDE レジスタ | FUZIX 0.5（8MB 用に作ったカーネル）、CP/M-68K 1.3 |

rs6809 の機械モデル（`src/machine.rs`、`src/m68k/tiny68k.rs`）が仕様で、ハードウェアがそれに合わせる。計画は [docs/PLAN.md](../PLAN.md)、レジスタ表は [spec-6809.md](../spec-6809.md)、[spec-68k.md](../spec-68k.md)（英語）。

## 状況

シミュレーション（Verilator。SDRAM と 4 ビットモードの SD カードのモデルを付け、ビットストリームと同じ RTL を動かす）で確認済み：

- 6809：CamelForth → キットの SD イメージから NitrOS-9 Level 1 → BASIC09、`RUN test` で `42`。
- 68000：ブート ROM → 8MB 用に作った FUZIX 0.5 カーネル（`8192KiB total RAM, 8094KiB available to processes`）→ `login: root` でシェル。スロット 1 から CP/M-68K 1.3 → `A>`、`DIR`。
- ICE：rs6809 の `--fpga tcp:...` をシミュレーションにつなぎ、コンソール、停止、ステップ、ハードウェアのブレークポイント、NitrOS-9 のプロセス表（`tests/ice_test.py`）。

実機ではまだ動かしていない：ここでは Gowin EDA でのビットストリーム生成をしておらず、Tang Nano 20K でも試していない。最初に確かめるのは SDRAM の読み出しタイミング、BL616 のシリアルのピン（出力 69、入力 70）、タイミング収束（「実機での最初の確認」）。

## ビルド

必要なもの：Gowin EDA（Education 版で可、`gw_sh`）、Python 3、68000 の ROM 用に m68k の binutils（`apt install binutils-m68k-linux-gnu`）。シミュレーションには Verilator 5、GHDL 4、C++ コンパイラ。

```sh
# 6809：ブート ROM はキットの 6809M.bin（再配布しない。rs6809 の setup.sh が取得する）
make rom6809 ROM=../rs6809/artifacts/nitros9/6809M.bin
gw_sh m6809/build.tcl          # impl/pnr/rs6809fpga_6809.fs

# 68000
make rom68k
gw_sh m68k/build.tcl           # impl/pnr/rs6809fpga_68k.fs

openFPGALoader -b tangnano20k impl/pnr/rs6809fpga_6809.fs        # SRAM へ（-f でフラッシュ）
```

`make check6809`／`make check68k` はオープンソースのツール（Yosys、nextpnr-himbaechel）で合成と配置配線をして、Gowin EDA なしで資源とタイミングを見る。

## SD カード

6809：NitrOS-9 のイメージを LBA 0 から書く（rs6809 と同じイメージ）。

```sh
sudo dd if=../rs6809/artifacts/nitros9/multicomp09_sd.img of=/dev/sdX bs=1M conv=fsync
```

68000：カードは 512MB ずつ 4 スロット。ブート ROM がスロットを聞く（2 秒で既定の 0）。`tools/mksd68k.py` でイメージを作る。

```sh
# rs6809 側：8MB 用の FUZIX カーネルと、TPA が $800000 で終わる CP/M の BIOS
sh scripts/build-fuzix-tiny68k.sh --tn20k        # artifacts/fuzix68k-tn20k/disk.img
python3 scripts/build-cpm68k-bios.py --tn20k     # examples/cpm68k/bios-tn20k.sr
# こちら側
python3 tools/mksd68k.py sd68k.img \
  0=fuzix:../rs6809/artifacts/fuzix68k-tn20k/disk.img \
  1=cpm:../rs6809/artifacts/cpm68k/a.img:../rs6809/artifacts/cpm68k/dist/DISK8/CPM15000.SR,../rs6809/examples/cpm68k/bios-tn20k.sr
sudo dd if=sd68k.img of=/dev/sdX bs=1M conv=sparse,fsync
```

書き込みはカードに残る。書き戻せるようにイメージを残しておく。

## 使い方

コンソールは Tang Nano 20K の USB シリアル（BL616 の 2 つ目のインターフェース。Linux では `/dev/ttyUSB1`）、115200 8N1。端末ソフトでそのまま使える。違いは 1 点だけで、同じポートにデバッガも載るので 0x10（Ctrl-P）は 2 回送り、2 回出る。

S2 で機械をリセット（RAM とカードの中身は残る）。

### 実 CPU での ICE

rs6809 の ICE（ブラウザ UI と VS Code/DAP）がエミュレータの代わりに FPGA の CPU を使う：

```sh
cd ../rs6809
./target/release/rs6809 --fpga /dev/ttyUSB1 --ice                       # 6809、NitrOS-9 モニタ
./target/release/rs6809 --cpu 68000 --fpga /dev/ttyUSB1 --os fuzix \
    --symbols artifacts/fuzix68k-tn20k/fuzix.sym --ice                    # 68000、FUZIX モニタ
# http://127.0.0.1:6809/ 。--dap で VS Code もいつも通り
```

- 停止と停止の間、CPU は FPGA 上で全速で走る。ブレークポイント（8 個）とウォッチポイント（4 個、アドレス範囲、読み／書き）はハードウェア。条件、ヒット回数、ログポイントはハードウェアが止まったときに ICE が評価する。
- 停止、ステップ、ステップオーバー（戻り番地にブレークポイント）、レジスタとメモリ（読み書き）、逆アセンブル、シンボル、C の変数、OS の表示（プロセス、モジュール、メモリ）はエミュレータと同じに使える。
- ソース行のステップ、ステップアウト、システムコールでの停止とシステムコールの記録は 1 命令ずつ見る必要があり、その間 ICE はハードウェアを 1 命令ずつステップさせる（遅い。115200 ボーで毎秒数百命令）。
- 実機ではできないこと：逆実行（記録）、状態の保存と読み込み、サイクル数（代わりに時間を出す）。リセットは ROM から機械を起こし直し、最初の命令で止まる。
- ステップ中は割り込みを止める。CPU が止まっている間、6809 のタイマーと DUART のカウンタ／タイマーも止まる。

しくみ：6809 の cpu09p にはレジスタ、次の命令の番地でのブレーク、レジスタ書き込みのポートを足した（tools/patch-cpu09p.py）。止まっている間はデバッグ回路が機械のバスでメモリを読み書きする。fx68k は改造しない：レベル 7 割り込み（停止、ウォッチポイント）、ブレークポイントの命令の代わりに見せる ILLEGAL、ステップ後のトレース例外で、使っている間だけ現れるデバッグ窓のスタブモニタ（`m68k/rom/stub.S`）に CPU を入れ、スタブがメールボックスにレジスタを置き、ホストがそこを読み書きする。

### シミュレーション

```sh
make rom6809 && make sim
cd sim/build
./sim_mc09 -s ../../../rs6809/artifacts/nitros9/multicomp09_sd.img              # コンソールはこの端末
./sim_mc09 -s IMAGE -S ../../tests/nitros9-basic09.tsv -u " 42"                 # スクリプトで 42 まで
./sim_t68k -s sd68k.img -S ../../tests/fuzix-boot.tsv -u "Welcome to FUZIX"
./sim_mc09 -s IMAGE -t 6820 &    # シリアルを TCP に：rs6809 --fpga tcp:127.0.0.1:6820 --ice
```

### 実機での最初の確認

1. カードなしで 6809 のビットストリームを書き、USB シリアルに CamelForth の表示が出ること（出なければピンと BL616 のファームウェア）。
2. NitrOS-9 のカードを入れて `NITROS9`。読めない、データがおかしいときは、まず SDRAM の読み込みタイミング（`common/sdram.v` の `S_WAIT` の phase 2）。
3. ICE をつなぐ：`rs6809 --fpga /dev/ttyUSB1 --ice`。

## ライセンス

GPL-3.0（[LICENSE](../../LICENSE)）。CPU コア（cpu09p、fx68k）と MiSTeryNano の SD 制御（`sd_rw.v`、`sdcmd_ctrl.v`）が GPL-3.0 で、`sim/sdcard.h` の SD カードモデルは MiSTeryNano のものを元にした。Grant Searle の Multicomp と Neal Crook の mem_mapper2 は GPL と両立しないので使わず、Multicomp の装置は rs6809 の仕様から書いた。rs6809 本体は MIT のまま。
