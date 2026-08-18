# セキュリティ設計

> 親ドキュメント:[../design.md](../design.md)(設計書ハブ)
> 対応要件:`docs/requirements.md` 6章 / `CLAUDE.md` 1章
> 関連:`claude` 呼び出しの防御は [02-generate-minutes.md §5](./02-generate-minutes.md)、実機検証結果は [09-decisions.md §1](./09-decisions.md)

---

## 1. `.gitignore` の確定内容(要件6.2)

```gitignore
# 機密データ(会議内容)
inputs/
outputs/

# プロジェクト固有設定(実在の顧客名・個人名を含みうる)。雛形と動作確認用の sample のみ追跡する
projects/*
!projects/_template/
!projects/sample/

# 認証情報
config/auth/active.env
.env
.env.*
!*.env.example

# Python
__pycache__/
*.py[cod]
.venv/
.pytest_cache/
.coverage
htmlcov/

# OS / エディタ
.DS_Store
```

- `inputs/` / `outputs/` はディレクトリごと除外する(配下のファイル名自体が機密を示唆しうるため)。
- `projects/*` もディレクトリごと除外し、`!projects/_template/` / `!projects/sample/` で雛形と動作確認用ダミー([05-project-assets.md §1](./05-project-assets.md))のみを復帰させる。実プロジェクトの `config.yaml` は話者の名寄せのために**実在の顧客名・個人名を書く前提**であり(要件3.2.4)、ディレクトリ名自体も案件名を示唆する。個別のプロジェクト名を列挙する方式は新規プロジェクト追加時の追記漏れがそのまま機密の混入になるため、**除外を既定とし雛形側を例外にする**方向で構成する。`.gitignore` を変更した際は `git check-ignore -v projects/_template/config.yaml` が**マッチしない**(=追跡対象のまま)ことを確認する。
- リポジトリ直下の `.env` / `.env.*` も除外対象に残す(認証情報の置き場として使われうるため)。
- `!*.env.example` は `config/auth/*.env.example`(`bedrock.env.example` 等)を除外対象から復帰させるための否定パターン。`.gitignore` を変更した際は `git check-ignore -v config/auth/bedrock.env.example` が否定パターンにマッチすることを確認する。
- 新規ファイル作成時は、そのパスが `.gitignore` に含まれるかを都度確認する(`CLAUDE.md` 1章)。

## 2. 外部送信経路が存在しないことの根拠

| リスク | 対策 |
|---|---|
| 音声・動画の生データ送信 | 文字起こしは `faster-whisper` によるローカル処理のみ。Claude に渡すのはテキスト化後のデータだけ(要件6.1) |
| Claude 経由のファイル読み出し・Web アクセス | `--tools ""` で全ツールを無効化。入力は stdin、出力は stdout のみ([02-generate-minutes.md §5](./02-generate-minutes.md)) |
| 開発時ルール・リポジトリ情報の混入送信 | `--bare` + 空ディレクトリ実行で `CLAUDE.md` およびプロジェクト設定の自動読み込みを無効化([09-decisions.md §1](./09-decisions.md)) |
| Web 検索・外部 API の追加 | 実装しない(`CLAUDE.md` 1章)。依存追加時は [01-conventions.md §7](./01-conventions.md) の方針に従いレビューする |
| 認証情報のハードコード | 認証値は `active.env` または環境変数からのみ取得。テンプレートに実値を書かない([04-auth.md §2.1](./04-auth.md)) |

## 3. ログ・メッセージに機密を出さない

- 進捗・エラーメッセージに会議内容の本文を含めない。ファイルパスは**リポジトリ相対パス**で表示する。
- `aws sts get-caller-identity` の出力は標準出力に流さない(`>/dev/null`、[04-auth.md §1.2](./04-auth.md))。
- `set -x` を本番実行パスに残さない(stdin にメモ本文が入るため)。デバッグ時のみ環境変数で明示的に有効化する。
