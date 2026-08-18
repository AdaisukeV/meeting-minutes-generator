# 議事録生成アプリ 設計書(ハブ)

作成日:2026-08-16
対象:`docs/requirements.md`(要件定義書)v1

---

## 1. 本書の位置づけと分冊構成

| ドキュメント | 役割 |
|---|---|
| `docs/requirements.md` | **WHAT**(何を作るか)。仕様の正。 |
| `docs/design.md`(本書)+ `docs/design/`(分冊) | **HOW**(どう作るか)。関数インターフェース・データ形式・スキーマ・エラーハンドリング・テスト戦略。 |
| `CLAUDE.md` | **開発時**のコーディング規約・アーキテクチャ制約(対話モード専用) |
| `projects/{name}/prompts/*.md` | **運用時**のシステムプロンプト(議事録生成の指示) |
| `README.md` | **利用者向け手順の正**(セットアップ・実行・オプション)。設計判断の根拠は書かず、必要に応じて分冊へリンクする |

運用ルール(要件8, 8.2):

- 実装が設計書と乖離した場合は、**コードを設計書に合わせるのではなく、まず設計書を実態に合わせて更新**してから実装を進める。
- 事後の最新化は `/save-design` コマンドで支援する。
- 設計書に記載が無い機能を推測で実装しない。要件定義書に無い設計判断を行う場合は [design/09-decisions.md](./design/09-decisions.md) に根拠を記録し、要件定義書へ反映すべき内容は利用者の承認を得てから反映する。

### 1.1 本書(ハブ)と分冊の役割分担

本書には**全体像のみ**を置く(位置づけ・アーキテクチャ・ファイル構成・分冊索引・要件対応表)。詳細設計はすべて分冊にあり、**同じ内容を本書と分冊の両方に書かない**(正は常に1箇所)。

| 分冊 | 内容 | 主な読み手・読むタイミング |
|---|---|---|
| [design/01-conventions.md](./design/01-conventions.md) | パス解決・引数検証・終了コード体系・メッセージ様式・原子的書き込み・エラーハンドリング方針 | **全スクリプト実装時に最初に読む**(他分冊の前提) |
| [design/02-generate-minutes.md](./design/02-generate-minutes.md) | `generate_minutes.sh` の CLI・関数一覧・実行順序・stdin 構成・`invoke_claude` 確定仕様 | パイプライン本体を実装・修正するとき |
| [design/03-transcribe.md](./design/03-transcribe.md) | `transcribe.py` の CLI・関数分割・出力フォーマット | 文字起こし(ステップ0)を実装・修正するとき |
| [design/04-auth.md](./design/04-auth.md) | `aws_sso_login.sh` の設計、`config/auth/*.env` と読み込み優先順位 | 認証経路を追加・変更するとき |
| [design/05-project-assets.md](./design/05-project-assets.md) | `config.yaml` スキーマ、`prompts/*.md` の設計、`minutes-review` コマンド設計 | プロジェクト雛形・運用プロンプトを編集するとき |
| [design/06-security.md](./design/06-security.md) | `.gitignore` 確定内容、外部送信経路が無いことの根拠、ログの機密除外 | 新規ファイル追加時・依存追加時のレビュー |
| [design/07-testing.md](./design/07-testing.md) | テストディレクトリ構成・隔離方法・`claude` のモック・テストケース一覧・Format/Lint/Test コマンド | TDD でテストを書くとき、完了条件を確認するとき |
| [design/08-dev-environment.md](./design/08-dev-environment.md) | devcontainer / postCreate / 依存パッケージ / ローカル環境セットアップ方針 | 開発環境・依存を変更するとき |
| [design/09-decisions.md](./design/09-decisions.md) | 実機検証結果・未決事項・要件定義書への反映記録 | **設計判断を変える前に必ず読む**(根拠置き場) |

分冊の節番号は**分冊ごとに独立**している(各分冊が `## 1.` から始まる)。他ファイルへの参照は `[01-conventions.md §4](リンク先)` の形式で記述する(本書からは `./design/01-conventions.md`、分冊間は `./01-conventions.md`、分冊から本書へは `../design.md`)。本書の各章・各分冊には対応する要件定義書の節番号を併記する(トレーサビリティ)。全体の対応表は §4 を参照。

---

## 2. 全体アーキテクチャとデータフロー(要件3.1, 3.2)

### 2.1 データフロー

```
inputs/{project}/{date}/
  ├── *.md / *.txt         (議事メモ:Geminiメモ / 人間メモ。同一会議で複数可)
  └── *.mp4 等             (会議録画・音声。任意。中断・再開による分割で複数可)
        │
        │  ステップ0:ローカル文字起こし(faster-whisper)
        │  scripts/transcribe.py           ※外部送信なし
        │  メディア1本ごとに実行 → パートを保存(再実行時に再利用)
        ▼
outputs/{project}/{date}/00_transcript_parts/{メディア名}.txt
        │
        │  ファイル名昇順で連結(2件以上ならパートマーカーを付与)
        ▼
outputs/{project}/{date}/00_transcript.txt
        │
        │  ステップ1:話者・発言の整理
        │  claude -p --bare --system-prompt-file prompts/01_organize.md --tools ""
        │  stdin ← config.yaml + 議事メモ全件 + 00_transcript.txt
        │  ※--parallel N 指定時は N 分割して並列実行し 01_parts/ へ保存(要件3.2.8)
        ▼
outputs/{project}/{date}/01_speakers_utterances.md
        │
        │  ステップ2:会話の構造化
        │  claude -p --bare --system-prompt-file prompts/02_structure.md --tools ""
        │  stdin ← config.yaml + 01_speakers_utterances.md
        │  ※--parallel N 指定時は 01_speakers_utterances.md を改めて N 分割して
        │    並列実行し 02_parts/ へ保存(ステップ1のパート境界は引き継がない)
        ▼
outputs/{project}/{date}/02_structured_conversation.md
        │
        │  ステップ3:議事録フォーマット
        │  claude -p --bare --system-prompt-file prompts/03_format.md --tools ""
        │  stdin ← config.yaml + 02_structured_conversation.md
        ▼
outputs/{project}/{date}/minutes.md   ← 最終アウトプット
        │
        └── /minutes-review {project} {date}(人間による対話レビュー)
              → outputs/{project}/{date}/review_{NN}.md(指摘結果。連番で追記保存)
```

### 2.2 設計原則(要件3.2.5)

1. **各ステップは独立した `claude` プロセス呼び出し**とする。1セッション内で3段階を暗黙に進めさせない。
2. **各ステップの入力は前段の出力ファイルを明示的に読み込む**形とし、ステップ間で状態を共有しない。これにより `--from-step 2` のような部分再実行が他ステップに影響しない。
3. **Claude 側にファイルアクセス・ネットワークアクセスを与えない。** 入力はシェルが連結して stdin に流し込み、出力は stdout を受け取ってシェルが書き込む(`--tools ""`)。
4. **中間生成物はすべて人間が読める Markdown / プレーンテキスト**(要件3.2.6)。

---

## 3. ファイル構成(確定版)(要件4)

```
meeting-minutes-generator/
├── CLAUDE.md
├── README.md
├── LICENSE
├── .gitignore                          # ★新規(design/06-security.md §1)
├── requirements.txt                    # 実行時Python依存(faster-whisper)
├── requirements-dev.txt                # ★新規:開発時依存(pytest, pytest-cov, ruff, black)
├── docs/
│   ├── requirements.md
│   ├── design.md                       # 本書(ハブ)
│   ├── design/                         # 分冊(01-conventions.md 〜 09-decisions.md)
│   └── memo/                           # コメントアウト・処理削除・依存変更の記録
├── config/
│   └── auth/
│       ├── bedrock.env.example
│       ├── anthropic-api.env.example
│       ├── vertex.env.example
│       └── active.env                  # ★Git管理外
├── projects/
│   ├── _template/
│   │   ├── config.yaml
│   │   └── prompts/{01_organize,02_structure,03_format}.md
│   ├── sample/                         # 動作確認用ダミープロジェクト(架空の内容。design/05-project-assets.md §1)
│   └── {project-name}/ …               # ★Git管理外・_template のコピー
├── .claude/
│   └── commands/
│       ├── minutes-review.md
│       └── save-design.md              # 既存
├── scripts/
│   ├── transcribe.py
│   ├── aws_sso_login.sh
│   └── generate_minutes.sh
├── tests/                              # ★新規(design/07-testing.md)
│   ├── bats/{generate_minutes.bats,aws_sso_login.bats,harness.bats,helper.bash}
│   ├── python/test_transcribe.py
│   ├── fixtures/{memo.md,transcript.txt,config.yaml,step1_output.md,step2_output.md}
│   └── stubs/{claude,aws,transcribe.py}
├── .devcontainer/{devcontainer.json,postCreate.sh}
├── inputs/{project}/{date}/            # ★Git管理外(議事メモ・録画は同一会議で複数可)
└── outputs/{project}/{date}/           # ★Git管理外
    ├── 00_transcript_parts/            # メディア1本ごとの文字起こし(再実行時に再利用)
    ├── 00_transcript.txt               # ステップ0の文字起こし結果(パートを連結したもの)
    ├── 01_parts/                       # ステップ1のチャンク出力(--parallel 時。再実行時に再利用)
    ├── 01_speakers_utterances.md
    ├── 02_parts/                       # ステップ2のチャンク出力(--parallel 時。再実行時に再利用)
    ├── 02_structured_conversation.md
    ├── minutes.md
    └── review_{NN}.md                  # /minutes-review の指摘結果(design/05-project-assets.md §3.1)
```

上記は要件4章のディレクトリ構造と一致する(`00_transcript.txt` / `tests/` / `requirements-dev.txt` / `docs/` 配下は設計時に追加したもので、要件定義書へ反映済み。経緯は [design/09-decisions.md §3](./design/09-decisions.md))。

### 3.1 既存資産の移行方針

| 現状 | 移行後 | 備考 |
|---|---|---|
| `scripts/relogin.sh` | `scripts/aws_sso_login.sh` | セッション有効性チェックを追加([design/04-auth.md §1](./design/04-auth.md))。旧ファイルは削除し、削除の記録を `docs/memo/` に残す(`CLAUDE.md` 5章) |
| リポジトリ直下 `.env`(`AWS_PROFILE_NAME`) | `config/auth/active.env`(`AWS_PROFILE`) | 変数名を AWS 標準の `AWS_PROFILE` に統一。旧 `.env` も `.gitignore` に残す |
| `.devcontainer/devcontainer.json` | 要件7.1準拠へ更新([design/08-dev-environment.md §1](./design/08-dev-environment.md)) | `aws-cdk` Feature は要件に無いため削除 |

---

## 4. 要件定義書との対応表

| 要件 | 設計書の該当箇所 |
|---|---|
| 2 インプット / アウトプット(複数インプット) | [02-generate-minutes.md §4.2, §6](./design/02-generate-minutes.md)、[09-decisions.md §4](./design/09-decisions.md) |
| 3.1 音声・動画の前処理 | §2.1、[02-generate-minutes.md §6](./design/02-generate-minutes.md)、[03-transcribe.md](./design/03-transcribe.md) |
| 3.2.1 ステップ1 | [02-generate-minutes.md §4, §4.2](./design/02-generate-minutes.md)、[05-project-assets.md §2](./design/05-project-assets.md) |
| 3.2.2 ステップ2 | [02-generate-minutes.md §4](./design/02-generate-minutes.md)、[05-project-assets.md §2](./design/05-project-assets.md) |
| 3.2.3 ステップ3 | [02-generate-minutes.md §4](./design/02-generate-minutes.md)、[05-project-assets.md §2](./design/05-project-assets.md) |
| 3.2.4 システムプロンプト設計 | [05-project-assets.md §1, §2](./design/05-project-assets.md) |
| 3.2.5 Claude Code の呼び出し方針 | §2.2、[02-generate-minutes.md §1, §3, §5, §5.2, §5.3](./design/02-generate-minutes.md) |
| 3.2.6 中間生成物の Markdown 採用 | §2.2、[03-transcribe.md §3](./design/03-transcribe.md)、[05-project-assets.md §2](./design/05-project-assets.md) |
| 3.2.7 `CLAUDE.md` と運用時プロンプトの分離 | §1、[02-generate-minutes.md §5](./design/02-generate-minutes.md)、[09-decisions.md §1](./design/09-decisions.md) |
| 3.2.8 長大な入力の分割と並列実行 | [02-generate-minutes.md §9](./design/02-generate-minutes.md)、[01-conventions.md §8.4](./design/01-conventions.md)、[05-project-assets.md §2.4](./design/05-project-assets.md)、[09-decisions.md §5](./design/09-decisions.md) |
| 3.3 `/minutes-review` | [05-project-assets.md §3](./design/05-project-assets.md) |
| 3.4 認証経路の抽象化 | [04-auth.md §2.1, §2.3](./design/04-auth.md)、[02-generate-minutes.md §5.1](./design/02-generate-minutes.md)(ステップ別モデルID) |
| 3.4.1 Bedrock SSO 認証 | [04-auth.md §1, §2.2](./design/04-auth.md) |
| 4 アプリ構成 | §3、[09-decisions.md §3](./design/09-decisions.md) |
| 5 実行フロー | [02-generate-minutes.md §1, §3](./design/02-generate-minutes.md) |
| 6 セキュリティ要件 | [06-security.md](./design/06-security.md) |
| 7.1 devcontainer 要件 | [08-dev-environment.md §1, §2](./design/08-dev-environment.md) |
| 7.2 Codespaces 特有の考慮 | [03-transcribe.md §1](./design/03-transcribe.md)、[04-auth.md §1.2, §2.2](./design/04-auth.md) |
| 7.3 ローカル環境でのセットアップ | [08-dev-environment.md §4](./design/08-dev-environment.md)、`README.md`(手順の正) |
| 8.1 開発時の運用ルール | [05-project-assets.md §2](./design/05-project-assets.md)(KISS)、[08-dev-environment.md §3](./design/08-dev-environment.md)(依存最小化) |
| 8.2 設計書の維持 | §1, §1.1 |
| 8.3 TDD の適用方針 | [03-transcribe.md §4](./design/03-transcribe.md)、[07-testing.md](./design/07-testing.md) |
| 8.4 タスクの完了条件 | [07-testing.md §5](./design/07-testing.md) |
| 9 今後の検討事項 | [09-decisions.md §2](./design/09-decisions.md) |
| 共通(6章・8.1:規約とエラー処理) | [01-conventions.md](./design/01-conventions.md) |
