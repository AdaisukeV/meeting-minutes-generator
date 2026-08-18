# 認証設計(`scripts/aws_sso_login.sh` / 認証経路の抽象化)

> 親ドキュメント:[../design.md](../design.md)(設計書ハブ)
> 対応要件:`docs/requirements.md` 3.4, 3.4.1, 6.5, 6.6, 7.2
> 前提:[01-conventions.md](./01-conventions.md)(終了コード体系)/ 呼び出し元は [02-generate-minutes.md §2](./02-generate-minutes.md) の `maybe_sso_login`

---

## 1. `scripts/aws_sso_login.sh` 詳細設計(要件3.4.1)

### 1.1 CLI 仕様

```
usage: aws_sso_login.sh
```
引数なし。`config/auth/active.env`(または既存環境変数)から `AWS_PROFILE` を読む。

### 1.2 関数

| 関数 | 責務 | 終了コード |
|---|---|---|
| `load_auth_env` | `active.env` があれば読み込み、無ければ既存環境変数を使用(要件7.2のフォールバック) | 0 |
| `resolve_profile` | `AWS_PROFILE` を取得。未設定なら die(2)し `HINT: aws configure sso --profile <name>` を出す | 0 / 2 |
| `is_session_valid` | `aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null 2>&1` の成否を返す(標準出力に ARN 等を出さない) | 0 / 1 |
| `do_login` | `aws sso login --profile "$AWS_PROFILE"` を実行し、その後 `is_session_valid` で再確認 | 0 / 2 |
| `main` | `load_auth_env → resolve_profile → is_session_valid ? skip : do_login` | 0 / 2 |

- **セッションが有効な場合は再ログインしない**(毎回ブラウザ確認が発生するのを防ぐ。要件3.4.1)。進捗は `既存のSSOセッションを使用します (profile: xxx)` の1行のみ。
- ヘッドレス(Codespaces)では `aws sso login` が認証用URLとコードをターミナルに表示する。初回はローカルPCのブラウザで開く必要がある旨を README に記載(要件7.2)。
- 呼び出し元(`generate_minutes.sh` の `maybe_sso_login`)は `CLAUDE_CODE_USE_BEDROCK=1` のときのみ本スクリプトを実行する。**他の認証経路では自然にスキップされ、スクリプト側に経路別分岐を持たない**(要件3.4)。

---

## 2. 認証経路の設計(要件3.4, 6.5, 6.6, 7.2)

### 2.1 `config/auth/*.env.example`

**`bedrock.env.example`**

| 変数 | 必須 | 例 | 機密 |
|---|---|---|---|
| `CLAUDE_CODE_USE_BEDROCK` | ✓ | `1` | – |
| `AWS_PROFILE` | ✓ | `my-sso-profile` | – |
| `AWS_REGION` | ✓ | `ap-northeast-1` | – |
| `ANTHROPIC_MODEL` | ✓ | `<推論プロファイルID / モデルIDを明示的に固定>` | – |
| `ANTHROPIC_SMALL_FAST_MODEL` | – | `<小型モデルの推論プロファイルID>` | – |

`ANTHROPIC_SMALL_FAST_MODEL` は任意。`claude` CLI が補助処理で小型モデルを引く場合、既定のモデルIDが当該アカウントで有効化されていないと失敗しうるため、Bedrock 経由では有効なIDを明示できるようにしておく(スクリプト側はこの変数を参照しない。`claude` CLI が環境変数から解決する)。

**`anthropic-api.env.example`**

| 変数 | 必須 | 例 | 機密 |
|---|---|---|---|
| `ANTHROPIC_API_KEY` | ✓ | `sk-ant-…` | **★機密** |
| `ANTHROPIC_MODEL` | ✓ | `claude-opus-5` | – |

**`vertex.env.example`**

| 変数 | 必須 | 例 | 機密 |
|---|---|---|---|
| `CLAUDE_CODE_USE_VERTEX` | ✓ | `1` | – |
| `CLOUD_ML_REGION` | ✓ | `asia-northeast1` | – |
| `ANTHROPIC_VERTEX_PROJECT_ID` | ✓ | `my-gcp-project` | – |
| `ANTHROPIC_MODEL` | ✓ | (固定モデルID) | – |

- どのテンプレートにも**静的なAWSアクセスキーを置かない**(要件6.5)。Bedrock は SSO セッション経由のみ。
- `ANTHROPIC_MODEL` はすべての経路で必須。未設定時は `require_model` が die(1)する。
- **`ANTHROPIC_MODEL_STEP1` / `_STEP2` / `_STEP3`(任意)** は3つのテンプレートすべてに**コメントアウトした記述例**として置く。設定されたステップだけがそのモデルIDを使い、未設定のステップは `ANTHROPIC_MODEL` にフォールバックする([02-generate-minutes.md §5.1](./02-generate-minutes.md))。経路ごとに書式が違う(推論プロファイルID / モデルID)ためテンプレート側に例を置くが、**`ANTHROPIC_MODEL` を不要にはしない**(フォールバック元として必須のまま。`require_model` は変更しない)。

### 2.2 読み込み優先順位(要件7.2)

1. `config/auth/active.env` が存在する場合:`set -a; source; set +a` で読み込む(**ファイルの値が既存環境変数を上書きする**)。
2. 存在しない場合:既存の環境変数(Codespaces Secrets 由来など)をそのまま使用する。

この「あれば読む、無ければ環境変数」というフォールバックを崩さない(`CLAUDE.md` 4章)。機密値(APIキー等)は Codespaces では Secrets 経由とし、`active.env` にはプロファイル名・リージョン等の非機密値のみを書く運用を基本とする(要件6.6)。

### 2.3 認証経路の分岐を持たない設計

スクリプトが参照する認証関連の値は `ANTHROPIC_MODEL`(および任意の `ANTHROPIC_MODEL_STEP{1,2,3}`)と `CLAUDE_CODE_USE_BEDROCK` のみ。前者はモデル固定のため、後者は SSO ログインの要否判定のためであり、それ以外の経路差分(APIキー / Vertex)は `claude` CLI が環境変数から解決する。**新しい認証経路を追加する場合も `*.env.example` の追加のみで対応する**(要件3.4)。
