# 実装計画(設計書 → 実装)

作成日:2026-08-16
対象:`docs/requirements.md`(要件定義書)/ `docs/design.md` + `docs/design/`(設計書ハブ+分冊)

> **本書の位置づけ**:設計書(HOW)をコードに落とすための**作業計画**。仕様の正は要件定義書、設計の正は設計書であり、本書は実装順序・品質ゲート・検証手順のみを持つ。完了したイテレーションはチェックを入れ、計画から乖離した場合は本書を更新する。

---

## 1. 背景と方針

要件定義書と設計書は確定済みだが、**実装はまだ存在しない**(`scripts/` にあるのは旧 `relogin.sh` のみ、`.gitignore` も未作成)。要件6.2(機密パスの Git 除外)が未充足のまま、リポジトリ直下に `.env` が未追跡で置かれている状態のため、**`.gitignore` の作成を最初のタスクとする**。

各イテレーションは要件8.1 の「最長30分程度」に収まる単位に分割し、末尾で必ず Format / Lint / Test をグリーンにしてからコミットする(要件8.4)。

### 1.1 確定方針

| 項目 | 決定 | 理由 |
|---|---|---|
| Python バージョン | **3.14 のまま**(バージョンを固定しない) | 現 Codespace が 3.14.2 で、`faster-whisper 1.2.1` / `ctranslate2 4.8.1` が解決することを確認済み。設計・要件側の「3.12 固定」記述を「3.12 以上」へ更新する |
| 検証の深さ | **実機E2Eまで** | モックテストに加え、(a) faster-whisper `tiny` での実文字起こし、(b) Bedrock でのステップ1〜3 実行、(c) `CLAUDE.md` 非混入の実測を行う |
| Git 運用 | **作業ブランチ `feature/implement-pipeline` でイテレーションごとにコミット** | 品質ゲート通過を「1コミット=1イテレーション」で担保し、ロールバック単位を明確にする |

実機E2Eの費用目安:1回あたり入力6k / 出力3k トークン程度(Sonnet で約 $0.06/回)。プロンプト調整を含め 5〜10回で $0.5 前後。faster-whisper のモデルダウンロードは無料。

### 1.2 実装前に修正する設計の穴

実装に着手する前に、**コードを設計に合わせるのではなく設計書を先に直す**(要件8章)。

| # | 内容 | 修正先 | 対応イテレーション |
|---|---|---|---|
| A | Python 3.12 固定の記述 | `docs/design/08-dev-environment.md` §1、`docs/requirements.md` 7.1、経緯を `docs/design/09-decisions.md` §3 | 0 |
| B | Lint 対象が `shellcheck ... tests/stubs/*` になっており、Python スタブ `tests/stubs/transcribe.py` を shellcheck に食わせてしまう | `docs/design/07-testing.md` §5(対象を `scripts/*.sh tests/stubs/claude tests/stubs/aws tests/bats/helper.bash` に限定) | 1 |
| C | `09-decisions.md` §2 の「stdin が 400,000 バイト超で WARN」に対応する関数が `02-generate-minutes.md` §2 の関数一覧に無い | `docs/design/02-generate-minutes.md` §2/§4(`build_step_input` 内で閾値 WARN)、`07-testing.md` §4 にケース33を追加 | 4 |
| D | `--system-prompt-file` は `claude --help`(v2.1.233)に**未記載だが受理される**(実測済み)。将来の非互換で壊れるリスク | `docs/design/09-decisions.md` §1 に注記(テストは bats ケース21で引数を固定) | 4 |

---

## 2. イテレーション

### イテレーション 0:足場とセキュリティ境界 ✅(コミット `2963c38`)

- [x] `git switch -c feature/implement-pipeline`
- [x] **`.gitignore` を最初に作成**(`06-security.md` §1 の確定内容:`inputs/`、`outputs/`、`config/auth/active.env`、`.env`、`.env.*`、`!*.env.example`、Python 生成物、`.DS_Store`)
- [x] `requirements.txt`(faster-whisper)/ `requirements-dev.txt`(pytest, pytest-cov, ruff, black)を `08-dev-environment.md` §3 のとおり作成
- [x] 設計の穴 **A** を修正
- [x] `.devcontainer/devcontainer.json` を `08-dev-environment.md` §1 へ更新(`aws-cdk` Feature 削除、`containerEnv` → `remoteEnv`、`hostRequirements: {cpus: 4}`)、`.devcontainer/postCreate.sh` を新規作成
- [x] 現 Codespace に開発ツールを導入(`ffmpeg` / `shellcheck` / `shfmt` / `bats` / `pip install --user -r requirements*.txt`)
- [x] `docs/memo/` を作成し、依存パッケージ追加を記録(`CLAUDE.md` 5章)
- [x] 追加対応:旧 `.env` が**追跡済み**だったため `git rm --cached .env`(記録:`docs/memo/2026-08-16-untrack-dotenv.md`)

**品質ゲート**:`git check-ignore -v` でダミーの `inputs/`・`outputs/`・`config/auth/active.env`・`.env` がすべて無視対象であること。`git status --porcelain` に機密パスが現れないこと。`python3 -c "import faster_whisper"` と各ツールの `--version` が成功すること。

### イテレーション 1:テストハーネス(`07-testing.md` §1〜§3)✅(コミット `7e58fa7`)

- [x] 設計の穴 **B** を修正
- [x] `tests/fixtures/`(`config.yaml`, `memo.md`, `transcript.txt`, `step1_output.md`, `step2_output.md`)
- [x] `tests/stubs/{claude,aws,transcribe.py}`(`STUB_ARGS_FILE` / `STUB_STDIN_FILE` / `STUB_STDOUT_FILE` / `STUB_EXIT` / `STUB_CWD_FILE` で挙動を制御)
- [x] `tests/bats/helper.bash`(`BATS_TEST_TMPDIR` に擬似リポジトリを構築し、`PATH` 先頭にスタブを挿入)

**品質ゲート**:スタブ+helper に `shellcheck` / `shfmt`。スモーク bats 1本(スタブが `PATH` 経由で拾われ `STUB_ARGS_FILE` に記録される)。`pytest tests/python` が起動する。

### イテレーション 2:`scripts/transcribe.py`(`03-transcribe.md`、TDD)✅(コミット `749ce77`)

サブステップごとに Red → Green → Refactor。括弧内は `07-testing.md` §4 の pytest ケース番号。

- [x] **2a** 純関数:`format_timestamp` / `format_segments` / `build_header`(4,5,6,7,11)
- [x] **2b** 入力系:`parse_args` / `validate_input_path`、`InputError`→1 / `TranscriptionError`→3 のマッピング(1,2,3)
- [x] **2c** 出力系:`write_output` の原子的置換(`os.replace`)、書き込み失敗時に既存ファイルを壊さない(10)
- [x] **2d** 連携:`transcribe_media` の引数受け渡し(8)、`faster_whisper` 遅延 import の `ImportError`→3(9)、`main` E2E モック(12)

**実績**:pytest 42件グリーン、`scripts/transcribe.py` カバレッジ 99%(80%目標を充足)。

**品質ゲート**(各サブステップ):`black` → `ruff check` → `pytest tests/python --cov=scripts --cov-report=term-missing` で `transcribe.py` 80%以上。
**実機検証**:`ffmpeg` で 5〜10秒の音声を生成し `--model-size tiny` で実際に文字起こし → 出力形式(メタ3行 + `[HH:MM:SS] 本文`)を確認。

### イテレーション 3:認証(`04-auth.md`)✅

- [x] `config/auth/{bedrock,anthropic-api,vertex}.env.example` を §2.1 の変数表どおり作成
- [x] `scripts/aws_sso_login.sh` を TDD(`aws` スタブ、bats ケース1〜6):`load_auth_env` / `resolve_profile` / `is_session_valid` / `do_login` / `main`
- [x] 旧 `scripts/relogin.sh` を削除し、削除記録を `docs/memo/` に残す(`docs/memo/2026-08-16-remove-relogin-sh.md`)
- [x] `.env`(`AWS_PROFILE_NAME`)→ `config/auth/active.env`(`AWS_PROFILE`)の移行手順を README に記載(**イテレーション7で削除**:移行はローカルで完了しており、README に残す必要が無い。過去の追跡状況を公開ドキュメントに明記しない方針とした)

**品質ゲート**:bats 6件グリーン、`shellcheck` / `shfmt`。実機で `./scripts/aws_sso_login.sh` を実行し、既存セッションが有効なため再ログインがスキップされ、stdout に ARN が出ないこと。

**実績**:bats 18件グリーン(ケース1〜6+境界ケース `3b` / `5b` + 関数単体2件、およびイテレーション1のハーネス8件)。`shellcheck` / `shfmt` クリーン。実機実行で `既存のSSOセッションを使用します (profile: …)` の1行のみを出力し終了コード0、`aws sso login` は呼ばれず stdout に ARN も出ないことを確認。

### イテレーション 4:`scripts/generate_minutes.sh`(`02-generate-minutes.md`、TDD)

着手前に設計の穴 **C**・**D** を修正。括弧内は `07-testing.md` §4 の bats ケース番号。サブステップ単位でコミットしてよい。

- [x] 設計の穴 **C** を修正(`02-generate-minutes.md` §2/§4.1 に入力サイズ WARN、`07-testing.md` §4 にケース33)
- [x] 設計の穴 **D** を修正(`09-decisions.md` §1.2 に `--system-prompt-file` の互換性リスクと緩和策)
- [x] **4a** `usage` / `die` / `parse_args`(2,3,4,5,6,7)
- [x] **4b** `load_auth_env` / `resolve_paths` / `validate_project` / `validate_inputs` / `find_media_file`(8,9,11,12,13,14,28)
- [x] **4c** `build_step_input` + 入力サイズ WARN(18,19,20,33)
- [x] **4d** `invoke_claude` / `run_step`(10,21,22,23,24,25):`--bare` / `--tools ""` / `--system-prompt-file` / `--model` が渡ること、cwd がリポジトリ外の空ディレクトリであること、失敗・空出力で終了コード3かつ出力ファイルを確定しないこと
- [x] **4e** `ensure_transcript` / `maybe_sso_login` / `require_model` / `warn_stale_outputs` / `main`(1,15,16,17,26,27,29,29b,29c,30,31,32)

**品質ゲート**(各サブステップ):累積の bats 全件グリーン、`shellcheck` / `shfmt`。`07-testing.md` §4 の表を**関数網羅チェックリスト**として消化状況を確認(全関数が少なくとも1ケースで実行される)。

**実績**:bats 95件グリーン(`generate_minutes.bats` 77件 + `aws_sso_login.bats` 10件 + `harness.bats` 8件)、`shellcheck` / `shfmt` クリーン。`07-testing.md` §4 のケース1〜33をすべて実装(境界ケースを `2b`〜`33c` として追加)。設計書 §2 の全関数 + §2.1 の補助関数が少なくとも1ケースで実行されることを確認。実装で追加した補助関数は `02-generate-minutes.md` §2.1 に、`--dry-run` が `aws_sso_login.sh` も呼ばないことは同 §3 に反映済み。

### イテレーション 5:プロジェクト資産と初回実機E2E(`05-project-assets.md` §1, §2)

- [x] `projects/_template/config.yaml` と `prompts/{01_organize,02_structure,03_format}.md`(共通ルールを各ファイルで自己完結させ、stdin の区切りヘッダ `===== INPUT: <ラベル> (<ファイル名>) =====` を前提に記述)
- [x] ダミープロジェクト `projects/sample` と `inputs/sample/{date}/memo.md`(架空の内容。`inputs/` はコミットしない)
- [x] スタブE2E:`--dry-run` の実行計画表示、スタブ経由で3ファイルが生成されること
- [x] **実機 Bedrock E2E**:`config/auth/active.env` に `CLAUDE_CODE_USE_BEDROCK=1` と `ANTHROPIC_MODEL`(モデルIDを明示。現在未設定のため利用者が設定)を置き、`./scripts/generate_minutes.sh sample {date}` を実行 → `minutes.md` を人間レビュー
- [x] **`CLAUDE.md` 非混入の実測**:生成物に `set -euo pipefail`・`inputs/`・「絶対にGitへコミットしない」等のリポジトリ固有語が出ないことを確認し、「システムプロンプト以外の指示を列挙して」というプローブ入力で `NO_PROJECT_INSTRUCTIONS` 相当になることを確認。結果を `09-decisions.md` §1 の表に追記
- [x] 出力品質を見てプロンプトを2〜3回調整(調整対象は `prompts/*.md` のみ。スクリプトは触らない)

**品質ゲート**:全 bats / pytest / lint がグリーンなまま、実機E2Eで所定のファイルが生成され、混入チェックが通ること。コミット対象は `projects/_template` と調整後プロンプトのみ(`inputs/`・`outputs/` が除外されていることを `git status` で再確認)。

**実績(資産作成まで)**:`projects/_template`(`config.yaml` + プロンプト3ファイル)と `projects/sample`(架空の在庫管理システム刷新案件)、`inputs/sample/2026-08-17/memo.md`(Git 管理外)を作成。スタブE2E は `PATH=tests/stubs` 経由で実行し、`--dry-run` が3ステップの実行計画のみを表示すること、通常実行で `outputs/sample/2026-08-17/{01_speakers_utterances.md,02_structured_conversation.md,minutes.md}` の3ファイルが生成されることを確認(確認後 `outputs/` は削除)。bats 95件 / pytest 42件 / lint すべてグリーン、`git status` に `inputs/`・`outputs/` が出ないことを確認。

**実績(実機E2E・混入実測・プロンプト調整)**:2026-08-17、`config/auth/active.env`(Bedrock / `AWS_PROFILE` / `AWS_REGION=ap-northeast-1` / `ANTHROPIC_MODEL=jp.anthropic.claude-sonnet-4-6`)を作成して実施。

- **実機E2E**:`./scripts/generate_minutes.sh sample 2026-08-17` が3ファイルを生成(所要 約3〜4分)。`--only-step 3` による部分再実行も動作を確認。
- **混入実測**:生成物へのリポジトリ固有語は全12語0件。プローブ入力では「パイプラインと同条件(リポジトリ外 + `--bare`)」でプロジェクト固有指示なし、「リポジトリ内 + `--bare` なし」で `CLAUDE.md` の混入を再現。結果と合格条件の見直しを `09-decisions.md` §1.1 に追記。
- **プロンプト調整(3回)**:(1) 会議メタ情報が失われ `会議概要` が常に `(要確認)` になる問題を、ステップ1・2の先頭に任意の `## 会議情報` ブロックを設けて解消(設計は `05-project-assets.md` §2.1 に反映)。併せて出席者を `speakers[]` から推定しない・ToDo をメタ的な項目にしない・括弧半角と日付 `YYYY-MM-DD` の統一を追加。(2) 議題を `## 会議情報` に無ければトピック名から列挙、決定事項を `結論:` 由来のみに限定。(3) トピック名プレフィックスのセクション内統一、ToDo の `内容` 列への担当・期限の重複禁止。

### イテレーション 6:`/minutes-review`(`05-project-assets.md` §3)

- [x] `.claude/commands/minutes-review.md` を作成(引数 `{project} {date}`、`minutes.md` + 中間生成物2つ + 元インプットを突き合わせ、漏れ・矛盾・要フォローを指摘)

**品質ゲート**:イテレーション5の実成果物に対して実行し、指摘が3観点(漏れ / 矛盾 / 要確認)に整理され、根拠として中間生成物を参照していることを人間が確認。

**実績**:`allowed-tools` を `Read` / `Glob` / `Grep` に限定し、「指摘のみ・自動修正なし」をツール権限で担保(設計は `05-project-assets.md` §3 に反映)。`sample 2026-08-17` の実成果物に対して実行し、漏れ3件(在庫締め処理の性能目標 6時間→1時間・並列化で2時間の見込み、UTやり直しの必要性、テストデータ作成のToDo未記載)と変質1件(週次報告の「依頼」がステップ2で `結論:` に格上げされ、議事録で決定事項として断定された)を、いずれも**落ちた段の特定つき**で検出。

- 実装時の修正:位置引数 `$1` / `$2` は呼び出し経路によって番号がずれる(`$1` に日付が入る事象を実測)ため、`$ARGUMENTS` を正として解釈する形に変更した。この実測結果も `05-project-assets.md` §3 に記録。
- レビューで判明した**プロンプト側の改善候補**(要件・目標値を議事録に残す手段、依頼を決定に格上げしない制御)はイテレーション7で扱う。

### イテレーション 7:仕上げ

- [x] README を更新(セットアップ、初回SSO、`active.env` の作り方、モデルID指定、実行例、Codespaces の注意)
- [x] 全体の Format / Lint / Test を通し、`pytest --cov` で 80%以上を最終確認。Bash 側は `07-testing.md` §4 の網羅チェックリストで確認
- [x] `/save-design` を実行して設計書と実装の差分を同期
- [x] `docs/memo/` の記録(依存変更・`relogin.sh` 削除)の漏れを確認
- [x] イテレーション6の `/minutes-review` で検出した欠落・変質をプロンプト・`config.yaml` 側で解消し、実機で再検証

**品質ゲート**:要件8.4 の完了条件(デグレなし / Format・Lint・Test 成功 / カバレッジ80%以上)。

**実績**:2026-08-17 実施(このイテレーションで計画分は完了。以降の追加対応は §2.1 に記録する)。

- **プロンプト改善(イテレーション6の指摘への対処)**:`minutes_sections[]` に `検討事項(要件・目標値・見積)` を追加し、`02_structure.md` に「`結論:` は合意・決定・確定した変更のみ(`(依頼)` は受諾が無ければ `持ち越し:`)」、`03_format.md` に「決定事項に担当が示された作業も ToDo に1行立てる」「検討中の要件・目標値・見積は数値のまま該当セクションへ残す」を追加(スクリプトは変更せず)。`--from-step 2` で実機再実行(所要 4分41秒)し、3件の漏れ・1件の変質がすべて解消されたことを確認(設計は `05-project-assets.md` §2.2 に反映)。
- **README**:全体の流れ(データフロー図・ローカル文字起こし・部分再実行・Git 管理外)、事前準備(依存導入・認証・`cp -r projects/_template`)、実行手順・主要オプション表・終了コード・`/minutes-review` の使い方を追記し、古い進捗記述を削除。
- **品質ゲート**:`black --check` / `ruff` クリーン、pytest 42件グリーン、`scripts/transcribe.py` カバレッジ 99%(目標80%以上)、`shfmt -d` 差分なし、`shellcheck` クリーン、bats 95件グリーン。`07-testing.md` §4 の表で `generate_minutes.sh` の全28関数が少なくとも1ケースで実行されることを再確認。`git check-ignore` で `inputs/` / `outputs/` / `config/auth/active.env` が無視対象であることを再確認。
- **ゲートで検出した回帰と修正**:`harness.bats` の隔離検証が「実リポジトリに `inputs/` / `outputs/` が存在しないこと」を条件にしていたため、イテレーション5の実機E2Eで実リポジトリに `inputs/sample` ができた時点で失敗するようになっていた。テスト用プロジェクト名(`testproj`)のディレクトリが実リポジトリ側に作られないことを条件に変更(意図は同じで誤検知のみ排除。`07-testing.md` §2 に記載)。
- **`/save-design` の同期**:`07-testing.md`(`harness.bats` の追加・隔離検証の条件)、`design.md` §2.1・§3(`--bare` / `--tools ""` の明示、`projects/sample/`・`harness.bats`・`step2_output.md` をファイル構成へ追加)、`05-project-assets.md` §1・§2.2・§3(`projects/sample/` の位置づけ、`/minutes-review` 由来の調整、`$ARGUMENTS` と `allowed-tools`)、`04-auth.md` §2.1(任意の `ANTHROPIC_SMALL_FAST_MODEL`)を更新。
- **`docs/memo/`**:記録が必要な変更(依存追加 / `relogin.sh` 削除 / `.env` の追跡解除)はいずれも既存3ファイルに記録済みで、イテレーション1以降に新規の依存変更・処理削除・コメントアウトは無いことを `git log --diff-filter=D` 等で確認。

## 2.1 計画完了後の追加対応

### レビュー結果のファイル出力(2026-08-17・利用者提案)

- [x] 要件定義書へ反映(3.3 に指摘結果の保存を追記、4章の `outputs/` 構成に `review_{NN}.md` を追加。記録は `09-decisions.md` §3 の #7)
- [x] 設計を先に更新(`05-project-assets.md` §3.1:保存先・連番・`allowed-tools` に `Write` を追加する判断、`design.md` §2.1・§3)
- [x] `.claude/commands/minutes-review.md` に手順5(連番決定 → ヘッダ付きで保存 → 保存先の通知 → 失敗時も画面出力は完了させる)を追加
- [x] README の「生成後のレビュー」にファイル出力の説明を追記
- [x] 実機確認:`sample 2026-08-17` に対して実行し、`outputs/sample/2026-08-17/review_01.md`(連番 `01`)が作られ、`git status` に現れないことを確認

**判断の要点**:`Write` を許可しても `Edit` / `Bash` は与えないため、既存の議事録を書き換える経路は閉じたまま(「指摘のみ」の担保をツール権限側に残す)。実測でレビュー結果ファイルのパーミッションが umask 依存になる点は `05-project-assets.md` §3.1 に注記した。

---

## 3. 検証(全体)

| 種別 | コマンド・手順 |
|---|---|
| Python Format / Lint / Test | `black scripts tests/python` / `ruff check scripts tests/python` / `pytest tests/python --cov=scripts --cov-report=term-missing` |
| Bash Format / Lint / Test | `shfmt -i 2 -w scripts tests` / `shellcheck scripts/*.sh tests/stubs/claude tests/stubs/aws tests/bats/helper.bash` / `bats tests/bats` |
| セキュリティ | `git check-ignore -v` で機密パスが無視対象であること、`git status --porcelain` に機密パスが出ないこと |
| 文字起こし実機 | `ffmpeg` で生成した短い音声を `transcribe.py --model-size tiny` で処理し、出力形式を確認 |
| パイプライン実機 | `./scripts/generate_minutes.sh sample {date}`(Bedrock)→ 出力ファイル生成、`--from-step 2` / `--only-step 2` / `--dry-run` の挙動確認 |
| `CLAUDE.md` 非混入 | 生成物へのリポジトリ固有語の非出現 + プローブ入力による確認。結果を `09-decisions.md` §1 へ追記 |

---

## 4. 注意事項

- 機密データ(会議内容・認証情報)は一切コミットしない。実機E2Eのダミー入力も `inputs/` 配下に置き、Git 管理外であることを都度確認する(要件6.2)。
- 音声・動画の生データを外部へ送るコードは書かない。Claude に渡すのはテキスト化後のデータのみ(要件3.1、6.1)。
- 本書を `docs/` に追加したため、`docs/requirements.md` 4章のディレクトリ構造への追記が必要かを確認する(未反映であれば利用者へ提案する)。
