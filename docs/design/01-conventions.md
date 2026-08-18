# 共通規約・エラーハンドリング

> 親ドキュメント:[../design.md](../design.md)(設計書ハブ)
> 対応要件:`docs/requirements.md` 6章、8.1 / `CLAUDE.md` 3章
> **全スクリプトの実装時に最初に読む分冊。** 終了コードとメッセージ様式は他分冊すべての前提となる。

---

## 1. パス解決とリポジトリルート

すべてのスクリプトは自身の位置からリポジトリルートを解決し、カレントディレクトリに依存しない。

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
```

パス生成規則:

| 名称 | パス |
|---|---|
| `INPUT_DIR` | `$REPO_ROOT/inputs/{project}/{date}` |
| `OUTPUT_DIR` | `$REPO_ROOT/outputs/{project}/{date}` |
| `PROJECT_DIR` | `$REPO_ROOT/projects/{project}` |
| `PROMPT_DIR` | `$PROJECT_DIR/prompts` |
| `AUTH_ENV` | `$REPO_ROOT/config/auth/active.env` |

## 2. 引数の妥当性検証

- `project`:`^[A-Za-z0-9._-]+$` に一致すること。`.` / `..` 単独および `/` を含む値は拒否(パストラバーサル防止)。
- `date`:`^[0-9]{4}-[0-9]{2}-[0-9]{2}$` に一致すること(カレンダー妥当性までは検証しない)。
- 不一致時は終了コード `1`。

## 3. 標準出力・標準エラーの使い分け

- **標準出力**:利用者向けの進捗(1行1メッセージ)。`claude` の生成物は**必ずファイルへリダイレクトし、標準出力に混ぜない**。
- **標準エラー**:警告(`WARN:`)・エラー(`ERROR:` / `HINT:`)。
- 会議内容(議事メモ・文字起こし・生成物の本文)を進捗メッセージやログに出力しない([06-security.md §3](./06-security.md))。

## 4. 終了コード体系(全スクリプト共通)

| コード | 意味 | 例 |
|---|---|---|
| `0` | 正常終了 | |
| `1` | 想定内のエラー(利用者の操作で解消可能) | 引数不正、入力ファイル未検出、プロンプト未検出、`ANTHROPIC_MODEL` 未設定 |
| `2` | 認証エラー | SSO セッション取得失敗、`AWS_PROFILE` 未設定、`claude` の認証失敗 |
| `3` | 外部コマンド失敗 | `claude` が非ゼロ終了 / 空出力 / **出力の先頭が契約と不一致**([02-generate-minutes.md §5.5](./02-generate-minutes.md))、`faster-whisper` 実行失敗、`ffmpeg` 不在 |
| `130` | 利用者による中断(`Ctrl+C` = SIGINT) | `claude` の実行中に `Ctrl+C` が押された |

**中断(130)をコード3として報告しないこと。** ステップ1・2は数分〜数十分かかるため `Ctrl+C` は日常的に起こる(要件3.2.8)。子プロセスの終了コード 130(SIGINT)/ 143(SIGTERM)を外部コマンド失敗と同一視すると、「認証状態と入力サイズを見直してください」という**的外れな HINT** を出してしまい、利用者が原因を誤認する。中断は `ERROR: 中断されました` として報告し、HINT を出さず、終了コード 130 をそのまま返す。

## 5. メッセージ様式(`CLAUDE.md` 3章:利用者が次に何をすべきか分かる文言)

```
ERROR: 入力ディレクトリが見つかりません: inputs/client-a/2026-08-16
HINT:  inputs/client-a/2026-08-16/ を作成し、議事メモ(.md / .txt)または録画ファイルを配置してください。
```

- `ERROR:` は事象、`HINT:` は次に取るべき操作。両方を標準エラーへ出力する。
- エラーを握りつぶさない(`set -euo pipefail` を全シェルスクリプトの先頭に置く)。
- **日本語メッセージ中で変数展開の直後に非ASCII文字が続く場合は必ずブレースで囲む**(`"$min〜$max"` ではなく `"${min}〜${max}"`)。UTF-8 ロケールでは `〜` などのバイトが変数名の一部と解釈され、`min〜: unbound variable` で**メッセージを出す前に落ちる**(Bash のバージョンではなくロケールに依存する。C ロケールでは再現しないため devcontainer では気付けない)。

## 6. ファイル書き込みの原子性

生成物は一時ファイルに書いてから `mv` で確定する。途中失敗時に壊れた成果物が残らないようにする。

```bash
tmp="$(mktemp "${out}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
... > "$tmp"
mv "$tmp" "$out"
```

## 7. エラーハンドリング方針

| 分類 | 検知箇所 | メッセージ | コード | 利用者の次アクション |
|---|---|---|---|---|
| 引数不正 | `parse_args` | ERROR + usage | 1 | 引数を修正して再実行 |
| プロジェクト未整備 | `validate_project` | 設定/プロンプト未検出 | 1 | `cp -r projects/_template projects/{p}` |
| 入力未検出 | `validate_inputs` | 入力ディレクトリ/ファイル未検出 | 1 | `inputs/{p}/{d}/` に配置 |
| 前段出力欠落 | `run_step` | 前段の中間生成物が無い | 1 | `--from-step` を前段から指定 |
| モデル未指定 | `require_model` | `ANTHROPIC_MODEL` 未設定 | 1 | `active.env` に固定モデルIDを設定 |
| 認証 | `aws_sso_login.sh` / `maybe_sso_login` | プロファイル未設定 / SSO 失敗 | 2 | `aws configure sso` / 再ログイン |
| 外部コマンド失敗 | `invoke_claude` | 非ゼロ終了 | 3 | エラー出力を確認、認証・モデルIDを確認 |
| 空出力 | `invoke_claude` | 生成結果が空 | 3 | 入力サイズ・プロンプトを確認して再実行 |
| 出力の先頭欠落 | `invoke_claude` | `出力の先頭が契約と一致しません` | 3 | 1回の呼び出しの出力量を減らして再実行([02-generate-minutes.md §5.5](./02-generate-minutes.md)) |
| 中断 | `invoke_claude` | `中断されました`(HINT なし) | 130 | 必要なら再実行。パート出力は再利用される([02-generate-minutes.md §9](./02-generate-minutes.md)) |
| 文字起こし失敗 | `ensure_transcript` / `transcribe.py` | モデルロード / ffmpeg 不在 | 3 | 依存の再導入(devcontainer は `postCreate.sh` の再実行、ローカルは README「ローカル環境のセットアップ」節。[08-dev-environment.md §4](./08-dev-environment.md)) |

- **`set +e` / `set -e` でグローバルな errexit を切り替えない。** 外部コマンドの終了コードを見たい場合は `status=0; cmd || status=$?` で受ける。関数の中で `set -e` に戻すと呼び出し元の `set +e` まで解除され、`return` した瞬間にシェルが終了して **`die` の `ERROR:` / `HINT:` が出ないまま落ちる**(実例:`invoke_claude` → `run_step`。[02-generate-minutes.md §5](./02-generate-minutes.md))。
- **握りつぶし禁止**:`|| true` は「セッション有効性チェック」「一時ファイル削除」など失敗が正常系である箇所のみに限定し、コメントで理由を書く。
- 例外的に警告で継続するケース:stale 出力の検出([02-generate-minutes.md §7](./02-generate-minutes.md))、議事メモが無く文字起こしのみのケース。

## 8. Bash の互換性方針(最低 3.2)

**パイプラインのシェルスクリプトは Bash 3.2 で動作すること。** macOS の `/bin/bash` は 3.2.57 であり(Apple はライセンス上 3.2 で固定している)、README は macOS ホストを正式サポート環境として案内している(要件7.2・[08-dev-environment.md §4](./08-dev-environment.md))。`bash` の追加インストールを前提にしない。

`bash -n` は**この種の非互換を検出できない**(`${var,,}` は実行時の `bad substitution`、`$()` 内の `case` はコマンド置換の実行時パース時にエラーになる)。静的検査はケース34、実行時検査はケース34b([07-testing.md §4](./07-testing.md))で担保する。

### 8.1 使用禁止(Bash 4.0+ 専用の構文)

| 禁止 | 代替 |
|---|---|
| `${var,,}` / `${var^^}`(大文字小文字変換) | `tr '[:upper:]' '[:lower:]'` |
| `mapfile` / `readarray` | `while IFS= read -r x; do arr+=("$x"); done < <(cmd)` |
| 連想配列 `declare -A` | 通常配列 + 逐次比較、または関数への分岐 |
| nameref `local -n` | 出力を stdout に書いて `$()` で受ける |
| `wait -n` / `;;&` / `shopt -s globstar` | 使わない(§8.4 の PID 集約方式で並列化する。再帰 glob は本アプリの要件に無い) |

### 8.2 Bash 3.2 固有の落とし穴

- **`$( ... )` の中に `case` を直接書かない。** 3.2 のコマンド置換はパターンの `)` を閉じ括弧と誤認して構文エラーになる。分岐は独立した関数へ切り出し、`$(関数名 引数)` の形で呼ぶ(実例:[02-generate-minutes.md §4](./02-generate-minutes.md) の `emit_step_sections`)。
- **`set -u` 下で空配列を素の `"${arr[@]}"` で展開しない**(3.2 では `unbound variable` になる)。`${arr+"${arr[@]}"}` の形で展開する。`"$@"`(引数0個)と `local -a arr=("$@")` は 3.2 でも安全。
- `printf '%02x' \'"$char"` は 3.2 では符号拡張された値を返す(マルチバイト文字で破綻する)。文字単位の16進変換に依存しない。

### 8.3 開発ツール側の例外(bats は Bash 4.0+ が必要)

**この規約が縛るのは `scripts/` 配下のスクリプトと `tests/` のヘルパ・スタブであり、テストランナー自身は対象外。** bats 1.14 は Bash 3.2 上では**日本語のテスト名を扱えない**(テスト関数名のエンコードが上記の `printf '%02x'` の挙動に依存しており、`bats: unknown test name` となって1件も実行されない)。macOS で `bats` を実行する場合は `brew install bash`(Bash 5)を追加で導入する。パイプライン本体の実行には不要([08-dev-environment.md §4.1](./08-dev-environment.md))。

### 8.4 並列実行の書き方(`wait -n` を使わない)

要件3.2.8 のチャンク並列実行は、**PID を配列に溜めて `wait "$pid"` を順に回し、終了コードを集約する**形で実装する。`wait -n`(最初に終わったジョブを待つ)は Bash 4.3+ 専用のため使えない(§8.1)。

```bash
# チャンク数 = 並列度なのでジョブプールは不要。全ジョブを起動して全て待つ。
pids=()
for part in ${parts+"${parts[@]}"}; do
  run_one_part "$part" &   # サブシェル
  pids+=("$!")
done

failed=0
for pid in ${pids+"${pids[@]}"}; do
  status=0
  wait "$pid" || status=$?      # set -e を触らない(§7)
  ((status == 0)) || failed="$status"
done
((failed == 0)) || die ...      # die は必ず親で行う
```

- **`die` をサブシェルの中で呼んではならない。** サブシェルの `exit` は親を終了させないため、`ERROR:` が出たまま処理が続行してしまう。失敗は終了コードとしてサブシェルの `exit` で親へ返し、判定と `die` は親で行う。
- **1つ失敗しても残りの `wait` を打ち切らない。** 途中で `die` すると残ったジョブが孤児になり、書き込み中の一時ファイルが残る。全ジョブの完了を待ってから確定処理を行うか `die` する(要件3.2.8)。
- **サブシェルはグローバル変数を親へ返せない。** 結果はファイル(パート出力)として受け渡す([02-generate-minutes.md §9.4](./02-generate-minutes.md))。逆に、親が起動時点で設定していたグローバル変数は fork 時の値としてサブシェルへ引き継がれる(読み取り専用の受け渡しには使える)。
- **中断(130)は失敗(3)より優先して集約する。** `Ctrl+C` はプロセスグループ全体に届くため複数のジョブが同時に 130 を返し、上のサンプルのように後勝ちで代入すると 130 が 3 に上書きされ得る。集約時は「既に 130 を記録していれば他のコードで上書きしない」判定を入れる(§4 の中断の扱い)。
- **`&` で起動したサブシェルは親の EXIT トラップを実行しない**(2026-08-18 実測)。したがってサブシェル内の一時ファイルは §6 の EXIT トラップに登録せず、サブシェル自身が `rm -f` する。裏を返せば、サブシェルの終了が親の登録した一時ファイルを消してしまう事故は起きない。
- 進捗表示はサブシェル側から stdout へ書いてよい(1行1メッセージなので混ざっても壊れない)。完了順は不定であることを前提にした文言にする。
