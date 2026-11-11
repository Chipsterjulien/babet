#!/usr/bin/env python3
"""Offline regression tests for docs/preprocess_pdf.py.

The PDF manual is one merged document: every relative Markdown link must
become an internal anchor, a public repository URL or plain text, and anything
else must fail the build. Neither pandoc nor a LaTeX engine is needed here.
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "docs" / "preprocess_pdf.py"
PASSED = []
FAILED = []


def check(label, condition, detail=""):
    if condition:
        PASSED.append(label)
        print(f"[PASS] {label}")
    else:
        FAILED.append(label)
        print(f"[FAIL] {label}" + (f"\n       {detail}" if detail else ""))


def run(src, dst, order=None, env=None):
    command = [sys.executable, str(SCRIPT), str(src), str(dst)]
    if order is not None:
        command.append(str(order))
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith("BABET_DOCS_")}
    environment.update(env or {})
    return subprocess.run(command, text=True, capture_output=True,
                          timeout=120, env=environment)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def make_tree(root, readme_extra="", order_extra="", files=()):
    """A small repository: two chapters, a changelog and an example."""
    write(root / "CHANGELOG.md", "# Changes\n")
    write(root / "examples" / "demo" / "main.lua", "print('demo')\n")
    write(root / "docs" / "xx" / "README.md", (
        "> **English** | [Français](../yy/README.md)\n"
        "\n"
        "# Index\n"
        "\n"
        "Chapter: [module a](modules/a.md), anchored: [mkdir](modules/a.md#mkdir).\n"
        "Wrapped: [a link whose text\n"
        "spans two lines](modules/a.md).\n"
        "Repo file: [`Changelog`](../../CHANGELOG.md), "
        "example: [demo](../../examples/demo/main.lua), "
        "folder: [examples](../../examples/demo/).\n"
        "External: [site](https://example.org/json), mail: [me](mailto:a@b.c).\n"
        "Folder text: [modules/](modules/), "
        "manifest: [order](../manual_order_xx.txt).\n"
        "Inline code `handlers[name](arg)` is not a link.\n"
        "\n"
        "```lua\n"
        "callbacks[i](value) -- [not a link](missing.md)\n"
        "```\n"
        "\n"
        "- nested fence:\n"
        "\n"
        "    ```lua\n"
        "    t[1](nothing.md)\n"
        "    ```\n"
        + readme_extra
    ))
    write(root / "docs" / "xx" / "modules" / "a.md", (
        "> [English](../../yy/modules/a.md) | **Français**\n"
        "\n"
        "# Module A\n"
        "\n"
        "<a id=\"mkdir\"></a>\n"
        "### `mkdir`\n"
        "\n"
        "Back to the [index](../README.md).\n"
    ))
    write(root / "docs" / "manual_order_xx.txt", (
        "# comment\n"
        "\n"
        "docs/xx/README.md\n"
        "docs/xx/modules/a.md\n"
        "docs/yy/README.md\n"  # another language: ignored for xx
        + order_extra
    ))
    for relative, text in files:
        write(root / relative, text)
    return root / "docs" / "xx"


def expect_failure(label, needle, **tree):
    with tempfile.TemporaryDirectory(prefix="babet-docs-") as tmp:
        root = Path(tmp) / "repo with space"
        src = make_tree(root, **tree)
        result = run(src, Path(tmp) / "out")
        check(label,
              result.returncode == 1 and needle in result.stderr
              and "error(s), PDF not generated" in result.stderr,
              f"rc={result.returncode} stderr={result.stderr!r}")


def synthetic_tests():
    with tempfile.TemporaryDirectory(prefix="babet-docs-") as tmp:
        root = Path(tmp) / "repo with space"
        src = make_tree(root)
        out = Path(tmp) / "out"
        result = run(src, out)
        check("valid tree is accepted without any diagnostic",
              result.returncode == 0 and result.stderr == "",
              f"rc={result.returncode} stderr={result.stderr!r}")
        readme = (out / "README.md").read_text(encoding="utf-8")
        module = (out / "modules" / "a.md").read_text(encoding="utf-8")
        base = "https://github.com/Chipsterjulien/babet"
        check("chapter link becomes the chapter anchor",
              "[module a](#ch-a)" in readme)
        check("chapter link with a fragment keeps only the fragment",
              "[mkdir](#mkdir)" in readme)
        check("link text spanning two lines is rewritten",
              "spans two lines](#ch-a)" in readme)
        check("link from a module back to the index is resolved by path",
              "[index](#ch-readme)" in module)
        check("repository file becomes a public blob URL",
              f"[`Changelog`]({base}/blob/main/CHANGELOG.md)" in readme
              and f"[demo]({base}/blob/main/examples/demo/main.lua)" in readme)
        check("repository folder becomes a public tree URL",
              f"[examples]({base}/tree/main/examples/demo)" in readme)
        check("external and mailto links are untouched",
              "[site](https://example.org/json)" in readme
              and "[me](mailto:a@b.c)" in readme)
        check("modules/ folder and manifest links become plain text",
              "`modules/`" in readme and "`order`" in readme
              and "(modules/)" not in readme and "manual_order_xx.txt)" not in readme)
        check("inline code and fenced code are left alone",
              "`handlers[name](arg)`" in readme
              and "callbacks[i](value) -- [not a link](missing.md)" in readme
              and "t[1](nothing.md)" in readme)
        check("language toggles are stripped in both orders",
              "English" not in readme and "English" not in module)
        check("chapter headings and HTML anchors receive pandoc ids",
              "# Index {#ch-readme}" in readme
              and "# Module A {#ch-a}" in module
              and "### `mkdir` {#mkdir}" in module)
        check("sources are never modified",
              "(modules/a.md)" in (src / "README.md").read_text(encoding="utf-8"))

        tagged = run(src, out, env={"BABET_DOCS_REF": "v9.9.9"})
        check("BABET_DOCS_REF selects the linked revision",
              tagged.returncode == 0 and f"{base}/blob/v9.9.9/CHANGELOG.md"
              in (out / "README.md").read_text(encoding="utf-8"))

        explicit = run(src, out, order=root / "docs" / "manual_order_xx.txt")
        check("explicit order file argument is accepted",
              explicit.returncode == 0 and explicit.stderr == "")

    expect_failure("broken link fails with file and line",
                   "docs/xx/README.md:23: lien cassé [gone](modules/gone.md)",
                   readme_extra="\nSee [gone](modules/gone.md).\n")
    expect_failure("link to a chapter missing from the order file fails",
                   "docs/xx/README.md:23: lien [extra](extra.md) vers un chapitre absent",
                   readme_extra="\nSee [extra](extra.md).\n",
                   files=[("docs/xx/extra.md", "# Extra\n")])
    expect_failure("Markdown file missing from the order file fails",
                   "docs/xx/extra.md:1: fichier absent du manifeste",
                   files=[("docs/xx/extra.md", "# Extra\n")])
    expect_failure("order entry without a file fails",
                   "chapitre introuvable : docs/xx/ghost.md",
                   order_extra="docs/xx/ghost.md\n")
    expect_failure("two chapters with the same anchor fail",
                   "produisent la même ancre #ch-a",
                   order_extra="docs/xx/other/a.md\n",
                   files=[("docs/xx/other/a.md", "# Other A\n")])
    expect_failure("link leaving the repository fails",
                   "hors du dépôt",
                   readme_extra="\nSee [outside](../../../outside.txt).\n",
                   files=[("../outside.txt", "outside\n")])

    with tempfile.TemporaryDirectory(prefix="babet-docs-") as tmp:
        src = make_tree(Path(tmp) / "repo")
        (Path(tmp) / "repo" / "docs" / "manual_order_xx.txt").unlink()
        result = run(src, Path(tmp) / "out")
        check("missing order file fails",
              result.returncode == 1 and "order file not found" in result.stderr)


LINK = re.compile(r'(?<!!)\[[^\]]+\]\(([^)#][^)]*)\)')


def remaining_relative_links(text):
    """Relative link targets left in preprocessed Markdown, code excluded."""
    text = re.sub(r'^[ \t]*(```|~~~).*?^[ \t]*\1[ \t]*$', '', text,
                  flags=re.MULTILINE | re.DOTALL)
    text = re.sub(r'`[^`\n]*`', '', text)
    return [target for target in LINK.findall(text)
            if not re.match(r'^[a-z][a-z0-9+.-]*://', target)
            and not target.startswith('mailto:')]


def real_documentation_tests():
    for lang in ("en", "fr"):
        src = ROOT / "docs" / lang
        order = ROOT / "docs" / f"manual_order_{lang}.txt"
        with tempfile.TemporaryDirectory(prefix="babet-docs-") as tmp:
            out = Path(tmp) / "out"
            result = run(src, out, order=order)
            check(f"{lang} manual preprocesses without warning or error",
                  result.returncode == 0 and result.stderr == "",
                  f"rc={result.returncode} stderr={result.stderr[-600:]!r}")
            if result.returncode != 0:
                continue
            leftovers = []
            unanchored = []
            chapters = [line.strip() for line in order.read_text(encoding="utf-8").splitlines()
                        if line.strip() and not line.strip().startswith("#")]
            for chapter in chapters:
                relative = Path(chapter).relative_to(f"docs/{lang}")
                text = (out / relative).read_text(encoding="utf-8")
                leftovers += [f"{chapter}: {t}" for t in remaining_relative_links(text)]
                if not re.search(r'^# .*\{#ch-[a-z0-9-]+\}\s*$', text, re.MULTILINE):
                    unanchored.append(chapter)
            check(f"{lang} manual keeps no relative link ({len(chapters)} chapters)",
                  not leftovers, "; ".join(leftovers[:5]))
            check(f"{lang} manual: every chapter heading has its anchor",
                  not unanchored, "; ".join(unanchored[:5]))
            on_disk = sorted(str(p.relative_to(ROOT)) for p in src.rglob("*.md"))
            check(f"{lang} manual lists every Markdown chapter",
                  on_disk == sorted(chapters),
                  f"missing: {sorted(set(on_disk) - set(chapters))}")


def main():
    synthetic_tests()
    real_documentation_tests()
    print(f"docs preprocess regression tests: {len(PASSED)} PASS / {len(FAILED)} FAIL")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
