#!/usr/bin/env bash
# 議事メモ・文字起こしから議事録(Markdown)を生成する3ステップパイプラインの実行エントリポイント。
#
# 設計書:docs/design/02-generate-minutes.md
# 終了コード:0=正常 / 1=想定内エラー / 2=認証エラー / 3=外部コマンド失敗
#            (docs/design/01-conventions.md §4)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AUTH_ENV="$REPO_ROOT/config/auth/active.env"

# 既定値(docs/design/02-generate-minutes.md §1)
readonly DEFAULT_MODEL_SIZE="base"
readonly LAST_STEP=3
# stdin の目安サイズ(docs/design/02-generate-minutes.md §4.1 / 09-decisions.md §2)。
# 環境変数 INPUT_WARN_BYTES で上書きできる。
readonly DEFAULT_INPUT_WARN_BYTES=400000
# 実行中の経過表示の間隔(docs/design/02-generate-minutes.md §5.2)。
# 環境変数 HEARTBEAT_INTERVAL_SECONDS で上書きでき、0 で無効になる。
readonly DEFAULT_HEARTBEAT_INTERVAL_SECONDS=60
# 中断(SIGINT / SIGTERM)を表す終了コード(docs/design/01-conventions.md §4)
readonly EXIT_INTERRUPTED=130
# 出力の先頭が契約と一致しなかったことを表す invoke_claude の内部戻り値
# (docs/design/02-generate-minutes.md §5.5)。**終了コードではない**:利用者へ返すのは
# 外部コマンド失敗と同じ 3 で、終了コード体系(0/1/2/3/130)は変えない。
readonly RET_HEAD_MISMATCH=4
# 分割・並列実行の既定値(docs/design/02-generate-minutes.md §9)。
# 上限8は Bedrock 側のスロットリングを避けるための安全弁(§9.5)。
readonly MAX_PARALLEL=8
# チャンク境界のオーバーラップ行数。環境変数 SPLIT_OVERLAP_LINES で上書きできる。
readonly DEFAULT_SPLIT_OVERLAP_LINES=30

# 途中失敗時に一時ファイルを残さないための後片付け(docs/design/01-conventions.md §6)。
# スクリプトとして実行された場合のみ EXIT トラップを張る(source 時は bats のトラップを壊さない)。
TMP_FILES=()
# 経過表示のバックグラウンドプロセス(docs/design/02-generate-minutes.md §5.2)。
# 空文字なら未起動。放置すると Ctrl+C 後も sleep が残るため EXIT トラップで止める。
HEARTBEAT_PID=""

# 分割実行中の状態(docs/design/02-generate-minutes.md §9.2)。
# run_step / run_step_parts が設定し、emit_step_sections が読む。分割しない場合は
# SPLIT_TARGET を空にする(この状態で従来と同一の stdin になる)。
# サブシェル(パート実行)へは fork 時の値がそのまま引き継がれる。
SPLIT_TARGET=""
SPLIT_LINES=0
SPLIT_OVERLAP=0

register_tmp_file() {
  TMP_FILES+=("$1")
}

cleanup_tmp_files() {
  local file
  stop_heartbeat
  for file in ${TMP_FILES+"${TMP_FILES[@]}"}; do
    rm -f "$file"
  done
}

# 秒数 → 経過表記(docs/design/02-generate-minutes.md §5.2)。
# 60秒未満は「N秒」、それ以上は「N分M秒」。
elapsed_label() {
  local seconds="$1"
  if ((seconds < 60)); then
    echo "${seconds}秒"
  else
    echo "$((seconds / 60))分$((seconds % 60))秒"
  fi
}

# 実行中の経過を定期表示する: start_heartbeat <ラベル>
# 会議内容は出さず、ラベルと経過時間のみを stdout へ出す(docs/design/06-security.md §3)。
start_heartbeat() {
  local label="$1"
  local interval="${HEARTBEAT_INTERVAL_SECONDS:-$DEFAULT_HEARTBEAT_INTERVAL_SECONDS}"

  HEARTBEAT_PID=""
  [[ "$interval" =~ ^[0-9]+$ ]] || return 0
  ((interval > 0)) || return 0

  (
    local waited=0
    while true; do
      sleep "$interval"
      waited=$((waited + interval))
      echo "${label} 実行中 (経過 $(elapsed_label "$waited"))"
    done
  ) &
  HEARTBEAT_PID="$!"
}

stop_heartbeat() {
  [[ -n "$HEARTBEAT_PID" ]] || return 0
  # 既に終了している場合の kill 失敗は正常系なので握りつぶす(docs/design/01-conventions.md §7)
  kill "$HEARTBEAT_PID" 2>/dev/null || true
  wait "$HEARTBEAT_PID" 2>/dev/null || true
  HEARTBEAT_PID=""
}

usage() {
  cat <<'EOF'
usage: generate_minutes.sh <project> <date> [options]

arguments:
  project           projects/{project}/ に対応するプロジェクト名
  date              YYYY-MM-DD 形式の会議日

options:
  --from-step N     ステップ N から最終ステップ(3)まで実行(N=1..3、既定 1)
  --only-step N     ステップ N のみ実行(N=0..3。0 は文字起こしのみ)
  --model-size S    ステップ0の faster-whisper モデルサイズ(既定 base)
  --parallel N      ステップ1・2を N 分割して並列実行(N=1..8、既定 1 = 分割しない)
  --dry-run         claude / transcribe.py を実行せず、実行計画のみ出力
  -h, --help        使い方を表示して終了(終了コード 0)
EOF
}

# die <code> <ERROR文> [HINT文]
die() {
  local code="$1" message="$2" hint="${3:-}"
  echo "ERROR: $message" >&2
  if [[ -n "$hint" ]]; then
    echo "HINT:  $hint" >&2
  fi
  exit "$code"
}

# usage を stderr に出して終了する(引数不正時)
die_usage() {
  echo "ERROR: $1" >&2
  usage >&2
  exit 1
}

# 数値かつ min..max の範囲内であることを検証する
validate_step() {
  local option="$1" value="$2" min="$3" max="$4"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    die 1 "$option の値が数値ではありません: $value" \
      "$option には ${min}〜${max} の整数を指定してください。"
  fi
  if ((value < min || value > max)); then
    die 1 "$option の値が範囲外です: $value" \
      "$option には ${min}〜${max} の整数を指定してください。"
  fi
}

# オプションに値が続いていることを確認する
require_value() {
  local option="$1" count="$2"
  if ((count < 2)); then
    die 1 "$option に値が指定されていません。" \
      "$option <値> の形式で指定してください。"
  fi
}

# 引数を解析し、グローバル変数 PROJECT / MEETING_DATE / FROM_STEP / TO_STEP /
# MODEL_SIZE / PARALLEL / DRY_RUN を設定する(docs/design/02-generate-minutes.md §1)。
parse_args() {
  PROJECT=""
  MEETING_DATE=""
  MODEL_SIZE="$DEFAULT_MODEL_SIZE"
  PARALLEL=1
  DRY_RUN=0

  local from_step="" only_step="" parallel=""
  local positional=()

  while (($# > 0)); do
    case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --from-step)
      require_value "$1" "$#"
      from_step="$2"
      shift 2
      ;;
    --only-step)
      require_value "$1" "$#"
      only_step="$2"
      shift 2
      ;;
    --model-size)
      require_value "$1" "$#"
      MODEL_SIZE="$2"
      shift 2
      ;;
    --parallel)
      require_value "$1" "$#"
      parallel="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -*)
      die_usage "不明なオプションです: $1"
      ;;
    *)
      positional+=("$1")
      shift
      ;;
    esac
  done

  if ((${#positional[@]} < 2)); then
    die_usage "引数が不足しています(project と date は必須です)。"
  fi
  if ((${#positional[@]} > 2)); then
    die_usage "引数が多すぎます: ${positional[*]}"
  fi

  PROJECT="${positional[0]}"
  MEETING_DATE="${positional[1]}"

  # パストラバーサル防止(docs/design/01-conventions.md §2)
  if [[ ! "$PROJECT" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$PROJECT" == "." ]] || [[ "$PROJECT" == ".." ]]; then
    die 1 "project の形式が不正です: $PROJECT" \
      "project には英数字・ドット・アンダースコア・ハイフンのみを使用してください(/ や .. は使用できません)。"
  fi
  if [[ ! "$MEETING_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    die 1 "date の形式が不正です(YYYY-MM-DD): $MEETING_DATE" \
      "date は 2026-08-16 のように YYYY-MM-DD 形式で指定してください。"
  fi

  if [[ -n "$from_step" && -n "$only_step" ]]; then
    die 1 "--from-step と --only-step は同時に指定できません。" \
      "途中から最終ステップまで実行する場合は --from-step、1ステップだけ実行する場合は --only-step を使用してください。"
  fi

  # 並列度は範囲検証を validate_step で共用する(docs/design/02-generate-minutes.md §1)
  if [[ -n "$parallel" ]]; then
    validate_step "--parallel" "$parallel" 1 "$MAX_PARALLEL"
    PARALLEL="$parallel"
  fi

  if [[ -n "$only_step" ]]; then
    validate_step "--only-step" "$only_step" 0 "$LAST_STEP"
    FROM_STEP="$only_step"
    TO_STEP="$only_step"
  elif [[ -n "$from_step" ]]; then
    validate_step "--from-step" "$from_step" 1 "$LAST_STEP"
    FROM_STEP="$from_step"
    TO_STEP="$LAST_STEP"
  else
    FROM_STEP=1
    TO_STEP="$LAST_STEP"
  fi
}

# active.env があれば読み込む。無ければ既存の環境変数をそのまま使う(要件7.2)。
# 認証経路ごとの分岐は持たない(CLAUDE.md 4章)。
load_auth_env() {
  if [[ -f "$AUTH_ENV" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$AUTH_ENV"
    set +a
  fi
}

# 入出力パスを解決し、OUTPUT_DIR を作成する(docs/design/01-conventions.md §1)。
resolve_paths() {
  INPUT_DIR="$REPO_ROOT/inputs/$PROJECT/$MEETING_DATE"
  OUTPUT_DIR="$REPO_ROOT/outputs/$PROJECT/$MEETING_DATE"
  PROJECT_DIR="$REPO_ROOT/projects/$PROJECT"
  PROMPT_DIR="$PROJECT_DIR/prompts"
  CONFIG_FILE="$PROJECT_DIR/config.yaml"
  TRANSCRIPT_FILE="$OUTPUT_DIR/00_transcript.txt"
  TRANSCRIPT_PARTS_DIR="$OUTPUT_DIR/00_transcript_parts"

  mkdir -p "$OUTPUT_DIR"
}

# ステップ番号 → システムプロンプトのパス
step_prompt_file() {
  case "$1" in
  1) echo "$PROMPT_DIR/01_organize.md" ;;
  2) echo "$PROMPT_DIR/02_structure.md" ;;
  3) echo "$PROMPT_DIR/03_format.md" ;;
  *) die 1 "不正なステップ番号です: $1" ;;
  esac
}

# ステップ番号 → 出力ファイルのパス
step_output_file() {
  case "$1" in
  1) echo "$OUTPUT_DIR/01_speakers_utterances.md" ;;
  2) echo "$OUTPUT_DIR/02_structured_conversation.md" ;;
  3) echo "$OUTPUT_DIR/minutes.md" ;;
  *) die 1 "不正なステップ番号です: $1" ;;
  esac
}

# プロジェクト資産(config.yaml + プロンプト3種)の存在を確認する。
validate_project() {
  if [[ ! -d "$PROJECT_DIR" ]]; then
    die 1 "プロジェクトが見つかりません: projects/$PROJECT" \
      "cp -r projects/_template projects/$PROJECT でプロジェクトを作成してください。"
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    die 1 "プロジェクト設定が見つかりません: projects/$PROJECT/config.yaml" \
      "cp -r projects/_template projects/$PROJECT でひな形をコピーし、話者・会社名を記入してください。"
  fi

  local step prompt
  for step in 1 2 3; do
    prompt="$(step_prompt_file "$step")"
    if [[ ! -f "$prompt" ]]; then
      die 1 "プロンプトが見つかりません: projects/$PROJECT/prompts/$(basename "$prompt")" \
        "projects/_template/prompts/ からコピーしてください。"
    fi
  done
}

# 入力の存在を確認する。議事メモ / メディア / 既存の文字起こしのいずれか1つで足りる。
validate_inputs() {
  if [[ ! -d "$INPUT_DIR" ]]; then
    die 1 "入力ディレクトリが見つかりません: inputs/$PROJECT/$MEETING_DATE" \
      "inputs/$PROJECT/$MEETING_DATE/ を作成し、議事メモ(.md / .txt)または録画ファイルを配置してください。"
  fi

  local memos media
  memos="$(find_memo_files)"
  media="$(find_media_files)"
  if [[ -z "$memos" && -z "$media" && ! -f "$TRANSCRIPT_FILE" ]]; then
    die 1 "入力が見つかりません: inputs/$PROJECT/$MEETING_DATE" \
      "議事メモ(.md / .txt)または録画・音声ファイルを配置してください(既存の文字起こしがある場合は outputs/$PROJECT/$MEETING_DATE/00_transcript.txt)。"
  fi
}

# INPUT_DIR 直下から指定拡張子のファイルを1行1件で出力する。
# 並びは LC_ALL=C のファイル名昇順(ロケール差で順序が変わらないようにする)。
find_input_files() {
  local -a exts=("$@")
  local file ext want
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    # 小文字化は tr で行う(${var,,} は Bash 4.0+ 専用。01-conventions.md §8)
    ext="$(printf '%s' "${file##*.}" | tr '[:upper:]' '[:lower:]')"
    for want in "${exts[@]}"; do
      if [[ "$ext" == "$want" ]]; then
        echo "$file"
        break
      fi
    done
  done < <(find "$INPUT_DIR" -maxdepth 1 -type f | LC_ALL=C sort)
}

# INPUT_DIR 直下の議事メモ候補を全件出力する(docs/design/02-generate-minutes.md §4.2)。
# 固定名 memo.md には依存しない(依存すると別名で置かれたメモが無言で落ちる)。
find_memo_files() {
  find_input_files md txt
}

# INPUT_DIR 直下のメディア候補を全件出力する(docs/design/02-generate-minutes.md §6)。
# 会議の中断・再開で1会議が複数ファイルに分割されるため、複数件をエラーにしない。
find_media_files() {
  find_input_files mp4 m4a mp3 wav mov webm aac flac
}

# 前段の中間生成物が存在することを確認する(docs/design/02-generate-minutes.md §3)。
require_prev_output() {
  local step="$1" prev file
  prev=$((step - 1))
  file="$(step_output_file "$prev")"
  if [[ ! -f "$file" ]]; then
    die 1 "前段の出力が存在しません: $(basename "$file")" \
      "先に --from-step $prev(または --from-step 1)で実行してください。"
  fi
}

# 区切りヘッダ付きでファイル内容を出力する: emit_section <ラベル> <ファイルパス>
# ファイル名は basename のみを書き、絶対パスを出さない(docs/design/02-generate-minutes.md §4)。
emit_section() {
  local label="$1" file="$2"
  printf '===== INPUT: %s (%s) =====\n' "$label" "$(basename "$file")"
  cat "$file"
  printf '\n'
}

# 区切りヘッダ付きで文字列を出力する: emit_labeled_lines <ラベル> <表示名> <本文>
# emit_section のファイル版に対する文字列版(PART_INFO / CONTEXT_* / チャンク本体で使う。§9.2)。
emit_labeled_lines() {
  local label="$1" display="$2" text="$3"
  printf '===== INPUT: %s (%s) =====\n' "$label" "$display"
  printf '%s\n' "$text"
  printf '\n'
}

# ステップ N の分割対象を1件だけ stdout に出力する(docs/design/02-generate-minutes.md §9.1)。
# 候補が無ければ空出力。ステップごとに独立して解決し、パート境界を引き継がない
# (--from-step 2 のような部分再実行でも分割できるようにするため)。
split_target_file() {
  local file
  case "$1" in
  1)
    if [[ -f "$TRANSCRIPT_FILE" ]]; then
      echo "$TRANSCRIPT_FILE"
    else
      largest_memo_file
    fi
    ;;
  2)
    file="$(step_output_file 1)"
    if [[ -f "$file" ]]; then
      echo "$file"
    fi
    ;;
  *)
    # ステップ3は分割しない(凝縮処理で出力が小さい。§9 冒頭)
    ;;
  esac
}

# 議事メモのうち最大バイト数のものを stdout に出力する(0件なら空出力)。
# 「最大のメモを分割対象にする」という規則を実行時に検証できるよう、選択結果は
# announce_split_plan が列挙する(§9.1)。
largest_memo_file() {
  local memo best="" best_bytes=0 bytes
  while IFS= read -r memo; do
    [[ -n "$memo" ]] || continue
    bytes="$(wc -c <"$memo")"
    if ((bytes > best_bytes)); then
      best="$memo"
      best_bytes="$bytes"
    fi
  done < <(find_memo_files)
  [[ -z "$best" ]] || echo "$best"
}

# 分割対象のファイルパス → §4 のラベル(分割時もラベル体系を崩さない。§9.1)。
split_target_label() {
  if [[ "$1" == "$TRANSCRIPT_FILE" ]]; then
    echo "TRANSCRIPT"
  elif [[ "$1" == "$(step_output_file 1)" ]]; then
    echo "STEP1_OUTPUT"
  else
    echo "MEETING_MEMO"
  fi
}

# パート数を決める: split_part_total <分割対象>
# min(PARALLEL, 行数) に丸める。対象が無い・行数が足りない場合は 1(単発実行)。
split_part_total() {
  local target="$1" lines
  if [[ -z "$target" || ! -f "$target" ]]; then
    echo 1
    return 0
  fi
  lines="$(count_lines "$target")"
  if ((lines < PARALLEL)); then
    echo "$lines"
  else
    echo "$PARALLEL"
  fi
}

# ファイルの行数を出力する(最終行に改行が無い場合も1行として数える)
count_lines() {
  awk 'END {print NR}' "$1"
}

# そのパートの本体行範囲を「<開始行> <終了行>」の形で出力する(§9.2)。
# 端数は先頭側のパートへ1行ずつ配分し、パート間の行数差を1以内に収める。
part_line_range() {
  local total="$1" index="$2" parts="$3"
  local base=$((total / parts)) rem=$((total % parts))
  local start size extra=$((index - 1))

  ((extra <= rem)) || extra="$rem"
  start=$(((index - 1) * base + extra + 1))
  size="$base"
  ((index > rem)) || size=$((base + 1))
  echo "$start $((start + size - 1))"
}

# 指定行範囲を出力する(範囲が空なら空出力)
extract_lines() {
  local file="$1" start="$2" end="$3"
  ((end >= start)) || return 0
  sed -n "${start},${end}p" "$file"
}

# 分割対象の本体チャンクと前後のオーバーラップを出力する: emit_part_sections <ラベル> <番号> <総数>
# オーバーラップは本体と別ラベルで渡す。連結時の重複除去は行わない(§9.2 / 09-decisions.md §5.2)。
emit_part_sections() {
  local label="$1" index="$2" total="$3"
  local name range start end from to text
  name="$(basename "$SPLIT_TARGET")"
  range="$(part_line_range "$SPLIT_LINES" "$index" "$total")"
  start="${range% *}"
  end="${range#* }"

  if ((index > 1 && SPLIT_OVERLAP > 0)); then
    from=$((start - SPLIT_OVERLAP))
    ((from > 0)) || from=1
    text="$(extract_lines "$SPLIT_TARGET" "$from" "$((start - 1))")"
    [[ -z "$text" ]] || emit_labeled_lines "CONTEXT_BEFORE" "$name" "$text"
  fi

  emit_labeled_lines "$label" "${name} part ${index}/${total}" \
    "$(extract_lines "$SPLIT_TARGET" "$start" "$end")"

  if ((index < total && SPLIT_OVERLAP > 0)); then
    to=$((end + SPLIT_OVERLAP))
    ((to <= SPLIT_LINES)) || to="$SPLIT_LINES"
    text="$(extract_lines "$SPLIT_TARGET" "$((end + 1))" "$to")"
    [[ -z "$text" ]] || emit_labeled_lines "CONTEXT_AFTER" "$name" "$text"
  fi
}

# ステップ N の入力セクションをすべて stdout へ出力する(docs/design/02-generate-minutes.md §4)。
# 存在しない入力のヘッダは出力しない(空セクションを作らない)。
# build_step_input から $() 経由で呼ぶ。case を $() の中に直接書くと Bash 3.2 が
# 解釈できないため、独立した関数に切り出している(01-conventions.md §8)。
emit_step_sections() {
  local step="$1" part_index="${2:-1}" part_total="${3:-1}"
  local memo
  local -a memos=()

  emit_section "PROJECT_CONFIG" "$CONFIG_FILE"
  # 分割実行時のみ通し番号を渡す。`会議情報` を先頭パートのみが出力する判定に使う(§9.2)
  if ((part_total > 1)); then
    emit_labeled_lines "PART_INFO" "part" "part: ${part_index}/${part_total}"
  fi
  case "$step" in
  1)
    # 議事メモは全件を個別セクションとして渡す(docs/design/02-generate-minutes.md §4.2)
    # while read で配列に積む(一括読み込みは Bash 4.0+ 専用。01-conventions.md §8)
    while IFS= read -r memo; do
      [[ -n "$memo" ]] || continue
      # 分割対象のメモは本体チャンクとして渡すため、全文セクションには出さない(§9.1)
      [[ "$memo" != "$SPLIT_TARGET" ]] || continue
      memos+=("$memo")
    done < <(find_memo_files)
    for memo in ${memos+"${memos[@]}"}; do
      emit_section "MEETING_MEMO" "$memo"
    done
    if ((part_total > 1)); then
      emit_part_sections "$(split_target_label "$SPLIT_TARGET")" "$part_index" "$part_total"
    elif [[ -f "$TRANSCRIPT_FILE" ]]; then
      emit_section "TRANSCRIPT" "$TRANSCRIPT_FILE"
    fi
    ;;
  2)
    require_prev_output 2
    if ((part_total > 1)); then
      emit_part_sections "STEP1_OUTPUT" "$part_index" "$part_total"
    else
      emit_section "STEP1_OUTPUT" "$(step_output_file 1)"
    fi
    ;;
  3)
    require_prev_output 3
    emit_section "STEP2_OUTPUT" "$(step_output_file 2)"
    ;;
  *)
    die 1 "不正なステップ番号です: $step"
    ;;
  esac
  printf '===== END OF INPUT =====\n'
}

# ステップ N の stdin テキストを stdout に組み立てる(docs/design/02-generate-minutes.md §4)。
build_step_input() {
  local step="$1" part_index="${2:-1}" part_total="${3:-1}"
  local text

  text="$(emit_step_sections "$step" "$part_index" "$part_total")"

  warn_if_input_too_large "$step" "$text"
  printf '%s\n' "$text"
}

# 入力サイズが目安を超える場合に WARN を出す(docs/design/02-generate-minutes.md §4.1)。
# 警告のみで処理は継続する。会議内容そのものは出力しない。
warn_if_input_too_large() {
  local step="$1" text="$2"
  local threshold="${INPUT_WARN_BYTES:-$DEFAULT_INPUT_WARN_BYTES}"
  local bytes
  bytes="$(printf '%s\n' "$text" | wc -c)"

  if ((bytes > threshold)); then
    echo "WARN: ステップ${step}の入力が大きすぎる可能性があります (${bytes} バイト / 目安 ${threshold} バイト)。" >&2
    echo "HINT:  --parallel N を指定してステップ1・2を分割・並列実行してください(例: --parallel 4)。" >&2
  fi
}

# ステップ番号 → 使用するモデルID(docs/design/02-generate-minutes.md §5.1)。
# ANTHROPIC_MODEL_STEP{N} があればそれ、無ければ ANTHROPIC_MODEL(要件3.4)。
# 環境変数を読むだけに留め、認証経路ごとの分岐は持たない(CLAUDE.md 4章)。
step_model() {
  local override=""
  case "$1" in
  1) override="${ANTHROPIC_MODEL_STEP1:-}" ;;
  2) override="${ANTHROPIC_MODEL_STEP2:-}" ;;
  3) override="${ANTHROPIC_MODEL_STEP3:-}" ;;
  *) die 1 "不正なステップ番号です: $1" ;;
  esac

  if [[ -n "$override" ]]; then
    echo "$override"
  else
    echo "$ANTHROPIC_MODEL"
  fi
}

# ステップ番号 → 進捗表示用の名称(要件3.2.1〜3.2.3)
step_label() {
  case "$1" in
  1) echo "話者・発言の整理" ;;
  2) echo "会話の構造化" ;;
  3) echo "議事録フォーマット" ;;
  *) die 1 "不正なステップ番号です: $1" ;;
  esac
}

# 進捗表示用にリポジトリルートからの相対パスへ変換する(絶対パスを並べない)
repo_relative() {
  echo "${1#"$REPO_ROOT"/}"
}

# `claude` 呼び出しを閉じ込める唯一の関数(docs/design/02-generate-minutes.md §5)。
# CLAUDE.md の混入を防ぐため --bare と「リポジトリ外の空ディレクトリでの実行」を併用する
# (二重防御・要件3.2.7、docs/design/09-decisions.md §1)。
# ステップ番号 → 出力の1行目が満たすべき正規表現(docs/design/02-generate-minutes.md §5.5)。
# 見出しの文言ではなく Markdown の構造で判定する(プロンプトの文言を変えても誤検知しない)。
output_head_pattern() {
  case "$1" in
  1 | 2) echo '^(#{1,6} |- )' ;; # ## 会議情報 / ## トピック: / 発言の箇条書き
  3) echo '^# ' ;;               # # 議事録: <project>
  *) die 1 "不正なステップ番号です: $1" ;;
  esac
}

# 出力の1行目が契約を満たすか検証する: verify_output_head <ステップ> <ファイル>
# 出力上限に達すると claude は応答を自動継続するが、-p が返すのは最後の応答だけなので
# 先頭が失われた出力が終了コード0で確定してしまう。自動継続は行の途中から再開するため、
# 1行目の構造を見れば検知できる(要件3.2.5、docs/design/09-decisions.md §6.5)。
# 空ファイルは invoke_claude の -s チェックが先に弾くため、ここでは扱わない。
verify_output_head() {
  local step="$1" file="$2" pattern head
  pattern="$(output_head_pattern "$step")"
  IFS= read -r head <"$file" || true # 改行が無い1行だけの出力でも読み取る
  [[ "$head" =~ $pattern ]]
}

invoke_claude() {
  local system_prompt="$1" stdin_file="$2" dest_file="$3" model="$4" step="$5"
  local work_dir status

  work_dir="$(mktemp -d)" # CLAUDE.md を含まない空ディレクトリ
  # 失敗は `|| status=$?` で受ける。グローバルな set -e を触ると呼び出し元
  # (run_step)の set +e まで解除してしまい、die の前にシェルが終了して
  # ERROR / HINT が出なくなる(docs/design/01-conventions.md §7)。
  status=0
  (cd "$work_dir" && claude -p \
    --bare \
    --system-prompt-file "$system_prompt" \
    --tools "" \
    --model "$model") <"$stdin_file" >"$dest_file" || status=$?
  rm -rf "$work_dir" # 失敗が正常系ではないため || true を付けない

  # 中断(SIGINT / SIGTERM)は外部コマンド失敗と区別する。同一視すると認証・入力サイズを
  # 見直させる的外れな HINT を出してしまう(docs/design/01-conventions.md §4)。
  if ((status == 130 || status == 143)); then
    return "$EXIT_INTERRUPTED"
  fi

  [[ $status -eq 0 ]] || return 3
  [[ -s "$dest_file" ]] || return 3 # 空出力は成功扱いにしない
  # 先頭が欠けた出力(応答の自動継続)を成功扱いにしない(§5.5)
  verify_output_head "$step" "$dest_file" || return "$RET_HEAD_MISMATCH"
}

# 失敗した claude の出力を診断用に残す:
#   preserve_failure_output <一時ファイル> <確定先パス> <退避先の拡張子>
# `claude` は API エラー(出力トークン上限など)を stdout へ書くため、一時ファイルを
# そのまま消すと失敗の原因が一切分からなくなる(docs/design/02-generate-minutes.md §5.4)。
# 拡張子は .error.log(エラーメッセージ)/ .truncated.md(先頭が欠けた部分出力。§5.5)の
# いずれかで、性質が違うため同じファイル名に混ぜない。
# 残せた場合はそのパスを stdout へ出力し、残す中身が無い場合は 1 を返す。
# 中身は会議内容を含みうるため、メッセージには本文を出さずパスのみを示す
# (docs/design/06-security.md §3)。
preserve_failure_output() {
  local tmp_out="$1" base="$2" suffix="$3" log

  log="${base}${suffix}"
  if [[ -s "$tmp_out" ]]; then
    mv "$tmp_out" "$log"
    echo "$log"
    return 0
  fi
  rm -f "$tmp_out"
  return 1
}

# 失敗の種類に応じた退避先の拡張子(docs/design/02-generate-minutes.md §5.4・§5.5)
failure_output_suffix() {
  if (($1 == RET_HEAD_MISMATCH)); then
    echo ".truncated.md" # 先頭が欠けた部分出力(後半は残っている)
  else
    echo ".error.log" # claude が stdout へ書いたエラーメッセージ
  fi
}

# 成功時に前回失敗の退避ファイルを消す(古い原因を残して誤読させない。§5.4・§5.5)
remove_failure_outputs() {
  rm -f "${1}.error.log" "${1}.truncated.md"
}

# ステップ N を実行する。成功時のみ mv で出力を確定する(docs/design/01-conventions.md §6)。
run_step() {
  local step="$1"
  local prompt out label model stdin_file tmp_out status started_at
  local target part_total error_log

  prompt="$(step_prompt_file "$step")"
  out="$(step_output_file "$step")"
  label="$(step_label "$step")"

  # 分割・並列実行の可否を判定する(§9.1)。PARALLEL=1(既定)ではこの経路に入らず、
  # 従来と完全に同一の stdin・呼び出し回数を保つ(要件3.2.8のオプト・イン)。
  SPLIT_TARGET=""
  SPLIT_LINES=0
  SPLIT_OVERLAP=0
  if ((PARALLEL > 1)) && ((step <= 2)); then
    target="$(split_target_file "$step")"
    part_total="$(split_part_total "$target")"
    if ((part_total > 1)); then
      run_step_parts "$step" "$target" "$part_total"
      return 0
    fi
    # 分割できない場合は die せず単発実行へ落とす(並列指定は高速化の希望であって必須要件ではない)
    ((DRY_RUN == 1)) || warn_split_fallback "$step" "$target"
  fi

  if ((DRY_RUN == 1)); then
    echo "[dry-run] ステップ${step} (${label}): $(repo_relative "$prompt") → $(repo_relative "$out")"
    return 0
  fi

  echo "ステップ${step} (${label}) を実行します"

  stdin_file="$(mktemp "${TMPDIR:-/tmp}/minutes_step${step}_stdin.XXXXXX")"
  register_tmp_file "$stdin_file"
  build_step_input "$step" >"$stdin_file"

  tmp_out="$(mktemp "${out}.XXXXXX")"
  register_tmp_file "$tmp_out"

  model="$(step_model "$step")"
  started_at="$SECONDS"
  start_heartbeat "ステップ${step}"
  status=0
  invoke_claude "$prompt" "$stdin_file" "$tmp_out" "$model" "$step" || status=$?
  stop_heartbeat

  rm -f "$stdin_file"
  if ((status != 0)); then
    error_log=""
    if ((status == EXIT_INTERRUPTED)); then
      rm -f "$tmp_out" # 中断は診断対象ではないため書きかけを残さない
    else
      error_log="$(preserve_failure_output "$tmp_out" "$out" "$(failure_output_suffix "$status")")" || error_log=""
    fi
    die_step_failure "$step" "$status" "$error_log"
  fi

  remove_failure_outputs "$out" # 前回失敗時の退避ファイルは成功時に消す(古い原因を残さない)
  mv "$tmp_out" "$out"
  echo "ステップ${step} 完了: $(repo_relative "$out") (所要 $(elapsed_label $((SECONDS - started_at))))"
}

# 分割対象の一覧を進捗へ出す(規則を利用者が実行時に検証できるようにする。§9.1)。
# 会議内容は出さず、ファイル名・行数のみを出す(docs/design/06-security.md §3)。
announce_split_plan() {
  local step="$1" target="$2" total="$3" lines="$4" overlap="$5"

  echo "ステップ${step} を ${total} 分割して並列実行します"
  echo "  分割対象: $(basename "$target") ($(split_target_label "$target")) / ${lines} 行"
  echo "  オーバーラップ: ${overlap} 行"
}

# 分割できずに単発実行へ落とす旨を警告する(§9.1)
warn_split_fallback() {
  local step="$1" target="$2"

  if [[ -z "$target" ]]; then
    echo "WARN: ステップ${step} の分割対象が見つからないため、分割せず単発で実行します。" >&2
  else
    echo "WARN: $(basename "$target") の行数が --parallel の指定に足りないため、ステップ${step} を分割せず単発で実行します。" >&2
  fi
}

# ステップ番号 → パート出力の格納先(§9.4)
step_part_dir() {
  case "$1" in
  1) echo "$OUTPUT_DIR/01_parts" ;;
  2) echo "$OUTPUT_DIR/02_parts" ;;
  *) die 1 "分割できないステップ番号です: $1" ;;
  esac
}

# パート出力のパス: step_part_file <ステップ> <パート番号> <パート総数>
# 総数をファイル名に含めることで、並列度を変えた再実行が別のキャッシュ空間になる(§9.4)。
step_part_file() {
  printf '%s/0%s_part%sof%s.md\n' "$(step_part_dir "$1")" "$1" "$2" "$3"
}

# パート出力を番号順に単純結合して stdout へ出力する(パートマーカーは挿入しない。§9.4)
concat_step_parts() {
  local step="$1" total="$2" index
  for ((index = 1; index <= total; index++)); do
    cat "$(step_part_file "$step" "$index" "$total")"
  done
}

# パート1つ分を実行する(サブシェルで呼ぶ)。
# die はサブシェルで呼ばず、終了コードで親へ返す(docs/design/01-conventions.md §8.4)。
# 一時ファイルは EXIT トラップが届かないため自前で消す。
run_one_part() {
  local step="$1" index="$2" total="$3" prompt="$4" model="$5"
  local part stdin_file tmp_out status started_at

  part="$(step_part_file "$step" "$index" "$total")"
  if [[ -f "$part" ]]; then
    echo "ステップ${step} パート ${index}/${total}: 既存のパートを使用します: $(repo_relative "$part")"
    return 0
  fi

  started_at="$SECONDS"
  stdin_file="$(mktemp "${TMPDIR:-/tmp}/minutes_step${step}_part${index}_stdin.XXXXXX")"
  tmp_out="$(mktemp "${part}.XXXXXX")"

  status=0
  build_step_input "$step" "$index" "$total" >"$stdin_file" || status=$?
  if ((status == 0)); then
    invoke_claude "$prompt" "$stdin_file" "$tmp_out" "$model" "$step" || status=$?
  fi
  rm -f "$stdin_file"

  if ((status != 0)); then
    if ((status == EXIT_INTERRUPTED)); then
      rm -f "$tmp_out" # 中断は診断対象ではない
    else
      # 退避先のパスは親へ返せない(サブシェル)。親は *.error.log / *.truncated.md として HINT で示す。
      preserve_failure_output "$tmp_out" "$part" "$(failure_output_suffix "$status")" >/dev/null || true # 残す中身が無い場合の1は正常系
    fi
    return "$status"
  fi

  remove_failure_outputs "$part" # 前回失敗時の退避ファイルは成功時に消す
  mv "$tmp_out" "$part"
  echo "ステップ${step} パート ${index}/${total} 完了 (経過 $(elapsed_label $((SECONDS - started_at))))"
}

# ステップ N をパート単位で並列実行し、全パートを連結して確定する(§9.3)。
# 並列化は PID 集約方式(wait -n は Bash 4.3+ 専用のため使わない。01-conventions.md §8.4)。
run_step_parts() {
  local step="$1" target="$2" total="$3"
  local prompt out label model tmp_out
  local index pid status started_at failed=0 failed_part=0
  local -a pids=()

  prompt="$(step_prompt_file "$step")"
  out="$(step_output_file "$step")"
  label="$(step_label "$step")"

  SPLIT_TARGET="$target"
  SPLIT_LINES="$(count_lines "$target")"
  SPLIT_OVERLAP="${SPLIT_OVERLAP_LINES:-$DEFAULT_SPLIT_OVERLAP_LINES}"

  announce_split_plan "$step" "$target" "$total" "$SPLIT_LINES" "$SPLIT_OVERLAP"

  if ((DRY_RUN == 1)); then
    echo "[dry-run] ステップ${step} (${label}): $(repo_relative "$prompt") → $(repo_relative "$out") (${total}パート)"
    return 0
  fi

  mkdir -p "$(step_part_dir "$step")"
  model="$(step_model "$step")"
  started_at="$SECONDS"
  # ハートビートはステップ全体に1つだけ起動する(パートごとだと出力が混み合う。§9.3)
  start_heartbeat "ステップ${step}"

  for ((index = 1; index <= total; index++)); do
    run_one_part "$step" "$index" "$total" "$prompt" "$model" &
    pids+=("$!")
  done

  # 1つ失敗しても残りの wait を打ち切らない(打ち切るとジョブが孤児になる。§9.3)
  index=0
  for pid in ${pids+"${pids[@]}"}; do
    index=$((index + 1))
    status=0
    wait "$pid" || status=$?
    if ((status != 0)); then
      # 報告の優先順は 中断(130) > 先頭不一致(4) > その他の失敗(3)。
      # 先頭不一致は原因と対処が特有(§5.5)なため、他の失敗に埋もれさせない。
      if ((status == EXIT_INTERRUPTED)) ||
        ((status == RET_HEAD_MISMATCH && failed != EXIT_INTERRUPTED)) ||
        ((failed != EXIT_INTERRUPTED && failed != RET_HEAD_MISMATCH)); then
        failed="$status"
        failed_part="$index"
      fi
    fi
  done
  stop_heartbeat

  if ((failed == EXIT_INTERRUPTED)); then
    die "$EXIT_INTERRUPTED" "中断されました(step $step)。"
  fi
  if ((failed == RET_HEAD_MISMATCH)); then
    die 3 "ステップ${step} のパート ${failed_part}/${total} の出力の先頭が契約と一致しません。中間生成物は確定していません。" \
      "出力トークン上限に達して claude が応答を自動継続し、先頭部分が失われた可能性があります。残った部分出力は $(repo_relative "$(step_part_dir "$step")")/*.truncated.md にあります。1回の呼び出しの出力量を減らして再実行してください(CLAUDE_CODE_DISABLE_THINKING=1 で thinking を止めて本文へ予算を回す、または --parallel を増やして1パートを小さくする)。完了したパートは再実行時にそのまま再利用されます。"
  fi
  if ((failed != 0)); then
    die 3 "ステップ${step} のパート ${failed_part}/${total} の生成に失敗しました。" \
      "失敗した claude の出力は $(repo_relative "$(step_part_dir "$step")")/*.error.log に残ります。API Error の記載を確認してください(出力トークン上限の場合は --parallel を増やして1パートを小さくする、または CLAUDE_CODE_MAX_OUTPUT_TOKENS を上げる)。完了したパートは再実行時にそのまま再利用されます。"
  fi

  # 全パートが揃ってから連結し、成功時のみ確定する(docs/design/01-conventions.md §6)
  tmp_out="$(mktemp "${out}.XXXXXX")"
  register_tmp_file "$tmp_out"
  concat_step_parts "$step" "$total" >"$tmp_out"
  mv "$tmp_out" "$out"
  echo "ステップ${step} 完了: $(repo_relative "$out") (所要 $(elapsed_label $((SECONDS - started_at))))"
}

# ステップの失敗を報告して終了する: die_step_failure <ステップ> <終了コード> [退避ファイル]
# 中断(130)は失敗(3)と区別し、HINT を出さない(docs/design/02-generate-minutes.md §5.3)。
# 先頭不一致(RET_HEAD_MISMATCH=4)は原因・対処が異なるため専用のメッセージを出すが、
# 利用者へ返す終了コードは他の失敗と同じ 3 とする(§5.5)。
die_step_failure() {
  local step="$1" status="$2" error_log="${3:-}"
  local hint

  if ((status == EXIT_INTERRUPTED)); then
    die "$EXIT_INTERRUPTED" "中断されました(step $step)。"
  fi
  if ((status == RET_HEAD_MISMATCH)); then
    hint="出力トークン上限に達して claude が応答を自動継続し、先頭部分が失われた可能性があります。"
    if [[ -n "$error_log" ]]; then
      hint="$hint 残った部分出力は $(repo_relative "$error_log") にあります。"
    fi
    hint="$hint 1回の呼び出しの出力量を減らして再実行してください(CLAUDE_CODE_DISABLE_THINKING=1 で thinking を止めて本文へ予算を回す / --parallel を増やして1パートを小さくする / projects/$PROJECT/config.yaml の minutes_sections から全発言を再掲するセクションを外す)。"
    die 3 "出力の先頭が契約と一致しません(step $step)。生成物は確定していません。" "$hint"
  fi
  hint="認証状態(config/auth/active.env)と ANTHROPIC_MODEL のモデルIDを確認し、入力サイズを見直して再実行してください。"
  if [[ -n "$error_log" ]]; then
    hint="claude の出力を $(repo_relative "$error_log") に残しました。API Error の記載を確認してください(出力トークン上限の場合は --parallel でステップを分割する、または CLAUDE_CODE_MAX_OUTPUT_TOKENS を上げる)。記載が無い場合は認証状態(config/auth/active.env)と ANTHROPIC_MODEL のモデルIDを確認してください。"
  fi
  die 3 "claude の実行に失敗しました(step $step)。非ゼロ終了、または空の出力が返りました。" "$hint"
}

# メディアパス → パートキャッシュのパス(docs/design/02-generate-minutes.md §6.1)。
# キャッシュのキーはメディアの basename。
transcript_part_file() {
  echo "$TRANSCRIPT_PARTS_DIR/$(basename "$1").txt"
}

# 連結順を利用者が検証できるよう列挙する(docs/design/02-generate-minutes.md §6)。
# ファイル名昇順が会議の時系列順であることを前提とするため、順序を明示する。
announce_media_order() {
  local -a media=("$@")
  local file index=0
  ((${#media[@]} > 1)) || return 0

  echo "ステップ0 (文字起こし): ${#media[@]}件のメディアを次の順で連結します"
  for file in "${media[@]}"; do
    index=$((index + 1))
    echo "  $index. $(basename "$file")"
  done
}

# メディアのパートを連結して stdout に出力する(docs/design/02-generate-minutes.md §6.2)。
# 2件以上のときのみパートマーカーを付ける(1件ならパートの内容と一致させる)。
# タイムスタンプのオフセットは行わない(理由は docs/design/09-decisions.md §4.2)。
concat_transcript_parts() {
  local -a media=("$@")
  local total="${#media[@]}"
  local file part index=0

  for file in "${media[@]}"; do
    index=$((index + 1))
    part="$(transcript_part_file "$file")"
    if ((total > 1)); then
      printf -- '----- TRANSCRIPT PART %d/%d: %s -----\n\n' \
        "$index" "$total" "$(basename "$file")"
    fi
    cat "$part"
    if ((index < total)); then
      printf '\n'
    fi
  done
}

# メディア1本を文字起こししてパートを作る。既存パートがあれば再実行しない。
transcribe_part() {
  local file="$1" part status
  part="$(transcript_part_file "$file")"

  if [[ -f "$part" ]]; then
    echo "既存のパートを使用します: $(repo_relative "$part")"
    return 0
  fi

  echo "ステップ0 (文字起こし) を実行します: $(basename "$file")"
  status=0
  python3 "$SCRIPT_DIR/transcribe.py" \
    --input "$file" --output "$part" --model-size "$MODEL_SIZE" || status=$?
  if ((status != 0)); then
    die "$status" "文字起こしに失敗しました: $(basename "$file")" \
      "上のエラー出力を確認してください(Python依存関係は pip install -r requirements.txt、ffmpeg はお使いの環境の手順で導入してください)。"
  fi
}

# ステップ0(文字起こし)。既存の 00_transcript.txt があれば再実行しない
# (docs/design/02-generate-minutes.md §6)。
ensure_transcript() {
  local -a media=()
  local file tmp_out
  # while read で配列に積む(mapfile は Bash 4.0+ 専用。01-conventions.md §8)
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    media+=("$file")
  done < <(find_media_files)

  if [[ -f "$TRANSCRIPT_FILE" ]]; then
    echo "既存の文字起こしを使用します: $(repo_relative "$TRANSCRIPT_FILE")"
    return 0
  fi

  if ((${#media[@]} == 0)); then
    if ((TO_STEP == 0)); then
      die 1 "文字起こし対象の録画・音声ファイルが見つかりません: inputs/$PROJECT/$MEETING_DATE" \
        "inputs/$PROJECT/$MEETING_DATE/ に録画・音声ファイル(mp4 / m4a / mp3 / wav / mov / webm / aac / flac)を配置してください。"
    fi
    echo "録画・音声ファイルが無いため文字起こしをスキップします"
    return 0
  fi

  announce_media_order "${media[@]}"

  if ((DRY_RUN == 1)); then
    echo "[dry-run] ステップ0 (文字起こし): ${#media[@]}件のメディア → $(repo_relative "$TRANSCRIPT_FILE") (model-size: $MODEL_SIZE)"
    return 0
  fi

  mkdir -p "$TRANSCRIPT_PARTS_DIR"
  for file in "${media[@]}"; do
    transcribe_part "$file"
  done

  # 全パートが揃ってから連結し、成功時のみ確定する(docs/design/01-conventions.md §6)
  tmp_out="$(mktemp "${TRANSCRIPT_FILE}.XXXXXX")"
  register_tmp_file "$tmp_out"
  concat_transcript_parts "${media[@]}" >"$tmp_out"
  mv "$tmp_out" "$TRANSCRIPT_FILE"
  echo "ステップ0 完了: $(repo_relative "$TRANSCRIPT_FILE")"
}

# Bedrock 利用時のみ SSO セッションを確保する。他の認証経路では自然にスキップされる
# (認証経路ごとの分岐を増やさない・CLAUDE.md 4章)。
maybe_sso_login() {
  if [[ "${CLAUDE_CODE_USE_BEDROCK:-}" != "1" ]]; then
    return 0
  fi

  if ((DRY_RUN == 1)); then
    echo "[dry-run] AWS SSO セッションの確認: scripts/aws_sso_login.sh"
    return 0
  fi

  if ! "$SCRIPT_DIR/aws_sso_login.sh"; then
    die 2 "AWS SSO ログインに失敗しました。" \
      "./scripts/aws_sso_login.sh を単体で実行し、認証が完了するか確認してください。"
  fi
}

# モデルIDは環境変数で明示的に固定する。エイリアスをコードに書かない(CLAUDE.md 4章)。
require_model() {
  if [[ -z "${ANTHROPIC_MODEL:-}" ]]; then
    die 1 "ANTHROPIC_MODEL が設定されていません。" \
      "config/auth/active.env に ANTHROPIC_MODEL=<モデルID / 推論プロファイルID> を明示的に設定してください(sonnet 等のエイリアスは使用しません)。"
  fi
}

# --only-step 実行で後続ステップの出力が古くなる場合に警告する
# (docs/design/02-generate-minutes.md §7)。処理は継続する。
warn_stale_outputs() {
  local last_step="$1" step file source_file warned=0

  ((last_step < LAST_STEP)) || return 0

  if ((last_step == 0)); then
    source_file="$TRANSCRIPT_FILE"
  else
    source_file="$(step_output_file "$last_step")"
  fi

  for ((step = last_step + 1; step <= LAST_STEP; step++)); do
    file="$(step_output_file "$step")"
    if [[ -f "$file" ]]; then
      echo "WARN: $(basename "$file") は現在の $(basename "$source_file") を反映していません。" >&2
      warned=1
    fi
  done

  if ((warned == 1)); then
    echo "HINT:  --from-step $((last_step + 1)) で再生成してください。" >&2
  fi
}

main() {
  local step

  parse_args "$@"
  load_auth_env
  resolve_paths
  validate_project
  validate_inputs

  # ステップ0はステップ1を実行する場合の前処理(--only-step 0 は文字起こしのみ)
  if ((FROM_STEP <= 1)); then
    ensure_transcript
  fi

  if ((TO_STEP >= 1)); then
    require_model
    maybe_sso_login
    for ((step = FROM_STEP > 1 ? FROM_STEP : 1; step <= TO_STEP; step++)); do
      run_step "$step"
    done
  fi

  warn_stale_outputs "$TO_STEP"
}

# Ctrl+C を受けた場合の報告(docs/design/02-generate-minutes.md §5.3)。
# 子プロセスの終了コードを見る経路を通らずにシェル自身が SIGINT を受けた場合も、
# 「外部コマンド失敗」ではなく中断として報告する。
on_interrupt() {
  stop_heartbeat
  echo "ERROR: 中断されました。" >&2
  exit "$EXIT_INTERRUPTED"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  trap cleanup_tmp_files EXIT
  trap on_interrupt INT TERM
  main "$@"
fi
