#!/usr/bin/env bash
set -euo pipefail

# devcontainer 作成後のセットアップ(要件7.1)。
# 冪等に実行できることを前提とする(Codespace の再ビルド・手動再実行を想定)。

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> apt パッケージを導入します (ffmpeg / shellcheck / shfmt / bats)"
sudo apt-get update
sudo apt-get install -y --no-install-recommends ffmpeg shellcheck shfmt bats

echo "==> Claude Code CLI を導入します"
npm install -g @anthropic-ai/claude-code

echo "==> Python 依存関係を導入します"
# --break-system-packages は前提にしない(CLAUDE.md 3章)
pip install --user -r "$REPO_ROOT/requirements.txt"
pip install --user -r "$REPO_ROOT/requirements-dev.txt"

echo "==> セットアップが完了しました"
