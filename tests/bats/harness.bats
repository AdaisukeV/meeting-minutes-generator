#!/usr/bin/env bats
# テストハーネス自体のスモークテスト(docs/design/07-testing.md §2, §3)。
# 擬似リポジトリの構築とスタブの PATH 注入が機能していることを確認する。

load helper

setup() {
  setup_repo
}

@test "harness: 擬似リポジトリが BATS_TEST_TMPDIR 配下に作られる" {
  [ -d "$REPO/inputs/$TEST_PROJECT/$TEST_DATE" ]
  [ -d "$REPO/outputs" ]
  [ -f "$REPO/projects/$TEST_PROJECT/config.yaml" ]
  [ -f "$REPO/projects/$TEST_PROJECT/prompts/01_organize.md" ]
  [ -f "$REPO/scripts/transcribe.py" ]
  [[ "$REPO" == "$BATS_TEST_TMPDIR"/* ]]
}

@test "harness: 実リポジトリにテスト用プロジェクトの入出力を作らない" {
  # 実リポジトリの inputs/ outputs/ は利用者の実行によって存在しうる(Git 管理外)。
  # ここで担保するのは「テスト用プロジェクトの資産を実リポジトリ側に作らない」こと。
  [ ! -e "$PROJECT_ROOT/inputs/$TEST_PROJECT" ]
  [ ! -e "$PROJECT_ROOT/outputs/$TEST_PROJECT" ]
  [ ! -e "$PROJECT_ROOT/projects/$TEST_PROJECT" ]
}

@test "harness: claude スタブが PATH 経由で拾われ、引数と stdin と cwd を記録する" {
  run bash -c 'cd / && echo "HELLO STDIN" | claude -p --bare --model "$ANTHROPIC_MODEL"'
  [ "$status" -eq 0 ]
  [ "$output" = "STUB CLAUDE OUTPUT" ]

  [ "$(stub_call_count claude)" -eq 1 ]
  stub_args_contains "-p"
  stub_args_contains "--bare"
  stub_args_contains "test.model.id-v1:0"

  grep -qF "HELLO STDIN" "$STUB_STDIN_FILE"
  grep -qxF "/" "$STUB_CWD_FILE"
}

@test "harness: claude スタブは STUB_STDOUT_FILE / STUB_EXIT に従う" {
  echo "GENERATED BODY" >"$BATS_TEST_TMPDIR/out.txt"
  STUB_STDOUT_FILE="$BATS_TEST_TMPDIR/out.txt" run bash -c 'echo x | claude -p'
  [ "$status" -eq 0 ]
  [ "$output" = "GENERATED BODY" ]

  STUB_EXIT=1 run bash -c 'echo x | claude -p'
  [ "$status" -eq 1 ]
}

@test "harness: aws スタブが sts / sso login をサブコマンド別に扱う" {
  run aws sts get-caller-identity --profile stub-profile
  [ "$status" -eq 0 ]
  [[ "$output" == arn:aws:sts::* ]]

  run aws sso login --profile stub-profile
  [ "$status" -eq 0 ]

  [ "$(stub_call_count aws)" -eq 2 ]
}

@test "harness: aws スタブは STUB_AWS_STS_EXITS を呼び出し順に消費する" {
  export STUB_AWS_STS_EXITS="1 0"

  run aws sts get-caller-identity --profile stub-profile
  [ "$status" -eq 1 ]

  run aws sts get-caller-identity --profile stub-profile
  [ "$status" -eq 0 ]

  # 値が尽きたら最後の値(0)を繰り返す
  run aws sts get-caller-identity --profile stub-profile
  [ "$status" -eq 0 ]
}

@test "harness: transcribe.py スタブが --output にダミー文字起こしを書く" {
  run python3 "$REPO/scripts/transcribe.py" \
    --input "$(input_dir)/recording.mp4" \
    --output "$(output_dir)/00_transcript.txt" \
    --model-size tiny
  [ "$status" -eq 0 ]

  [ -f "$(output_dir)/00_transcript.txt" ]
  grep -qF "STUB_TRANSCRIPT_LINE" "$(output_dir)/00_transcript.txt"

  [ "$(stub_call_count transcribe.py)" -eq 1 ]
  stub_args_contains "--model-size"
  stub_args_contains "tiny"
}

@test "harness: fixture 配置ヘルパが動作する" {
  given_transcript
  given_step_output 1
  given_step_output 2
  given_media recording.mp4
  given_active_env "ANTHROPIC_MODEL=from-active-env"

  [ -f "$(output_dir)/00_transcript.txt" ]
  [ -f "$(output_dir)/01_speakers_utterances.md" ]
  [ -f "$(output_dir)/02_structured_conversation.md" ]
  [ -f "$(input_dir)/recording.mp4" ]
  grep -qxF "ANTHROPIC_MODEL=from-active-env" "$REPO/config/auth/active.env"

  remove_memo
  [ ! -f "$(input_dir)/memo.md" ]

  given_memo human_memo.txt HUMAN_MEMO_MARKER
  grep -qF "HUMAN_MEMO_MARKER" "$(input_dir)/human_memo.txt"

  given_transcript_part recording_1.mp4 CACHED_PART_MARKER
  grep -qF "CACHED_PART_MARKER" "$(output_dir)/00_transcript_parts/recording_1.mp4.txt"
}
