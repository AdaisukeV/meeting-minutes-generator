#!/usr/bin/env bash
# bats 共通ヘルパ(docs/design/07-testing.md §2)。
# BATS_TEST_TMPDIR 配下に擬似リポジトリを構築し、PATH 先頭にスタブを挿入する。
# 実リポジトリの inputs/ outputs/ を汚さないこと(要件6.2)。

# 実リポジトリのルート(tests/bats/ から2階層上)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PROJECT_ROOT

# テストで共通に使うプロジェクト名・日付
export TEST_PROJECT="testproj"
export TEST_DATE="2026-08-16"

# 擬似リポジトリを作り、テスト用の環境変数を設定する。
setup_repo() {
  REPO="$BATS_TEST_TMPDIR/repo"
  export REPO
  export FIXTURES="$PROJECT_ROOT/tests/fixtures"
  export STUBS="$PROJECT_ROOT/tests/stubs"

  mkdir -p \
    "$REPO/scripts" \
    "$REPO/config/auth" \
    "$REPO/projects/$TEST_PROJECT/prompts" \
    "$REPO/inputs/$TEST_PROJECT/$TEST_DATE" \
    "$REPO/outputs"

  # $SCRIPT_DIR 経由で呼ばれるものは擬似リポジトリの scripts/ に配置する
  local f
  for f in generate_minutes.sh aws_sso_login.sh; do
    if [[ -f "$PROJECT_ROOT/scripts/$f" ]]; then
      cp "$PROJECT_ROOT/scripts/$f" "$REPO/scripts/$f"
      chmod +x "$REPO/scripts/$f"
    fi
  done
  cp "$STUBS/transcribe.py" "$REPO/scripts/transcribe.py"

  # プロジェクト資産(config.yaml + プロンプト3種)
  cp "$FIXTURES/config.yaml" "$REPO/projects/$TEST_PROJECT/config.yaml"
  for f in 01_organize 02_structure 03_format; do
    echo "# テスト用システムプロンプト ($f)" >"$REPO/projects/$TEST_PROJECT/prompts/$f.md"
  done

  # 既定の入力は memo.md のみ(メディアなし)
  cp "$FIXTURES/memo.md" "$REPO/inputs/$TEST_PROJECT/$TEST_DATE/memo.md"

  # 実行対象スクリプトのパス
  export GENERATE="$REPO/scripts/generate_minutes.sh"
  export SSO_LOGIN="$REPO/scripts/aws_sso_login.sh"

  # 記録ファイル(スタブが追記する)
  export STUB_ARGS_FILE="$BATS_TEST_TMPDIR/stub_args.txt"
  export STUB_STDIN_FILE="$BATS_TEST_TMPDIR/stub_stdin.txt"
  export STUB_CWD_FILE="$BATS_TEST_TMPDIR/stub_cwd.txt"
  export STUB_STATE_DIR="$BATS_TEST_TMPDIR"
  : >"$STUB_ARGS_FILE"
  : >"$STUB_STDIN_FILE"
  : >"$STUB_CWD_FILE"

  # スタブを PATH 経由で拾わせる(claude / aws)
  export PATH="$STUBS:$PATH"

  # 認証・モデル関連の既定値(ケース10・31の前提)
  export ANTHROPIC_MODEL="test.model.id-v1:0"
  export AWS_PROFILE="stub-profile"
  unset ANTHROPIC_MODEL_STEP1
  unset ANTHROPIC_MODEL_STEP2
  unset ANTHROPIC_MODEL_STEP3
  unset CLAUDE_CODE_USE_BEDROCK
  unset STUB_EXIT
  unset STUB_STDOUT_FILE
  unset STUB_SLEEP_SECONDS
  unset STUB_CALL_DIR
  unset STUB_FAIL_ON_STDIN_MATCH
  unset SPLIT_OVERLAP_LINES

  # 経過表示は既定で無効(出力を安定させる。ケース41で明示的に有効化する)
  export HEARTBEAT_INTERVAL_SECONDS=0
  unset STUB_AWS_STS_EXITS
  unset STUB_AWS_LOGIN_EXIT
}

# --- 入力・出力を組み立てるヘルパ ---

input_dir() {
  echo "$REPO/inputs/$TEST_PROJECT/$TEST_DATE"
}

output_dir() {
  echo "$REPO/outputs/$TEST_PROJECT/$TEST_DATE"
}

# 既存の文字起こしを配置する
given_transcript() {
  mkdir -p "$(output_dir)"
  cp "$FIXTURES/transcript.txt" "$(output_dir)/00_transcript.txt"
}

# パートキャッシュを配置する: given_transcript_part recording_1.mp4 MARKER
given_transcript_part() {
  mkdir -p "$(output_dir)/00_transcript_parts"
  cat >"$(output_dir)/00_transcript_parts/$1.txt" <<EOF
# transcript: $1
# model: cached / language: ja

[00:00:01] $2
EOF
}

# 行番号入りの文字起こしを配置する: given_numbered_transcript 20
# 分割の行範囲・オーバーラップを1行単位で検証するために内容を一意にする。
given_numbered_transcript() {
  local total="$1" i
  mkdir -p "$(output_dir)"
  : >"$(output_dir)/00_transcript.txt"
  for ((i = 1; i <= total; i++)); do
    printf 'TLINE_%03d 発言%d\n' "$i" "$i" >>"$(output_dir)/00_transcript.txt"
  done
}

# 行番号入りのステップ1出力を配置する: given_numbered_step1_output 20
given_numbered_step1_output() {
  local total="$1" i
  mkdir -p "$(output_dir)"
  : >"$(output_dir)/01_speakers_utterances.md"
  for ((i = 1; i <= total; i++)); do
    printf -- '- **話者%d**: SLINE_%03d\n' "$i" "$i" >>"$(output_dir)/01_speakers_utterances.md"
  done
}

# 前段の中間生成物を配置する: given_step_output 1|2
given_step_output() {
  mkdir -p "$(output_dir)"
  case "$1" in
  1) cp "$FIXTURES/step1_output.md" "$(output_dir)/01_speakers_utterances.md" ;;
  2) cp "$FIXTURES/step2_output.md" "$(output_dir)/02_structured_conversation.md" ;;
  *)
    echo "given_step_output: 不正なステップ: $1" >&2
    return 1
    ;;
  esac
}

# ダミーのメディアファイルを配置する: given_media recording.mp4
given_media() {
  echo "dummy media" >"$(input_dir)/$1"
}

# 任意の名前・拡張子の議事メモを配置する: given_memo human_memo.txt MARKER
given_memo() {
  printf '# %s\n\n- %s\n' "$1" "$2" >"$(input_dir)/$1"
}

# memo.md を取り除く
remove_memo() {
  rm -f "$(input_dir)/memo.md"
}

# active.env を作る: given_active_env "KEY=VALUE" ...
given_active_env() {
  local line
  : >"$REPO/config/auth/active.env"
  for line in "$@"; do
    echo "$line" >>"$REPO/config/auth/active.env"
  done
}

# --- 検証用ヘルパ ---

# スタブの呼び出し回数を数える: stub_call_count claude
stub_call_count() {
  grep -c -- "--- $1 ---" "$STUB_ARGS_FILE" || true
}

# STUB_ARGS_FILE に指定の行が含まれるか
stub_args_contains() {
  grep -qxF -- "$1" "$STUB_ARGS_FILE"
}

# STUB_ARGS_FILE に指定の行が現れた回数: stub_args_count <行>
stub_args_count() {
  grep -c -xF -- "$1" "$STUB_ARGS_FILE" || true
}

# --- 並列実行(--parallel N)用の検証ヘルパ(docs/design/07-testing.md §3)---
# 追記方式は並列では行が混ざるため、呼び出しごとの専用ファイルを使う。

# 呼び出しごとの記録を有効にする(setup_repo の後に呼ぶ)
use_call_dir() {
  export STUB_CALL_DIR="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$STUB_CALL_DIR"
}

# 記録された呼び出し回数(完了順に依存しない)
call_count() {
  local -a files=("$STUB_CALL_DIR"/*.stdin)
  [[ -e "${files[0]}" ]] || return 0
  echo "${#files[@]}"
}

# stdin に指定文字列を含む呼び出しの .stdin パスを出力する: find_call "part: 1/2"
find_call() {
  grep -lF -- "$1" "$STUB_CALL_DIR"/*.stdin 2>/dev/null || true
}

# stdin に指定文字列を含む呼び出しの数: call_count_matching "part: 1/2"
call_count_matching() {
  find_call "$1" | grep -c . || true
}
