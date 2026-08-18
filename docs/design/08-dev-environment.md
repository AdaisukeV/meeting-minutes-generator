# 開発環境設計(devcontainer / 依存パッケージ)

> 親ドキュメント:[../design.md](../design.md)(設計書ハブ)
> 対応要件:`docs/requirements.md` 7.1, 7.2, 8.1

---

## 1. `.devcontainer/devcontainer.json`(更新後)

```jsonc
{
  "name": "meeting-minutes-generator",
  "image": "mcr.microsoft.com/devcontainers/base:ubuntu-24.04",
  "features": {
    "ghcr.io/devcontainers/features/node:1": {},
    "ghcr.io/devcontainers/features/python:1": { "version": "latest" },
    "ghcr.io/devcontainers/features/aws-cli:1": {},
    "ghcr.io/devcontainers/features/github-cli:1": {}
  },
  "postCreateCommand": "bash .devcontainer/postCreate.sh",
  "hostRequirements": { "cpus": 4 },
  "remoteEnv": {
    "AWS_PROFILE": "${localEnv:AWS_PROFILE}",
    "AWS_REGION": "${localEnv:AWS_REGION}",
    "ANTHROPIC_MODEL": "${localEnv:ANTHROPIC_MODEL}",
    "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}"
  },
  "remoteUser": "vscode"
}
```

既存ファイルからの差分:

| 変更 | 理由 |
|---|---|
| `image` を明示 | 要件7.1のベースイメージ指定 |
| `aws-cdk` Feature を削除 | 要件に無い(依存最小化・要件8.1) |
| `python` / `github-cli` Feature を追加 | 要件7.1 |
| `python` の `version` を `latest`(バージョン固定なし)とする | 要件7.1は「3.12以上」であり上限を固定しない。現 Codespace の 3.14.2 で `faster-whisper 1.2.1` / `ctranslate2 4.8.1` が解決することを実測([09-decisions.md §3](./09-decisions.md)) |
| `postCreateCommand` を `postCreate.sh` に集約 | 要件7.1 |
| `hostRequirements: {cpus: 4}` を追加 | 文字起こしのCPU負荷(要件7.1) |
| `containerEnv.AWS_DEFAULT_REGION` を削除し `remoteEnv` へ | リージョンをリポジトリに固定値で持たない。認証値は Codespaces Secrets 経由(要件6.6) |
| `customizations.vscode.extensions` の見直し | `claude-dev`(サードパーティ拡張)は本アプリの前提ではないため削除 |

## 2. `.devcontainer/postCreate.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sudo apt-get update
sudo apt-get install -y --no-install-recommends ffmpeg shellcheck shfmt bats
npm install -g @anthropic-ai/claude-code
pip install --user -r "$REPO_ROOT/requirements.txt"
pip install --user -r "$REPO_ROOT/requirements-dev.txt"
```

- `pip install --break-system-packages` を前提にしない(`CLAUDE.md` 3章)。`--user` インストール、または Python Feature が用意する環境を使う。
- `shfmt` / `bats` は **apt から導入する**(Ubuntu 24.04 に `shfmt 3.8.0` / `bats 1.10.0` のパッケージがある)。npm の `shfmt` パッケージは実体を含まないプレースホルダのため使用しない。
- 冪等に再実行できること(Codespace の再ビルド・手動再実行を想定)を前提とし、`REPO_ROOT` はスクリプト位置から解決してカレントディレクトリに依存させない([01-conventions.md §1](./01-conventions.md))。

## 3. 依存パッケージ

**`requirements.txt`(実行時)**

```
faster-whisper
```

**`requirements-dev.txt`(開発時)**

```
pytest
pytest-cov
ruff
black
```

- 依存追加は最小限とし、追加時は標準機能・既存依存で代替できないかを先に検討する(要件8.1)。YAML パーサを追加しないのは [02-generate-minutes.md §4](./02-generate-minutes.md) の設計判断による。
- 依存を変更した場合は `docs/memo/` に記録する(`CLAUDE.md` 5章)。

## 4. ローカル環境(devcontainer 以外)のセットアップ方針(要件7.3)

devcontainer / Codespaces では §1・§2 が環境を用意するが、ローカル環境ではこれに相当する導入を利用者が手で行う。**手順(コマンド列)の正は `README.md`「ローカル環境のセットアップ」節**とし、本節は**方針・根拠・条件のみ**を持つ(役割分担は [../design.md §1](../design.md) の役割表)。本節にコマンド列は置かない。

### 4.1 必要物と経路依存

| 必要物 | 必要になる条件 | 根拠 |
|---|---|---|
| Python 3.12以上 + pip | 常に必要 | 要件7.1 |
| ffmpeg | 録音・録画を入力にする場合 | [03-transcribe.md](./03-transcribe.md)、[01-conventions.md §4](./01-conventions.md)(不在時はコード3) |
| Node.js **22以上** + npm(`@anthropic-ai/claude-code`) | 常に必要 | [02-generate-minutes.md §5](./02-generate-minutes.md)(`invoke_claude` が `claude` を呼ぶ)。**22以上**は当該 npm パッケージの `engines` による(§4.4) |
| AWS CLI v2 | **Bedrock 経路のみ** | [04-auth.md §1](./04-auth.md)(`aws sts` / `aws sso login`) |
| gcloud CLI | **Vertex AI 経路のみ** | [04-auth.md §2.1](./04-auth.md)(`vertex.env.example` が `gcloud auth application-default login` を前提にする) |
| shellcheck / shfmt / bats | 開発する場合のみ | [07-testing.md §5](./07-testing.md) |
| Bash 5(`brew install bash`) | **macOS で `bats` を実行する場合のみ** | bats 1.14 は Bash 3.2 で日本語のテスト名を解決できない([07-testing.md §5](./07-testing.md)・[01-conventions.md §8.3](./01-conventions.md))。**パイプラインの実行には不要**(macOS 標準の Bash 3.2 で動くことが要件。[01-conventions.md §8](./01-conventions.md)) |

- **Anthropic 商用APIキー経路では AWS CLI / gcloud のいずれも不要。** 認証経路ごとに必要な CLI が変わるため、README では経路別に併記する。
- GPU は前提としない(要件7.1・7.2。CPU 4コア相当を推奨)。
- `jq` / `yq` は不要(§3 および [02-generate-minutes.md §4](./02-generate-minutes.md) の設計判断により外部 YAML パーサを使わない)。

### 4.2 Python 依存は仮想環境(venv)を正とする

**ローカルは venv、devcontainer は `pip install --user`(§2)という差異を意図的に許容する。**

- 理由:Ubuntu 24.04 や Homebrew の Python は PEP 668 の外部管理環境であり、`pip install` が拒否されうる。回避策の `--break-system-packages` は `CLAUDE.md` 3章が前提にすることを禁じているため、OS の Python を変更しない venv が唯一整合する解となる。
- `.venv/` は既に Git 管理外([06-security.md §1](./06-security.md))。venv を案内するために `.gitignore` を変更する必要はない。
- **実装上の制約**:`generate_minutes.sh` はステップ0で `python3` を **PATH から解決して呼ぶだけ**であり、インタプリタを切り替える機構を持たない([02-generate-minutes.md §6](./02-generate-minutes.md))。したがって「venv を有効化したシェルでパイプラインを実行する」ことが前提条件になる。この前提を README に明記する。
- スクリプト側に venv 検出・自動有効化のロジックを追加しない(KISS・要件8.1。認証と同様、環境の違いは環境側で吸収する)。

### 4.3 Windows(WSL2)の扱い

- 独立した手順を持たせず、**WSL2 上の Ubuntu として Ubuntu/Debian 手順を流用**する。Windows ネイティブは対象外(パイプラインが Bash スクリプト前提のため)。
- リポジトリ・入力ファイルは WSL 側のファイルシステムに置く(`/mnt/c/...` は I/O が遅く、改行コード・実行権限の差異でスクリプト実行に支障が出ることがある)。
- ブラウザ認証は、Codespaces のヘッドレス環境と**同じ事象**(ターミナルに表示されたURL・コードをホスト側ブラウザで開く)として扱う。既存の記述([04-auth.md §1.2](./04-auth.md)・要件7.2)を再定義せず、README 側で参照させる。

### 4.4 実測に基づく制約(2026-08-17 時点)

README に書く手順は、以下の実測・一次情報に基づく。バージョンを固定する意図はなく、**「apt / brew で足りるか」の判断根拠**として残す。

| 事項 | 実測結果 | 手順への影響 |
|---|---|---|
| Ubuntu 24.04(noble、universe 有効)の `awscli` | **apt に存在しない**(`apt-cache policy awscli` が `Candidate: (none)`) | `apt install awscli` は書けない。**AWS 公式インストールスクリプトを案内する**(macOS / Linux 共通で使えるため、AWS CLI の導入は OS 別ではなく認証経路別のステップに置く) |
| Homebrew の `awscli` | AWS 公式ドキュメントはサードパーティリポジトリを最新性保証の対象外とし、`brew` を推奨方法として挙げていない | macOS でも公式インストールスクリプトを案内し、`brew install awscli` は書かない |
| apt の `nodejs` | **18.19.1**。`@anthropic-ai/claude-code`(2.1.233)の `engines` は **`>=22.0.0`** | **apt の Node では要件を満たせない。** Ubuntu / WSL2 では nvm 等で Node 22以上(LTS)を導入する手順を書く。Homebrew の `node` は 26 系のため条件を満たす |
| apt の `ffmpeg` / `shellcheck` / `shfmt` / `bats` / `python3-venv` | `6.1.1` / `0.9.0` / `3.8.0` / `1.10.0` / `3.12.3` | devcontainer(§2)と同一構成が apt で揃う。`shfmt` を npm から入れない理由は §2 と同じ |
| Homebrew の formula 名 | `ffmpeg` / `node` / `shellcheck` / `shfmt` / `bats-core` / `python@3.13` が実在 | macOS 手順はこの名前で記述する(`bats` ではなく `bats-core`) |
| gcloud の Debian/Ubuntu パッケージ名 | `google-cloud-cli`(apt リポジトリの追加が必要) | 多段手順のため README はパッケージ名の提示と公式手順への誘導に留める |
