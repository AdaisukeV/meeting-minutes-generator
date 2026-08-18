"""``scripts/transcribe.py`` のテスト(docs/design/07-testing.md §4)。

括弧内の番号は設計書 07-testing.md §4 の pytest ケース番号に対応する。
"""

import sys
from pathlib import Path
from typing import ClassVar

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import transcribe


class FakeSegment:
    """faster-whisper の Segment の代替(start / text のみ使う)。"""

    def __init__(self, start: float, text: str):
        self.start = start
        self.text = text


# --- ケース4: format_timestamp ---


@pytest.mark.parametrize(
    ("seconds", "expected"),
    [
        (0, "00:00:00"),
        (0.4, "00:00:00"),
        (4.9, "00:00:04"),
        (61, "00:01:01"),
        (3661.4, "01:01:01"),
        (86399, "23:59:59"),
        (90000, "25:00:00"),
    ],
)
def test_format_timestamp(seconds, expected):
    assert transcribe.format_timestamp(seconds) == expected


# --- ケース5: format_segments(タイムスタンプ付き) ---


def test_format_segments_with_timestamps():
    segments = [
        FakeSegment(4.2, "それでは始めます。"),
        FakeSegment(11.9, "前回の宿題から確認します。"),
    ]

    assert transcribe.format_segments(segments, with_timestamps=True) == (
        "[00:00:04] それでは始めます。\n[00:00:11] 前回の宿題から確認します。"
    )


# --- ケース6: --no-timestamps 相当 ---


def test_format_segments_without_timestamps():
    segments = [
        FakeSegment(4.2, "それでは始めます。"),
        FakeSegment(11.9, "確認します。"),
    ]

    assert transcribe.format_segments(segments, with_timestamps=False) == (
        "それでは始めます。\n確認します。"
    )


# --- ケース7: 空セグメント・前後空白 ---


def test_format_segments_strips_and_drops_empty():
    segments = [
        FakeSegment(1.0, "  前後に空白  "),
        FakeSegment(2.0, "   "),
        FakeSegment(3.0, ""),
        FakeSegment(4.0, "\n本文\t"),
    ]

    assert transcribe.format_segments(segments, with_timestamps=True) == (
        "[00:00:01] 前後に空白\n[00:00:04] 本文"
    )


def test_format_segments_empty_input():
    assert transcribe.format_segments([], with_timestamps=True) == ""


# --- ケース11: 出力ヘッダ(basename のみ・絶対パスを含まない) ---


def test_build_header_uses_basename_only():
    header = transcribe.build_header(
        "/srv/secret/inputs/client-a/recording.mp4", "base", "ja"
    )

    assert header == (
        "# transcript: recording.mp4\n"
        "# model: base / language: ja\n"
        "# generated-by: transcribe.py (faster-whisper, local)"
    )
    assert "/srv/secret" not in header
    assert "client-a" not in header


# --- ケース1: 必須引数の欠落 → コード1 ---


@pytest.mark.parametrize(
    "argv",
    [
        [],
        ["--input", "a.mp4"],
        ["--output", "out.txt"],
    ],
)
def test_main_missing_required_args_returns_1(argv, capsys):
    assert transcribe.main(argv) == 1

    captured = capsys.readouterr()
    assert "ERROR:" in captured.err
    assert "HINT:" in captured.err
    assert captured.out == ""


def test_parse_args_missing_required_raises_input_error():
    with pytest.raises(transcribe.InputError):
        transcribe.parse_args(["--input", "a.mp4"])


def test_parse_args_unknown_option_raises_input_error():
    with pytest.raises(transcribe.InputError):
        transcribe.parse_args(["--input", "a.mp4", "--output", "o.txt", "--nope"])


def test_parse_args_invalid_model_size_raises_input_error():
    with pytest.raises(transcribe.InputError):
        transcribe.parse_args(
            ["--input", "a.mp4", "--output", "o.txt", "--model-size", "huge"]
        )


def test_parse_args_defaults():
    args = transcribe.parse_args(["--input", "a.mp4", "--output", "o.txt"])

    assert args.input == "a.mp4"
    assert args.output == "o.txt"
    assert args.model_size == "base"
    assert args.language == "ja"
    assert args.device == "cpu"
    assert args.compute_type == "int8"
    assert args.no_timestamps is False


def test_parse_args_overrides():
    args = transcribe.parse_args(
        [
            "--input",
            "a.mp4",
            "--output",
            "o.txt",
            "--model-size",
            "tiny",
            "--language",
            "auto",
            "--device",
            "cuda",
            "--compute-type",
            "float16",
            "--no-timestamps",
        ]
    )

    assert args.model_size == "tiny"
    assert args.language == "auto"
    assert args.device == "cuda"
    assert args.compute_type == "float16"
    assert args.no_timestamps is True


# --- ケース2: 入力ファイル不存在 ---


def test_validate_input_path_missing_file(tmp_path):
    with pytest.raises(transcribe.InputError):
        transcribe.validate_input_path(str(tmp_path / "no-such-file.mp4"))


def test_validate_input_path_directory(tmp_path):
    with pytest.raises(transcribe.InputError):
        transcribe.validate_input_path(str(tmp_path))


def test_main_missing_input_file_returns_1(tmp_path, capsys):
    code = transcribe.main(
        ["--input", str(tmp_path / "nope.mp4"), "--output", str(tmp_path / "o.txt")]
    )

    assert code == 1
    assert "ERROR:" in capsys.readouterr().err


# --- ケース3: 非対応拡張子 ---


def test_validate_input_path_unsupported_extension(tmp_path):
    media = tmp_path / "notes.txt"
    media.write_text("x", encoding="utf-8")

    with pytest.raises(transcribe.InputError):
        transcribe.validate_input_path(str(media))


def test_main_unsupported_extension_returns_1(tmp_path, capsys):
    media = tmp_path / "notes.txt"
    media.write_text("x", encoding="utf-8")

    code = transcribe.main(["--input", str(media), "--output", str(tmp_path / "o.txt")])

    assert code == 1
    err = capsys.readouterr().err
    assert "ERROR:" in err
    assert "HINT:" in err


def test_validate_input_path_accepts_supported_extensions(tmp_path):
    for name in ("a.mp4", "b.M4A", "c.WAV", "d.webm", "e.flac"):
        media = tmp_path / name
        media.write_text("x", encoding="utf-8")

        result = transcribe.validate_input_path(str(media))

        assert result == media
        assert isinstance(result, Path)


# --- エラーメッセージに機密(絶対パス以外の本文)を混ぜない ---


def test_error_messages_go_to_stderr_only(tmp_path, capsys):
    transcribe.main(["--input", str(tmp_path / "nope.mp4"), "--output", "o.txt"])

    captured = capsys.readouterr()
    assert captured.out == ""


# --- ケース10: write_output(親ディレクトリ作成・原子的置換) ---


def test_write_output_creates_parent_directories(tmp_path):
    out = tmp_path / "outputs" / "proj" / "2026-08-16" / "00_transcript.txt"

    transcribe.write_output("本文\n", out)

    assert out.read_text(encoding="utf-8") == "本文\n"


def test_write_output_replaces_existing_file(tmp_path):
    out = tmp_path / "00_transcript.txt"
    out.write_text("古い内容\n", encoding="utf-8")

    transcribe.write_output("新しい内容\n", out)

    assert out.read_text(encoding="utf-8") == "新しい内容\n"


def test_write_output_leaves_no_temp_file_behind(tmp_path):
    out = tmp_path / "00_transcript.txt"

    transcribe.write_output("本文\n", out)

    assert [p.name for p in tmp_path.iterdir()] == ["00_transcript.txt"]


def test_write_output_keeps_existing_file_on_failure(tmp_path, monkeypatch):
    out = tmp_path / "00_transcript.txt"
    out.write_text("既存の内容\n", encoding="utf-8")

    def boom(*_args, **_kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(transcribe.os, "replace", boom)

    with pytest.raises(OSError):
        transcribe.write_output("新しい内容\n", out)

    # 既存ファイルが壊れていないこと・一時ファイルが残っていないこと
    assert out.read_text(encoding="utf-8") == "既存の内容\n"
    assert [p.name for p in tmp_path.iterdir()] == ["00_transcript.txt"]


def test_write_output_is_utf8_with_lf(tmp_path):
    out = tmp_path / "00_transcript.txt"

    transcribe.write_output("日本語\n2行目\n", out)

    assert out.read_bytes() == "日本語\n2行目\n".encode()


# --- ケース8: transcribe_media の引数受け渡し(モック検証) ---


class FakeInfo:
    def __init__(self, language: str = "ja"):
        self.language = language


class FakeWhisperModel:
    """faster_whisper.WhisperModel の代替。生成時・transcribe 時の引数を記録する。"""

    instances: ClassVar[list["FakeWhisperModel"]] = []

    def __init__(self, model_size, device=None, compute_type=None):
        self.model_size = model_size
        self.device = device
        self.compute_type = compute_type
        self.transcribe_calls: list[tuple] = []
        FakeWhisperModel.instances.append(self)

    def transcribe(self, path, **kwargs):
        self.transcribe_calls.append((path, kwargs))
        return iter([FakeSegment(1.0, "モックの発言")]), FakeInfo()


def install_fake_faster_whisper(monkeypatch, model_cls=FakeWhisperModel):
    """``faster_whisper`` モジュールを差し替える(遅延 import を捕まえる)。"""
    import types

    module = types.ModuleType("faster_whisper")
    module.WhisperModel = model_cls
    monkeypatch.setitem(sys.modules, "faster_whisper", module)
    return module


def test_transcribe_media_passes_arguments(monkeypatch, tmp_path):
    FakeWhisperModel.instances.clear()
    install_fake_faster_whisper(monkeypatch)
    media = tmp_path / "recording.mp4"
    media.write_text("x", encoding="utf-8")

    segments, info = transcribe.transcribe_media(
        media,
        model_size="tiny",
        language="ja",
        device="cpu",
        compute_type="int8",
    )

    model = FakeWhisperModel.instances[-1]
    assert model.model_size == "tiny"
    assert model.device == "cpu"
    assert model.compute_type == "int8"

    called_path, kwargs = model.transcribe_calls[0]
    assert called_path == str(media)
    assert kwargs["language"] == "ja"

    assert [s.text for s in segments] == ["モックの発言"]
    assert info.language == "ja"


def test_transcribe_media_language_auto_passes_none(monkeypatch, tmp_path):
    FakeWhisperModel.instances.clear()
    install_fake_faster_whisper(monkeypatch)
    media = tmp_path / "recording.mp4"
    media.write_text("x", encoding="utf-8")

    transcribe.transcribe_media(
        media,
        model_size="base",
        language="auto",
        device="cpu",
        compute_type="int8",
    )

    _, kwargs = FakeWhisperModel.instances[-1].transcribe_calls[0]
    assert kwargs["language"] is None


def test_transcribe_media_wraps_runtime_failure(monkeypatch, tmp_path):
    class BoomModel:
        def __init__(self, *_args, **_kwargs):
            raise RuntimeError("model load failed")

    install_fake_faster_whisper(monkeypatch, BoomModel)
    media = tmp_path / "recording.mp4"
    media.write_text("x", encoding="utf-8")

    with pytest.raises(transcribe.TranscriptionError):
        transcribe.transcribe_media(
            media,
            model_size="base",
            language="ja",
            device="cpu",
            compute_type="int8",
        )


def test_transcribe_media_wraps_decode_failure_during_iteration(monkeypatch, tmp_path):
    def broken_segments():
        raise RuntimeError("ffmpeg not found")
        yield  # pragma: no cover - ジェネレータにするため

    class DecodeFailModel:
        def __init__(self, *_args, **_kwargs):
            pass

        def transcribe(self, _path, **_kwargs):
            return broken_segments(), FakeInfo()

    install_fake_faster_whisper(monkeypatch, DecodeFailModel)
    media = tmp_path / "recording.mp4"
    media.write_text("x", encoding="utf-8")

    with pytest.raises(transcribe.TranscriptionError):
        transcribe.transcribe_media(
            media,
            model_size="base",
            language="ja",
            device="cpu",
            compute_type="int8",
        )


# --- ケース9: faster_whisper の ImportError → コード3 + requirements.txt の HINT ---


def test_transcribe_media_import_error_raises_transcription_error(
    monkeypatch, tmp_path
):
    import builtins

    real_import = builtins.__import__

    def fake_import(name, *args, **kwargs):
        if name == "faster_whisper":
            raise ImportError("No module named 'faster_whisper'")
        return real_import(name, *args, **kwargs)

    monkeypatch.delitem(sys.modules, "faster_whisper", raising=False)
    monkeypatch.setattr(builtins, "__import__", fake_import)

    media = tmp_path / "recording.mp4"
    media.write_text("x", encoding="utf-8")

    with pytest.raises(transcribe.TranscriptionError):
        transcribe.transcribe_media(
            media,
            model_size="base",
            language="ja",
            device="cpu",
            compute_type="int8",
        )


def test_main_transcription_error_returns_3_with_requirements_hint(
    tmp_path, monkeypatch, capsys
):
    media = tmp_path / "recording.mp4"
    media.write_text("x", encoding="utf-8")

    def boom(*_args, **_kwargs):
        raise transcribe.TranscriptionError("faster-whisper を import できません")

    monkeypatch.setattr(transcribe, "transcribe_media", boom)

    code = transcribe.main(
        ["--input", str(media), "--output", str(tmp_path / "00_transcript.txt")]
    )

    assert code == 3
    err = capsys.readouterr().err
    assert "ERROR:" in err
    assert "requirements.txt" in err
    assert not (tmp_path / "00_transcript.txt").exists()


# --- ケース12: 正常系 E2E(モック) ---


def test_main_end_to_end_with_mock(tmp_path, monkeypatch, capsys):
    media = tmp_path / "recording.mp4"
    media.write_text("x", encoding="utf-8")
    out = tmp_path / "outputs" / "00_transcript.txt"

    captured_kwargs = {}

    def fake_transcribe_media(path, **kwargs):
        captured_kwargs.update(kwargs)
        captured_kwargs["path"] = path
        segments = [
            FakeSegment(4.2, " それでは始めます。 "),
            FakeSegment(11.9, ""),
            FakeSegment(97.5, "承知しました。"),
        ]
        return segments, FakeInfo("ja")

    monkeypatch.setattr(transcribe, "transcribe_media", fake_transcribe_media)

    code = transcribe.main(
        ["--input", str(media), "--output", str(out), "--model-size", "tiny"]
    )

    assert code == 0
    assert out.read_text(encoding="utf-8") == (
        "# transcript: recording.mp4\n"
        "# model: tiny / language: ja\n"
        "# generated-by: transcribe.py (faster-whisper, local)\n"
        "\n"
        "[00:00:04] それでは始めます。\n"
        "[00:01:37] 承知しました。\n"
    )
    assert captured_kwargs["model_size"] == "tiny"
    assert captured_kwargs["language"] == "ja"
    assert captured_kwargs["device"] == "cpu"
    assert captured_kwargs["compute_type"] == "int8"

    # 進捗は stdout / 会議本文は含まない(06-security.md §3)
    captured = capsys.readouterr()
    assert "recording.mp4" in captured.out
    assert "それでは始めます" not in captured.out
    assert captured.err == ""


def test_main_language_auto_uses_detected_language(tmp_path, monkeypatch):
    media = tmp_path / "recording.mp4"
    media.write_text("x", encoding="utf-8")
    out = tmp_path / "00_transcript.txt"

    monkeypatch.setattr(
        transcribe,
        "transcribe_media",
        lambda *_a, **_k: ([FakeSegment(0.0, "hello")], FakeInfo("en")),
    )

    assert (
        transcribe.main(
            ["--input", str(media), "--output", str(out), "--language", "auto"]
        )
        == 0
    )
    assert "# model: base / language: en" in out.read_text(encoding="utf-8")


def test_main_no_timestamps(tmp_path, monkeypatch):
    media = tmp_path / "recording.mp4"
    media.write_text("x", encoding="utf-8")
    out = tmp_path / "00_transcript.txt"

    monkeypatch.setattr(
        transcribe,
        "transcribe_media",
        lambda *_a, **_k: ([FakeSegment(4.2, "本文です。")], FakeInfo("ja")),
    )

    assert (
        transcribe.main(
            ["--input", str(media), "--output", str(out), "--no-timestamps"]
        )
        == 0
    )
    assert out.read_text(encoding="utf-8").endswith("\n本文です。\n")
    assert "[00:00:04]" not in out.read_text(encoding="utf-8")


def test_main_empty_result_writes_header_only(tmp_path, monkeypatch):
    media = tmp_path / "recording.mp4"
    media.write_text("x", encoding="utf-8")
    out = tmp_path / "00_transcript.txt"

    monkeypatch.setattr(
        transcribe, "transcribe_media", lambda *_a, **_k: ([], FakeInfo("ja"))
    )

    assert transcribe.main(["--input", str(media), "--output", str(out)]) == 0
    assert out.read_text(encoding="utf-8").endswith(
        "# generated-by: transcribe.py (faster-whisper, local)\n"
    )
