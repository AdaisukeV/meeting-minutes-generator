# リポジトリ直下 `.env` の Git 追跡解除

- **日付**:2026-08-16
- **分類**:処理削除(Git 追跡からの除外)
- **対象**:リポジトリ直下 `.env`

## 内容

`.gitignore` を作成した際、`.env` が `git check-ignore` に掛からないことから **`.env` がコミット済み(追跡済み)である**ことが判明した(`git ls-files --error-unmatch .env` が成功。追加コミットは `d1c889b`)。`.gitignore` は追跡済みファイルには効かないため、`git rm --cached .env` でインデックスから外した。ワークツリー上のファイルは削除していない(ローカルの SSO 実行に使われているため)。

```
$ git rm --cached .env
$ git check-ignore -v .env
.gitignore:7:.env	.env
```

## 理由

要件6.2(認証情報をリポジトリに含めない)。実装計画書 §1 は「`.env` は未追跡」という前提だったが、実態は追跡済みだったため、`.gitignore` の作成だけでは要件を満たせなかった。

## 影響・代替

- **追跡解除しても旧履歴には残る。** 追跡されていた `.env` の内容は SSO プロファイル名(AWS アカウントIDを含む)であり、アクセスキー等の**秘密値は含まない**。ただし公開リポジトリではアカウントIDの開示になるため、**公開版は当該履歴を持たない新規リポジトリとして作成した**(`git filter-repo` 等の履歴書き換え+force-push ではなく、確定したツリーからの単一コミットで作成する。GitHub では force-push 後も旧オブジェクトが SHA 指定で取得できる状態が GC まで残るため)。
- 今後の正しい置き場は `config/auth/active.env`(変数名は AWS 標準の `AWS_PROFILE`)。移行手順は README に記載する([../design.md §3.1](../design.md)、[04-auth.md §2.2](../design/04-auth.md))。
- 旧 `.env` を使う運用が残っていても漏洩しないよう、`.gitignore` には `.env` / `.env.*` を残す([06-security.md §1](../design/06-security.md))。
