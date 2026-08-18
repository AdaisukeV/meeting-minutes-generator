# 出力の先頭行の検証追加に伴うテンプレート設定・運用プロンプトの契約変更

- **日付**:2026-08-18
- **分類**:運用時プロンプト・テンプレート設定の契約変更 / スタブの既定出力の変更(コメントアウト・処理削除・依存変更には該当しない)
- **対象**:`projects/_template/config.yaml`、`projects/_template/prompts/03_format.md`(および `projects/sample/prompts/` への反映)、`config/auth/*.env.example`、`tests/stubs/claude`

## 内容

出力トークン上限に達した際に `claude` が応答を自動継続し、**先頭が失われた出力が終了コード0で確定してしまう**欠陥([09-decisions.md §6.5](../design/09-decisions.md))への対処として、スクリプトが各ステップの出力の1行目を検証するようにした([02-generate-minutes.md §5.5](../design/02-generate-minutes.md))。これに伴い、コード以外に次の契約を変更した。

| ファイル | 変更内容 |
|---|---|
| `projects/_template/config.yaml` | `minutes_sections` に「全発言を再掲するセクション(『詳細な議事録』『発言録』等)を足さない」注意を追記。経過は `02_structured_conversation.md` を参照する運用が既定である旨も明記 |
| `projects/_template/prompts/03_format.md` | 「議論の経過そのものは議事録に含めない」に但し書きを追加。`minutes_sections[]` に経過再掲のセクションが指定されている場合も `### やり取り` を全文転記せず、論点の推移を数行に要約する |
| `config/auth/{bedrock,anthropic-api,vertex}.env.example` | コメントアウトした `CLAUDE_CODE_DISABLE_THINKING=1` を追記(thinking が出力上限を本文と共有する説明付き)。`MAX_THINKING_TOKENS` も併記するが「実測で効果が確認できなかった」旨を添えた |
| `tests/stubs/claude` | `STUB_STDOUT_FILE` 未指定時の既定出力を、`--system-prompt-file` の basename から判定したステップの**1行目の契約を満たす行**で始めるようにした |

**運用時プロンプトの「出力の1行目」の指示は、これ以降スクリプト側の検証対象である。** ステップ1・2は `^(#{1,6} |- )`、ステップ3は `^# ` を要求する。文言ではなく Markdown の構造で判定するため見出し語の変更は自由だが、**1行目を見出しでも箇条書きでもない行に変える改変はできない**(実行が必ずコード3で止まる)。

## 理由

- **テンプレート設定に注意を書いた**理由:実プロジェクト(`projects/{project-name}`)で `minutes_sections` に `詳細な議事録(発言者・発言内容)` を追加していたことが、ステップ3の出力の69%(14,241字 / 20,580字)を占め、上限超過の直接の引き金になっていた。設定は Git 管理外(`projects/*` は `_template` と `sample` のみ追跡)なので、再発防止はテンプレート側の注意書きにしか置けない。
- **`03_format.md` に但し書きを足した**理由:利用者が経過再掲のセクションを敢えて指定した場合でも、全文転記に至らないようプロンプト側で歯止めをかける(設定の削除を強制はしない)。
- **thinking の抑制を案内のみに留めた**理由:認証経路ごとの分岐をスクリプトに増やさない方針(`CLAUDE.md` 4章)。`CLAUDE_CODE_MAX_OUTPUT_TOKENS` と同じ扱いで、`active.env` に書ける環境変数として案内するだけにした。
- **案内を `MAX_THINKING_TOKENS` から `CLAUDE_CODE_DISABLE_THINKING` に切り替えた**理由:実データでの検証中に `MAX_THINKING_TOKENS=8000` が尊重されないことが分かった(8000 指定でも出力上限32,000を使い切る thinking のみの応答が2回発生)。`CLAUDE_CODE_DISABLE_THINKING=1` では同じ入力のステップ3が **41分 → 1分52秒**で完了し、自動継続も起きなくなった([09-decisions.md §6.6](../design/09-decisions.md) の実測表)。
- **スタブの既定出力を変えた**理由:既存のケースが `STUB CLAUDE OUTPUT` の1行だけを返しており、先頭行の検証を入れると全ケースが失敗するため。`--system-prompt-file` が渡らない呼び出しでは従来どおり1行のみを出し、`harness.bats` の完全一致アサーションを保った。

## 影響・代替

- **プロジェクト固有プロンプトの反映先**:`_template` を正として `sample` へコピーではなく該当行のみ反映した。実プロジェクトの `projects/{project-name}/prompts/` は独自構成があるためテンプレートで上書きしない(前回のメモと同じ方針)。
- 既存ケースのうち **55**(パート出力の本文を `PART_BODY` → `## PART_BODY` に変更)と **24b**(`find` の除外に `*.truncated.md` を追加)を先頭行の契約に合わせて調整した。挙動の検証内容は変えていない。
- 検知はできるが**上限に当たった呼び出しの待ち時間は取り戻せない**。予防(`CLAUDE_CODE_DISABLE_THINKING=1`・`--parallel`・`minutes_sections` の見直し)と併用する必要がある。
- 部分出力の退避先は `<確定先>.truncated.md` で、`.error.log`(エラーメッセージ)とは分けている。どちらも成功時に削除される。
