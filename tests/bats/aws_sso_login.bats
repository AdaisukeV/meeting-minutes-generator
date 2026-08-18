#!/usr/bin/env bats
# scripts/aws_sso_login.sh のテスト(docs/design/07-testing.md §4 の aws_sso_login.sh 表)。
# 番号はテストケース一覧の # に対応する。

load helper

setup() {
  setup_repo
}

# --- ケース1: セッションが有効なら再ログインしない ---

@test "1: sts get-caller-identity 成功時は aws sso login を呼ばず終了コード0" {
  export STUB_AWS_STS_EXITS="0"

  run "$SSO_LOGIN"

  [ "$status" -eq 0 ]
  [[ "$output" == *"既存のSSOセッションを使用します"* ]]
  [[ "$output" == *"stub-profile"* ]]
  ! stub_args_contains "login"
}

# --- ケース2: セッションが無効ならログインする ---

@test "2: sts が失敗したら aws sso login --profile <p> が呼ばれる" {
  export STUB_AWS_STS_EXITS="1 0"

  run "$SSO_LOGIN"

  [ "$status" -eq 0 ]
  stub_args_contains "sso"
  stub_args_contains "login"
  stub_args_contains "--profile"
  stub_args_contains "stub-profile"
}

# --- ケース3: ログイン後もセッションが無効 ---

@test "3: ログイン後も sts が失敗したら終了コード2" {
  export STUB_AWS_STS_EXITS="1"

  run "$SSO_LOGIN"

  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR:"* ]]
  [[ "$output" == *"HINT:"* ]]
}

@test "3b: aws sso login 自体が失敗したら終了コード2" {
  export STUB_AWS_STS_EXITS="1"
  export STUB_AWS_LOGIN_EXIT="1"

  run "$SSO_LOGIN"

  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR:"* ]]
}

# --- ケース4: AWS_PROFILE 未設定 ---

@test "4: AWS_PROFILE 未設定なら ERROR + aws configure sso の HINT、終了コード2" {
  unset AWS_PROFILE

  run "$SSO_LOGIN"

  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR:"* ]]
  [[ "$output" == *"aws configure sso"* ]]
  [ "$(stub_call_count aws)" -eq 0 ]
}

# --- ケース5: active.env からプロファイルを読み込む ---

@test "5: active.env の AWS_PROFILE が --profile に渡る(既存環境変数を上書き)" {
  export AWS_PROFILE="env-profile"
  given_active_env "AWS_PROFILE=file-profile"
  export STUB_AWS_STS_EXITS="1 0"

  run "$SSO_LOGIN"

  [ "$status" -eq 0 ]
  stub_args_contains "file-profile"
  ! stub_args_contains "env-profile"
}

@test "5b: active.env が無ければ既存の環境変数を使う(要件7.2のフォールバック)" {
  [ ! -f "$REPO/config/auth/active.env" ]
  export AWS_PROFILE="env-only-profile"
  export STUB_AWS_STS_EXITS="0"

  run "$SSO_LOGIN"

  [ "$status" -eq 0 ]
  stub_args_contains "env-only-profile"
}

# --- ケース6: 標準出力に caller identity を出さない ---

@test "6: stdout に ARN が現れない" {
  export STUB_AWS_STS_EXITS="0"
  export STUB_AWS_STS_ARN="arn:aws:sts::999999999999:assumed-role/SecretRole/secret-session"

  run "$SSO_LOGIN"

  [ "$status" -eq 0 ]
  [[ "$output" != *"arn:aws:sts"* ]]
  [[ "$output" != *"SecretRole"* ]]
}

# --- 関数単体(source して呼ぶ) ---

@test "関数: is_session_valid は aws の成否をそのまま返し stdout を汚さない" {
  # shellcheck source=/dev/null
  source "$SSO_LOGIN"

  export STUB_AWS_STS_EXITS="0"
  run is_session_valid
  [ "$status" -eq 0 ]
  [ "$output" = "" ]

  export STUB_AWS_STS_EXITS="1"
  run is_session_valid
  [ "$status" -eq 1 ]
  [ "$output" = "" ]
}

@test "関数: source しても main が自動実行されない" {
  # shellcheck source=/dev/null
  source "$SSO_LOGIN"

  [ "$(stub_call_count aws)" -eq 0 ]
}
