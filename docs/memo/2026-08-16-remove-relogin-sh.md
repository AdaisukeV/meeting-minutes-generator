# 旧 `scripts/relogin.sh` の削除

- **日付**:2026-08-16
- **分類**:処理削除(ファイル削除)
- **対象**:`scripts/relogin.sh`(33行)

## 内容

`scripts/aws_sso_login.sh`([04-auth.md §1](../design/04-auth.md))の実装に伴い、旧 `scripts/relogin.sh` を削除した([../design.md §3.1](../design.md) の移行方針)。

旧スクリプトの処理と、新スクリプトでの引き継ぎ先は以下のとおり。

| 旧 `relogin.sh` の処理 | 新 `aws_sso_login.sh` での扱い |
|---|---|
| リポジトリ直下 `.env` の読み込み(`set -a; source; set +a`) | `load_auth_env` が `config/auth/active.env` を同じ方式で読む(読み込み先のみ変更) |
| `AWS_PROFILE_NAME` 未設定時のエラー終了 | `resolve_profile` が `AWS_PROFILE`(AWS 標準の変数名)で判定し、コード2 + `aws configure sso` の HINT を出す |
| `export AWS_PROFILE="$PROFILE"` | 不要(`AWS_PROFILE` を直接読むため変数名の変換をしない) |
| 無条件の `aws sso login` | `is_session_valid`(`aws sts get-caller-identity`)が成功した場合はログインをスキップ(要件3.4.1。毎回ブラウザ確認が発生するのを防ぐ) |
| `aws sts get-caller-identity` の結果を stdout に表示 | **表示しない**(ARN・アカウントIDを標準出力に出さない。要件6.3)。成否のみを終了コードで扱う |

## 理由

- 要件3.4.1(セッションが有効な場合は再ログインしない)を満たすには、`relogin.sh` の「無条件ログイン」という前提そのものを変える必要があり、改修ではなく置き換えが妥当だった。
- 変数名が `AWS_PROFILE_NAME` という独自名だったため、AWS 標準の `AWS_PROFILE` に統一した([04-auth.md §2.1](../design/04-auth.md))。認証値の置き場も `config/auth/active.env` に集約する方針([../design.md §3.1](../design.md))と合わせた。
- caller identity の stdout 出力は、ログ・画面共有経由でアカウントIDが露出する経路になるため引き継がなかった(要件6.3)。

## 影響・代替

- **旧コマンドは動かなくなる**。`./scripts/relogin.sh` を使っていた場合は `./scripts/aws_sso_login.sh` に読み替える。移行手順(`.env` の `AWS_PROFILE_NAME` → `config/auth/active.env` の `AWS_PROFILE`)は [README](../../README.md) に記載した。
- ログイン後に ARN を確認したい場合は `aws sts get-caller-identity --profile "$AWS_PROFILE"` を手動で実行する(スクリプトからは意図的に外している)。
- 復元が必要な場合は削除前のコミット(`749ce77` 時点)から `git show 749ce77:scripts/relogin.sh` で取り出せる。
- 新スクリプトの挙動は `tests/bats/aws_sso_login.bats`(設計書 [07-testing.md §4](../design/07-testing.md) のケース1〜6)で担保している。
