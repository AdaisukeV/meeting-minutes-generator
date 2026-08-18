#!/usr/bin/env bats
# scripts/generate_minutes.sh のテスト(docs/design/07-testing.md §4 の generate_minutes.sh 表)。
# 番号はテストケース一覧の # に対応する。

load helper

setup() {
  setup_repo
}

# =============================================================================
# 4a: usage / die / parse_args(ケース2〜7)
# =============================================================================

@test "2: 引数0個なら usage が stderr に出て終了コード1" {
  run "$GENERATE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: generate_minutes.sh"* ]]
  [[ "$output" == *"ERROR:"* ]]
}

@test "2b: 引数1個なら usage が stderr に出て終了コード1" {
  run "$GENERATE" "$TEST_PROJECT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: generate_minutes.sh"* ]]
}

@test "3: date が YYYY/MM/DD 形式なら ERROR、終了コード1" {
  run "$GENERATE" "$TEST_PROJECT" "2026/08/16"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
  [[ "$output" == *"YYYY-MM-DD"* ]]
}

@test "4: project に ../ を含むなら ERROR、終了コード1(パストラバーサル拒否)" {
  run "$GENERATE" "../etc" "$TEST_DATE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
  [[ "$output" == *"project"* ]]
}

@test "4b: project が .. 単独なら ERROR、終了コード1" {
  run "$GENERATE" ".." "$TEST_DATE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
}

@test "5: --from-step と --only-step の同時指定は ERROR、終了コード1" {
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --from-step 2 --only-step 3

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
  [[ "$output" == *"--from-step"* ]]
  [[ "$output" == *"--only-step"* ]]
}

@test "6: --from-step 4 は範囲外で ERROR、終了コード1" {
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --from-step 4

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
}

@test "6b: --from-step abc は非数値で ERROR、終了コード1" {
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --from-step abc

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
}

@test "6c: --from-step 0 は範囲外(1..3)で ERROR、終了コード1" {
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --from-step 0

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
}

@test "6d: --only-step 4 は範囲外(0..3)で ERROR、終了コード1" {
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 4

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
}

@test "6e: 未知のオプションは ERROR + usage、終了コード1" {
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --unknown-option

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
  [[ "$output" == *"usage: generate_minutes.sh"* ]]
}

@test "6f: --from-step に値が無ければ ERROR、終了コード1" {
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --from-step

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
}

@test "7: --help は usage を stdout に出して終了コード0" {
  run "$GENERATE" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: generate_minutes.sh"* ]]
  [[ "$output" == *"--from-step"* ]]
  [[ "$output" == *"--only-step"* ]]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" != *"ERROR:"* ]]
}

@test "7b: -h も usage を stdout に出して終了コード0" {
  run "$GENERATE" -h

  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: generate_minutes.sh"* ]]
}

# --- 関数単体(source して呼ぶ) ---

@test "関数: parse_args の既定値は FROM_STEP=1 / TO_STEP=3 / MODEL_SIZE=base / DRY_RUN=0" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"

  [ "$PROJECT" = "$TEST_PROJECT" ]
  [ "$MEETING_DATE" = "$TEST_DATE" ]
  [ "$FROM_STEP" -eq 1 ]
  [ "$TO_STEP" -eq 3 ]
  [ "$MODEL_SIZE" = "base" ]
  [ "$DRY_RUN" -eq 0 ]
}

@test "関数: --from-step 2 は FROM_STEP=2 / TO_STEP=3" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE" --from-step 2

  [ "$FROM_STEP" -eq 2 ]
  [ "$TO_STEP" -eq 3 ]
}

@test "関数: --only-step 2 は FROM_STEP=TO_STEP=2" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE" --only-step 2

  [ "$FROM_STEP" -eq 2 ]
  [ "$TO_STEP" -eq 2 ]
}

@test "関数: --only-step 0 は FROM_STEP=TO_STEP=0(文字起こしのみ)" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE" --only-step 0

  [ "$FROM_STEP" -eq 0 ]
  [ "$TO_STEP" -eq 0 ]
}

@test "関数: --model-size / --dry-run が反映され、オプションは引数の前後どちらでもよい" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args --model-size small "$TEST_PROJECT" "$TEST_DATE" --dry-run

  [ "$PROJECT" = "$TEST_PROJECT" ]
  [ "$MEETING_DATE" = "$TEST_DATE" ]
  [ "$MODEL_SIZE" = "small" ]
  [ "$DRY_RUN" -eq 1 ]
}

@test "関数: source しても main が自動実行されない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  [ "$(stub_call_count claude)" -eq 0 ]
  [ "$(stub_call_count transcribe.py)" -eq 0 ]
}

@test "関数: die はコードとメッセージを stderr に出す" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  run die 3 "事象の説明" "次の操作"

  [ "$status" -eq 3 ]
  [[ "$output" == *"ERROR: 事象の説明"* ]]
  [[ "$output" == *"HINT:"* ]]
  [[ "$output" == *"次の操作"* ]]
}

@test "関数: usage は stdout に出力する(die 経由では stderr)" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  run usage

  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: generate_minutes.sh"* ]]
}

# =============================================================================
# 4b: load_auth_env / resolve_paths / validate_project / validate_inputs /
#     find_media_file(ケース8,9,11,12,13,14,28)
# =============================================================================

@test "8: active.env が存在すればファイル内の値が環境変数として反映される" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  given_active_env "ANTHROPIC_MODEL=from-active-env" "STUB_MARKER_VAR=from-file"
  load_auth_env

  [ "$ANTHROPIC_MODEL" = "from-active-env" ]
  [ "$STUB_MARKER_VAR" = "from-file" ]
}

@test "9: active.env が存在しなければ既存の環境変数がそのまま使われる(要件7.2)" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  [ ! -f "$REPO/config/auth/active.env" ]
  export ANTHROPIC_MODEL="from-environment"

  run load_auth_env
  [ "$status" -eq 0 ]

  load_auth_env
  [ "$ANTHROPIC_MODEL" = "from-environment" ]
}

@test "11: パス生成:outputs/{p}/{d}/ が作成され、各ファイルパスが規定どおり" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths

  [ "$INPUT_DIR" = "$REPO/inputs/$TEST_PROJECT/$TEST_DATE" ]
  [ "$OUTPUT_DIR" = "$REPO/outputs/$TEST_PROJECT/$TEST_DATE" ]
  [ "$PROJECT_DIR" = "$REPO/projects/$TEST_PROJECT" ]
  [ "$PROMPT_DIR" = "$REPO/projects/$TEST_PROJECT/prompts" ]
  [ "$CONFIG_FILE" = "$PROJECT_DIR/config.yaml" ]
  [ "$TRANSCRIPT_FILE" = "$OUTPUT_DIR/00_transcript.txt" ]
  [ -d "$OUTPUT_DIR" ]

  [ "$(step_output_file 1)" = "$OUTPUT_DIR/01_speakers_utterances.md" ]
  [ "$(step_output_file 2)" = "$OUTPUT_DIR/02_structured_conversation.md" ]
  [ "$(step_output_file 3)" = "$OUTPUT_DIR/minutes.md" ]
  [ "$(step_prompt_file 1)" = "$PROMPT_DIR/01_organize.md" ]
  [ "$(step_prompt_file 2)" = "$PROMPT_DIR/02_structure.md" ]
  [ "$(step_prompt_file 3)" = "$PROMPT_DIR/03_format.md" ]
}

@test "12: projects/{p}/config.yaml 欠落なら ERROR + _template の HINT、終了コード1" {
  rm "$REPO/projects/$TEST_PROJECT/config.yaml"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
  [[ "$output" == *"config.yaml"* ]]
  [[ "$output" == *"cp -r projects/_template"* ]]
}

@test "12b: プロジェクトディレクトリ自体が無ければ ERROR、終了コード1" {
  run "$GENERATE" "no-such-project" "$TEST_DATE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
  [[ "$output" == *"no-such-project"* ]]
}

@test "13: プロンプトファイル欠落なら ERROR、終了コード1" {
  rm "$REPO/projects/$TEST_PROJECT/prompts/02_structure.md"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
  [[ "$output" == *"02_structure.md"* ]]
}

@test "14: 入力ディレクトリ欠落なら ERROR、終了コード1" {
  rm -rf "$REPO/inputs/$TEST_PROJECT"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
  [[ "$output" == *"inputs/$TEST_PROJECT/$TEST_DATE"* ]]
}

@test "14b: 入力ディレクトリが空(メモ・メディア・文字起こしのいずれも無い)なら ERROR、終了コード1" {
  remove_memo

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
  [[ "$output" == *"議事メモ"* ]]
  [[ "$output" == *".txt"* ]]
}

@test "14c: 議事メモが無くても既存の 00_transcript.txt があれば validate_inputs を通る" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  remove_memo
  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  given_transcript

  run validate_inputs
  [ "$status" -eq 0 ]
}

@test "28: メディアが2件なら find_media_files が両方をファイル名昇順で返す" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  given_media recording_2.m4a
  given_media recording_1.mp4

  run find_media_files

  [ "$status" -eq 0 ]
  [ "$output" = "$(input_dir)/recording_1.mp4
$(input_dir)/recording_2.m4a" ]
}

@test "関数: find_media_files はメディア1件をそのまま返し、0件なら空を返す" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths

  run find_media_files
  [ "$status" -eq 0 ]
  [ "$output" = "" ]

  given_media recording.MP4
  run find_media_files
  [ "$status" -eq 0 ]
  [ "$output" = "$(input_dir)/recording.MP4" ]
}

@test "関数: find_media_files は議事メモや文字起こしをメディアとみなさない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  given_transcript
  given_memo human_memo.txt HUMAN_MEMO_MARKER

  run find_media_files
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "関数: find_memo_files は *.md / *.txt を昇順で全件返し、0件なら空を返す" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths

  run find_memo_files
  [ "$status" -eq 0 ]
  [ "$output" = "$(input_dir)/memo.md" ]

  given_memo 01_gemini_memo.md GEMINI_MEMO_MARKER
  given_memo human_memo.TXT HUMAN_MEMO_MARKER
  run find_memo_files
  [ "$status" -eq 0 ]
  [ "$output" = "$(input_dir)/01_gemini_memo.md
$(input_dir)/human_memo.TXT
$(input_dir)/memo.md" ]

  remove_memo
  rm "$(input_dir)/01_gemini_memo.md" "$(input_dir)/human_memo.TXT"
  run find_memo_files
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "関数: find_memo_files はメディアファイルを議事メモとみなさない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  remove_memo
  given_media recording.mp4
  echo "not a memo" >"$(input_dir)/handout.pdf"

  run find_memo_files
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "14d: 議事メモが memo.md 以外の名前でも validate_inputs を通る" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  remove_memo
  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  given_memo gemini_memo.md GEMINI_MEMO_MARKER

  run validate_inputs
  [ "$status" -eq 0 ]
}

# =============================================================================
# 4c: build_step_input + 入力サイズ WARN(ケース18,19,20,33)
# =============================================================================

@test "18: ステップ1の stdin は PROJECT_CONFIG / MEETING_MEMO / TRANSCRIPT を含み END OF INPUT で終わる" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  given_transcript

  run build_step_input 1
  [ "$status" -eq 0 ]

  [[ "$output" == *"===== INPUT: PROJECT_CONFIG (config.yaml) ====="* ]]
  [[ "$output" == *"===== INPUT: MEETING_MEMO (memo.md) ====="* ]]
  [[ "$output" == *"===== INPUT: TRANSCRIPT (00_transcript.txt) ====="* ]]
  [[ "$output" == *"===== END OF INPUT ====="* ]]

  # 各ファイルの本文が含まれる
  [[ "$output" == *"FIXTURE_CONFIG_MARKER"* ]]
  [[ "$output" == *"FIXTURE_MEMO_MARKER"* ]]
  [[ "$output" == *"FIXTURE_TRANSCRIPT_MARKER"* ]]

  # 絶対パスを含めない(basename のみ)
  [[ "$output" != *"$REPO"* ]]

  # 末尾は END OF INPUT
  [ "$(echo "$output" | tail -n 1)" = "===== END OF INPUT =====" ]
}

@test "19: memo.md が無い場合、MEETING_MEMO ヘッダを出力しない(空セクションを作らない)" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  remove_memo
  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  given_transcript

  run build_step_input 1
  [ "$status" -eq 0 ]

  [[ "$output" == *"PROJECT_CONFIG"* ]]
  [[ "$output" == *"TRANSCRIPT"* ]]
  [[ "$output" != *"MEETING_MEMO"* ]]
}

@test "19c: 議事メモが2件(.md + .txt)なら MEETING_MEMO を2つ出力し双方の本文を含める" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  remove_memo
  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  given_memo gemini_memo.md GEMINI_MEMO_MARKER
  given_memo human_memo.txt HUMAN_MEMO_MARKER

  run build_step_input 1
  [ "$status" -eq 0 ]

  [[ "$output" == *"===== INPUT: MEETING_MEMO (gemini_memo.md) ====="* ]]
  [[ "$output" == *"===== INPUT: MEETING_MEMO (human_memo.txt) ====="* ]]
  [[ "$output" == *"GEMINI_MEMO_MARKER"* ]]
  [[ "$output" == *"HUMAN_MEMO_MARKER"* ]]
  [ "$(grep -c "INPUT: MEETING_MEMO" <<<"$output")" -eq 2 ]

  # 絶対パスを含めない(basename のみ)
  [[ "$output" != *"$REPO"* ]]
}

@test "19d: 議事メモが3件ならファイル名昇順で並ぶ" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  remove_memo
  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  given_memo 03_c.md MARKER_C
  given_memo 01_a.md MARKER_A
  given_memo 02_b.txt MARKER_B

  run build_step_input 1
  [ "$status" -eq 0 ]

  [ "$(grep -o "MEETING_MEMO ([^)]*)" <<<"$output")" = "MEETING_MEMO (01_a.md)
MEETING_MEMO (02_b.txt)
MEETING_MEMO (03_c.md)" ]
}

@test "19e: .md / .txt 以外のファイルは議事メモとして出力しない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  given_media recording.mp4
  echo "HANDOUT_MARKER" >"$(input_dir)/handout.pdf"

  run build_step_input 1
  [ "$status" -eq 0 ]

  [ "$(grep -c "INPUT: MEETING_MEMO" <<<"$output")" -eq 1 ]
  [[ "$output" != *"HANDOUT_MARKER"* ]]
  [[ "$output" != *"recording.mp4"* ]]
}

@test "19b: 文字起こしが無い場合、TRANSCRIPT ヘッダを出力しない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths

  run build_step_input 1
  [ "$status" -eq 0 ]

  [[ "$output" == *"MEETING_MEMO"* ]]
  [[ "$output" != *"TRANSCRIPT"* ]]
}

@test "20: ステップ2の stdin は STEP1_OUTPUT を含み TRANSCRIPT を含まない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  given_transcript
  given_step_output 1

  run build_step_input 2
  [ "$status" -eq 0 ]

  [[ "$output" == *"===== INPUT: PROJECT_CONFIG (config.yaml) ====="* ]]
  [[ "$output" == *"===== INPUT: STEP1_OUTPUT (01_speakers_utterances.md) ====="* ]]
  [[ "$output" == *"FIXTURE_STEP1_MARKER"* ]]
  [[ "$output" != *"TRANSCRIPT"* ]]
  [[ "$output" != *"MEETING_MEMO"* ]]
}

@test "20b: ステップ3の stdin は STEP2_OUTPUT を含み STEP1_OUTPUT を含まない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  given_step_output 1
  given_step_output 2

  run build_step_input 3
  [ "$status" -eq 0 ]

  [[ "$output" == *"===== INPUT: STEP2_OUTPUT (02_structured_conversation.md) ====="* ]]
  [[ "$output" == *"FIXTURE_STEP2_MARKER"* ]]
  [[ "$output" != *"STEP1_OUTPUT"* ]]
}

@test "33: 入力が INPUT_WARN_BYTES を超えると stderr に WARN が出るが処理は継続する" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  export INPUT_WARN_BYTES=100

  run build_step_input 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN:"* ]]
  [[ "$output" == *"100"* ]]
  [[ "$output" == *"===== END OF INPUT ====="* ]]
}

@test "33b: 閾値以下なら WARN を出さない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  export INPUT_WARN_BYTES=400000

  run build_step_input 1
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARN:"* ]]
}

@test "33c: WARN は stdout(claude への入力)を汚さない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  export INPUT_WARN_BYTES=100

  build_step_input 1 >"$BATS_TEST_TMPDIR/stdin.txt" 2>"$BATS_TEST_TMPDIR/warn.txt"

  grep -qF "WARN:" "$BATS_TEST_TMPDIR/warn.txt"
  ! grep -qF "WARN:" "$BATS_TEST_TMPDIR/stdin.txt"
  grep -qF "===== END OF INPUT =====" "$BATS_TEST_TMPDIR/stdin.txt"
}

# =============================================================================
# 4d: invoke_claude / run_step(ケース21,22,23,24,25)
# =============================================================================

@test "21: claude に -p / --bare / --tools '' / --system-prompt-file / --model が渡る" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths

  run run_step 1
  [ "$status" -eq 0 ]

  [ "$(stub_call_count claude)" -eq 1 ]
  stub_args_contains "-p"
  stub_args_contains "--bare"
  stub_args_contains "--tools"
  stub_args_contains ""
  stub_args_contains "--system-prompt-file"
  stub_args_contains "$(step_prompt_file 1)"
  stub_args_contains "--model"
  stub_args_contains "test.model.id-v1:0"
}

@test "35: ANTHROPIC_MODEL_STEP1 を設定するとステップ1の --model に当該IDが渡る" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  export ANTHROPIC_MODEL_STEP1="test.step1.model-v1:0"
  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths

  run run_step 1
  [ "$status" -eq 0 ]

  stub_args_contains "test.step1.model-v1:0"
  ! stub_args_contains "test.model.id-v1:0"
}

@test "36: ANTHROPIC_MODEL_STEP1 未設定なら ANTHROPIC_MODEL にフォールバックする" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  unset ANTHROPIC_MODEL_STEP1
  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths

  run run_step 1
  [ "$status" -eq 0 ]

  stub_args_contains "test.model.id-v1:0"
}

@test "37: ステップ1のみ上書きした通し実行で、ステップ2・3は ANTHROPIC_MODEL を使う" {
  given_active_env \
    "ANTHROPIC_MODEL=test.model.id-v1:0" \
    "ANTHROPIC_MODEL_STEP1=test.step1.model-v1:0"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"
  [ "$status" -eq 0 ]

  [ "$(stub_call_count claude)" -eq 3 ]
  [ "$(stub_args_count "test.step1.model-v1:0")" -eq 1 ]
  [ "$(stub_args_count "test.model.id-v1:0")" -eq 2 ]
}

@test "38: ANTHROPIC_MODEL 未設定ならステップ別指定があってもコード1で停止する" {
  unset ANTHROPIC_MODEL
  export ANTHROPIC_MODEL_STEP1="test.step1.model-v1:0"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ANTHROPIC_MODEL が設定されていません"* ]]
  [ "$(stub_call_count claude)" -eq 0 ]
}

@test "21b: ステップ2ではステップ2のプロンプトが渡る" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  given_step_output 1

  run run_step 2
  [ "$status" -eq 0 ]

  stub_args_contains "$(step_prompt_file 2)"
  ! stub_args_contains "$(step_prompt_file 1)"
}

@test "21c: stdin に組み立てた入力が渡り、出力ファイルが生成される" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths

  run run_step 1
  [ "$status" -eq 0 ]

  grep -qF "===== INPUT: PROJECT_CONFIG (config.yaml) =====" "$STUB_STDIN_FILE"
  grep -qF "===== END OF INPUT =====" "$STUB_STDIN_FILE"
  [ -f "$(step_output_file 1)" ]
  grep -qF "STUB CLAUDE OUTPUT" "$(step_output_file 1)"
}

@test "22: claude の cwd はリポジトリ配下ではない空の一時ディレクトリ" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths

  run run_step 1
  [ "$status" -eq 0 ]

  local cwd
  cwd="$(head -n 1 "$STUB_CWD_FILE")"
  [ -n "$cwd" ]
  [[ "$cwd" != "$REPO"* ]]
  [[ "$cwd" != "$PROJECT_ROOT"* ]]
  # 実行後に一時ディレクトリは削除される
  [ ! -d "$cwd" ]
}

@test "23: claude が終了コード1を返したら終了コード3で停止し、出力ファイルを作らない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  export STUB_EXIT=1

  run run_step 1

  [ "$status" -eq 3 ]
  [[ "$output" == *"ERROR:"* ]]
  [ ! -f "$(step_output_file 1)" ]
}

@test "39: claude が 130(SIGINT)を返したら中断として報告し、コード130で終わる" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  export STUB_EXIT=130

  run run_step 1

  [ "$status" -eq 130 ]
  [[ "$output" == *"中断されました"* ]]
  # 的外れな原因を提示しない(01-conventions.md §4)
  [[ "$output" != *"claude の実行に失敗しました"* ]]
  [[ "$output" != *"HINT:"* ]]
  [ ! -f "$(step_output_file 1)" ]
}

@test "40: claude が 143(SIGTERM)を返した場合も中断として扱う" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  export STUB_EXIT=143

  run run_step 1

  [ "$status" -eq 130 ]
  [[ "$output" == *"中断されました"* ]]
  [[ "$output" != *"HINT:"* ]]
}

@test "41: HEARTBEAT_INTERVAL_SECONDS を有効にすると実行中の経過が表示される" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  export HEARTBEAT_INTERVAL_SECONDS=1
  export STUB_SLEEP_SECONDS=3

  run run_step 1

  [ "$status" -eq 0 ]
  [[ "$output" == *"ステップ1 実行中 (経過"* ]]
}

@test "42: HEARTBEAT_INTERVAL_SECONDS=0 なら経過表示を出さない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  export HEARTBEAT_INTERVAL_SECONDS=0

  run run_step 1

  [ "$status" -eq 0 ]
  [[ "$output" != *"実行中 (経過"* ]]
}

@test "43: 経過表示に会議内容が含まれない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  given_transcript
  export HEARTBEAT_INTERVAL_SECONDS=1
  export STUB_SLEEP_SECONDS=3

  run run_step 1

  [ "$status" -eq 0 ]
  local line
  while IFS= read -r line; do
    [[ "$line" != *"$(head -n 3 "$FIXTURES/memo.md" | tail -n 1)"* ]]
  done <<<"$output"
  [[ "$output" == *"実行中 (経過"* ]]
}

@test "関数: on_interrupt は HINT を出さずコード130で終わる" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  run on_interrupt

  [ "$status" -eq 130 ]
  [[ "$output" == *"中断されました"* ]]
  [[ "$output" != *"HINT:"* ]]
}

@test "関数: stop_heartbeat はバックグラウンドの経過表示プロセスを止める" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  HEARTBEAT_INTERVAL_SECONDS=1 start_heartbeat "テスト"
  [ -n "$HEARTBEAT_PID" ]
  kill -0 "$HEARTBEAT_PID"

  local pid="$HEARTBEAT_PID"
  stop_heartbeat
  [ -z "$HEARTBEAT_PID" ]
  ! kill -0 "$pid" 2>/dev/null
}

@test "関数: elapsed_label は秒数を日本語の経過表記に整形する" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  [ "$(elapsed_label 0)" = "0秒" ]
  [ "$(elapsed_label 45)" = "45秒" ]
  [ "$(elapsed_label 60)" = "1分0秒" ]
  [ "$(elapsed_label 194)" = "3分14秒" ]
  [ "$(elapsed_label 3600)" = "60分0秒" ]
}

@test "24: claude が空出力を返したら終了コード3、既存の出力ファイルは壊れない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths

  # 既存の出力(前回の成果物)を置く
  echo "PREVIOUS CONTENT" >"$(step_output_file 1)"

  : >"$BATS_TEST_TMPDIR/empty.txt"
  export STUB_STDOUT_FILE="$BATS_TEST_TMPDIR/empty.txt"

  run run_step 1

  [ "$status" -eq 3 ]
  [[ "$output" == *"ERROR:"* ]]
  [ "$(cat "$(step_output_file 1)")" = "PREVIOUS CONTENT" ]
}

@test "24b: 失敗時に一時ファイルが残らない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  export STUB_EXIT=1

  run run_step 1
  [ "$status" -eq 3 ]

  # OUTPUT_DIR に mktemp の一時ファイル(01_speakers_utterances.md.XXXXXX 等)が残っていない。
  # 診断用の .error.log / .truncated.md は意図して残す(ケース64・65)。
  run find "$OUTPUT_DIR" -type f ! -name '*.error.log' ! -name '*.truncated.md'
  [ "$output" = "" ]
}

@test "25: --dry-run では claude を呼ばず実行計画を stdout に出して終了コード0" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE" --dry-run
  resolve_paths

  run run_step 2

  [ "$status" -eq 0 ]
  [ "$(stub_call_count claude)" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"02_structure.md"* ]]
  [[ "$output" == *"02_structured_conversation.md"* ]]
  # 前段の出力が無くてもエラーにしない(計画表示のみ)
  [ ! -f "$(step_output_file 2)" ]
}

@test "関数: invoke_claude は成功時に dest_file へ生成物を書き、0を返す" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  echo "STDIN BODY" >"$BATS_TEST_TMPDIR/in.txt"

  run invoke_claude "$(step_prompt_file 1)" "$BATS_TEST_TMPDIR/in.txt" \
    "$BATS_TEST_TMPDIR/dest.txt" "$(step_model 1)" 1
  [ "$status" -eq 0 ]

  grep -qF "STUB CLAUDE OUTPUT" "$BATS_TEST_TMPDIR/dest.txt"
  grep -qF "STDIN BODY" "$STUB_STDIN_FILE"
}

@test "関数: invoke_claude は失敗・空出力で 3 を返す" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  echo "x" >"$BATS_TEST_TMPDIR/in.txt"

  STUB_EXIT=1 run invoke_claude "$(step_prompt_file 1)" "$BATS_TEST_TMPDIR/in.txt" \
    "$BATS_TEST_TMPDIR/dest.txt" "$(step_model 1)" 1
  [ "$status" -eq 3 ]

  : >"$BATS_TEST_TMPDIR/empty.txt"
  STUB_STDOUT_FILE="$BATS_TEST_TMPDIR/empty.txt" run invoke_claude \
    "$(step_prompt_file 1)" "$BATS_TEST_TMPDIR/in.txt" "$BATS_TEST_TMPDIR/dest.txt" "$(step_model 1)" 1
  [ "$status" -eq 3 ]
}

@test "関数: run_step の進捗出力に会議内容が含まれない(ケース32の関数版)" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE"
  resolve_paths
  given_transcript

  run run_step 1
  [ "$status" -eq 0 ]

  [[ "$output" != *"FIXTURE_CONFIG_MARKER"* ]]
  [[ "$output" != *"FIXTURE_MEMO_MARKER"* ]]
  [[ "$output" != *"FIXTURE_TRANSCRIPT_MARKER"* ]]
  [[ "$output" != *"STUB CLAUDE OUTPUT"* ]]
}

# =============================================================================
# 4e: ensure_transcript / maybe_sso_login / require_model / warn_stale_outputs /
#     main(ケース1,8,10,15,16,17,25,26,27,29,29b,29c,30,31,32)
# =============================================================================

@test "1: 正常系(memo + transcript)で3ファイルが生成され終了コード0" {
  given_transcript

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [ -f "$(output_dir)/01_speakers_utterances.md" ]
  [ -f "$(output_dir)/02_structured_conversation.md" ]
  [ -f "$(output_dir)/minutes.md" ]
  [ "$(stub_call_count claude)" -eq 3 ]
  [[ "$output" != *"WARN:"* ]]
}

@test "1b: 正常系で一時ファイルが残らない" {
  given_transcript

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"
  [ "$status" -eq 0 ]

  run bash -c "find '$(output_dir)' -type f | sort"
  [ "$output" = "$(output_dir)/00_transcript.txt
$(output_dir)/01_speakers_utterances.md
$(output_dir)/02_structured_conversation.md
$(output_dir)/minutes.md" ]
}

@test "8e2e: active.env の ANTHROPIC_MODEL が --model に渡る" {
  given_active_env "ANTHROPIC_MODEL=model-from-active-env"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  stub_args_contains "model-from-active-env"
  ! stub_args_contains "test.model.id-v1:0"
}

@test "10: ANTHROPIC_MODEL 未設定なら ERROR、終了コード1、claude は呼ばれない" {
  unset ANTHROPIC_MODEL

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
  [[ "$output" == *"ANTHROPIC_MODEL"* ]]
  [[ "$output" == *"active.env"* ]]
  [ "$(stub_call_count claude)" -eq 0 ]
}

@test "15: --from-step 2 で 01_speakers_utterances.md が無ければ ERROR、終了コード1" {
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --from-step 2

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
  [[ "$output" == *"01_speakers_utterances.md"* ]]
  [[ "$output" == *"--from-step"* ]]
}

@test "16: --from-step 2 なら claude 呼び出しは2回、ステップ1のプロンプトは使われない" {
  given_step_output 1

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --from-step 2

  [ "$status" -eq 0 ]
  [ "$(stub_call_count claude)" -eq 2 ]
  ! stub_args_contains "$REPO/projects/$TEST_PROJECT/prompts/01_organize.md"
  stub_args_contains "$REPO/projects/$TEST_PROJECT/prompts/02_structure.md"
  stub_args_contains "$REPO/projects/$TEST_PROJECT/prompts/03_format.md"
}

@test "17: --only-step 2 なら呼び出し1回、minutes.md は更新されず stale WARN が出る" {
  given_step_output 1
  echo "OLD MINUTES" >"$(output_dir)/minutes.md"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 2

  [ "$status" -eq 0 ]
  [ "$(stub_call_count claude)" -eq 1 ]
  [ "$(cat "$(output_dir)/minutes.md")" = "OLD MINUTES" ]
  [[ "$output" == *"WARN:"* ]]
  [[ "$output" == *"minutes.md"* ]]
  [[ "$output" == *"--from-step 3"* ]]
}

@test "17b: --from-step 実行では stale WARN が出ない" {
  given_step_output 1
  echo "OLD MINUTES" >"$(output_dir)/minutes.md"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --from-step 2

  [ "$status" -eq 0 ]
  [[ "$output" != *"WARN:"* ]]
}

@test "25e2e: --dry-run では claude / transcribe.py を呼ばず実行計画を出して終了コード0" {
  given_media recording.mp4

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --dry-run

  [ "$status" -eq 0 ]
  [ "$(stub_call_count claude)" -eq 0 ]
  [ "$(stub_call_count transcribe.py)" -eq 0 ]
  [[ "$output" == *"dry-run"* ]]
  [[ "$output" == *"01_speakers_utterances.md"* ]]
  [[ "$output" == *"minutes.md"* ]]
  [ ! -f "$(output_dir)/minutes.md" ]
}

@test "26: メディアあり・文字起こしなしなら transcribe.py が1回呼ばれる" {
  given_media recording.mp4

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [ "$(stub_call_count transcribe.py)" -eq 1 ]
  stub_args_contains "--input"
  stub_args_contains "$(input_dir)/recording.mp4"
  stub_args_contains "--output"
  stub_args_contains "$(output_dir)/00_transcript_parts/recording.mp4.txt"
  stub_args_contains "--model-size"
  stub_args_contains "base"
  [ -f "$(output_dir)/00_transcript_parts/recording.mp4.txt" ]
  [ -f "$(output_dir)/00_transcript.txt" ]
}

@test "26b: --model-size が transcribe.py に渡る" {
  given_media recording.mp4

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --model-size small

  [ "$status" -eq 0 ]
  stub_args_contains "small"
}

@test "26c: transcribe.py が失敗したら終了コードを伝播し claude を呼ばない" {
  given_media recording.mp4
  export STUB_EXIT=3

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 3 ]
  [[ "$output" == *"ERROR:"* ]]
  [ "$(stub_call_count claude)" -eq 0 ]
}

@test "27: メディアあり・文字起こしありなら transcribe.py は呼ばれない" {
  given_media recording.mp4
  given_transcript

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [ "$(stub_call_count transcribe.py)" -eq 0 ]
  [[ "$output" == *"既存の文字起こしを使用します"* ]]
}

@test "28c: メディアが1件ならパートマーカーを挿入しない(後方互換)" {
  given_media recording.mp4

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 0

  [ "$status" -eq 0 ]
  ! grep -qF "TRANSCRIPT PART" "$(output_dir)/00_transcript.txt"
  # パートの内容がそのまま 00_transcript.txt になる
  diff "$(output_dir)/00_transcript_parts/recording.mp4.txt" \
    "$(output_dir)/00_transcript.txt"
}

@test "28e2e: メディアが2件なら両方が文字起こしされ昇順で連結される" {
  given_media recording_2.wav
  given_media recording_1.mp4

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 0

  [ "$status" -eq 0 ]
  [ "$(stub_call_count transcribe.py)" -eq 2 ]
  stub_args_contains "$(input_dir)/recording_1.mp4"
  stub_args_contains "$(input_dir)/recording_2.wav"
  [ -f "$(output_dir)/00_transcript_parts/recording_1.mp4.txt" ]
  [ -f "$(output_dir)/00_transcript_parts/recording_2.wav.txt" ]

  # 連結順はファイル名昇順(スタブはヘッダに --input の basename を書く)
  [ "$(grep -o "STUB_TRANSCRIPT_LINE .*" "$(output_dir)/00_transcript.txt")" = "STUB_TRANSCRIPT_LINE recording_1.mp4
STUB_TRANSCRIPT_LINE recording_2.wav" ]
}

@test "28b: メディアが2件ならパートマーカーが順に現れ、連結順が stdout に列挙される" {
  given_media recording_2.wav
  given_media recording_1.mp4

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 0

  [ "$status" -eq 0 ]
  [ "$(grep -o "^----- TRANSCRIPT PART .*" "$(output_dir)/00_transcript.txt")" = "----- TRANSCRIPT PART 1/2: recording_1.mp4 -----
----- TRANSCRIPT PART 2/2: recording_2.wav -----" ]

  # 連結順を利用者が検証できるよう進捗に列挙する
  [[ "$output" == *"1. recording_1.mp4"* ]]
  [[ "$output" == *"2. recording_2.wav"* ]]
}

@test "28d: 既存パートがあるメディアは文字起こしを再実行しない" {
  given_media recording_1.mp4
  given_media recording_2.wav
  given_transcript_part recording_1.mp4 CACHED_PART_MARKER

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 0

  [ "$status" -eq 0 ]
  [ "$(stub_call_count transcribe.py)" -eq 1 ]
  stub_args_contains "$(input_dir)/recording_2.wav"
  ! stub_args_contains "$(input_dir)/recording_1.mp4"

  # 既存パートの内容が連結結果に含まれる
  grep -qF "CACHED_PART_MARKER" "$(output_dir)/00_transcript.txt"
  grep -qF "STUB_TRANSCRIPT_LINE recording_2.wav" "$(output_dir)/00_transcript.txt"
}

@test "28e: 2件目の文字起こしが失敗したら 00_transcript.txt を確定しない" {
  given_media recording_1.mp4
  given_media recording_2.wav
  given_transcript_part recording_1.mp4 CACHED_PART_MARKER
  export STUB_EXIT=3

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 0

  [ "$status" -eq 3 ]
  [[ "$output" == *"ERROR:"* ]]
  [[ "$output" == *"recording_2.wav"* ]]
  [ ! -f "$(output_dir)/00_transcript.txt" ]
}

@test "28f: パートが残っていてもメディアを削除すれば連結対象から外れる" {
  given_media recording_2.wav
  given_transcript_part recording_1.mp4 REMOVED_MEDIA_MARKER

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 0

  [ "$status" -eq 0 ]
  ! grep -qF "REMOVED_MEDIA_MARKER" "$(output_dir)/00_transcript.txt"
  ! grep -qF "TRANSCRIPT PART" "$(output_dir)/00_transcript.txt"
  grep -qF "STUB_TRANSCRIPT_LINE recording_2.wav" "$(output_dir)/00_transcript.txt"
}

@test "28g: --dry-run では連結順を表示し transcribe.py を呼ばず 00_transcript.txt も作らない" {
  given_media recording_1.mp4
  given_media recording_2.wav
  given_transcript_part recording_1.mp4 CACHED_PART_MARKER

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 0 --dry-run

  [ "$status" -eq 0 ]
  [ "$(stub_call_count transcribe.py)" -eq 0 ]
  [[ "$output" == *"1. recording_1.mp4"* ]]
  [[ "$output" == *"2. recording_2.wav"* ]]
  [ ! -f "$(output_dir)/00_transcript.txt" ]
}

@test "29: メディアなし・memo のみなら文字起こしをスキップして正常終了" {
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [ "$(stub_call_count transcribe.py)" -eq 0 ]
  [ "$(stub_call_count claude)" -eq 3 ]
  [ ! -f "$(output_dir)/00_transcript.txt" ]
}

@test "29b: --from-step 2 では transcribe.py が呼ばれない" {
  given_media recording.mp4
  given_step_output 1

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --from-step 2

  [ "$status" -eq 0 ]
  [ "$(stub_call_count transcribe.py)" -eq 0 ]
}

@test "29c: --only-step 0 かつメディアなしなら ERROR、終了コード1" {
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 0

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR:"* ]]
  [ "$(stub_call_count claude)" -eq 0 ]
}

@test "29d: --only-step 0 は文字起こしのみで claude を呼ばない" {
  given_media recording.mp4

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 0

  [ "$status" -eq 0 ]
  [ "$(stub_call_count transcribe.py)" -eq 1 ]
  [ "$(stub_call_count claude)" -eq 0 ]
  [ -f "$(output_dir)/00_transcript.txt" ]
}

@test "30: CLAUDE_CODE_USE_BEDROCK=1 なら aws_sso_login.sh が呼ばれる" {
  export CLAUDE_CODE_USE_BEDROCK=1

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  # aws_sso_login.sh の内部で aws sts get-caller-identity が実行される
  [ "$(stub_call_count aws)" -ge 1 ]
  stub_args_contains "get-caller-identity"
}

@test "30b: SSO ログインが失敗したら終了コード2で停止し claude を呼ばない" {
  export CLAUDE_CODE_USE_BEDROCK=1
  export STUB_AWS_STS_EXITS="1"
  export STUB_AWS_LOGIN_EXIT="1"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 2 ]
  [ "$(stub_call_count claude)" -eq 0 ]
}

@test "31: CLAUDE_CODE_USE_BEDROCK 未設定なら aws_sso_login.sh は呼ばれない" {
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [ "$(stub_call_count aws)" -eq 0 ]
}

@test "32: 進捗出力に会議内容・生成物の本文が含まれない" {
  given_transcript
  export CLAUDE_CODE_USE_BEDROCK=1

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [[ "$output" != *"FIXTURE_CONFIG_MARKER"* ]]
  [[ "$output" != *"FIXTURE_MEMO_MARKER"* ]]
  [[ "$output" != *"FIXTURE_TRANSCRIPT_MARKER"* ]]
  [[ "$output" != *"STUB CLAUDE OUTPUT"* ]]
  # 認証情報(ARN)も出さない
  [[ "$output" != *"arn:aws:sts"* ]]
}

@test "関数: warn_stale_outputs は後続の出力が無ければ WARN を出さない" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  parse_args "$TEST_PROJECT" "$TEST_DATE" --only-step 2
  resolve_paths

  run warn_stale_outputs 2
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "関数: require_model は設定済みなら何も出さずに0を返す" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  run require_model
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# =============================================================================
# 4f: Bash 3.2 互換性(ケース34。docs/design/01-conventions.md §8)
# =============================================================================

# Bash 4.0+ 専用構文を使っている箇所を「ファイル:行番号:内容」で返す(0件なら空)。
# 検出対象: ${var,,} / ${var^^} / mapfile / readarray / declare -A / local -n
#           / wait -n / ;;& / shopt -s globstar
# 行頭コメント(禁止構文を説明のために書いた箇所)は除外する。
bash4_only_syntax_hits() {
  local pattern='\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^)|(^|[^[:alnum:]_./-])(mapfile|readarray)([[:space:]]|$)|(declare|local)[[:space:]]+-[a-zA-Z]*[An]|wait[[:space:]]+-n|;;&|shopt[[:space:]]+-s[[:space:]]+globstar'

  grep -nE "$pattern" \
    "$PROJECT_ROOT"/scripts/*.sh \
    "$PROJECT_ROOT/.devcontainer/postCreate.sh" \
    "$PROJECT_ROOT/tests/stubs/claude" \
    "$PROJECT_ROOT/tests/stubs/aws" \
    "$PROJECT_ROOT/tests/bats/helper.bash" |
    grep -vE ':[0-9]+:[[:space:]]*#' || true
}

@test "34: シェルスクリプトに Bash 4.0+ 専用構文が含まれない" {
  # macOS 標準の /bin/bash は 3.2 のため、4.0+ 専用構文を使うと
  # `bad substitution` などで即座に落ちる(docs/design/01-conventions.md §8)。
  run bash4_only_syntax_hits

  [ "$status" -eq 0 ]
  # 検出行があればここに出るので、失敗時はそのまま修正箇所が分かる
  [ "$output" = "" ]
}

@test "34c: 変数展開の直後に非ASCII文字が続く箇所がない(ブレース必須)" {
  # "$min〜$max" は UTF-8 ロケールで `min〜: unbound variable` になり、
  # メッセージを出す前に落ちる(docs/design/01-conventions.md §5)。
  run bash -c '
    grep -nE "\\\$[A-Za-z_][A-Za-z0-9_]*[^ -~]" \
      "'"$PROJECT_ROOT"'"/scripts/*.sh \
      "'"$PROJECT_ROOT"'/tests/stubs/claude" \
      "'"$PROJECT_ROOT"'/tests/stubs/aws" \
      "'"$PROJECT_ROOT"'/tests/bats/helper.bash" || true'

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "34b: /bin/bash が 3.x ならパイプライン全体がその bash でも完走する" {
  # 静的な grep(ケース34)では検出できない実行時の非互換
  # (例: case を $() の中に書くと Bash 3.2 が解釈できない)を通し実行で検知する。
  # /bin/bash が 4.0 以上の環境(devcontainer / Ubuntu)ではスキップする。
  local major
  major="$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')"
  if ((major >= 4)); then
    skip "/bin/bash が ${major}.x のため Bash 3.2 の検証は不要"
  fi

  # 議事メモ2件(配列を経由する経路)+ メディア1件を通す
  given_memo 01_gemini_memo.md GEMINI_MEMO_MARKER
  given_media recording.MP4

  run /bin/bash "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [ -f "$(output_dir)/00_transcript.txt" ]
  [ -f "$(output_dir)/minutes.md" ]
  [ "$(stub_call_count claude)" -eq 3 ]
  [ "$(grep -c '^===== INPUT: MEETING_MEMO' "$STUB_STDIN_FILE")" -eq 2 ]
}

@test "34d: /bin/bash が 3.x なら --parallel 2 の分割・並列実行も完走する" {
  # PID 集約方式(docs/design/01-conventions.md §8.4)が Bash 3.2 でも動くことを
  # 実行で担保する(bash -n では並列構文の非互換を検出できない)。
  local major
  major="$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')"
  if ((major >= 4)); then
    skip "/bin/bash が ${major}.x のため Bash 3.2 の検証は不要"
  fi

  given_numbered_transcript 20

  run /bin/bash "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --parallel 2

  [ "$status" -eq 0 ]
  [ -f "$(output_dir)/01_parts/01_part2of2.md" ]
  [ -f "$(output_dir)/minutes.md" ]
}

# =============================================================================
# 4h: 分割と並列実行(ケース44〜63。docs/design/02-generate-minutes.md §9)
# =============================================================================

@test "44: --parallel が範囲外・非数値なら ERROR、終了コード1" {
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --parallel 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"--parallel"* ]]

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --parallel 9
  [ "$status" -eq 1 ]

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --parallel abc
  [ "$status" -eq 1 ]

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --parallel
  [ "$status" -eq 1 ]
}

@test "45: --parallel 未指定なら従来と同じ3回・PART_INFO なしの stdin(後方互換)" {
  given_transcript

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [ "$(stub_call_count claude)" -eq 3 ]
  ! grep -qF "PART_INFO" "$STUB_STDIN_FILE"
  ! grep -qF "CONTEXT_BEFORE" "$STUB_STDIN_FILE"
  [ ! -d "$(output_dir)/01_parts" ]
  [ ! -d "$(output_dir)/02_parts" ]
}

@test "46: --parallel 1 の明示指定は未指定と同一(分割経路に入らない)" {
  given_transcript

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --parallel 1

  [ "$status" -eq 0 ]
  [ "$(stub_call_count claude)" -eq 3 ]
  ! grep -qF "PART_INFO" "$STUB_STDIN_FILE"
  [ ! -d "$(output_dir)/01_parts" ]
}

@test "47: --parallel 2 なら claude はステップ1で2回・2で2回・3で1回の計5回" {
  use_call_dir
  given_numbered_transcript 20

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --parallel 2

  [ "$status" -eq 0 ]
  [ "$(call_count)" -eq 5 ]
  [ "$(call_count_matching "part: 1/2")" -eq 2 ]
  [ "$(call_count_matching "part: 2/2")" -eq 2 ]
}

@test "48: --parallel 2 の先頭パートは CONTEXT_AFTER のみを持つ" {
  use_call_dir
  given_numbered_transcript 20
  export SPLIT_OVERLAP_LINES=2

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2
  [ "$status" -eq 0 ]

  local f
  f="$(find_call "part: 1/2")"
  grep -qF "===== INPUT: PART_INFO (part) =====" "$f"
  grep -qF "===== INPUT: TRANSCRIPT (00_transcript.txt part 1/2) =====" "$f"
  grep -qF "===== INPUT: CONTEXT_AFTER (00_transcript.txt) =====" "$f"
  ! grep -qF "CONTEXT_BEFORE" "$f"
  # 本体は1〜10行目
  grep -qF "TLINE_001" "$f"
  grep -qF "TLINE_010" "$f"
  # 重なりは11〜12行目のみ(13行目以降は入らない)
  grep -qF "TLINE_012" "$f"
  ! grep -qF "TLINE_013" "$f"
}

@test "49: --parallel 2 の末尾パートは CONTEXT_BEFORE のみを持つ" {
  use_call_dir
  given_numbered_transcript 20
  export SPLIT_OVERLAP_LINES=2

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2
  [ "$status" -eq 0 ]

  local f
  f="$(find_call "part: 2/2")"
  grep -qF "===== INPUT: CONTEXT_BEFORE (00_transcript.txt) =====" "$f"
  grep -qF "===== INPUT: TRANSCRIPT (00_transcript.txt part 2/2) =====" "$f"
  ! grep -qF "CONTEXT_AFTER" "$f"
  # 重なりは9〜10行目のみ、本体は11〜20行目
  grep -qF "TLINE_009" "$f"
  ! grep -qF "TLINE_008" "$f"
  grep -qF "TLINE_011" "$f"
  grep -qF "TLINE_020" "$f"
}

@test "50: 分割対象以外の議事メモは全パートに全文が入る" {
  use_call_dir
  given_numbered_transcript 20
  given_memo human_memo.txt HUMAN_MEMO_MARKER

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2
  [ "$status" -eq 0 ]

  [ "$(call_count_matching "HUMAN_MEMO_MARKER")" -eq 2 ]
  [ "$(call_count_matching "FIXTURE_MEMO_MARKER")" -eq 2 ]
}

@test "51: 文字起こしが無ければ最大バイト数のメモが分割対象になり、全文セクションに重複しない" {
  use_call_dir
  remove_memo
  given_memo small_memo.md SMALL_MEMO_MARKER
  # 明確に最大のメモを作る
  {
    echo "# big_memo.md"
    local i
    for i in $(seq 1 40); do
      echo "- BIG_MEMO_MARKER 行$i"
    done
  } >"$(input_dir)/big_memo.md"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2
  [ "$status" -eq 0 ]

  local f
  f="$(find_call "part: 1/2")"
  # 分割対象は本体セクションとしてのみ現れる
  grep -qF "===== INPUT: MEETING_MEMO (big_memo.md part 1/2) =====" "$f"
  [ "$(grep -c '^===== INPUT: MEETING_MEMO (big_memo.md)' "$f")" -eq 0 ]
  # 他のメモは全文で入る
  grep -qF "===== INPUT: MEETING_MEMO (small_memo.md) =====" "$f"
  grep -qF "SMALL_MEMO_MARKER" "$f"
}

@test "52: 分割対象・パート数・オーバーラップ行数が進捗に表示される" {
  given_numbered_transcript 20

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2

  [ "$status" -eq 0 ]
  [[ "$output" == *"ステップ1 を 2 分割して並列実行します"* ]]
  [[ "$output" == *"分割対象: 00_transcript.txt (TRANSCRIPT)"* ]]
  [[ "$output" == *"オーバーラップ"* ]]
  # 会議内容は出さない(要件6・06-security.md §3)
  [[ "$output" != *"TLINE_001"* ]]
}

@test "53: SPLIT_OVERLAP_LINES で重なりの行数を変えられる" {
  use_call_dir
  given_numbered_transcript 20
  export SPLIT_OVERLAP_LINES=5

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2
  [ "$status" -eq 0 ]

  local f
  f="$(find_call "part: 2/2")"
  # 重なりは6〜10行目の5行
  grep -qF "TLINE_006" "$f"
  ! grep -qF "TLINE_005" "$f"
}

@test "54: --parallel 2 のステップ2は 01_speakers_utterances.md を分割する" {
  use_call_dir
  given_numbered_step1_output 20
  export SPLIT_OVERLAP_LINES=2

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 2 --parallel 2
  [ "$status" -eq 0 ]

  local f
  f="$(find_call "part: 1/2")"
  grep -qF "===== INPUT: STEP1_OUTPUT (01_speakers_utterances.md part 1/2) =====" "$f"
  grep -qF "===== INPUT: CONTEXT_AFTER (01_speakers_utterances.md) =====" "$f"
  grep -qF "SLINE_001" "$f"
  grep -qF "SLINE_012" "$f"
  ! grep -qF "SLINE_013" "$f"
}

@test "54b: --only-step 2 --parallel 2 は 01_parts/ が無くても分割できる" {
  use_call_dir
  given_numbered_step1_output 20

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 2 --parallel 2

  [ "$status" -eq 0 ]
  [ ! -d "$(output_dir)/01_parts" ]
  [ "$(call_count)" -eq 2 ]
  [ -f "$(output_dir)/02_parts/02_part1of2.md" ]
}

@test "55: パート出力が保存され、中間生成物はパートの連結になる" {
  given_numbered_transcript 20
  # 先頭行はステップ1の契約(見出し始まり)を満たす必要がある(§5.5・ケース65)
  printf '## PART_BODY\n' >"$BATS_TEST_TMPDIR/out.txt"
  export STUB_STDOUT_FILE="$BATS_TEST_TMPDIR/out.txt"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2

  [ "$status" -eq 0 ]
  [ -f "$(output_dir)/01_parts/01_part1of2.md" ]
  [ -f "$(output_dir)/01_parts/01_part2of2.md" ]
  [ "$(grep -c '^## PART_BODY$' "$(output_dir)/01_speakers_utterances.md")" -eq 2 ]
}

@test "56: 既存のパートがあれば claude を呼ばずに再利用する" {
  use_call_dir
  given_numbered_transcript 20
  mkdir -p "$(output_dir)/01_parts"
  echo "CACHED_PART_1" >"$(output_dir)/01_parts/01_part1of2.md"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2

  [ "$status" -eq 0 ]
  [ "$(call_count)" -eq 1 ]
  [[ "$output" == *"既存のパートを使用します"* ]]
  grep -qF "CACHED_PART_1" "$(output_dir)/01_speakers_utterances.md"
}

@test "57: 並列度を変えるとパートキャッシュは再利用されない(行範囲の食い違い防止)" {
  use_call_dir
  given_numbered_transcript 20
  mkdir -p "$(output_dir)/01_parts"
  # --parallel 4 で作られたパート
  local i
  for i in 1 2 3 4; do
    echo "STALE_PART_${i}of4" >"$(output_dir)/01_parts/01_part${i}of4.md"
  done

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2

  [ "$status" -eq 0 ]
  [ "$(call_count)" -eq 2 ]
  ! grep -qF "STALE_PART" "$(output_dir)/01_speakers_utterances.md"
}

@test "58: 1パートが失敗したら全パートを待ってからコード3で停止し、中間生成物を確定しない" {
  use_call_dir
  given_numbered_transcript 20
  export STUB_FAIL_ON_STDIN_MATCH="part: 2/2"
  export STUB_EXIT=1

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2

  [ "$status" -eq 3 ]
  [[ "$output" == *"ERROR:"* ]]
  [ ! -f "$(output_dir)/01_speakers_utterances.md" ]
  # 失敗パートの完了を待つ前に抜けていないこと(両パートが実行されている)
  [ "$(call_count)" -eq 2 ]
}

@test "59: 失敗した実行でも成功したパートは残り、再実行で再利用される" {
  use_call_dir
  given_numbered_transcript 20
  export STUB_FAIL_ON_STDIN_MATCH="part: 2/2"
  export STUB_EXIT=1

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2
  [ "$status" -eq 3 ]

  [ -f "$(output_dir)/01_parts/01_part1of2.md" ]
  [ ! -f "$(output_dir)/01_parts/01_part2of2.md" ]

  # 再実行では失敗したパートのみが呼ばれる
  unset STUB_FAIL_ON_STDIN_MATCH
  unset STUB_EXIT
  rm -rf "$STUB_CALL_DIR"
  mkdir -p "$STUB_CALL_DIR"
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2
  [ "$status" -eq 0 ]
  [ "$(call_count)" -eq 1 ]
}

@test "60: 1パートが中断(130)ならコード130で中断として報告する" {
  use_call_dir
  given_numbered_transcript 20
  export STUB_FAIL_ON_STDIN_MATCH="part: 2/2"
  export STUB_EXIT=130

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2

  [ "$status" -eq 130 ]
  [[ "$output" == *"中断されました"* ]]
  [[ "$output" != *"HINT:"* ]]
}

@test "61: --parallel 2 + --dry-run は claude を呼ばず分割計画を表示する" {
  given_numbered_transcript 20

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --parallel 2 --dry-run

  [ "$status" -eq 0 ]
  [ "$(stub_call_count claude)" -eq 0 ]
  [[ "$output" == *"[dry-run]"* ]]
  [[ "$output" == *"2 分割"* ]]
  [ ! -d "$(output_dir)/01_parts" ]
}

@test "62: 分割対象の行数が足りなければ WARN を出して単発実行にフォールバックする" {
  given_numbered_transcript 1 # 1行では分割できない

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 8

  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN:"* ]]
  [ "$(stub_call_count claude)" -eq 1 ]
  ! grep -qF "PART_INFO" "$STUB_STDIN_FILE"
}

@test "62c: 行数が --parallel より少ない場合はパート数が行数に丸められる" {
  use_call_dir
  given_numbered_transcript 3

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 8

  [ "$status" -eq 0 ]
  [ "$(call_count)" -eq 3 ]
  [ "$(call_count_matching "part: 3/3")" -eq 1 ]
}

@test "62b: 分割対象が1つも無ければ WARN を出して単発実行にフォールバックする" {
  # ステップ2の分割対象(ステップ1の中間生成物)が無いケース。
  # 分割の可否判定で die せず、単発経路の前段チェック(コード1)に委ねる。
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 2 --parallel 2

  [ "$status" -eq 1 ]
  [[ "$output" == *"WARN: ステップ2 の分割対象が見つからない"* ]]
  [[ "$output" == *"前段の出力が存在しません"* ]]
  [ "$(stub_call_count claude)" -eq 0 ]
}

@test "63: ステップ3は分割されず PART_INFO を含まない" {
  use_call_dir
  given_numbered_transcript 20

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 3 --parallel 2

  [ "$status" -eq 1 ] # 前段の出力が無いのでエラー(分割経路に入らないことの確認は下で行う)

  rm -rf "$STUB_CALL_DIR"
  mkdir -p "$STUB_CALL_DIR"
  given_step_output 2
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 3 --parallel 2

  [ "$status" -eq 0 ]
  [ "$(call_count)" -eq 1 ]
  [ "$(call_count_matching "PART_INFO")" -eq 0 ]
  [ ! -d "$(output_dir)/03_parts" ]
}

@test "64: 単発実行の失敗時は claude の出力を .error.log に残し、HINT でパスを示す" {
  given_transcript
  export STUB_EXIT=1

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1

  [ "$status" -eq 3 ]
  [ -s "$(output_dir)/01_speakers_utterances.md.error.log" ]
  [[ "$output" == *"01_speakers_utterances.md.error.log"* ]]
  [[ "$output" == *"CLAUDE_CODE_MAX_OUTPUT_TOKENS"* ]]
  # 診断ログの本文(会議内容を含みうる)はメッセージに出さない
  [[ "$output" != *"STUB CLAUDE OUTPUT"* ]]
  [ ! -f "$(output_dir)/01_speakers_utterances.md" ]
}

@test "64b: 空出力での失敗では .error.log を作らず、従来の HINT を出す" {
  given_transcript
  : >"$BATS_TEST_TMPDIR/empty.txt"
  export STUB_STDOUT_FILE="$BATS_TEST_TMPDIR/empty.txt"
  export STUB_EXIT=1

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1

  [ "$status" -eq 3 ]
  [ ! -f "$(output_dir)/01_speakers_utterances.md.error.log" ]
  [[ "$output" == *"認証状態"* ]]
}

@test "64c: 中断(130)では .error.log を残さない" {
  given_transcript
  export STUB_EXIT=130

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1

  [ "$status" -eq 130 ]
  [ ! -f "$(output_dir)/01_speakers_utterances.md.error.log" ]
}

@test "64d: パート失敗時は当該パートの .error.log を残し、HINT で対処を示す" {
  use_call_dir
  given_numbered_transcript 20
  export STUB_FAIL_ON_STDIN_MATCH="part: 2/2"
  export STUB_FAIL_STDOUT="API Error: Claude's response exceeded the 32000 output token maximum."
  export STUB_EXIT=1

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2

  [ "$status" -eq 3 ]
  grep -qF "32000 output token maximum" "$(output_dir)/01_parts/01_part2of2.md.error.log"
  [ ! -f "$(output_dir)/01_parts/01_part2of2.md" ]
  [[ "$output" == *"*.error.log"* ]]
  [[ "$output" == *"CLAUDE_CODE_MAX_OUTPUT_TOKENS"* ]]
}

@test "64e: 再実行でパートが成功したら前回の .error.log は消える" {
  use_call_dir
  given_numbered_transcript 20
  export STUB_FAIL_ON_STDIN_MATCH="part: 2/2"
  export STUB_FAIL_STDOUT="API Error: something went wrong"
  export STUB_EXIT=1

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2
  [ "$status" -eq 3 ]
  [ -f "$(output_dir)/01_parts/01_part2of2.md.error.log" ]

  unset STUB_FAIL_ON_STDIN_MATCH
  unset STUB_FAIL_STDOUT
  unset STUB_EXIT
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2

  [ "$status" -eq 0 ]
  [ -f "$(output_dir)/01_parts/01_part2of2.md" ]
  [ ! -f "$(output_dir)/01_parts/01_part2of2.md.error.log" ]
}

@test "65: 出力の先頭が契約と一致しなければコード3で停止し、部分出力を .truncated.md に残す" {
  given_step_output 2
  echo "PREVIOUS MINUTES" >"$(output_dir)/minutes.md"
  # 自動継続で先頭が失われた出力(本文の途中から始まる)を再現する
  printf '続行で。(サンプルソフト)\n- 以降は残った後半部分\n' >"$BATS_TEST_TMPDIR/out.txt"
  export STUB_STDOUT_FILE="$BATS_TEST_TMPDIR/out.txt"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 3

  [ "$status" -eq 3 ]
  [[ "$output" == *"先頭"* ]]
  [[ "$output" == *"minutes.md.truncated.md"* ]]
  grep -qF "続行で。(サンプルソフト)" "$(output_dir)/minutes.md.truncated.md"
  # 確定済みの成果物は壊さない
  [ "$(cat "$(output_dir)/minutes.md")" = "PREVIOUS MINUTES" ]
  # 診断ログの本文(会議内容を含みうる)はメッセージに出さない
  [[ "$output" != *"以降は残った後半部分"* ]]
}

@test "65b: 見出しで始まる出力は文言を問わず正常終了する(誤検知しない)" {
  given_step_output 2
  printf '# 独自タイトル\n\n続行で。(サンプルソフト)\n' >"$BATS_TEST_TMPDIR/out.txt"
  export STUB_STDOUT_FILE="$BATS_TEST_TMPDIR/out.txt"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 3

  [ "$status" -eq 0 ]
  grep -qF "# 独自タイトル" "$(output_dir)/minutes.md"
  [ ! -f "$(output_dir)/minutes.md.truncated.md" ]
}

@test "65c: パートの先頭が契約と一致しなければコード3で停止し、成功したパートは残る" {
  use_call_dir
  given_numbered_transcript 20
  export STUB_FAIL_ON_STDIN_MATCH="part: 2/2"
  export STUB_FAIL_STDOUT="本文の途中から始まる出力"
  export STUB_EXIT=0 # 自動継続は成功扱い(exit 0)で返る

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1 --parallel 2

  [ "$status" -eq 3 ]
  [[ "$output" == *"先頭"* ]]
  [ ! -f "$(output_dir)/01_parts/01_part2of2.md" ]
  grep -qF "本文の途中から始まる出力" "$(output_dir)/01_parts/01_part2of2.md.truncated.md"
  # 成功したパートは残り、再実行で再利用できる
  [ -f "$(output_dir)/01_parts/01_part1of2.md" ]
  [ ! -f "$(output_dir)/01_speakers_utterances.md" ]
}

@test "65d: 箇条書きで始まるステップ1の出力は正常終了する" {
  given_transcript
  printf -- '- **話者A**: 発言内容\n' >"$BATS_TEST_TMPDIR/out.txt"
  export STUB_STDOUT_FILE="$BATS_TEST_TMPDIR/out.txt"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 1

  [ "$status" -eq 0 ]
  [ -f "$(output_dir)/01_speakers_utterances.md" ]
  [ ! -f "$(output_dir)/01_speakers_utterances.md.truncated.md" ]
}

@test "65e: 再実行で先頭が契約を満たしたら前回の .truncated.md は消える" {
  given_step_output 2
  printf '続行で。(サンプルソフト)\n' >"$BATS_TEST_TMPDIR/out.txt"
  export STUB_STDOUT_FILE="$BATS_TEST_TMPDIR/out.txt"

  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 3
  [ "$status" -eq 3 ]
  [ -f "$(output_dir)/minutes.md.truncated.md" ]

  unset STUB_STDOUT_FILE
  run "$GENERATE" "$TEST_PROJECT" "$TEST_DATE" --only-step 3

  [ "$status" -eq 0 ]
  [ -f "$(output_dir)/minutes.md" ]
  [ ! -f "$(output_dir)/minutes.md.truncated.md" ]
}

@test "65f: 関数: output_head_pattern / verify_output_head はステップ別の契約を判定する" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  local f="$BATS_TEST_TMPDIR/head.md"

  # ステップ1・2: 見出し(#〜######)と箇条書き(- )を受理する
  local step
  for step in 1 2; do
    printf '## 会議情報\n' >"$f"
    run verify_output_head "$step" "$f"
    [ "$status" -eq 0 ]

    printf '###### 深い見出し\n' >"$f"
    run verify_output_head "$step" "$f"
    [ "$status" -eq 0 ]

    printf -- '- **話者A**: 発言\n' >"$f"
    run verify_output_head "$step" "$f"
    [ "$status" -eq 0 ]

    printf '続行で。(サンプルソフト)\n' >"$f"
    run verify_output_head "$step" "$f"
    [ "$status" -ne 0 ]

    # 見出し記号の直後に空白が無い行は Markdown の見出しではない
    printf '#見出しではない\n' >"$f"
    run verify_output_head "$step" "$f"
    [ "$status" -ne 0 ]
  done

  # ステップ3: `# ` のみを受理する
  printf '# 議事録: testproj\n' >"$f"
  run verify_output_head 3 "$f"
  [ "$status" -eq 0 ]

  printf '## 会議概要\n' >"$f"
  run verify_output_head 3 "$f"
  [ "$status" -ne 0 ]

  printf -- '- 発言(話者A)\n' >"$f"
  run verify_output_head 3 "$f"
  [ "$status" -ne 0 ]
}

@test "関数: part_line_range は端数を先頭側のパートへ配分する" {
  # shellcheck source=/dev/null
  source "$GENERATE"

  # 10行を3分割 → 4 / 3 / 3
  [ "$(part_line_range 10 1 3)" = "1 4" ]
  [ "$(part_line_range 10 2 3)" = "5 7" ]
  [ "$(part_line_range 10 3 3)" = "8 10" ]

  # 割り切れる場合
  [ "$(part_line_range 20 1 2)" = "1 10" ]
  [ "$(part_line_range 20 2 2)" = "11 20" ]

  # 1分割は全体
  [ "$(part_line_range 7 1 1)" = "1 7" ]
}
