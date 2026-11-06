# rs6809 → Tang Nano 20K 実機化計画

Nov 6, 2026 · @実

## 概要とゴール

rs6809 で動作確認したソフトを、同じ機械仕様を持つ Tang Nano 20K 上の FPGA 実機で動かす。6809（Multicomp09 互換）を先に完成させ、その成果（SDRAM、SD、検証の仕組み）を 68000（Tiny68K 互換、fx68k）に展開する。

- 最終ゴール 6809：NitrOS-9 Level 1 と Level 2 が実機で起動し、rs6809 で作ったディスクイメージが SD カードからそのまま動く。
- 最終ゴール 68000：CP/M-68K 1.3 が実機で起動し、rs6809 と同じディスクイメージが動く。続いて FUZIX 0.5（RAM 8MB 用に作り直したカーネル）。
- 原則：rs6809 の machine 実装を「正しい動作」の定義とし、FPGA 側をそれに合わせる。合わせられない差分は rs6809 側に実機互換プロファイルとして反映する。
- ライセンス：FPGA 側は別リポジトリ rs6809-fpga とし、GPL-3.0 で公開する。rs6809 本体は MIT のまま変えない。

## ボード諸元

ターゲットは Sipeed Tang Nano 20K の 1 枚で、外付け部品は microSD カードのみ（6809 の 2 端末目と FUZIX の tty2 だけ USB シリアル変換を追加）。

| 項目 | 内容 | 本計画での使い方 |
| --- | --- | --- |
| FPGA | GW2AR-LV18QN88C8/I7。LUT4 20,736、FF 15,552、BSRAM 46 ブロック（828Kbit）、S-SRAM 41.5Kbit、乗算器 18×18 が 48、PLL 2 | 見積もりは後述 |
| SDRAM | パッケージ内蔵 64Mbit（8MB）、32 ビット幅 SDR。ピン割り当てはなく、決まった信号名（`O_sdram_*`、`IO_sdram_dq`）で接続する | MiSTeryNano の `sdram.v`（CPU 側 16 ビット、22 ビットのワードアドレスで 8MB） |
| クロック | 27MHz 水晶。MS5351（BL616 が制御） | PLL で 27→32MHz。MS5351 は使わない |
| シリアル | オンボード BL616 が JTAG と USB シリアルを兼ねる。FPGA の受信は 70 番ピン（MiSTeryNano の制約ファイルで確認）、送信は 69 番ピン（Sipeed のサンプルによる。実機で確認） | コンソール。既定は 115200 ボー。文字化けや「実際のボーレートが 4 倍になる」不具合は BL616 のファームウェア更新で直る（Sipeed Wiki） |
| SD カード | 4 ビットのネイティブモードで配線済み（CLK 83、CMD 82、DAT0 84、DAT1 85、DAT2 80、DAT3 81） | MiSTeryNano の `sd_rw.v`（ネイティブ 4 ビット、SDHC 対応、SD クロック 16MHz） |
| 表示・入力 | LED 6、WS2812 1、ボタン 2、HDMI | LED はフェーズごとの状態表示、ボタンはリセットと起動 OS の選択。HDMI は使わない |
| フラッシュ | 64Mbit | ビットストリームの保存 |
| 開発ツール | Gowin EDA Education 版（無料）。MiSTeryNano は 1.9.9〜1.9.10 で開発されている | オープンソースのツール（Apicula）はメモリまわりの対応が不完全なので使わない |

## 参照プロジェクトとライセンス

ライセンスは各ソースのヘッダーで確認した。GPL と両立しないファイルは取り込まず、動作を確かめる参考資料として読むだけにする（コピーしない）。

| 部品 | 出典 | ライセンス | 扱い |
| --- | --- | --- | --- |
| cpu09p（6809 コア、John Kent） | [nealcrook/multicomp6809](https://github.com/nealcrook/multicomp6809) `multicomp/Components/M6809p` | GPL-3.0 以降 | 取り込む |
| fx68k（68000 コア） | [ijor/fx68k](https://github.com/ijor/fx68k)（MiSTeryNano 同梱版も同じ） | GPL-3.0 | 取り込む（サブモジュール） |
| `sdram.v`（Tang Nano 20K 用 SDRAM コントローラ） | [harbaum/MiSTeryNano](https://github.com/harbaum/MiSTeryNano) `src/tang/nano20k` | GPL-3.0 以降 | 取り込み、CPU 専用の調停回路に改造 |
| `sd_rw.v`（SD の初期化とセクタ読み書き） | MiSTeryNano `src/misc`（元は WangXuan95 の SD カード読み出し回路） | GPL-3.0 | 取り込む。周りの `sd_card.v` は BL616 のファイルシステム経由なので使わない |
| CamelForth（6809 の ROM） | multicomp6809 `camelforth` | GPL-3.0 | ソースからビルドして使える |
| `sd_controller.vhd`、`bufferedUART.vhd`、`Microcomputer.vhd`（Grant Searle） | multicomp6809 | 独自の条件（料金を取ってはならない。再公開には許可が要る） | **取り込まない**。自作する |
| `mem_mapper2.vhd`（Neal Crook） | multicomp6809 | 独自の条件（料金を取ってはならない） | **取り込まない**。自作する |
| cavnex/mc6809（サイクル精度の 6809 コア） | [cavnex/mc6809](https://github.com/cavnex/mc6809) | BSD 3 条項（ソースを再配布する場合） | cpu09p が合成できなかったときの代替候補 |
| NanoMig（Amiga。fx68k と TG68K を混在） | [harbaum/NanoMig](https://github.com/harbaum/NanoMig) | GPL | SystemVerilog と VHDL を混ぜて Gowin で合成できる実例、GAO の手順 |
| NitrOS-9 の ROM と SD イメージ | kyo-ta04/nitros9-basic09-starter-kit | 明示なし | 再配布しない。利用者が rs6809 の `setup.sh` で取得して SD に書く |

## クロック、タイミング、リソースの見積もり

### クロック

- システムクロックは 32MHz の 1 本（27MHz から PLL で作る。MiSTeryNano と同じで、GW2AR の C8 品で fx68k が動いた実績のある周波数）。CPU はクロックイネーブルで分周する。
- SDRAM は `sd_clk = ~clk`（32MHz の反転）、CAS 2、1 回のアクセスは 7 クロック（219ns）。
- 68000：最初は 8MHz（4 クロックごとに `enPhi1`／`enPhi2`）。1 回のバスサイクルは 16 クロック（500ns）なので SDRAM は待ちなしで収まり、リフレッシュは `ASn` が出ていない間に入れる。16MHz（2 クロックごと）は後で試す。バスサイクルが 8 クロックになるので、リフレッシュと重なったときは `DTACKn` を遅らせる。
- 6809：cpu09p をクロックイネーブル付きで動かす。目標は等価 8MHz 程度。cpu09p はサイクル精度ではないので、rs6809 とサイクル数は一致しない（アプリをサイクル数に依存させない方針で吸収する）。
- 68681 の X1（3.6864MHz）：27MHz からは PLL で正確に作れない（必要な比 256/1875 は PLL の分周比の範囲外）。32MHz で回す 32 ビットの位相アキュムレータで作る。加算値は `0x1D7DBF48`（494,780,232、誤差 0.001ppm）。揺らぎは ±31ns で、115200 ボーとタイマーには問題ない。
- rs6809 との合わせ方：rs6809 の Tiny68K は CPU を 10MHz と仮定している（`src/m68k/tiny68k.rs` の `CPU_HZ`）。実機互換プロファイルでは実機の周波数（8MHz、後に 16MHz）に合わせる。

### リソース（68000 構成）

fx68k の Gowin での実測値は公開されていない。Cyclone の値から換算した推定で、Q0 で単体合成して確定させる。

| 回路 | LUT4 | BSRAM | 根拠 |
| --- | --- | --- | --- |
| fx68k | 5,000〜6,500 | 3〜5 | Cyclone で 5,145 LE。マイクロコード 1024 語×17 ビット、ナノコード 336 語×68 ビット |
| SDRAM コントローラと調停 | 約 400 | 0 | `sdram.v` を改造 |
| `sd_rw.v` | 約 700 | 0 | 推定 |
| IDE→SD 変換とセクタバッファ | 約 400 | 1 | 推定 |
| 68681 DUART（2 チャンネル、タイマー、IVR） | 800〜1,200 | 0 | 推定 |
| ブート ROM、ROM の重ね合わせ、アドレスデコード、`DTACKn` | 約 200 | 1〜2 | 推定 |
| GAO（デバッグ時のみ） | 1,000〜2,000 | 4〜8 | 推定 |
| **合計** | **8,500〜11,400（41〜55%）** | **9〜16 / 46** | |

同じ FPGA に Atari ST 一式（チップセット、ブリッター、HD63701、YM2149、HDMI）と fx68k を入れた MiSTeryNano が動いているので、CPU と周辺回路だけの構成は余裕を持って収まる。

### リソース（6809 構成）

| 回路 | LUT4 | BSRAM | 根拠 |
| --- | --- | --- | --- |
| cpu09p | 2,000〜3,000 | 0 | 推定（Gowin での実測なし。P0 で単体合成して確定） |
| ROM 8KB | 0 | 4 | 2KB／ブロック |
| RAM 64KB（P1〜P2） | 0 | 32 | P3 で SDRAM に移すと 0 |
| ACIA 1〜4 個、MMU、タイマー、SD 制御、`sd_rw.v` | 1,500〜2,000 | 1 | 推定 |
| GAO（デバッグ時のみ） | 1,000〜2,000 | 4〜8 | 推定 |
| **合計（P2、BRAM 64KB の時点）** | **4,500〜7,000（22〜34%）** | **37〜45 / 46** | BRAM はほぼ満杯。GAO の観測点は絞る |

## フェーズ計画 6809（Multicomp09 互換）

Multicomp09 の周辺回路はライセンスの都合で取り込まず、rs6809 の `src/machine.rs` を仕様として自作する。multicomp6809 の VHDL は動作を確かめる参考資料として読む。BRAM だけで Level 1 を起動してから、SDRAM で Level 2 に進む。各フェーズは完了条件を満たしてから次へ進む。

1. **P0 調査**：rs6809 の Multicomp 互換モードからレジスタ仕様を書き出し、multicomp6809 の VHDL と照合する。
   - 対象：ROM `$E000-$FFFF`、ACIA `$FFD0/$FFD1`、追加 ACIA `$FFD2-$FFD7`、SD `$FFD8-$FFDC`（LBA は 24 ビット）、タイマー `$FFDD`、MMU `$FFDE/$FFDF`（タスク 2 つ、8KB バンク、書き込み保護）。
   - rs6809 の Level 2 は、キットのソースへの修正（`docs/level2.md` の「Changes needed for the Level 2 boot image」）と、上位固定領域 `$FE00-$FFFF` のラッチ動作（キットの C 製エミュレータ `exec09/miscsbc.c` が基準）に依存している。これが実機の mem_mapper2 と一致するかを照合する。
   - 追加 ACIA の `$FFD2-$FFD7` が、実機の別の装置とアドレスで重ならないかを確認する。
   - cpu09p を Gowin EDA（gw_sh）で単体合成し、LUT 数と最大周波数を記録する。通らなければ cavnex/mc6809 を検討する。
   - 完了条件：仕様表 `docs/spec-6809.md`（rs6809 との差分と、各差分の扱い）が入り、cpu09p の合成結果が記録されている。
2. **P1 最小構成**：cpu09p ＋ BRAM の ROM 8KB ＋ BRAM の RAM ＋ 自作の 6850 互換 ACIA。multicomp6809 の CamelForth をソースからビルドして ROM にし、USB シリアルにプロンプトを出す。
   - 完了条件：実機の USB シリアルに CamelForth が起動し、キー入力にエコーが返る。rs6809（`multicomp-tn20k`）でも同じ ROM で同じ表示になる。
3. **P2 SD、MMU、タイマー**：自作の SD 制御（中身は `sd_rw.v`）、MMU、50Hz タイマーを入れる。RAM は BRAM 64KB のまま。SD には rs6809 のイメージを LBA 0 から `dd` で書く（6809 用の SD カードを 1 枚用意する）。
   - 完了条件：CamelForth から SD のセクタを読める。rs6809 と同じ SD イメージから NitrOS-9 Level 1 が起動し、BASIC09 のテスト（42 を表示）が通る。
4. **P3 SDRAM**：`sdram.v` に 8 ビットの CPU をつなぐ変換（バイトマスク）を入れ、物理 RAM を 512KB、続いて 1MB にする。この SDRAM 回路は 68000 側でもそのまま使う。
   - 完了条件：Level 2 が起動し、mfree が 512KB／1MB を表示（rs6809 では `$7FFFF` で 440KB、`$FFFFF` で 952KB）。rs6809 の Level 2 ディスクで cc1 による hello.c のコンパイルと実行が通る。
5. **P4 複数端末（任意）**：追加 ACIA を GPIO に出し、3.3V の USB シリアル変換で 2 端末目にする。ACIA の配置は rs6809 の Telnet 構成と同じにする。
   - 完了条件：2 端末から同時にログインできる。

## フェーズ計画 68000（fx68k、Tiny68K 互換）

6809 の P3 が終わってから着手する。CPU は fx68k をそのまま使い、68681 DUART、IDE 互換のストレージ、ブート ROM は自作する。SDRAM と SD は 6809 側の成果を使う。

1. **Q0 調査と仕様の確定**：rs6809 の `docs/m68k.md` と `src/m68k/tiny68k.rs` から実装範囲の表を作る。次の項目は調査済みなので、表に書き込んで扱いを確定させる。
   - メモリマップ：RAM `$000000-$FF7FFF`（rs6809 では約 16MB）、IDE `$FFE000-$FFEFFF`（レジスタは (address & 31) >> 1）、DUART `$FFF000-$FFF01F`（奇数番地、レジスタは (address >> 1) & 15）。
   - 実機の RAM は 8MB（`$000000-$7FFFFF`）。`$800000` 以上で折り返すかどうかを決め、互換プロファイルも同じにする。
   - 割り込み：DUART はレベル 2 で、ベクタは IVR から供給する。fx68k の割り込み応答サイクル（FC=7）で IVR を返す。
   - FUZIX が使う DUART の設定：CTLR=`$80`、CTUR=`$04`（初期値 `$480`、X1/16 で 100Hz）、IVR=`$81`、IMR=`$2A`。ACR は端末の初期化で `$70`／`$F0` に設定される。
   - IDE のデータレジスタは 16 ビットで、セクタの最初のバイトがワードの下位に入る（バイトが入れ替わる）。変換回路はこれと完全に一致させる。
   - fx68k を Gowin EDA で単体合成し（`-verilog_std sysv2017`）、LUT 数と 32MHz でのタイミングの余裕を記録する。
   - 完了条件：実装範囲の表が `docs/spec-68k.md` に入り、fx68k の合成結果が記録されている。
2. **Q1 最小構成**：fx68k ＋ ブート ROM ＋ BRAM の RAM（BSRAM が許す範囲で数十 KB）＋ 68681 の送信だけ。CPU は 8MHz。
   - リセット直後は ROM を `$000000` に重ねて見せ、ベクタ（SSP と PC）を ROM から読ませる。最初の RAM への書き込みか、決まった回数の読み出しで重ね合わせを外す。
   - `DTACKn` は `ASn` の 1 サイクル後に返す。未使用の `VPAn`、`BERRn`、`BRn`、`BGACKn`、`HALTn` は High、`IPL` は全 High。
   - 完了条件：同じ hello バイナリが、rs6809（`tiny68k-tn20k`）と実機の両方で同じ文字列を出す。
3. **Q2 DUART 完成**：受信、カウンタ／タイマー、割り込み（IVR）、X1 の位相アキュムレータを入れる。動作はデータシート通りにする（ACR=0 は IP2 端子を数えるカウンタモード）。
   - 完了条件：エコーバックと、100Hz のタイマー割り込みでカウンタを進めるテストが、両方で同じ結果になる。
4. **Q3 SDRAM**：6809 の P3 の SDRAM 回路を 16 ビットのまま 68000 につなぎ、RAM を 8MB にする。リフレッシュは CPU が SDRAM を使っていない間に入れる。
   - 完了条件：8MB 全域のメモリテストが通る（アドレス線ごとのパターンと、`$800000` 以上の扱いの確認を含む）。
5. **Q4 ストレージ、ブート ROM、CP/M-68K**：IDE 互換レジスタ（rs6809 と同一）を `sd_rw.v` につなぎ、ブート ROM から CP/M-68K を起動する。
   - IDE の状態：命令を受けたら直ちに BSY=1・DRQ=0 を返し、SD の処理中は BSY を保つ。読み出しは 512 バイトそろってから DRQ。書き込みは 512 バイトを受け取ってから BSY にして SD に書く。対応する命令は rs6809 と同じ（`READ SECTORS`、`WRITE SECTORS`、`IDENTIFY DEVICE`）。
   - SD の配置：ファイルシステムは使わず、生の LBA で区切る（例：CP/M ディスク 8MB、CP/M システム、FUZIX ディスク）。IDE 変換が領域の先頭 LBA を足す。書き込みは `dd`。
   - CP/M の起動：rs6809 では `CPM15000.SR` と `bios.sr` を直接メモリに読み込み `$15000` から開始している。実機では、この 2 本をバイナリにして SD の予約領域に置き、ブート ROM が RAM にコピーして `$15000` に飛ぶ。
   - CP/M の BIOS は `bios.s` の `TPA_END` を `0xfe0000` から `0x800000` に変えた版を使う（BIOS はディスクと別に読み込むので、ディスクイメージ `a.img` はそのまま）。
   - ボタンで起動する OS（CP/M／FUZIX）を選ぶ。
   - 完了条件：rs6809 の CP/M-68K ディスクイメージを書いた SD から CP/M-68K 1.3 が起動し、`A>` が出る。Alcyon C で hello.c をコンパイルして実行できる。
6. **Q5 FUZIX**：RAM 8MB 用に直したカーネルで FUZIX 0.5 を起動する。
   - カーネルは RAM 容量をソースに書き込んでいる。`Kernel/platform/platform-tiny68k/main.c` の `kmemaddblk(e, 0xFF8000 - e)` と、`p68000.S` の `ramsize`（16352）を 8MB に合わせる。`scripts/build-fuzix-tiny68k.sh` にこの修正を当てる手順を足し、tn20k 用のディスクを作る。
   - 起動：ブート ROM が、実機のモニタ ROM の「CP/M boot loader」と同じように、LBA 1 の 512 バイトを `$15000` に置いて開始する（ワード単位のバイト入れ替えに注意）。ローダーは `$1F0000` に移動し、LBA 2 以降のカーネルを `$400` に読み込む。
   - 完了条件：FUZIX のシェルで ls などのコマンドが動き、fsck が通ったあと再起動してもファイルシステムが壊れていない。

## 検証方針と rs6809 側の対応

「rs6809 で通ったものは実機でも動く」を保証するため、エミュレータ側に実機互換プロファイルを作り、FPGA 側は焼く前に必ずシミュレーションを通す。

- **実機互換プロファイル**：`--machine multicomp-tn20k` と `--machine tiny68k-tn20k` を rs6809 に追加する。FPGA で実装した機能の範囲だけを持ち、未実装レジスタへのアクセスでは警告を出す。`tiny68k-tn20k` は次の点で `tiny68k` と違う。
  - RAM は 8MB。`$800000` 以上は実機と同じ扱い（折り返しか、読み出しが `$FF`）。
  - CPU 周波数は 8MHz（後に 16MHz）。DUART の換算もこれに合わせる。
  - DUART の ACR はデータシート通りに扱う（ACR=0 のときは X1/16 で数えない）。
  - IDE に、わざと BSY の時間を作るオプションを付け、状態を待たずにデータを読むソフトを見つけられるようにする。
  - プログラムを直接メモリに読み込まず、実機と同じブート ROM から起動する。
- **SoC シミュレーション**：FPGA のトップを回すテストベンチを用意する。68000 側（SystemVerilog）は Verilator、6809 側の cpu09p（VHDL）は GHDL。混在が必要になったら ghdl-yosys-plugin で VHDL を Verilog に変換して Verilator に寄せる。ROM イメージと SD イメージを読み込み、UART の出力をテキストで記録して rs6809 の出力と diff する。
- **共通テスト ROM**：各フェーズの完了条件で使う小さなテストプログラム（hello、エコー、タイマー割り込み、メモリテスト、SD の読み書き）をリポジトリに置き、rs6809・シミュレーション・実機の 3 か所で同じ期待出力を確認する。
- **SD への書き込み**：rs6809 は既定では書き込みをメモリ上にとどめるが、実機の SD には残る。テストのたびに元のイメージを書き戻す手順（スクリプト）を用意する。
- **実機デバッグ**：Gowin EDA の GAO（内蔵ロジックアナライザ）でアドレス、`ASn`、`DTACKn`、チップセレクト、IDE の状態を観測する（NanoMig の `doc/GAO_HOWTO.md` を参照）。LED 6 個はフェーズごとの状態表示に使う。
- **タイミング依存を避ける**：rs6809 は命令単位のサイクル計算で、cpu09p はサイクル精度ではない。アプリはサイクル数ぴったりの待ちに依存させず、時間はタイマー割り込みで扱う。

## リポジトリ構成・ツールチェーン

FPGA 側は rs6809 とは別のリポジトリ rs6809-fpga（GPL-3.0）にする。rs6809 本体は「外部クレート・C・FFI なし」と MIT の方針を崩さず、変更は実機互換プロファイル、ブート ROM の取り込み、テスト ROM の追加だけにする。

```
rs6809-fpga/
  common/        sdram（MiSTeryNano 由来）、sd_rw（MiSTeryNano 由来）、PLL・リセット、UART の部品
  m6809/         cpu09p、自作の ACIA・SD 制御・MMU・タイマー、Tang Nano 20K のトップ、制約ファイル
  m68k/          fx68k（サブモジュール）、68681、IDE-SD 変換、ブート ROM、トップ、制約ファイル
  sim/           GHDL・Verilator のテストベンチ、UART ログの diff スクリプト
  tests/         共通テスト ROM のソースと期待出力
  tools/         SD イメージの組み立て（生の LBA 配置）と書き戻しのスクリプト
  docs/          PLAN.md、spec-6809.md、spec-68k.md、フェーズごとの記録
```

| 用途 | ツール |
| --- | --- |
| 論理合成・書き込み | Gowin EDA Education 1.9.9 以降（GUI と gw\_sh）。fx68k には `-verilog_std sysv2017` |
| シミュレーション | GHDL、Verilator、波形は GTKWave |
| 6809 ソフト | LWTOOLS（rs6809 の setup で導入済み） |
| 68000 ソフト | m68k-elf binutils・gcc（rs6809 の build-m68k-elf.sh） |
| 動作の基準 | rs6809（実機互換プロファイル） |

## 要確認事項とリスク

ライセンスと RAM 容量は調査で決着した。残る大きな不確定要素は、Gowin での cpu09p と fx68k の実際のリソースとタイミングで、P0／Q0 の単体合成で潰す。

| 項目 | 内容 | 対応 |
| --- | --- | --- |
| ライセンス | 決着済み。cpu09p・fx68k・`sdram.v`・`sd_rw.v` は GPL-3.0。Grant Searle と Neal Crook のファイルは GPL と両立しない | rs6809-fpga は GPL-3.0。両立しないファイルは取り込まず自作する |
| 6809 コアの合成 | cpu09p が Gowin で通るか、何 MHz 出るかは未確認 | P0 で単体合成。だめなら cavnex/mc6809（BSD） |
| fx68k の合成 | MiSTeryNano で 32MHz・GW2AR C8 の実績あり。LUT 数の実測値はない | Q0 で単体合成して見積もりを確定 |
| RAM 容量 | 決着済み。Tiny68K 互換は約 16MB で、実機は 8MB | 互換プロファイルを 8MB にし、CP/M の BIOS と FUZIX のカーネルを直す |
| FUZIX のディスク | カーネルがディスクに入っているので、tn20k 用は別のディスクになる | 「同じディスクイメージ」は CP/M だけの目標とする |
| 起動の仕組み | rs6809 はプログラムを直接メモリに置いて起動するが、実機にはその代わりがない | ブート ROM と ROM の重ね合わせを作り、互換プロファイルも同じ ROM から起動する |
| IDE の待ち | 実機では SD の待ちで BSY が出る。CP/M の BIOS は BSY と DRQ を、FUZIX のローダーは READY と DRQ を待つことは確認済み | 互換プロファイルの BSY 遅延オプションで、ほかのソフトも確認する |
| Level 2 の固定領域 | rs6809 の動作はキットの C 製エミュレータが基準で、実機の mem_mapper2 と同じかは未確認 | P0 で VHDL と照合する |
| 6809 の BRAM | P2 の時点で 37〜45／46 ブロックとほぼ満杯 | GAO の観測点を絞る。P3 で RAM を SDRAM に移す |
| BL616 のシリアル | 送信ピン 69 は未確認。ファームウェアによってはボーレートの不具合がある | P1／Q1 の最初に確認し、BL616 のファームウェアを最新にする |
| SD の互換 | SDSC／SDHC でアドレスの指定が違う | SDHC 前提で統一（`sd_rw.v` は両方に対応） |
| GPIO の電圧 | 2 端末目と FUZIX の tty2 の USB シリアル変換 | 3.3V 品を使う |

## Claude Code への作業指示

この文書を rs6809-fpga の `docs/PLAN.md` として置いたうえで、次の指示から始める。最初の作業は 6809 の P0（仕様表の作成と cpu09p の単体合成）で、FPGA のコードはまだ書かない。

```
docs/PLAN.md を読んで、6809 の P0 を進めてください。

1. rs6809 の src/machine.rs と docs/level2.md から、Multicomp 互換モードの
   レジスタ仕様（ROM、ACIA、追加 ACIA、SD、タイマー、MMU、上位固定領域）を
   docs/spec-6809.md に書き出す。
2. nealcrook/multicomp6809 を参照用に取得し、bufferedUART、sd_controller、
   mem_mapper2 の動作を読んで、1 の仕様と照合する。違いには
   「FPGA に合わせる／rs6809 に合わせる」の案を付ける。
   これらのファイルはライセンスの都合で rs6809-fpga にコピーしない。
3. Level 2 の修正点と上位固定領域のラッチ動作が、mem_mapper2 と一致するかを確認する。
4. cpu09p を Gowin EDA（gw_sh、GW2AR-LV18QN88C8/I7）で単体合成するスクリプトを
   用意し、LUT 数と最大周波数を記録する。

守ること:
- rs6809 本体に外部クレート・C・FFI を入れない。rs6809 は MIT のまま。
- rs6809-fpga は GPL-3.0。GPL と両立しないファイルを取り込まない。
- 各フェーズは PLAN.md の完了条件を満たしてから次へ進む。
- 判断が必要な差分は勝手に決めず、選択肢を示して確認を求める。
```

- [ ] rs6809-fpga リポジトリを作り（GPL-3.0）、この文書を docs/PLAN.md に置く
- [ ] Claude Code に上の指示を渡して P0 を開始する
- [ ] P0 の仕様表と cpu09p の合成結果を確認し、各差分の扱いを決める
