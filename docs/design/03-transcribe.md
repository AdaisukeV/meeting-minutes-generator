# `scripts/transcribe.py` 詳細設計

> 親ドキュメント:[../design.md](../design.md)(設計書ハブ)
> 対応要件:`docs/requirements.md` 3.1, 7.2, 8.3
> 前提:[01-conventions.md](./01-conventions.md)(終了コード体系)/ 呼び出し元は [02-generate-minutes.md §6](./02-generate-minutes.md)

---

## 1. CLI 仕様

```
usage: transcribe.py --input PATH --output PATH
                     [--model-size {tiny,base,small,medium,large-v3}]
                     [--language LANG] [--device {cpu,cuda,auto}]
                     [--compute-type TYPE] [--no-timestamps]
```

| オプション | 既定値 | 説明 |
|---|---|---|
| `--input` | (必須) | 音声・動画ファイルパス |
| `--output` | (必須) | 出力テキストファイルパス |
| `--model-size` | `base` | faster-whisper モデルサイズ(要件7.2:引数で選択可能) |
| `--language` | `ja` | 認識言語。`auto` 指定時は自動判定 |
| `--device` | `cpu` | 実行デバイス(GPUは前提としない・要件7.1) |
| `--compute-type` | `int8` | 量子化設定(CPU 実行時の既定) |
| `--no-timestamps` | (off) | タイムスタンプを付けずに本文のみ出力 |

本スクリプトは**メディア1本を1回の呼び出しで処理する**。同一会議が複数ファイルに分割されている場合は、呼び出し元(`generate_minutes.sh` の `ensure_transcript`)が**1本ごとに本スクリプトを呼び、結果を連結する**([02-generate-minutes.md §6](./02-generate-minutes.md))。本スクリプト側に複数入力・連結の責務は持たせない。

## 2. 関数分割

| 関数 | シグネチャ | 責務 |
|---|---|---|
| `parse_args` | `(argv: list[str]) -> argparse.Namespace` | 引数解析。異常時は `argparse` の `SystemExit(2)` ではなく `InputError` に正規化してコード1に揃える |
| `validate_input_path` | `(path: str) -> pathlib.Path` | 存在・通常ファイル・拡張子チェック。失敗時 `InputError` |
| `transcribe_media` | `(path, model_size, language, device, compute_type) -> tuple[Iterable[Segment], Info]` | **faster-whisper への依存をこの関数だけに閉じ込める**(テストではモック)。失敗時 `TranscriptionError` |
| `format_timestamp` | `(seconds: float) -> str` | `HH:MM:SS` 形式へ変換(純関数) |
| `format_segments` | `(segments, with_timestamps: bool) -> str` | 出力テキストを生成(純関数) |
| `build_header` | `(src_name: str, model_size: str, language: str) -> str` | 先頭メタ情報行を生成。**basename のみ**を含め絶対パスを出さない |
| `write_output` | `(text: str, path: pathlib.Path) -> None` | 一時ファイル + `os.replace` で原子的に書き込み。親ディレクトリを作成 |
| `main` | `(argv: list[str] \| None = None) -> int` | オーケストレーション。例外を終了コードへマップ |

例外 → 終了コードのマッピング([01-conventions.md §4](./01-conventions.md) と一致):

| 例外 | コード |
|---|---|
| `InputError`(引数不正・ファイル未検出・非対応拡張子) | 1 |
| `TranscriptionError`(モデルロード失敗・ffmpeg 不在・デコード失敗) | 3 |

`faster_whisper` の import は `transcribe_media` 内で遅延 import する(未インストール環境でも他関数の単体テストが動くようにする)。ImportError は `TranscriptionError` に変換し、HINT に `pip install -r requirements.txt` を示す。

- **セグメントは `transcribe_media` 内でリスト化する**(`list(generator)`)。faster-whisper の `transcribe()` は遅延ジェネレータを返し、デコードエラーは**反復時**に発生するため、関数の外へ漏らすと `TranscriptionError`(コード3)へ正規化できない。会議1本分のセグメント数ならメモリ上の問題はない。
- `--language auto` の場合は faster-whisper へ `language=None` を渡し、ヘッダには検出結果(`info.language`)を記録する。
- **初回実行時のみ、指定モデルの重みが Hugging Face Hub からダウンロードされる**(以降はローカルキャッシュを使用)。ダウンロードは重みの取得のみで、**音声・動画データは送信しない**(要件6.1)。オフライン環境では事前にキャッシュを用意する必要がある。

## 3. 出力フォーマット

```
# transcript: recording.mp4
# model: base / language: ja
# generated-by: transcribe.py (faster-whisper, local)

[00:00:04] それでは、本日の定例を始めます。
[00:00:11] 前回の宿題から確認させてください。
[00:01:37] 承知しました。来週までに見積を提出します。
```

- 先頭3行はメタ情報コメント(`#`)+空行。以降は1発言セグメント=1行。
- `--no-timestamps` 指定時は `[HH:MM:SS] ` を付けず本文のみ。
- セグメント本文は前後空白を strip し、空セグメントは出力しない。
- 文字コードは UTF-8(LF)。

## 4. テスト対象範囲(要件8.3)

- **対象**:引数解析、パス検証、タイムスタンプ整形、出力フォーマット、`transcribe_media` の呼び出し引数、終了コード。
- **対象外**:認識精度(モデル依存)。

テストケース一覧は [07-testing.md §4](./07-testing.md) を参照。
