# テスト戦略

> 親ドキュメント:[../design.md](../design.md)(設計書ハブ)
> 対応要件:`docs/requirements.md` 8.3, 8.4 / `CLAUDE.md` 6章
> 対象実装:[02-generate-minutes.md](./02-generate-minutes.md) / [03-transcribe.md](./03-transcribe.md) / [04-auth.md](./04-auth.md)

---

## 1. ディレクトリ構成

```
tests/
├── bats/
│   ├── generate_minutes.bats
│   ├── aws_sso_login.bats
│   ├── harness.bats           # ヘルパ・スタブ自体の自己テスト(テスト基盤が壊れていないことの確認)
│   └── helper.bash            # setup/teardown、一時 REPO_ROOT の作成、PATH へのスタブ挿入
├── python/
│   └── test_transcribe.py
├── fixtures/
│   ├── config.yaml            # 最小のプロジェクト設定
│   ├── memo.md
│   ├── transcript.txt
│   ├── step1_output.md
│   └── step2_output.md
└── stubs/
    ├── claude                 # claude CLI スタブ
    ├── aws                    # aws CLI スタブ
    └── transcribe.py          # 文字起こしスタブ(即座にダミー出力を書く)
```

## 2. テスト用の隔離

bats の `setup()`(`tests/bats/helper.bash` の `setup_repo`)で `BATS_TEST_TMPDIR/repo` 配下に擬似リポジトリを作り、実リポジトリの `inputs/` / `outputs/` を汚さない。

擬似リポジトリの構成と、スタブの注入方法は**呼び出し方によって2系統**ある。

| 呼ばれ方 | 対象 | 注入方法 |
|---|---|---|
| `PATH` 経由(コマンド名で呼ぶ) | `claude`、`aws` | `tests/stubs` を `PATH` の先頭に挿入 |
| `$SCRIPT_DIR` 経由(絶対パスで呼ぶ) | `transcribe.py`、`aws_sso_login.sh` | 擬似リポジトリの `scripts/` に**配置するファイルを差し替える**(`transcribe.py` はスタブを、`aws_sso_login.sh` は実物をコピー) |

`generate_minutes.sh` は `transcribe.py` / `aws_sso_login.sh` を `$SCRIPT_DIR/...` で呼ぶ([02-generate-minutes.md §6](./02-generate-minutes.md))ため `PATH` では差し替えられない。`aws_sso_login.sh` は**実物をコピーし、その先の `aws` を `PATH` のスタブで止める**(ケース30/31は `STUB_ARGS_FILE` に `sts` 呼び出しが記録されたかで判定する)。これによりスタブの種類を設計どおり3つ(`claude` / `aws` / `transcribe.py`)に保つ。

擬似リポジトリの既定状態(`setup_repo` が作るもの):

```
$BATS_TEST_TMPDIR/repo/
├── scripts/{generate_minutes.sh, aws_sso_login.sh, transcribe.py(スタブ)}
├── projects/testproj/{config.yaml, prompts/{01_organize,02_structure,03_format}.md}
├── config/auth/                       # active.env は既定では作らない(ケース9)
├── inputs/testproj/2026-08-16/memo.md
└── outputs/                           # 空(OUTPUT_DIR は generate_minutes.sh が作る)
```

`ANTHROPIC_MODEL` は `setup_repo` が既定でダミー値を設定し、`CLAUDE_CODE_USE_BEDROCK` は `unset` する(ケース10・31の前提)。

入力を組み立てるヘルパ:

| ヘルパ | 役割 |
|---|---|
| `given_memo <ファイル名> <マーカー>` | 任意の名前・拡張子の議事メモを配置する(複数メモのケース19c〜19e) |
| `remove_memo` | 既定の `memo.md` を取り除く |
| `given_media <ファイル名>` | ダミーのメディアファイルを配置する(複数指定で分割録画を再現) |
| `given_transcript` | 既存の `00_transcript.txt` を配置する |
| `given_transcript_part <メディアのファイル名> <マーカー>` | パートキャッシュを配置する(ケース28d・28f) |
| `given_step_output 1\|2` | 前段の中間生成物を配置する |

隔離の検証(`harness.bats`)は「実リポジトリに `inputs/` / `outputs/` が存在しないこと」ではなく、**テスト用プロジェクト名(`testproj`)のディレクトリが実リポジトリの `inputs/` / `outputs/` / `projects/` に作られないこと**を確認する。実リポジトリの `inputs/` / `outputs/` は利用者の実行(実機E2E)で正当に存在しうるため、存在自体を失敗条件にすると開発者の環境で誤検知する。

## 3. `claude` / `aws` / `transcribe.py` のモック方法

`tests/stubs/` を `PATH` の先頭に置く。スタブは以下の環境変数で挙動を制御し、受け取った引数と stdin を記録する。

**共通(3スタブすべて)**

| 環境変数 | 役割 |
|---|---|
| `STUB_ARGS_FILE` | 受け取った引数を1行ずつ**追記**。1回の呼び出しの先頭に `--- <コマンド名> ---` の区切り行を書き、呼び出し回数を数えられるようにする |
| `STUB_STDIN_FILE` | 受け取った stdin 全文を**追記**(区切りヘッダの検証に使う) |
| `STUB_STDOUT_FILE` | このファイルの内容を stdout に出力(未指定なら固定文字列) |
| — | `claude` スタブは `STUB_STDOUT_FILE` 未指定のとき、`--system-prompt-file` の basename からステップを判定し、**そのステップの1行目の契約を満たす行**(ステップ1・2は `## 会議情報`、ステップ3は `# 議事録: STUB`)を出してから `STUB CLAUDE OUTPUT` を出す([02-generate-minutes.md §5.5](./02-generate-minutes.md))。`--system-prompt-file` が渡されない呼び出しでは従来どおり `STUB CLAUDE OUTPUT` の1行のみを出す(`harness.bats` の完全一致アサーションを保つため)。**先頭行が契約に反するケースは `STUB_STDOUT_FILE` に任意の内容を置いて再現する**(新しい環境変数を増やさない) |
| `STUB_EXIT` | 終了コード(既定 0) |
| `STUB_CWD_FILE` | 実行時の `pwd` を1行追記(空ディレクトリ実行の検証に使う) |

- 記録は**追記**であるため、ステップ別の stdin を検証するケース(18・19・20)は `--only-step N` を使って呼び出しを1回に限定する。
- `STUB_EXIT` は `claude` スタブと `transcribe.py` スタブで共有する(両方を同時に失敗させるテストは無い)。

**並列実行(`--parallel N`)を検証する場合の追加**

追記方式は並列実行では成立しない。複数のスタブが同じファイルへ同時に書くため、**行が混ざり、どの引数がどの stdin に対応していたか分からなくなる**。並列のケース(47〜63)では次の2変数を使う。

| 環境変数 | 役割 |
|---|---|
| `STUB_CALL_DIR` | 呼び出しごとに `mktemp "$STUB_CALL_DIR/call.XXXXXX"` で**専用ファイル**を作り、引数と stdin をそこへ書く(`<file>.args` / `<file>.stdin`)。呼び出し回数はファイル数で数え、パートの検証は各 `.stdin` を `grep` して該当パートのファイルを特定する。設定されていればこちらを使い、`STUB_ARGS_FILE` / `STUB_STDIN_FILE` への追記は行わない |
| `STUB_FAIL_ON_STDIN_MATCH` | stdin にこの文字列が含まれる呼び出しのみ `STUB_EXIT`(既定 1)で終了する。**完了順が不定でも特定のパートだけを確実に失敗させられる**(ケース58〜60は `part: 2/2` を指定する)。他の呼び出しは 0 で成功する |
| `STUB_FAIL_STDOUT` | 上記で失敗させる際に、この文字列を stdout へ書いてから終了する。**実物の `claude` が API エラーを stdout に書く挙動**の再現用(診断ログの検証・ケース64d/64e。[02-generate-minutes.md §5.4](./02-generate-minutes.md))。未指定なら何も書かずに終了する |

- パート数・呼び出し回数の検証はファイル数で行うため、**完了順に依存しない**([01-conventions.md §8.4](./01-conventions.md):並列実行の完了順は不定)。
- ハートビート(ケース41)の遅延は `STUB_SLEEP_SECONDS` で与える(スタブが `sleep` してから出力する)。

**`aws` スタブ固有**(サブコマンドごとに挙動を変える必要があるため)

| 環境変数 | 役割 |
|---|---|
| `STUB_AWS_STS_EXITS` | `sts get-caller-identity` の終了コードを**呼び出し順に**空白区切りで指定(既定 `0`)。値が尽きたら最後の値を繰り返す。ケース2の「1回目は失敗、ログイン後は成功」は `"1 0"` と指定する |
| `STUB_AWS_LOGIN_EXIT` | `sso login` の終了コード(既定 0) |
| `STUB_AWS_STS_ARN` | `sts get-caller-identity` 成功時に出力する ARN 文字列(既定はダミー ARN)。ケース6でこの文字列が stdout に出ないことを検証する |
| `STUB_STATE_DIR` | 呼び出し回数カウンタの置き場(既定 `$TMPDIR`)。`helper.bash` が `BATS_TEST_TMPDIR` を設定する |

`invoke_claude` は `claude` を呼ぶ唯一の場所であるため、この1点のスタブで3ステップすべてを検証できる(要件8.3)。

## 4. テストケース一覧

**`generate_minutes.sh`(bats)**

| # | 観点 | 期待結果 |
|---|---|---|
| 1 | 正常系:memo + transcript が揃っている | 3ファイルが生成され、終了コード0 |
| 2 | 引数0個 / 1個 | usage が stderr、コード1 |
| 3 | `date` が `2026/08/16` | ERROR、コード1 |
| 4 | `project` に `../` を含む | ERROR、コード1(パストラバーサル拒否) |
| 5 | `--from-step` と `--only-step` の同時指定 | ERROR、コード1 |
| 6 | `--from-step 4` / `--from-step abc` | ERROR、コード1 |
| 7 | `--help` | usage が stdout、コード0 |
| 8 | `active.env` が存在する | ファイル内の値が環境変数として反映される |
| 9 | `active.env` が存在しない | 既存環境変数がそのまま使われ、エラーにならない |
| 10 | `ANTHROPIC_MODEL` 未設定 | ERROR、コード1、`claude` は呼ばれない |
| 11 | パス生成 | `outputs/{p}/{d}/` が作成され、出力先が規定どおり |
| 12 | `projects/{p}/config.yaml` 欠落 | ERROR + `cp -r projects/_template` の HINT、コード1 |
| 13 | プロンプトファイル欠落 | ERROR、コード1 |
| 14 | 入力ディレクトリ欠落 | ERROR、コード1 |
| 15 | `--from-step 2` で `01_*.md` が無い | ERROR、コード1 |
| 16 | `--from-step 2` | `claude` の呼び出しが2回、ステップ1のプロンプトは使われない |
| 17 | `--only-step 2` | 呼び出し1回、`minutes.md` は更新されず stale WARN が出る |
| 18 | ステップ1の stdin | `PROJECT_CONFIG` / `MEETING_MEMO` / `TRANSCRIPT` の3ヘッダを含み、`END OF INPUT` で終わる |
| 19 | 議事メモが無い場合のステップ1 stdin | `MEETING_MEMO` ヘッダが出力されない(空セクションを作らない) |
| 19b | 文字起こしが無い場合のステップ1 stdin | `TRANSCRIPT` ヘッダが出力されない |
| 19c | 議事メモが2件(`.md` + `.txt`) | `MEETING_MEMO` ヘッダが2つ出力され、双方の本文が stdin に含まれる([02-generate-minutes.md §4.2](./02-generate-minutes.md)) |
| 19d | 議事メモが3件 | `MEETING_MEMO` ヘッダが `LC_ALL=C` のファイル名昇順で並ぶ |
| 19e | `.md` / `.txt` 以外のファイル | 議事メモとして扱われない(メディアファイルもメモに含めない) |
| 20 | ステップ2の stdin | `STEP1_OUTPUT` ヘッダを含み、`TRANSCRIPT` を含まない |
| 21 | `claude` 引数 | `-p` `--bare` が含まれ、`--tools` に空文字、`--system-prompt-file` に当該ステップのプロンプトパス、`--model` に `ANTHROPIC_MODEL` の値が渡る |
| 22 | `claude` 実行時の cwd | リポジトリ配下ではない(空の一時ディレクトリ) |
| 23 | `claude` が終了コード1を返す | コード3で停止し、後続ステップを実行しない |
| 24 | `claude` が空出力を返す | コード3、出力ファイルは確定されない(前回の内容が壊れない) |
| 24b | `claude` 失敗後の `OUTPUT_DIR` | `mktemp` の一時ファイル(`*.md.XXXXXX`)が残らない。**診断用の `*.error.log` / `*.truncated.md` は意図して残すため除外して検証する**(ケース64・65) |
| 25 | `--dry-run` | `claude` が呼ばれず、実行計画が stdout に出て コード0 |
| 26 | メディアあり・`00_transcript.txt` なし | `transcribe.py` スタブが1回呼ばれる |
| 27 | メディアあり・`00_transcript.txt` あり | `transcribe.py` は呼ばれない(スキップ) |
| 28 | メディアが2件(`find_media_files` 単体) | 両方をファイル名昇順(`LC_ALL=C`)で返し、複数件をエラーにしない([02-generate-minutes.md §6](./02-generate-minutes.md)) |
| 28e2e | メディアが2件(通し実行) | `transcribe.py` が2回・メディアごとに呼ばれ、`00_transcript.txt` に両パートが**ファイル名昇順**で連結される |
| 28b | メディアが2件 | 連結結果に `----- TRANSCRIPT PART 1/2: ... -----` のマーカーが順に現れ、連結順が stdout に列挙される |
| 28c | メディアが1件 | パートマーカーを挿入せず、`00_transcript.txt` が `transcribe.py` の出力と一致する(後方互換) |
| 28d | メディア2件のうち1件のパートが既存 | `transcribe.py` の呼び出しは1回のみ(パートキャッシュの再利用。§6.1) |
| 28e | メディア2件のうち後半で `transcribe.py` が失敗 | コード3で停止し、`00_transcript.txt` を確定しない(原子的置換) |
| 28f | パートが存在するメディアを削除して再実行 | 削除したメディアのパートは連結されない(連結対象は毎回メディア一覧から再計算) |
| 28g | メディア2件で `--dry-run` | 連結順を表示して `transcribe.py` を呼ばず、パートも作らない |
| 29 | メディアなし・memo のみ | 文字起こしをスキップして正常終了 |
| 29b | `--from-step 2` | `transcribe.py` スタブが呼ばれない |
| 29c | `--only-step 0` かつメディアなし | ERROR、コード1 |
| 30 | `CLAUDE_CODE_USE_BEDROCK=1` | `aws_sso_login.sh` が呼ばれる |
| 31 | `CLAUDE_CODE_USE_BEDROCK` 未設定 | `aws_sso_login.sh` が呼ばれない |
| 32 | 進捗出力に会議内容が含まれない | stdout に fixture の本文が現れない |
| 33 | stdin が `INPUT_WARN_BYTES` を超える | stderr に `WARN`(バイト数付き)が出るが処理は継続し コード0。HINT が `--parallel` を案内する([02-generate-minutes.md §4.1](./02-generate-minutes.md)) |
| 34 | Bash 4.0+ 専用構文の静的検査 | `scripts/*.sh`・スタブ・`helper.bash` に `${var,,}` / `mapfile` / `declare -A` / **`wait -n`** 等が1件も無い([01-conventions.md §8.1](./01-conventions.md)) |
| 34c | 変数展開の直後に非ASCII文字が続く箇所の静的検査 | `"$min〜$max"` のようなブレース無しの展開が1件も無い(UTF-8 ロケールで `unbound variable` になる。[01-conventions.md §5](./01-conventions.md)) |
| 34b | `/bin/bash` が 3.x の環境での通し実行 | メモ2件 + メディア1件のパイプラインが `/bin/bash` 実行でも完走(コード0・`claude` 3回・`MEETING_MEMO` 2件)。`/bin/bash` が 4.0 以上なら `skip`([01-conventions.md §8.2](./01-conventions.md)) |
| 34d | `/bin/bash` が 3.x の環境で `--parallel 2` | 分割・並列実行が完走(コード0)。`bash -n` では並列構文の非互換を検出できないため実行で担保する。`/bin/bash` が 4.0 以上なら `skip` |

**ステップ別モデルID(要件3.4 / [02-generate-minutes.md §5.1](./02-generate-minutes.md))**

| # | 観点 | 期待結果 |
|---|---|---|
| 35 | `ANTHROPIC_MODEL_STEP1` 設定・`--only-step 1` | `claude` の `--model` に当該IDが渡る |
| 36 | `ANTHROPIC_MODEL_STEP1` 未設定 | `--model` に `ANTHROPIC_MODEL` の値が渡る(フォールバック) |
| 37 | `ANTHROPIC_MODEL_STEP1` のみ設定して通し実行 | ステップ1は当該ID、ステップ2・3は `ANTHROPIC_MODEL`(ステップごとに独立して解決される) |
| 38 | `ANTHROPIC_MODEL` 未設定・`ANTHROPIC_MODEL_STEP1` のみ設定 | ERROR、コード1(`require_model` は変更しない。フォールバック元は必須) |

**経過表示と中断([02-generate-minutes.md §5.2・§5.3](./02-generate-minutes.md))**

| # | 観点 | 期待結果 |
|---|---|---|
| 39 | `claude` スタブが `STUB_EXIT=130` | ERROR に `中断されました` を含み、`claude の実行に失敗しました` を**含まない**。HINT を出さず コード130 |
| 40 | 同 `STUB_EXIT=143`(SIGTERM) | 130 と同じ扱い |
| 41 | `HEARTBEAT_INTERVAL_SECONDS=1` + 遅延するスタブ | stdout に `実行中 (経過` の行が1行以上現れる |
| 42 | `HEARTBEAT_INTERVAL_SECONDS=0` | 経過表示が出ない(無効化。既定値に依存しない検証のため明示指定) |
| 43 | 経過表示に会議内容が含まれない | ハートビート行に fixture の本文が現れない(ケース32の分割実行版) |

**分割と並列実行([02-generate-minutes.md §9](./02-generate-minutes.md))**

| # | 観点 | 期待結果 |
|---|---|---|
| 44 | `--parallel 0` / `--parallel 9` / `--parallel abc` | ERROR、コード1(`validate_step` の `1..8` 範囲検証) |
| 45 | `--parallel` 未指定(既定1) | `claude` の呼び出しが3回で、stdin がケース18と**完全に一致**する(後方互換の固定) |
| 46 | `--parallel 1` の明示指定 | ケース45と同一(分割経路に入らない) |
| 47 | `--parallel 2` で `00_transcript.txt` あり | `claude` が5回(ステップ1が2回 + ステップ2が2回 + ステップ3が1回) |
| 48 | `--parallel 2` のステップ1 stdin(パート1) | `PART_INFO` に `part: 1/2`、`TRANSCRIPT` のファイル名表示に ` part 1/2`、`CONTEXT_AFTER` あり、`CONTEXT_BEFORE` **なし** |
| 49 | 同(パート2) | `part: 2/2`、`CONTEXT_BEFORE` あり、`CONTEXT_AFTER` **なし**(末尾パート) |
| 50 | `--parallel 2` の各パート stdin | 分割対象以外の `MEETING_MEMO` が**全パートに全文**含まれる |
| 51 | `--parallel 2` で `00_transcript.txt` なし・メモ2件 | 最大バイト数のメモが分割対象になり、そのメモは `MEETING_MEMO` の全文セクションとして重複しない |
| 52 | 分割対象の選択表示 | stdout に分割対象のファイル名・パート数・オーバーラップ行数が出る(`announce_split_plan`) |
| 53 | `SPLIT_OVERLAP_LINES=5` | `CONTEXT_BEFORE` の行数が5行になる |
| 54 | `--parallel 2` のステップ2 stdin | `STEP1_OUTPUT` のファイル名表示が `01_speakers_utterances.md part i/2` で、`PART_INFO` と `CONTEXT_*` を含む(ステップ1と同じ規則。§9.1) |
| 54b | `--only-step 2 --parallel 2`(`01_parts/` 無し) | ステップ1のパートに依存せず2分割で実行される(`claude` 2回。部分再実行でも分割できること) |
| 55 | `--parallel 2` のパート出力 | `01_parts/01_part1of2.md` ・ `02_parts/02_part1of2.md` が作られ、中間生成物は連結結果になる |
| 56 | パート1が既存 | `claude` の呼び出しがステップ1で1回のみ(パートキャッシュの再利用) |
| 57 | `--parallel 4` で作ったパートを `--parallel 2` で再実行 | 総数がファイル名に含まれるためキャッシュが再利用されず、2分割で作り直される(行範囲の食い違いによる欠落防止。§9.4) |
| 58 | 2パートのうち1つで `claude` が失敗 | **全パートの完了を待ってから**コード3で停止し、中間生成物を確定しない |
| 59 | 同 | 成功したパートのファイルは残る(次回の再実行で再利用できる) |
| 60 | `--parallel 2` で1パートが `STUB_EXIT=130` | コード130・`中断されました`(失敗3より中断を優先) |
| 61 | `--parallel 2` + `--dry-run` | `claude` が呼ばれず、分割計画が stdout に出て コード0 |
| 62 | `--parallel 2` で分割対象が1行のみ | WARN(`行数が --parallel の指定に足りない`)を出して単発実行にフォールバックし コード0(die しない。§9.1) |
| 62b | `--only-step 2 --parallel 2` で `01_speakers_utterances.md` が無い | WARN(`分割対象が見つからない`)の後、前段欠落の ERROR でコード1・`claude` 0回(分割の可否判定が前段検証を飛ばさないこと) |
| 62c | 3行の分割対象 + `--parallel 8` | パート数は `min(PARALLEL, 行数)` の3に丸められ、`part: 3/3` が現れる |
| 63 | 全パートのステップ3 | ステップ3は分割されず `claude` 1回・stdin に `PART_INFO` を含まない |
| 63b | `part_line_range` の単体呼び出し | 等分割・端数の先頭配分・1パート指定が期待どおり(`10 2 3` → `5 7` など) |
| 64 | 単発実行で `STUB_EXIT=1`(stdout に出力あり) | `01_speakers_utterances.md.error.log` が残り、HINT にそのパスと `CLAUDE_CODE_MAX_OUTPUT_TOKENS` が現れる。**診断ログの本文はメッセージに出さない**([02-generate-minutes.md §5.4](./02-generate-minutes.md)) |
| 64b | 同上で stdout が空(`STUB_STDOUT_FILE` に空ファイル) | `.error.log` を作らず、従来の認証・入力サイズの HINT が出る |
| 64c | 単発実行で `STUB_EXIT=130` | `.error.log` を作らない(中断は診断対象ではない) |
| 64d | `--parallel 2` で1パートが `STUB_FAIL_STDOUT` を出して失敗 | `01_parts/01_part2of2.md.error.log` にその内容が残り、HINT が `*.error.log` と `CLAUDE_CODE_MAX_OUTPUT_TOKENS` を案内する |
| 64e | 64d の後、失敗要因を解いて再実行 | パートが確定し、前回の `.error.log` が消える(古い原因を残さない) |

**出力の先頭行の検証([02-generate-minutes.md §5.5](./02-generate-minutes.md))**

| # | 観点 | 期待結果 |
|---|---|---|
| 65 | `--only-step 3` でステップ3の出力が本文の途中から始まる | コード3・ERROR に `先頭` を含み、`minutes.md.truncated.md` に部分出力が残り、既存の `minutes.md` は壊れない |
| 65b | 同じ内容が `# ` で始まる | 正常終了(見出しの文言を問わないこと = 誤検知しないこと) |
| 65c | `--parallel 2` で1パートの先頭が不正 | コード3、そのパートは確定せず `01_parts/*.truncated.md` に残り、成功したパートのファイルは残る |
| 65d | ステップ1の出力が `- ` で始まる | 正常終了(箇条書き始まりを弾かない) |
| 65e | 65 の後、正常な出力で再実行 | `minutes.md` が確定し、前回の `.truncated.md` が消える |
| 65f | `output_head_pattern` / `verify_output_head` の単体呼び出し | ステップ1・2は `#`〜`######` と `- ` を受理し平文を拒否、ステップ3は `# ` のみを受理する |

**`aws_sso_login.sh`(bats)**

| # | 観点 | 期待結果 |
|---|---|---|
| 1 | `sts get-caller-identity` 成功 | `aws sso login` が呼ばれない、コード0 |
| 2 | 同 失敗 | `aws sso login --profile <p>` が呼ばれる |
| 3 | ログイン後も無効 | コード2 |
| 4 | `AWS_PROFILE` 未設定 | ERROR + `aws configure sso` HINT、コード2 |
| 5 | `active.env` からプロファイル読み込み | 読み込んだ値が `--profile` に渡る |
| 6 | 標準出力に caller identity が出ない | ARN 文字列が stdout に現れない |

**`transcribe.py`(pytest)**

| # | 観点 | 期待結果 |
|---|---|---|
| 1 | `--input` / `--output` 欠落 | コード1 |
| 2 | 入力ファイル不存在 | `InputError` → コード1 |
| 3 | 非対応拡張子 | コード1 |
| 4 | `format_timestamp` | `0 → 00:00:00`、`3661.4 → 01:01:01` |
| 5 | `format_segments`(タイムスタンプ付き) | `[00:00:04] 本文` 形式 |
| 6 | `--no-timestamps` | 本文のみ |
| 7 | 空セグメント・前後空白 | 除去される |
| 8 | `transcribe_media` 引数 | `--model-size` / `--language` / `--device` / `--compute-type` が正しく渡る(モック検証) |
| 9 | `faster_whisper` の ImportError | `TranscriptionError` → コード3、HINT に `requirements.txt` |
| 10 | `write_output` | 親ディレクトリを作成し、原子的に置換。書き込み失敗時に既存ファイルを壊さない |
| 11 | 出力ヘッダ | basename のみを含み、絶対パスを含まない |
| 12 | 正常系 E2E(モック) | 期待テキストが出力ファイルに書かれ、コード0 |

## 5. Format / Lint / Test コマンド

| 対象 | Format | Lint | Test |
|---|---|---|---|
| Python | `black scripts tests` | `ruff check scripts tests` | `pytest tests/python --cov=scripts --cov-report=term-missing` |
| Bash | `shfmt -i 2 -w scripts tests .devcontainer` | `shellcheck scripts/*.sh .devcontainer/postCreate.sh tests/stubs/claude tests/stubs/aws tests/bats/helper.bash` | `bats tests/bats` |

- **macOS で `bats` を実行する場合は Bash 5(`brew install bash`)が必要。** bats 1.14 は Bash 3.2 上では日本語のテスト名を解決できず、1件も実行されない(`bats: unknown test name`)。パイプライン本体は Bash 3.2 で動くこと(ケース34・34b)が要件であり、この制約は**テストランナー側だけの前提**である([01-conventions.md §8.3](./01-conventions.md))。
- Lint / Format の対象から外すもの:
  - **`tests/bats/*.bats`**:`@test "..." { }` は Bash の構文ではないため `shellcheck` / `shfmt` が解釈できない(shellcheck 0.9 / shfmt 3.8 とも bats 非対応)。`.bats` の記述品質は `bats` 実行そのもので担保する。`shfmt` は拡張子と shebang でファイルを選ぶため、`tests` を渡しても `.bats` は自動的に対象外になる。
  - **`tests/stubs/transcribe.py`**:Python スクリプトなので `shellcheck` に渡さない(渡すと構文エラーになる)。Python 側の `black` / `ruff` の対象に含める(上表の対象が `tests/python` ではなく `tests` なのはこのため)。

- カバレッジ目標:**決定的なコード部分に対して80%以上**(要件8.3)。対象は `scripts/transcribe.py` と `generate_minutes.sh` / `aws_sso_login.sh` の関数群。`prompts/*.md`・LLM 生成結果の品質は対象外。
- Bash 側のカバレッジは数値計測が困難なため、**§4 のテストケース表を関数網羅のチェックリストとして扱う**(全関数が少なくとも1ケースで実行されること)。
- タスク完了条件(要件8.4):デグレなし / Format・Lint・Test がすべて成功 / カバレッジ80%以上。
