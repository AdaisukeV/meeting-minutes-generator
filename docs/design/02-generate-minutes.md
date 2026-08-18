# `scripts/generate_minutes.sh` 詳細設計

> 親ドキュメント:[../design.md](../design.md)(設計書ハブ)
> 対応要件:`docs/requirements.md` 3.2.5, 3.4.1, 5, 7.2
> 前提:[01-conventions.md](./01-conventions.md)(終了コード体系・メッセージ様式・原子的書き込み)

---

## 1. CLI 仕様

```
usage: generate_minutes.sh <project> <date> [options]

arguments:
  project           projects/{project}/ に対応するプロジェクト名
  date              YYYY-MM-DD 形式の会議日

options:
  --from-step N     ステップ N から最終ステップ(3)まで実行(N=1..3、既定 1)
  --only-step N     ステップ N のみ実行(N=0..3。0 は文字起こしのみ)
  --model-size S    ステップ0の faster-whisper モデルサイズ(既定 base)
  --parallel N      ステップ1・2を N 分割して並列実行(N=1..8、既定 1 = 分割しない)
  --dry-run         claude / transcribe.py を実行せず、実行計画のみ出力
  -h, --help        使い方を表示して終了(終了コード 0)
```

| 条件 | 挙動 | 終了コード |
|---|---|---|
| 引数が2個未満 | usage を stderr に出力 | 1 |
| `project` / `date` が [01-conventions.md §2](./01-conventions.md) の形式に不一致 | ERROR + HINT | 1 |
| `--from-step` と `--only-step` の同時指定 | ERROR + HINT | 1 |
| `--from-step` / `--only-step` / `--parallel` の値が範囲外・非数値 | ERROR + HINT | 1 |
| 未知のオプション | ERROR + usage | 1 |

`--parallel` の上限を 8 とするのは、Bedrock 側のスロットリングを避けるための安全弁(§9.5)。`validate_step` を範囲 `1..8` で再利用して検証する。

### 1.1 環境変数

| 変数 | 既定 | 役割 |
|---|---|---|
| `ANTHROPIC_MODEL` | (必須) | 全ステップで使うモデルID。`require_model` が未設定を検出する |
| `ANTHROPIC_MODEL_STEP1` / `_STEP2` / `_STEP3` | 未設定 | ステップ別のモデルID上書き。未設定なら `ANTHROPIC_MODEL`(§5.1・要件3.4) |
| `INPUT_WARN_BYTES` | `400000` | stdin サイズ警告の閾値(§4.1) |
| `SPLIT_OVERLAP_LINES` | `30` | チャンク境界のオーバーラップ行数(§9.2) |
| `HEARTBEAT_INTERVAL_SECONDS` | `60` | 実行中の経過表示の間隔(§5.2)。`0` で無効化 |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `32000`(CLI 側の既定) | 1回の呼び出しの出力トークン上限。**スクリプトは参照せず `claude` CLI が解決する**(§9.6) |
| `CLAUDE_CODE_DISABLE_THINKING` | 未設定(thinking 有効) | `1` で thinking を無効化する。thinking は出力上限を本文と共有するため、止めると本文へ予算が回り自動継続が起きにくくなる。**所要時間に最も効く設定**(実測でステップ3が41分→1分52秒)。**スクリプトは参照せず `claude` CLI が解決する**(§9.6・[09-decisions.md §6.6](./09-decisions.md)) |
| `MAX_THINKING_TOKENS` | 未設定(CLI 側の既定) | thinking に割り当てる上限トークン数。**実測では効果が確認できなかった**ため上の `CLAUDE_CODE_DISABLE_THINKING` を優先する([09-decisions.md §6.6](./09-decisions.md)) |

## 2. 関数一覧

すべての関数は単一責務で、bats から個別に呼べるよう設計する。スクリプト末尾に以下のガードを置き、`source` 時に `main` が走らないようにする。

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

| 関数 | 引数 | 出力・副作用 | 終了コード |
|---|---|---|---|
| `usage` | なし | usage 文を stdout に出力 | 0 |
| `die` | `<code> <ERROR文> [HINT文]` | stderr へ出力し `exit <code>` | 指定値 |
| `parse_args` | `"$@"` | グローバル変数 `PROJECT` `MEETING_DATE` `FROM_STEP` `TO_STEP` `MODEL_SIZE` `PARALLEL` `DRY_RUN` を設定 | 0 / 1 |
| `load_auth_env` | なし | `config/auth/active.env` が存在すれば `set -a; source; set +a`。存在しなければ既存環境変数をそのまま使用(要件7.2) | 0 |
| `resolve_paths` | なし | `INPUT_DIR` `OUTPUT_DIR` `PROJECT_DIR` `PROMPT_DIR` `TRANSCRIPT_PARTS_DIR` および各ファイルパス変数を設定。`OUTPUT_DIR` を `mkdir -p` | 0 |
| `step_model` | `<step>` | `ANTHROPIC_MODEL_STEP{N}` があればそれ、無ければ `ANTHROPIC_MODEL` を stdout に出力(§5.1・要件3.4) | 0 |
| `validate_project` | なし | `PROJECT_DIR/config.yaml` と `PROMPT_DIR/{01,02,03}*.md` の存在確認 | 0 / 1 |
| `validate_inputs` | なし | `INPUT_DIR` の存在、および「議事メモ / メディアファイル / 既存 `00_transcript.txt`」の少なくとも1つの存在を確認 | 0 / 1 |
| `find_input_files` | `<拡張子...>` | `INPUT_DIR` 直下から指定拡張子のファイルを stdout に**1行1件**出力(`LC_ALL=C` のファイル名昇順)。拡張子の大文字小文字は `tr` で正規化して比較する(`${var,,}` は使わない。[01-conventions.md §8](./01-conventions.md)) | 0 |
| `find_memo_files` | なし | `INPUT_DIR` 直下の議事メモ候補を stdout に**1行1件で全件**出力(0件なら空出力。§4.2)。`find_input_files md txt` を呼ぶだけ | 0 |
| `find_media_files` | なし | `INPUT_DIR` 直下のメディア候補を stdout に**1行1件で全件**出力(0件なら空出力。§6)。`find_input_files mp4 m4a ...` を呼ぶだけ | 0 |
| `ensure_transcript` | なし | ステップ0。メディアがあり `00_transcript.txt` が無ければメディア1本ごとに `transcribe.py` を呼び、結果を連結して確定する。既存ならスキップし `WARN` 無しで進捗のみ出力 | 0 / 1 / 3 |
| `maybe_sso_login` | なし | `CLAUDE_CODE_USE_BEDROCK` が `1` のときのみ `aws_sso_login.sh` を実行 | 0 / 2 |
| `require_model` | なし | `ANTHROPIC_MODEL` が未設定なら die(モデルIDのエイリアス直書き禁止・要件3.4) | 0 / 1 |
| `emit_step_sections` | `<step> <part_index> <part_total>` | そのステップの入力セクション(`PROJECT_CONFIG` / `PART_INFO` / `MEETING_MEMO` / `CONTEXT_BEFORE` / `TRANSCRIPT` / `CONTEXT_AFTER` / `STEP{1,2}_OUTPUT` と終端行)を stdout へ出力(§4)。**ステップ別の `case` をここに閉じ込める**(`$()` の中に `case` を直接書くと Bash 3.2 が解釈できない。[01-conventions.md §9.2](./01-conventions.md)) | 0 / 1 |
| `build_step_input` | `<step> <part_index> <part_total>` | `emit_step_sections` の出力を `$()` で受けて stdout に出力(§4)。結果が `INPUT_WARN_BYTES` を超える場合は stderr へ `WARN`(§4.1) | 0 / 1 |
| `invoke_claude` | `<system_prompt_file> <stdin_file> <dest_file> <model> <step>` | **`claude` 呼び出しを閉じ込める唯一の関数**。`dest_file` には呼び出し元が用意した一時ファイルを渡す。テストではスタブに差し替える([07-testing.md §3](./07-testing.md))。中断(130 / 143)は 3 と区別して返す(§5.3)。成功時は `verify_output_head <step>` で出力の先頭行を検証し、不一致なら 4 を返す(§5.5) | 0 / 3 / 4 / 130 |
| `run_step` | `<step>` | 入力構築 → 一時ファイルへ `invoke_claude` → 成功時のみ `mv` で確定([01-conventions.md §6](./01-conventions.md))。分割対象があり `PARALLEL > 1` なら `run_step_parts` に委譲(§9)。`--dry-run` 時は計画のみ出力 | 0 / 1 / 3 / 130 |
| `run_step_parts` | `<step> <分割対象> <パート総数>` | 分割状態(`SPLIT_TARGET` / `SPLIT_LINES` / `SPLIT_OVERLAP`)を設定し、ステップ N をパート単位で並列実行して、パート出力を連結して確定する(§9.3) | 0 / 1 / 3 / 130 |
| `warn_stale_outputs` | `<last_step>` | `--only-step` で後続ステップの出力が古くなる場合に `WARN` を出す | 0 |
| `main` | `"$@"` | 上記のオーケストレーション | 0〜3 / 130 |

### 2.1 補助関数(実装時に追加)

上表の関数を単一責務に保つため、実装では以下の補助関数を置く。いずれも上位の関数から呼ばれ、単体でも bats から呼べる。

| 関数 | 引数 | 責務 |
|---|---|---|
| `die_usage` | `<ERROR文>` | `ERROR:` + usage を stderr に出して `exit 1`(引数不正時のみ) |
| `validate_step` | `<オプション名> <値> <min> <max>` | ステップ番号が数値かつ範囲内であることを検証 |
| `require_value` | `<オプション名> <残り引数数>` | オプションに値が続いていることを検証 |
| `step_prompt_file` | `<step>` | ステップ番号 → `prompts/{01_organize,02_structure,03_format}.md` |
| `step_output_file` | `<step>` | ステップ番号 → `{01_speakers_utterances,02_structured_conversation,minutes}.md` |
| `step_label` | `<step>` | ステップ番号 → 進捗表示用の名称(話者・発言の整理 / 会話の構造化 / 議事録フォーマット) |
| `repo_relative` | `<絶対パス>` | 進捗表示用にリポジトリルートからの相対パスへ変換(絶対パスを並べない) |
| `emit_section` | `<ラベル> <ファイルパス>` | §4 の区切りヘッダ + ファイル内容を stdout に出力 |
| `transcript_part_file` | `<メディアパス>` | メディアの basename からパートキャッシュのパスを組み立てる(§6.1) |
| `transcribe_part` | `<メディアパス>` | メディア1本を文字起こししてパートキャッシュへ保存する。既存パートがあれば `transcribe.py` を呼ばずスキップする(§6.1)。失敗時は die(1 / 3) |
| `announce_media_order` | `<メディアパス...>` | メディアが2件以上のときのみ、連結順を番号付きで stdout へ列挙する(規則を実行時に検証できるようにする。§6) |
| `concat_transcript_parts` | `<パートファイル...>` | パートを連結して stdout に出力。2件以上のときのみパートマーカーを付与(§6.2) |
| `require_prev_output` | `<step>` | 前段の中間生成物の存在を検証し、無ければ die(1)(§3) |
| `warn_if_input_too_large` | `<step> <テキスト>` | §4.1 の入力サイズ WARN |
| `register_tmp_file` / `cleanup_tmp_files` | `<パス>` / なし | 一時ファイルを登録し、`EXIT` トラップで削除([01-conventions.md §6](./01-conventions.md))。トラップは**スクリプトとして実行された場合のみ**張る(`source` して関数単体テストを行う bats のトラップを壊さないため) |
| `emit_labeled_lines` | `<ラベル> <表示名> <行データ>` | 区切りヘッダ + 与えられたテキストを stdout に出力。`emit_section` のファイル版に対する文字列版(`PART_INFO` / `CONTEXT_*` / チャンク本体で使う。§9.2) |
| `split_target_file` | `<step>` | そのステップの分割対象のファイルパスを stdout に出力(ステップ1は `00_transcript.txt` があればそれ、無ければ `largest_memo_file`。ステップ2は `01_speakers_utterances.md`。ステップ3は空)。候補が無ければ空出力(§9.1) |
| `largest_memo_file` | なし | `find_memo_files` のうち最大バイト数のものを stdout に出力。メモが無ければ空出力(§9.1) |
| `split_target_label` | `<ファイルパス>` | 分割対象のラベルを stdout に出力(`TRANSCRIPT` / `STEP1_OUTPUT` / `MEETING_MEMO`)。§4 のラベル体系を分割時も崩さないため(§9.1) |
| `count_lines` | `<ファイルパス>` | 行数を stdout に出力(§9.2) |
| `split_part_total` | `<分割対象>` | パート総数 `min(PARALLEL, 行数)` を stdout に出力。分割対象が空なら `1`(= 分割しない。§9.1) |
| `part_line_range` | `<全行数> <パート番号> <パート総数>` | そのパートの本体行範囲を `<開始行> <終了行>` の形で stdout に出力(§9.2) |
| `extract_lines` | `<ファイルパス> <開始行> <終了行>` | 指定行範囲を stdout に出力。範囲が空なら空出力(§9.2) |
| `emit_part_sections` | `<ラベル> <パート番号> <パート総数>` | `CONTEXT_BEFORE` / 本体 / `CONTEXT_AFTER` の3セクションを `SPLIT_TARGET` から切り出して出力(§9.2) |
| `step_part_dir` / `step_part_file` | `<step>` / `<step> <パート番号> <パート総数>` | `outputs/{p}/{d}/0{N}_parts/` と `.../0{N}_part{i}of{n}.md`(§9.4) |
| `run_one_part` | `<step> <パート番号> <パート総数> <プロンプト> <モデルID>` | 1パート分の「既存キャッシュ判定 → stdin 構築 → `invoke_claude` → `mv` で確定」。サブシェルで実行され、`die` せず終了コードで親へ返す(§9.3) |
| `concat_step_parts` | `<step> <パート総数>` | パート出力を番号順に単純結合して stdout に出力(§9.4) |
| `announce_split_plan` | `<step> <分割対象> <パート総数> <全行数> <オーバーラップ行数>` | 分割対象のファイル名・ラベル・行数・パート数を進捗へ列挙(規則を実行時に検証可能にする。§9.1) |
| `warn_split_fallback` | `<step> <分割対象>` | 分割できなかった理由を WARN で出し、単発実行へ落ちることを伝える(§9.1) |
| `start_heartbeat` / `stop_heartbeat` | `<表示文>` / なし | 実行中の経過を定期表示するバックグラウンドプロセスの開始・停止(§5.2) |
| `elapsed_label` | `<経過秒数>` | 経過秒数を `3分12秒`(60秒未満は `45秒`)の形の文字列に整形(§5.2) |
| `preserve_failure_output` | `<一時ファイル> <確定先パス> <退避先の拡張子>` | 失敗した `claude` の stdout を `<確定先><拡張子>` として残し、そのパスを stdout に出力。残す中身が無ければ削除して `1` を返す。拡張子は `.error.log`(エラーメッセージ)/ `.truncated.md`(先頭が欠けた部分出力)のいずれか(§5.4・§5.5) |
| `failure_output_suffix` | `<終了コード>` | 失敗の種類に応じた退避先の拡張子を stdout に出力(先頭不一致=4 なら `.truncated.md`、それ以外は `.error.log`)。`run_step` / `run_one_part` で同じ判定を書かないため(§5.4・§5.5) |
| `remove_failure_outputs` | `<確定先パス>` | 前回失敗時の `.error.log` / `.truncated.md` を削除する。成功パスから呼ぶ(古い原因を残して誤読させないため。§5.4) |
| `output_head_pattern` | `<step>` | そのステップの出力の1行目が満たすべき正規表現を stdout に出力(§5.5) |
| `verify_output_head` | `<step> <ファイル>` | ファイルの1行目を `output_head_pattern` と照合し、一致すれば 0、不一致なら 1 を返す(§5.5) |
| `die_step_failure` | `<step> <終了コード> [診断ログのパス]` | `run_step` / `run_step_parts` の失敗を報告して終了する。中断(130)は `中断されました(step N)`(HINT なし)、先頭不一致(4)は `出力の先頭が契約と一致しません(step N)` + HINT(退避先と出力量を減らす対処。§5.5)、それ以外は `claude の実行に失敗しました(step N)` + HINT(診断ログがあればそのパスと出力トークン上限の対処、無ければ認証・入力サイズ。§5.3・§5.4・§8)。**終了コードは 4 でも 3 を使う**([01-conventions.md §4](./01-conventions.md) の終了コード体系を変えない) |
| `on_interrupt` | なし | `SIGINT` / `SIGTERM` トラップ。ハートビートを止め、`ERROR: 中断されました` を stderr へ出して 130 で終了する(§5.3) |

## 3. 実行順序(`main`)

```
parse_args → load_auth_env → resolve_paths → validate_project → validate_inputs
  → (ステップ1が実行対象、または --only-step 0 の場合) ensure_transcript
  → (ステップ1..3のいずれかが実行対象の場合) require_model → maybe_sso_login
  → for step in max(FROM_STEP,1)..TO_STEP: run_step $step
       └ ステップ1・2 かつ PARALLEL > 1 かつ分割対象あり → run_step_parts $step(§9)
  → warn_stale_outputs $TO_STEP
```

- 既定は `FROM_STEP=1` / `TO_STEP=3`。**ステップ0(文字起こし)はステップ1を実行する場合の前処理として走る**(出力が既存ならスキップ)。`--from-step 2` 以降では文字起こしは不要なため実行しない。`--only-step 0` のときは文字起こしのみで終了する(`FROM_STEP=TO_STEP=0`)。
- `--from-step 2` 以降を指定した場合、前段の出力ファイルが存在しなければ die(1)し、「先に `--from-step 1` で実行してください」と HINT する。
- `--dry-run` では**外部コマンドを一切実行しない**:`claude` / `transcribe.py` に加えて `aws_sso_login.sh` も呼ばず、実行予定を1行で表示する(計画確認のためにブラウザ認証が走るのを防ぐ)。`parse_args` 〜 `validate_inputs` の検証と `require_model` は通常どおり行うため、設定不備は `--dry-run` で検出できる。`--parallel N` 併用時は分割対象とパート数も表示する(実行前に分割計画を確認できるようにする)。
- **`PARALLEL=1`(既定)のときは §9 の分割経路に入らず、従来と完全に同一の stdin・呼び出し回数を保つ。** 並列実行は明示的なオプト・イン(要件3.2.8)であり、既定動作の変更ではない。

## 4. 各ステップの入力構成(要件3.2.1〜3.2.3)

| ステップ | stdin に含める内容(この順) | システムプロンプト | 出力ファイル |
|---|---|---|---|
| 1 | `config.yaml`、議事メモ**全件**(あれば)、`00_transcript.txt`(あれば) | `prompts/01_organize.md` | `01_speakers_utterances.md` |
| 2 | `config.yaml`、`01_speakers_utterances.md` | `prompts/02_structure.md` | `02_structured_conversation.md` |
| 3 | `config.yaml`、`02_structured_conversation.md` | `prompts/03_format.md` | `minutes.md` |

`config.yaml` は**シェル側でパースせず内容をそのまま添付**する(YAML パーサ依存を追加しない。プロンプト側が自然言語として解釈する)。

**stdin の区切りヘッダ形式**(プロンプト側もこの見出しを前提に記述する):

```
===== INPUT: PROJECT_CONFIG (config.yaml) =====
project: client-a
companies:
  ...

===== INPUT: MEETING_MEMO (gemini_memo.md) =====
## 出席者
...

===== INPUT: MEETING_MEMO (human_memo.txt) =====
- 結合テストは来週金曜まで
...

===== INPUT: TRANSCRIPT (00_transcript.txt) =====
[00:00:04] それでは始めます。
...

===== END OF INPUT =====
```

- ヘッダは `===== INPUT: <ラベル> (<ファイル名>) =====` の固定書式。ラベルは `PROJECT_CONFIG` / `PART_INFO` / `MEETING_MEMO` / `CONTEXT_BEFORE` / `TRANSCRIPT` / `CONTEXT_AFTER` / `STEP1_OUTPUT` / `STEP2_OUTPUT` の8種(この順に出力する)。このうち `PART_INFO` / `CONTEXT_BEFORE` / `CONTEXT_AFTER` の3種は**分割実行時のみ**出力する(§9.2)。
- ファイル名は**basename のみ**を書き、絶対パスを出さない。`PART_INFO` はファイルに対応しないため `(part)` を書く。
- 存在しない入力のヘッダは出力しない(空セクションを作らない)。オーバーラップが空になる先頭・末尾パートでは `CONTEXT_BEFORE` / `CONTEXT_AFTER` を出さない。
- **`MEETING_MEMO` は議事メモの件数だけ繰り返す**(§4.2)。ラベルは増やさず、ファイル名で出所を区別する。
- 組み立ては `emit_step_sections`(ステップ別の `case` を持つ)と `build_step_input`(`$()` で受けてサイズ警告を出す)の2関数に分ける。**`case` を `$()` の中に直接書かない**という Bash 3.2 の制約による分割であり、この形を崩さない([01-conventions.md §9.2](./01-conventions.md))。

### 4.1 入力サイズの警告

1回のリクエストに収まらない、あるいは出力が最大出力トークンで切り詰められる可能性への注意喚起。**判定は警告のみで処理は継続する。**

```
WARN: ステップ1の入力が大きすぎる可能性があります (512000 バイト / 目安 400000 バイト)。
HINT:  --parallel N を指定してステップ1・2を分割・並列実行してください(例: --parallel 4)。
```

- 判定は `build_step_input` が組み立て**結果のバイト数**に対して行い、警告は **stderr** へ出す(stdout は `claude` への入力そのものであるため汚さない。[01-conventions.md §3](./01-conventions.md))。
- 閾値は `INPUT_WARN_BYTES`(既定 `400000`)。環境変数で上書きできる(テストではこの値を小さくして検証する)。
- **バイト数基準は日本語では実トークン量を過小評価する。** UTF-8 の日本語は1文字3バイトのため、閾値 400,000 バイトは約 133,000 文字に相当し、モデルのコンテキスト上限に達する水準である。既定値を下げないのは既存の bats 期待値と後方互換のためであり、**実際の判断材料は所要時間**(§9 の分割)である旨をここに明記しておく。
- HINT は `--parallel N` を案内する(従来の「`00_transcript.txt` を分割して個別に実行してください」という手作業の案内は、分割が実装されたため置き換える)。
- **警告のみで処理は継続する**(終了コードは0)。実際に上限を超えた場合は `claude` が非ゼロ終了し `invoke_claude` がコード3で停止する。
- 警告文に会議内容そのものを含めない([06-security.md §3](./06-security.md))。

### 4.2 議事メモの探索(`find_memo_files`。要件2, 3.2.1)

同一会議に対して複数のメモが存在する運用(Google Meet の Gemini 自動メモ + 人間が書いたメモ)を前提とする。

- 対象は `INPUT_DIR` **直下**(`-maxdepth 1`)の `*.md` / `*.txt`(拡張子の大文字小文字は区別しない。判定は `find_input_files` が `tr` で小文字化して行う)。要件2の「議事メモ(Markdown / テキスト)」に対応する。
- 並び順は **`LC_ALL=C` によるファイル名昇順**(ロケール差で順序が変わらないようにする)。順序を制御したい場合は `01_`・`02_` のような接頭辞を付ける運用とする。
- 0件でもエラーにしない(録画のみの会議に対応)。`validate_inputs` が「メモ / メディア / 既存文字起こし」のいずれも無い場合にのみ die(1)する。
- メモを1件も無視しない。**`memo.md` という固定名に依存しない**(固定名に依存すると、他の名前で置かれたメモが無言で落ちる)。
- 複数メモの突き合わせ(どちらを一次情報とするか・食い違いの扱い)は**プロンプト側の責務**とし、シェル側では判断しない(`prompts/01_organize.md`)。

## 5. `invoke_claude` の確定仕様(要件3.2.5, 3.2.7, 6.1)

```bash
# dest_file には run_step が用意した一時ファイルを渡す(確定は run_step が mv で行う)
# model は step_model が解決したモデルID(§5.1)
invoke_claude() {
  local system_prompt="$1" stdin_file="$2" dest_file="$3" model="$4" step="$5"
  local work_dir status
  work_dir="$(mktemp -d)"                      # CLAUDE.md を含まない空ディレクトリ
  status=0                                     # 失敗は `|| status=$?` で受ける(下記の注意)
  (cd "$work_dir" && claude -p \
      --bare \
      --system-prompt-file "$system_prompt" \
      --tools "" \
      --model "$model" \
    ) < "$stdin_file" > "$dest_file" || status=$?
  rm -rf "$work_dir"                           # 失敗が正常系ではないため || true を付けない
  # 中断は外部コマンド失敗と区別する(§5.3・01-conventions.md §4)
  if ((status == 130 || status == 143)); then
    return 130
  fi
  [[ $status -eq 0 ]] || return 3
  [[ -s "$dest_file" ]] || return 3            # 空出力は成功扱いにしない
  # 先頭が欠けた出力(自動継続)を成功扱いにしない(§5.5)
  verify_output_head "$step" "$dest_file" || return "$RET_HEAD_MISMATCH"
}
```

**`set +e` / `set -e` でグローバルな errexit を切り替えないこと。** `invoke_claude` の末尾で `set -e` に戻すと、呼び出し元(`run_step`)が `set +e` にしていた状態まで解除してしまい、`return 3` の時点でシェルが即座に終了する。その結果、`run_step` の `die 3`(`ERROR:` / `HINT:`)が**出力されないまま終了コード3で落ちる**([01-conventions.md §7](./01-conventions.md))。失敗は `|| status=$?` で受ける。

各オプションの根拠:

| オプション | 根拠 |
|---|---|
| `-p` | 非対話モード(要件3.2.5) |
| `--system-prompt-file` | システムプロンプトを完全置き換え(要件3.2.5) |
| `--bare` | **`CLAUDE.md` の自動読み込み(auto-memory / CLAUDE.md auto-discovery)・hooks・plugin を無効化**。要件3.2.7の「開発時ルールを運用時に混入させない」を実際に成立させるために必須([09-decisions.md §1](./09-decisions.md) の実機検証結果を参照) |
| `--tools ""` | 全ツールを無効化。Claude にファイル読み書き・Web検索・外部API経路を一切与えない(要件6.1、`CLAUDE.md` 1章) |
| `--model "$model"` | モデルIDを環境変数で明示固定。`sonnet` 等のエイリアスをコードに書かない(`CLAUDE.md` 4章)。値の解決は `step_model`(§5.1) |
| 空ディレクトリで実行 | `--bare` の挙動に依存しない二重防御。cwd の親を遡って `CLAUDE.md` が発見されることを構造的に防ぐ |

**制約**:`--bare` では Anthropic 直接認証が `ANTHROPIC_API_KEY`(または `apiKeyHelper`)に限定され、OAuth(Pro/Max のコンシューマープラン)は使用できない。本アプリは Bedrock または商用APIキーを前提とし、コンシューマープランは非推奨(要件6.4)であるため問題にならない。

### 5.1 `step_model`(ステップ別モデル指定・要件3.4)

```bash
# ステップ別の上書きがあればそれ、無ければ ANTHROPIC_MODEL(認証経路による分岐は持たない)
step_model() {
  local step="$1" override=""
  case "$step" in
  1) override="${ANTHROPIC_MODEL_STEP1:-}" ;;
  2) override="${ANTHROPIC_MODEL_STEP2:-}" ;;
  3) override="${ANTHROPIC_MODEL_STEP3:-}" ;;
  *) die 1 "不正なステップ番号です: $step" ;;
  esac
  if [[ -n "$override" ]]; then
    echo "$override"
  else
    echo "$ANTHROPIC_MODEL"
  fi
}
```

- ステップ1はフィラー除去・表記統一・名寄せという機械的処理が主なため、軽量なモデルへ振って生成速度を上げられる(要件3.4)。判断の重さはステップ2・3にある。
- **`require_model` は変更しない。** `ANTHROPIC_MODEL` はフォールバック元として引き続き必須とし、「ステップ別指定だけで `ANTHROPIC_MODEL` が無い」という設定を許さない(どのステップがどのモデルで動くかを `active.env` だけで追えなくなるのを防ぐ)。
- **認証経路ごとの分岐は増やさない**(`CLAUDE.md` 4章)。`active.env` に変数が増えるだけで、スクリプトは値を読むのみ。
- 上書きが効いているかは進捗表示では出さない(モデルIDは会議内容ではないが、進捗を1行1メッセージに保つため)。確認は `--dry-run` の出力で行う。

### 5.2 実行中の経過表示(要件3.2.5)

ステップ1・2は単発実行では10分を超えることがあり、`claude` の stdout はファイルへリダイレクトされるため**無表示の時間が続く**。これを「停止」と誤認して `Ctrl+C` されるのを防ぐため、実行中に経過を定期表示する。

```
ステップ1 (話者・発言の整理) を実行します
ステップ1 実行中 (経過 1分0秒)
ステップ1 実行中 (経過 2分0秒)
ステップ1 完了: outputs/client-a/2026-08-16/01_speakers_utterances.md (所要 2分34秒)
```

- `start_heartbeat` がバックグラウンドで `sleep` ループを回し、`stop_heartbeat` が停止する。間隔は `HEARTBEAT_INTERVAL_SECONDS`(既定60秒)。**`0` を指定すると起動しない**(bats では `0` にして出力を安定させる)。数値以外が入っていた場合も起動しない(不正な設定で `sleep` が暴走しないよう、die ではなく無効化で扱う)。
- 経過表示は **stdout**(利用者向け進捗)。`claude` の生成物はファイルという分離を崩さない([01-conventions.md §3](./01-conventions.md))。
- **会議内容は一切出さない**([06-security.md §3](./06-security.md))。出すのはステップ名と経過時間のみ。
- ハートビートのプロセスは `EXIT` トラップで確実に停止させる(`cleanup_tmp_files` と同じ経路)。放置すると `Ctrl+C` 後も `sleep` が残る。
- 経過時間は `SECONDS`(Bash 組み込み)の差分から `elapsed_label` で整形する。`date` の呼び出しを増やさない。

### 5.3 中断(`Ctrl+C`)の扱い

```
^C
ERROR: 中断されました(step 1)。
```

- `invoke_claude` は子プロセスの終了コード 130(SIGINT)/ 143(SIGTERM)を **130 として返す**(コード3の「外部コマンド失敗」と区別する)。
- `run_step` / `run_step_parts` は 130 を受けたら「認証状態と入力サイズを確認してください」という HINT を出さず、`中断されました` のみを出して終了コード130で終わる(`die_step_failure`)。**中断に対して的外れな原因を提示しないため**([01-conventions.md §4](./01-conventions.md))。
- あわせて `SIGINT` / `SIGTERM` のトラップ(`on_interrupt`)を張る。`claude` を待たずにシェル側へ直接シグナルが届いた場合でも、ハートビートを止めて `ERROR: 中断されました` を出し、130 で終わる(step 番号は付かない)。
- 一時ファイル(`stdin_file` / `tmp_out`)は `EXIT` トラップで削除され、確定済みのパート出力(§9.4)は残るため、再実行時は未完了のパートのみが実行される。

### 5.4 失敗時の診断ログ(`preserve_failure_output`)

**`claude` は API エラーを stdout に書いて非ゼロ終了する。** stdout は `tmp_out` へリダイレクトされているため、失敗時に `tmp_out` を消すと**原因が一切残らない**(実際に「35分走って `ERROR: ... の生成に失敗しました` だけが出る」状態になった。[09-decisions.md §6](./09-decisions.md))。

- 失敗した `tmp_out` が**非空**なら `<確定先>.error.log` へ `mv` して残す(`preserve_failure_output`)。空なら削除する(残す中身が無い)。
  - 単発実行:`outputs/{p}/{d}/01_speakers_utterances.md.error.log`
  - パート実行:`outputs/{p}/{d}/01_parts/01_part1of4.md.error.log`
- **中断(130)では残さない。** 書きかけの出力であって診断対象ではない。
- **成功時は同名の `.error.log` を削除する**(前回失敗の原因を残して誤読させない)。
- 診断ログの**本文はメッセージに出さない**(会議内容を含みうる。[06-security.md §3](./06-security.md))。HINT で示すのは**パスのみ**。単発実行は実パス、パート実行は完了順が不定でパスを親へ返せない(サブシェル)ため `01_parts/*.error.log` というパターンで示す。
- `.error.log` は `outputs/` 配下なので Git 管理外([06-security.md §1](./06-security.md))。`24b`(一時ファイルが残らないこと)の検証は `! -name '*.error.log'` と `! -name '*.truncated.md'` で除外する([07-testing.md §4](./07-testing.md))。
- 退避先の拡張子は `preserve_failure_output` の第3引数で受ける。**`.error.log` はエラーメッセージ、`.truncated.md` は先頭が欠けた部分出力**(§5.5)で、性質が違うため同じファイル名に混ぜない。

### 5.5 出力の先頭行の検証(`output_head_pattern` / `verify_output_head`。要件3.2.5)

**`claude` が出力上限に当たった応答を自動継続した場合、`-p` が返すのは最後の応答の本文だけである**(§9.6 (b))。終了コードは 0、出力も非空なので、§5 の既存2チェックはどちらも通過する。実際に `minutes.md` の先頭 12,040字が失われた状態が「成功」として確定した([09-decisions.md §6.5](./09-decisions.md))。

自動継続は**行の途中から再開する**ため、**出力の1行目が Markdown の構造的な行かどうか**を見れば捕まえられる。各ステップのプロンプトには既に1行目の契約がある(`01_organize.md` / `02_structure.md` / `03_format.md` の禁止事項。[05-project-assets.md §2](./05-project-assets.md))。

| ステップ | 1行目に要求するパターン | 契約の根拠 |
|---|---|---|
| 1・2 | `^(#{1,6} \|- )` | 1行目は `## 会議情報` / `## トピック:` / 発言の箇条書き(`- **話者名**: …`)のいずれか |
| 3 | `^# ` | 1行目は `# 議事録: <project>` |

- **見出しの文言ではなく構造で判定する。** プロジェクトがプロンプトの見出し語を変えても誤検知しないようにするため(`_template` の文言に実装を結び付けない)。実データ10ファイル(`01_parts/` 4件・`02_parts/` 4件・中間生成物2件)がすべて一致し、既知の壊れた `minutes.md`(1行目が `続行で。(サンプルソフト)`)のみが不一致になることを確認済み。
- 不一致は `invoke_claude` が内部戻り値 `RET_HEAD_MISMATCH`(= 4)で返す。**これは終了コードではない。** `die_step_failure` は 4 を受けても `die 3` で終了し、[01-conventions.md §4](./01-conventions.md) の終了コード体系(0/1/2/3/130)を変えない。
- 部分出力は捨てず `<確定先>.truncated.md` へ退避する(`preserve_failure_output` に `.truncated.md` を渡す)。先頭は失われているが本文の後半は残っており、利用者が内容を確認できるようにするため。**成功時は `.error.log` と同様に削除する**(古い失敗を残して誤読させない)。
- 空ファイルは §5 の `[[ -s ]]` が先に弾くため、この関数は非空を前提にしてよい。
- 中断(130)は検証しない(書きかけの出力であり、契約違反ではない)。
- HINT では**1回の呼び出しに要求する出力量を減らす**方向を案内する(`CLAUDE_CODE_DISABLE_THINKING=1` で thinking を止める / `--parallel` を増やす / `minutes_sections` を見直す。§9.6)。

## 6. `ensure_transcript`(ステップ0)

会議を中断して録画を再開した場合、**1つの会議が複数のメディアファイルに分割される**。この運用を前提に、メディア全件を文字起こしして連結する([09-decisions.md §4](./09-decisions.md) で「暗黙の連結はしない」という当初判断を撤回した経緯を記録)。

- メディア拡張子の探索対象:`mp4 m4a mp3 wav mov webm aac flac`(大文字小文字は区別しない。判定は `find_input_files` が `tr` で小文字化して行う)。探索は `INPUT_DIR` 直下(`-maxdepth 1`)。
- **探索結果が2件以上でもエラーにしない。** 全件を文字起こしし、**`LC_ALL=C` によるファイル名昇順**に連結する。この順序が会議の時系列順であることを前提とするため、連結順を進捗出力に列挙して利用者が検証できるようにする。
  ```
  ステップ0 (文字起こし): 3件のメディアを次の順で連結します
    1. recording_1.mp4
    2. recording_2.mp4
    3. recording_3.mp4
  ```
- 0件かつ `00_transcript.txt` も無い場合は、議事メモがあればスキップして進む(録画なしの会議に対応)。ただし `--only-step 0` が指定されている場合は「文字起こし対象が無い」ため die(1)する。
- `00_transcript.txt` が既存の場合は再実行しない(進捗に「既存の文字起こしを使用します」と出力)。再作成したい場合は当該ファイルを削除する運用とする(要件3.1)。

### 6.1 パートキャッシュ

`faster-whisper` の実行時間が長いため、**メディア1本ごとの文字起こし結果を残して再利用する**。録画を1本追加したときに、既存分をやり直さずに済ませるためのもの。

- 保存先は `OUTPUT_DIR/00_transcript_parts/{メディアの basename}.txt`(例 `00_transcript_parts/recording_1.mp4.txt`)。キャッシュのキーはメディアの basename。
- 該当パートが既存ならそのメディアの `transcribe.py` 呼び出しをスキップする(進捗に「既存のパートを使用します」と出力)。
- 連結対象は**毎回メディア一覧から再計算する**ため、メディアを削除しても古いパートが `00_transcript.txt` に混入しない(不要になったパートファイルは残るだけで無害)。
- パートは1本ごとに `transcribe.py` を呼ぶ。非ゼロ終了時は終了コードをそのまま伝播(1 または 3)し、どのメディアで失敗したかを ERROR に含める。詳細は [03-transcribe.md](./03-transcribe.md)。
  ```bash
  python3 "$SCRIPT_DIR/transcribe.py" \
    --input "$media" --output "$part" --model-size "$MODEL_SIZE"
  ```
- `--dry-run` では `transcribe.py` を呼ばず、連結順とパートの再利用有無のみ表示する。

### 6.2 連結とパートマーカー

- 連結結果は一時ファイルへ書き、成功時のみ `mv` で `00_transcript.txt` を確定する(原子的置換。[01-conventions.md §6](./01-conventions.md))。
- パートが**2件以上のときのみ**、各パートの先頭に次のマーカー行と空行を挿入する。1件のときは挿入せず、`00_transcript.txt` は `transcribe.py` の出力とバイト単位で同一になる(後方互換)。
  ```
  ----- TRANSCRIPT PART 1/3: recording_1.mp4 -----
  ```
- **タイムスタンプのオフセットは行わない。** 各パートは `[00:00:00]` から振り直されるが、会議を中断しているため実時間には空白があり、累積オフセットを足すと存在しない時刻を捏造することになる([09-decisions.md §4](./09-decisions.md))。パート内の相対時刻として扱い、時系列はファイル内の出現順で表す。
- プロンプト側(`prompts/01_organize.md`)にはこのマーカー書式と「パートをまたいでタイムスタンプを比較しない」ことを明記する。ステップ1はタイムスタンプを出力しないため、実務上の影響は小さい。
- マーカー行にファイル名以外の情報(会議内容)を含めない([06-security.md §3](./06-security.md))。

## 7. 再実行時の出力の扱い

- `run_step` は既存の出力を上書きする(原子的置換、[01-conventions.md §6](./01-conventions.md))。
- `--only-step N` を使い、後続ステップの出力が既存の場合は次の警告を出す。
  ```
  WARN: minutes.md は現在の 02_structured_conversation.md を反映していません。
  HINT: --from-step 3 で再生成してください。
  ```
- `--from-step` 実行は最終ステップまで走るため stale は発生しない。

## 8. 主要エラーメッセージ一覧

| 検知箇所 | メッセージ(要約) | コード |
|---|---|---|
| `parse_args` | `引数が不足しています` + usage | 1 |
| `parse_args` | `date の形式が不正です(YYYY-MM-DD)` | 1 |
| `validate_project` | `プロジェクト設定が見つかりません: projects/{p}/config.yaml` / `HINT: cp -r projects/_template projects/{p}` | 1 |
| `validate_project` | `プロンプトが見つかりません: projects/{p}/prompts/01_organize.md` | 1 |
| `validate_inputs` | `入力ディレクトリが見つかりません` / `HINT: 議事メモまたは録画を配置` | 1 |
| `require_model` | `ANTHROPIC_MODEL が設定されていません` / `HINT: config/auth/active.env で明示的にモデルIDを指定` | 1 |
| `maybe_sso_login` | `AWS SSO ログインに失敗しました` | 2 |
| `build_step_input` | `WARN: ステップ N の入力が大きすぎる可能性があります` / `HINT: --parallel N を指定してステップ1・2を分割・並列実行`(警告のみ・継続) | – |
| `warn_split_fallback` | `WARN: ステップ N の分割対象が見つからないため、分割せず単発で実行します` / `WARN: <basename> の行数が --parallel の指定に足りないため、ステップ N を分割せず単発で実行します`(警告のみ・継続。§9.1) | – |
| `invoke_claude` | `claude の実行に失敗しました(step N)` / `空の出力が返りました`。診断ログを残せた場合は HINT を `claude の出力を <パス>.error.log に残しました`(出力トークン上限なら `--parallel` / `CLAUDE_CODE_MAX_OUTPUT_TOKENS` を案内)に差し替える(§5.4) | 3 |
| `invoke_claude`(先頭不一致) | `出力の先頭が契約と一致しません(step N)` / `HINT: 出力上限に達して claude が応答を自動継続し、先頭部分が失われた可能性があります` + 退避先 `<パス>.truncated.md` + `CLAUDE_CODE_DISABLE_THINKING` / `--parallel` / `minutes_sections` の見直し(§5.5) | 3 |
| `run_step`(前段欠落) | `前段の出力が存在しません: 01_speakers_utterances.md` | 1 |
| `ensure_transcript` | `文字起こしに失敗しました: <メディアの basename>` | 1 / 3 |
| `ensure_transcript`(`--only-step 0` かつメディア0件) | `文字起こし対象の録画・音声ファイルが見つかりません` | 1 |
| `run_step` / `run_step_parts`(中断) | `中断されました(step N)`(HINT なし) | 130 |
| `run_step_parts` | `ステップ N のパート M/K の生成に失敗しました` / `HINT: 失敗した claude の出力は 0N_parts/*.error.log に残ります`(§5.4)+ 完了パートは再利用される旨 | 3 |

## 9. 分割と並列実行(要件3.2.8)

ステップ1・2の所要時間は**出力トークンの逐次生成**が律速であり、分割を直列で実行しても短縮しない。短縮はチャンクを**並列実行**して初めて得られる。`--parallel N`(既定 1)で有効化する。

- 対象はステップ1・2のみ。ステップ3は凝縮処理で出力が小さいため、パートを連結した後に**単発で実行**する。
- `PARALLEL=1`(既定)、または分割対象が見つからない場合は、`run_step` が従来の単発経路をそのまま通る。

### 9.1 分割対象の選択(`split_target_file` / `split_target_label`)

**各ステップは「自身の入力のうち最も大きい1ファイル」だけを分割する。** ステップごとに独立して解決するため、ステップ間でパート境界を引き継ぐ結線を持たない。

| ステップ | 分割対象 | ラベル |
|---|---|---|
| 1 | `OUTPUT_DIR/00_transcript.txt` があればそれ、無ければ `find_memo_files` のうち**最大バイト数**のもの | `TRANSCRIPT` / `MEETING_MEMO` |
| 2 | `OUTPUT_DIR/01_speakers_utterances.md`(ステップ1の中間生成物 = ステップ2の唯一の入力) | `STEP1_OUTPUT` |
| 3 | 分割しない(§9 冒頭) | — |

- **議事メモは分割しない。** 話者の名寄せ・固有名詞の確認に全チャンクで必要なため、分割対象以外の議事メモは**全チャンクへ全文を添付**する。分割対象がメモの場合、そのメモは本体(チャンク)としてのみ現れ、`MEETING_MEMO` の全文としては現れない(二重添付を避ける)。
- 最大バイト数のメモを選ぶ規則は、**進捗出力に列挙して利用者が実行時に検証できるようにする**(§6 の連結順表示と同じ思想。[09-decisions.md §5](./09-decisions.md))。

```
ステップ1 を 4 分割して並列実行します
  分割対象: 00_transcript.txt (TRANSCRIPT) / 1204 行
  オーバーラップ: 30 行
```

- **ステップ2はステップ1のパート境界を引き継がない。** ステップ1の連結済み出力(`01_speakers_utterances.md`)を改めて行数分割する。ステップ1のパート出力を直接ステップ2の入力にする案(パート `i` → パート `i`)も検討したが採らなかった。理由は次の3点。
  - `--from-step 2` / `--only-step 2` では `01_parts/` が存在しないため、**引き継ぎ方式では分割できない**。ステップ単位の部分再実行を保つ方針(要件3.2.5)と噛み合わない。
  - 引き継ぎ方式ではステップ1とステップ2で並列度を変えられない。
  - 「自身の入力を分割する」1つの規則に統一でき、ステップ固有の分岐が減る(KISS・要件8.1)。
- 分割対象が見つからない、または対象の行数がパート数に足りない(1パートに縮退する)場合は、**WARN を出して単発実行にフォールバックする**(die しない。並列指定は高速化の希望であって必須要件ではない)。パート数は `min(PARALLEL, 行数)` に丸める。
- ただし `--dry-run` ではこの WARN を出さない。ステップ2の分割対象(`01_speakers_utterances.md`)は計画時点では存在しないのが正常であり、「分割できません」と表示すると実行時の挙動を誤解させる。

### 9.2 行数分割とオーバーラップ(`part_line_range` / `extract_lines`)

分割は**行数ベース**。チャンク境界の前後に `SPLIT_OVERLAP_LINES`(既定30)行の重なりを付ける。境界付近の話者推定・応答関係の手がかりを残すため。

- 本体の行範囲は全行数を N 等分し、端数は先頭側のパートへ1行ずつ配分する(パート間の行数差を1以内に収める)。
- 分割対象・全行数・オーバーラップ行数はグローバル変数 `SPLIT_TARGET` / `SPLIT_LINES` / `SPLIT_OVERLAP` で受け渡す(`run_step` / `run_step_parts` が設定し、`emit_part_sections` が読む)。引数で引き回さないのは、`build_step_input <step> <part_index> <part_total>` のシグネチャを単発実行時と共通に保つため。`SPLIT_TARGET` が空のときは分割していない状態を表し、この場合の stdin は従来と完全に同一になる。パート実行のサブシェルへは fork 時の値がそのまま引き継がれる。
- **重なりは本体と別ラベルで渡す。** `CONTEXT_BEFORE` は直前パート末尾の重なり行、`CONTEXT_AFTER` は次パート先頭の重なり行。先頭パートに `CONTEXT_BEFORE` は無く、末尾パートに `CONTEXT_AFTER` は無い(空セクションを作らない・§4)。
- **連結時の重複除去は実装しない。** プロンプト側で `CONTEXT_*` を「文脈把握のみに使い、出力に含めない」と規定することで、パート出力を単純結合できる状態を保つ([09-decisions.md §5](./09-decisions.md))。

分割実行時の stdin(ステップ1・パート2/4の例):

```
===== INPUT: PROJECT_CONFIG (config.yaml) =====
project: client-a
...

===== INPUT: PART_INFO (part) =====
part: 2/4
...

===== INPUT: MEETING_MEMO (human_memo.txt) =====
- 結合テストは来週金曜まで
...

===== INPUT: CONTEXT_BEFORE (00_transcript.txt) =====
[00:12:31] ……前パート末尾の重なり(出力禁止)
...

===== INPUT: TRANSCRIPT (00_transcript.txt part 2/4) =====
[00:13:02] それでは次の議題に移ります。
...

===== INPUT: CONTEXT_AFTER (00_transcript.txt) =====
[00:25:44] ……次パート先頭の重なり(出力禁止)
...

===== END OF INPUT =====
```

- 本体セクションのファイル名表示には ` part i/N` を付記する(`CONTEXT_*` には付けない。重なりはパートに属さない文脈だと示すため)。
- `PART_INFO` はファイルに対応しないため表示名を `(part)` とし、`part: i/N` の1行のみを本文とする。**`会議情報` ブロックを先頭パートのみが出力する**判定にプロンプト側が使う。
- **ステップ2も同じ構成**で、本体が `STEP1_OUTPUT (01_speakers_utterances.md part i/N)`、`CONTEXT_BEFORE` / `CONTEXT_AFTER` が前後の重なり行になる。ステップ1と同じ規則(§9.1)なので、ラベル以外の分岐は無い。
- ステップ1で分割対象がメモだった場合、そのメモは本体セクションとしてのみ現れ、`MEETING_MEMO` の全文セクションには現れない(§9.1)。他のメモは全パートに全文が入る。

### 9.3 並列実行(`run_step_parts`)

[01-conventions.md §8.4](./01-conventions.md) の PID 集約方式で実装する(`wait -n` は Bash 4.3+ 専用のため使わない)。

- パートごとにサブシェルで「stdin 構築 → `invoke_claude` → 一時ファイルを `mv` でパート出力へ確定」まで行う(`run_one_part`)。**`die` はサブシェルで呼ばず**、終了コードで親へ返す。
- `run_one_part` は `register_tmp_file` を使わず、自分の一時ファイル(stdin ファイルとパート出力の一時ファイル)を自分で `rm -f` する([01-conventions.md §8.4](./01-conventions.md) の EXIT トラップの挙動による)。
- **1つでも失敗したら全パートの完了を待ってから親で `die` する。** 途中で抜けるとジョブが孤児になり、書き込み中の一時ファイルが残る(要件3.2.8)。
- 複数パートが同時に失敗した場合、報告は **中断(130)> 先頭不一致(4)> その他の失敗(3)** の優先順とする([01-conventions.md §8.4](./01-conventions.md))。`Ctrl+C` は全パートに届くため、複数パートが同時に130を返す。先頭不一致を3より優先するのは、原因と対処(出力量を減らす。§5.5)が特有であり他の失敗に埋もれさせないため。**利用者へ返す終了コードは 4 でも 3 である。**
- パート完了時に進捗を出す。**並列実行なので完了順は不定**であり、文言もそれを前提にする。
  ```
  ステップ1 パート 2/4 完了 (経過 3分12秒)
  ```
- パート単位の実行なので、ハートビート(§5.2)はステップ全体に対して1つだけ起動する(パートごとに起動すると出力が混み合う)。

### 9.4 パートキャッシュと連結(`step_part_file` / `concat_step_parts`)

`00_transcript_parts/`(§6.1)と同じ思想で、**チャンクごとの出力を残して再利用する**。中断・一部失敗からの再開で、完了済みのパートをやり直さないため。

- 保存先は `OUTPUT_DIR/0{N}_parts/0{N}_part{i}of{k}.md`(例 `01_parts/01_part2of4.md`)。
- **キャッシュのキーにパート総数 `k` を含める。** `--parallel 4` で作ったパートを `--parallel 2` の実行が誤って再利用すると、行範囲が違うため会議内容が欠落する。ファイル名に総数を含めることで、並列度を変えた再実行は別のキャッシュ空間になる。
- 既存パートがあれば `claude` を呼ばずスキップし、進捗に `既存のパートを使用します` を出す。
- **全パートが揃ってから**連結し、成功時のみ `mv` で中間生成物を確定する([01-conventions.md §6](./01-conventions.md))。連結は番号順の単純結合で、パートマーカーは挿入しない(中間生成物は次ステップの入力であり、`会議情報` 以外はフラットな構造のため区切りが不要)。
- パート出力をやり直したい場合は当該ファイルまたは `0{N}_parts/` を削除する運用とする(§6.1 と同じ)。

### 9.5 並列度の上限とスロットリング

- `--parallel` の範囲は `1..8`。上限を設ける理由は Bedrock 側のスロットリング(`ThrottlingException`)で、並列度を上げすぎると個々のリクエストが失敗して**かえって遅くなる**。
- 既定を 1 とし、並列実行を**明示的なオプト・イン**とする(要件3.2.8)。既定を上げると、既存利用者の実行がスロットリングで失敗する形の後方非互換になる。
- スロットリングによる失敗はリトライしない。`claude` が非ゼロ終了した場合はコード3で報告し、利用者が並列度を下げて再実行する。**完了済みのパートは §9.4 のキャッシュで再利用されるため、やり直しは失敗したパートのみになる。**

### 9.6 1パートあたりの出力トークン上限(`CLAUDE_CODE_MAX_OUTPUT_TOKENS`)

**分割で下げなければならないのは入力サイズではなく1回の呼び出しの出力量である。** `claude` CLI の既定の出力上限は 32,000 トークンで、超えると次のエラーを **stdout** に書いて非ゼロ終了する(実測。[09-decisions.md §6](./09-decisions.md))。

```
API Error: Claude's response exceeded the 32000 output token maximum.
To configure this behavior, set the CLAUDE_CODE_MAX_OUTPUT_TOKENS environment variable.
```

- ステップ1・2は全発言を書き直すため、**出力量は入力量に比例する**。長い会議では単発実行も、粗い分割も、この上限に当たる。
- 対処は2つあり、どちらもスクリプト側の分岐を増やさずに済む。
  1. `--parallel` を増やして**1パートの出力を小さくする**(推奨。並列化と両立する)。
  2. `CLAUDE_CODE_MAX_OUTPUT_TOKENS` を上げる。`claude` CLI が環境変数から解決するため、スクリプトはこの変数を参照しない(`ANTHROPIC_SMALL_FAST_MODEL` と同じ扱い。[04-auth.md §2.1](./04-auth.md))。
- 上限に当たった結果は**2通りに分かれる**。原因はいずれも stdout にしか出ないため、§5.4 の診断ログ保存が無いと (a) すら利用者に伝わらない。
  - **(a) 上記のエラーで非ゼロ終了する。** `invoke_claude` が捕らえ、`*.error.log` に残る。
  - **(b) `claude` が応答を自動継続し、exit 0 で終わる。** この場合 `-p` が返すのは**最後の応答の本文だけ**で、それ以前に生成された本文は失われる。終了コードも `[[ -s "$dest_file" ]]` も通過するため、**§5.5 の先頭行検証で捕らえる**(実測。[09-decisions.md §6.5](./09-decisions.md))。
- thinking も同じ出力上限を消費する。上限を上げるだけでは thinking に吸われて (b) を招きやすくなるため、**`CLAUDE_CODE_DISABLE_THINKING=1` で thinking を止める**のが最も効く(実測でステップ3が41分→1分52秒になり、自動継続そのものが起きなくなった)。あわせて `--parallel` による分割で1回の出力量を減らす。`MAX_THINKING_TOKENS` は実測で効果が確認できなかった([09-decisions.md §6.6](./09-decisions.md))。いずれも `CLAUDE_CODE_MAX_OUTPUT_TOKENS` と同じくスクリプトは参照せず、`active.env` に書ける環境変数として案内するだけに留める(`CLAUDE.md` 4章)。
- ステップ3は分割しない(§9 冒頭)ため、出力量を下げる手段は `config.yaml` の `minutes_sections` の見直しになる。**全発言を再掲するセクション(`詳細な議事録`)を含めると出力が数倍になり、上限に当たりやすい**([05-project-assets.md §2.3](./05-project-assets.md))。
