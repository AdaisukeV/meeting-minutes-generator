#!/usr/bin/env bash
# AWS SSO セッションを確保する(Bedrock 利用時のみ呼ばれる)。
#
# 設計書:docs/design/04-auth.md §1
# 終了コード:0=正常 / 2=認証エラー(docs/design/01-conventions.md §4)
#
# セッションが有効な場合は再ログインしない(毎回ブラウザ確認が発生するのを防ぐ・要件3.4.1)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AUTH_ENV="$REPO_ROOT/config/auth/active.env"

# die <code> <ERROR文> [HINT文]
die() {
  local code="$1" message="$2" hint="${3:-}"
  echo "ERROR: $message" >&2
  if [[ -n "$hint" ]]; then
    echo "HINT:  $hint" >&2
  fi
  exit "$code"
}

# active.env があれば読み込む。無ければ既存の環境変数をそのまま使う(要件7.2)。
load_auth_env() {
  if [[ -f "$AUTH_ENV" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$AUTH_ENV"
    set +a
  fi
}

resolve_profile() {
  if [[ -z "${AWS_PROFILE:-}" ]]; then
    die 2 "AWS_PROFILE が設定されていません。" \
      "config/auth/active.env に AWS_PROFILE=<プロファイル名> を設定してください(未作成の場合は aws configure sso で作成します)。"
  fi
}

# セッションが有効かどうかを終了コードで返す。ARN 等を stdout に出さない(要件6.3)。
is_session_valid() {
  aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null 2>&1
}

do_login() {
  echo "SSO セッションが無効です。ログインします (profile: $AWS_PROFILE)"
  if ! aws sso login --profile "$AWS_PROFILE"; then
    die 2 "AWS SSO ログインに失敗しました (profile: $AWS_PROFILE)" \
      "表示された認証用URLをブラウザで開き、コードを入力してください。プロファイル設定は aws configure sso で確認できます。"
  fi
  if ! is_session_valid; then
    die 2 "ログイン後もSSOセッションが有効になりませんでした (profile: $AWS_PROFILE)" \
      "aws sso login --profile $AWS_PROFILE を手動で実行し、認証が完了するか確認してください。"
  fi
  echo "SSO ログインが完了しました (profile: $AWS_PROFILE)"
}

main() {
  load_auth_env
  resolve_profile
  if is_session_valid; then
    echo "既存のSSOセッションを使用します (profile: $AWS_PROFILE)"
  else
    do_login
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
