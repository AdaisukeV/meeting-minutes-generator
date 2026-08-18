#!/usr/bin/env python3
"""``scripts/transcribe.py`` のテスト用スタブ(docs/design/07-testing.md §3)。

実際の文字起こしは行わず、引数を記録して ``--output`` にダミーの
文字起こしテキストを書き込む。挙動は共通のスタブ用環境変数で制御する。

ダミー出力のヘッダには ``--input`` の basename を含める(実物の
``build_header`` と同じ性質)。これにより、分割録画のどのメディアが
どのパートになったかをテスト側で追跡できる。
"""

import os
import sys

DUMMY_TRANSCRIPT = """# transcript: {src}
# model: stub / language: ja
# generated-by: tests/stubs/transcribe.py (stub)

[00:00:01] STUB_TRANSCRIPT_LINE {src}
"""


def main(argv: list[str]) -> int:
    args_file = os.environ.get("STUB_ARGS_FILE")
    if args_file:
        with open(args_file, "a", encoding="utf-8") as fh:
            fh.write("--- transcribe.py ---\n")
            fh.writelines(f"{arg}\n" for arg in argv)

    cwd_file = os.environ.get("STUB_CWD_FILE")
    if cwd_file:
        with open(cwd_file, "a", encoding="utf-8") as fh:
            fh.write(f"{os.getcwd()}\n")

    exit_code = int(os.environ.get("STUB_EXIT", "0"))

    output = None
    src = "stub"
    for i, arg in enumerate(argv):
        if arg == "--output" and i + 1 < len(argv):
            output = argv[i + 1]
        elif arg.startswith("--output="):
            output = arg.split("=", 1)[1]
        elif arg == "--input" and i + 1 < len(argv):
            src = os.path.basename(argv[i + 1])
        elif arg.startswith("--input="):
            src = os.path.basename(arg.split("=", 1)[1])

    if exit_code == 0 and output:
        os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
        stdout_file = os.environ.get("STUB_STDOUT_FILE")
        text = DUMMY_TRANSCRIPT.format(src=src)
        if stdout_file:
            with open(stdout_file, encoding="utf-8") as fh:
                text = fh.read()
        with open(output, "w", encoding="utf-8") as fh:
            fh.write(text)

    if exit_code != 0:
        print("stub transcribe.py: forced failure", file=sys.stderr)

    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
