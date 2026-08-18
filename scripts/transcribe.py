#!/usr/bin/env python3
"""音声・動画ファイルをローカルで文字起こしする(ステップ0)。

設計書:``docs/design/03-transcribe.md``
終了コード体系:``docs/design/01-conventions.md`` §4(1=想定内エラー / 3=外部コマンド失敗)

文字起こしは ``faster-whisper`` によりローカルで完結させる。音声・動画の生データを
外部へ送信しない(要件6.1)。
"""

from __future__ import annotations

import argparse
import os
import pathlib
import sys
import tempfile

# 探索・受理するメディア拡張子(docs/design/02-generate-minutes.md §6 と同一)
SUPPORTED_EXTENSIONS = (
    ".mp4",
    ".m4a",
    ".mp3",
    ".wav",
    ".mov",
    ".webm",
    ".aac",
    ".flac",
)

MODEL_SIZES = ("tiny", "base", "small", "medium", "large-v3")
DEVICES = ("cpu", "cuda", "auto")


class InputError(Exception):
    """引数不正・ファイル未検出・非対応拡張子(終了コード1)。"""


class TranscriptionError(Exception):
    """モデルロード失敗・ffmpeg 不在・デコード失敗(終了コード3)。"""


class _ArgumentParser(argparse.ArgumentParser):
    """引数エラーを ``InputError`` に正規化する(SystemExit(2) を出さない)。

    終了コードを [01-conventions.md §4] の体系(引数不正=1)へ揃えるため。
    """

    def error(self, message: str):
        raise InputError(f"引数が不正です: {message}")


def _eprint(error: str, hint: str | None = None) -> None:
    """``ERROR:`` / ``HINT:`` を標準エラーへ出力する(01-conventions.md §5)。"""
    print(f"ERROR: {error}", file=sys.stderr)
    if hint:
        print(f"HINT:  {hint}", file=sys.stderr)


def parse_args(argv: list[str]) -> argparse.Namespace:
    """コマンドライン引数を解析する。異常時は ``InputError``。"""
    parser = _ArgumentParser(
        prog="transcribe.py",
        description="音声・動画ファイルをローカル(faster-whisper)で文字起こしする",
        add_help=True,
    )
    parser.add_argument("--input", required=True, help="音声・動画ファイルパス")
    parser.add_argument("--output", required=True, help="出力テキストファイルパス")
    parser.add_argument(
        "--model-size", default="base", choices=MODEL_SIZES, help="モデルサイズ"
    )
    parser.add_argument(
        "--language", default="ja", help="認識言語(auto を指定すると自動判定)"
    )
    parser.add_argument("--device", default="cpu", choices=DEVICES, help="実行デバイス")
    parser.add_argument("--compute-type", default="int8", help="量子化設定")
    parser.add_argument(
        "--no-timestamps",
        action="store_true",
        help="タイムスタンプを付けずに本文のみ出力する",
    )
    return parser.parse_args(argv)


def validate_input_path(path: str) -> pathlib.Path:
    """入力パスの存在・通常ファイル・拡張子を検証する。異常時は ``InputError``。"""
    media = pathlib.Path(path)
    if not media.exists():
        raise InputError(f"入力ファイルが見つかりません: {path}")
    if not media.is_file():
        raise InputError(f"入力パスが通常ファイルではありません: {path}")
    if media.suffix.lower() not in SUPPORTED_EXTENSIONS:
        raise InputError(
            f"非対応の拡張子です: {media.suffix or '(拡張子なし)'} "
            f"(対応: {', '.join(SUPPORTED_EXTENSIONS)})"
        )
    return media


def transcribe_media(
    path: pathlib.Path,
    model_size: str,
    language: str,
    device: str,
    compute_type: str,
):
    """faster-whisper で文字起こしする。

    **faster-whisper への依存はこの関数だけに閉じ込める**(03-transcribe.md §2)。
    import は遅延させ、未インストール環境でも他関数の単体テストが動くようにする。
    デコードはこの関数内で完了させる(セグメントをリスト化する)ことで、
    反復中の失敗も ``TranscriptionError`` に正規化する。
    """
    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:
        raise TranscriptionError(f"faster-whisper を import できません: {exc}") from exc

    detect_language = None if language == "auto" else language
    try:
        model = WhisperModel(model_size, device=device, compute_type=compute_type)
        generator, info = model.transcribe(str(path), language=detect_language)
        segments = list(generator)
    except Exception as exc:
        raise TranscriptionError(f"文字起こしに失敗しました: {exc}") from exc

    return segments, info


def format_timestamp(seconds: float) -> str:
    """秒数を ``HH:MM:SS`` へ変換する(純関数)。"""
    total = int(seconds)
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def format_segments(segments, with_timestamps: bool) -> str:
    """セグメント列を出力テキストへ整形する(純関数)。

    前後の空白は除去し、空セグメントは出力しない(設計書 03-transcribe.md §3)。
    """
    lines = []
    for segment in segments:
        text = segment.text.strip()
        if not text:
            continue
        if with_timestamps:
            lines.append(f"[{format_timestamp(segment.start)}] {text}")
        else:
            lines.append(text)
    return "\n".join(lines)


def build_header(src_name: str, model_size: str, language: str) -> str:
    """先頭のメタ情報行を生成する。

    ファイル名は basename のみを含め、絶対パスを出さない(要件6.3)。
    """
    return (
        f"# transcript: {os.path.basename(src_name)}\n"
        f"# model: {model_size} / language: {language}\n"
        "# generated-by: transcribe.py (faster-whisper, local)"
    )


def write_output(text: str, path: pathlib.Path) -> None:
    """一時ファイル + ``os.replace`` で原子的に書き込む(01-conventions.md §6)。

    途中で失敗しても既存ファイルを壊さず、一時ファイルも残さない。
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        os.replace(tmp_name, path)
    except BaseException:
        # 失敗時は一時ファイルを片付けて例外を伝播する(握りつぶさない)
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)
        raise


def main(argv: list[str] | None = None) -> int:
    """オーケストレーション。例外を終了コードへマップする(03-transcribe.md §2)。"""
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        args = parse_args(argv)
        media = validate_input_path(args.input)

        print(f"文字起こしを開始します: {media.name} (model: {args.model_size})")
        segments, info = transcribe_media(
            media,
            model_size=args.model_size,
            language=args.language,
            device=args.device,
            compute_type=args.compute_type,
        )

        body = format_segments(segments, with_timestamps=not args.no_timestamps)
        language = args.language
        if language == "auto":
            # 自動判定時は検出結果をヘッダに残す
            language = getattr(info, "language", None) or "auto"
        header = build_header(media.name, args.model_size, language)
        text = f"{header}\n\n{body}\n" if body else f"{header}\n"

        output = pathlib.Path(args.output)
        write_output(text, output)
        print(f"文字起こしを書き出しました: {output.name}")
        return 0
    except InputError as exc:
        _eprint(
            str(exc),
            "usage: transcribe.py --input PATH --output PATH "
            "[--model-size {tiny,base,small,medium,large-v3}] [--language LANG] "
            "[--device {cpu,cuda,auto}] [--compute-type TYPE] [--no-timestamps]",
        )
        return 1
    except TranscriptionError as exc:
        _eprint(
            str(exc),
            "ffmpeg が導入されているか、`pip install -r requirements.txt` が"
            "完了しているかを確認してください。",
        )
        return 3


if __name__ == "__main__":
    sys.exit(main())
