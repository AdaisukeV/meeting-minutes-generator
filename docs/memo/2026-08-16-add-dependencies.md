# 依存パッケージの追加(初期実装)

- **日付**:2026-08-16
- **分類**:依存変更(追加)
- **対象**:`requirements.txt`、`requirements-dev.txt`、`.devcontainer/postCreate.sh`

## 内容

実装着手にあたり、以下を新規に追加した(いずれも設計書 [08-dev-environment.md §3](../design/08-dev-environment.md) に定義済みのもの)。

| 種別 | パッケージ | 用途 | 実測バージョン |
|---|---|---|---|
| 実行時(`requirements.txt`) | `faster-whisper` | ステップ0のローカル文字起こし(要件3.1) | 1.2.1(依存 `ctranslate2` 4.8.1 / `onnxruntime` 1.28.0 / `av` 18.1.0 / `tokenizers` 0.23.1 / `numpy` 2.5.2) |
| 開発時(`requirements-dev.txt`) | `pytest` | Python のテスト(要件8.3) | 9.1.1 |
| 開発時 | `pytest-cov` | カバレッジ計測(要件8.4 の80%判定) | 7.1.0 |
| 開発時 | `ruff` | Python の Lint | 0.16.3 |
| 開発時 | `black` | Python の Format | 26.5.1 |
| OS(apt) | `ffmpeg` | 音声・動画のデコード(`faster-whisper` の前提) | 6.1.1 |
| OS(apt) | `shellcheck` | Bash の Lint | 0.9.0 |
| OS(apt) | `shfmt` | Bash の Format | 3.8.0 |
| OS(apt) | `bats` | Bash のテスト | 1.10.0 |
| npm(グローバル) | `@anthropic-ai/claude-code` | パイプライン本体が呼ぶ `claude` CLI | (Codespace に既存) |

## 理由

要件8.3・`CLAUDE.md` 6章が定めるテスト・Lint・Format ツール(Python: pytest / ruff / black、Bash: bats / shellcheck / shfmt)と、要件3.1のローカル文字起こしに必要な最小構成。標準機能では代替できない(文字起こしモデル実行・各言語の静的解析)ため追加した。

## 影響・代替

- Python パッケージは `pip install --user` で導入する(`--break-system-packages` は前提にしない。`CLAUDE.md` 3章)。
- `shfmt` は当初 npm(`npm install -g shfmt`)で導入を試みたが、npm の `shfmt@0.0.1` はバイナリを含まないプレースホルダで `shfmt` コマンドが入らなかった。**apt の `shfmt` パッケージに変更**した(`docs/design/08-dev-environment.md` §2 に記載)。
- Python は 3.14.2 で上記すべてが解決することを実測した。要件7.1の「3.12」表記は「3.12以上(上限を固定しない)」へ更新した(経緯は [09-decisions.md §3](../design/09-decisions.md) の #6)。
- 撤回する場合は `pip uninstall -r requirements-dev.txt` および `requirements*.txt` の該当行削除で戻せる。
