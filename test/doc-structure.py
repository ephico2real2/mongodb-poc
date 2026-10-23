#!/usr/bin/env python3
"""The doc-guide skill's checks (.claude/skills/doc-guide/SKILL.md), no cluster needed.

  test/doc-structure.py                      every tracked .md, against test/doc-structure-baseline.txt (CI)
  test/doc-structure.py [--kind K] FILE...   the named files, strictly: no baseline
  test/doc-structure.py --list               today's violations, one per line, in the baseline's format
  test/doc-structure.py --prune              remove the baseline's lines that no longer occur (never adds one)
  test/doc-structure.py --guard REF          neither baseline has more entries than at REF (CI, on a pull request)

Three checks:
  rule 3   no command inline in prose or in a table cell: a backticked span that starts with a command word
           (kubectl, helm, oc, bash, curl, ...) or a repository script path and goes on with an argument. A name, a
           flag or a script's path alone is fine.
  rule 12  inside every ```bash, ```sh and ```shell block: no prompt ($, or # before a command); trailing comments
           on one column, two spaces or more after their command; no line over 120 characters; a space before a
           continuation backslash, and the continuation line indented two spaces from its command's first line; no
           blank line at the start or end, nor two in a row. A # inside quotes, in ${#var} or after an escaped space
           is not a comment, << inside $(( )) is a shift, a heredoc's body is not read, and quoted data spanning
           lines is checked for length only.
  shape    the page's kind (guide, record or reference; decided by KIND_BY_PATH, or --kind) has its H2s in order,
           and for a guide each step is "### N. <Imperative...>" with a fenced block and a "Result:" line.

The baseline lists the violations that were already there when the checks came in (#199), so CI passes while the
documents are rewritten. A violation that is not in it fails; so does a line of it that no longer occurs, so the
list always says what is left. --guard keeps it, and test/markdownlint-baseline.txt, from growing: it compares
counts, not lines, so a renamed page does not trip it, and only the kinds of entry the base has, so a new check
comes in with its baseline. Exit 0 = passes, 1 = fails, 2 = usage.
"""
import argparse
import collections
import fnmatch
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / "test" / "doc-structure-baseline.txt"
LINT_BASELINE = ROOT / "test" / "markdownlint-baseline.txt"
LINT_CONFIG = ROOT / ".markdownlint-cli2.yaml"

# First match wins; every other page is a reference. Keep in step with the skill's "The three kinds".
KIND_BY_PATH = [
    ("guide", "docs/building-the-kind-mesh-lab.md"),
    ("guide", "docs/prerequisite-and-setup-doc.md"),
    ("guide", "docs/mongot-envoy-*-runbook.md"),
    ("guide", "docs/mongot-envoy-vanity-url.md"),
    ("guide", "chart/mongodb-search-helm/volume-expansion-runbook.md"),
    ("record", "docs/testing-*.md"),
    ("record", "chart/mongodb-search-helm/docs/testing-*.md"),
]

# kind: (every H2 in its order, the optional ones among them, the H2 whose H3s are the steps)
KINDS = {
    "guide": (["What you get", "Architecture", "Prerequisites", "Steps", "Verify", "Reference", "Troubleshooting",
               "Clean up", "What's next"], {"Troubleshooting"}, "Steps"),
    "record": (["Summary", "Files", "Run it", "What was recorded", "Checks", "What is deliberately not here",
                "Runs that did not go to plan", "Open", "Clean up"],
               {"Summary", "Runs that did not go to plan", "Open"}, "What was recorded"),
    "reference": (None, set(), None),
}

COMMAND = re.compile(r"""
    ^(?:\$\s+)?(?:\./)?                         # a prompt, ./
    (?:
      (?:[A-Z_][A-Z0-9_]*=\S*\s+)+(?:\./)?(?:\S*\.(?:sh|py)|scripts/mdfmt)\b   # VAR=value before a script runs it
    | (?:[A-Z_][A-Z0-9_]*=\S*\s+)*              # VAR=value prefixes
      (?:kubectl|helm|oc|bash|curl|docker|kind|colima|openssl|git|gh|cilium|cilium-dbg|hubble|mongosh|sudo|export
         |make|python3|crc|cd|cat|ss|jq|yq|npm|npx|grpcurl|crictl|go\s+run|for|env|watch|mkdir|ssh|scp|podman
         |limactl|\S*\.(?:sh|py)|scripts/mdfmt)
      \s+\S                                     # and an argument: the word or script alone is a name
    )
""", re.X)
FENCE = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")
SHELL = {"bash", "sh", "shell"}  # the info words of the blocks rule 12 applies to
WIDTH = 120
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*\\?(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")  # <<EOF, <<-'EOF'; not <<<
WORD_START = " \t;&|()<>"  # a # starts a comment only at the start of a word: after one of these, or the line's start
SPAN = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)", re.S)


def ignores():
    """The ignores of .markdownlint-cli2.yaml, so both tools skip the same vendored and recorded files."""
    globs, inside = [], False
    for line in LINT_CONFIG.read_text(encoding="utf-8").splitlines():
        if re.match(r"^\S", line):
            inside = line.startswith("ignores:")
        elif inside and (m := re.match(r'^\s+-\s+"?([^"#]+?)"?\s*$', line)):
            globs.append(m.group(1))
    return globs


def tracked():
    out = subprocess.run(["git", "ls-files", "*.md"], cwd=ROOT, check=True, capture_output=True, text=True).stdout
    skip = ignores()
    return [p for p in out.splitlines() if not any(fnmatch.fnmatch(p, g) for g in skip)]


def kind_of(path):
    return next((k for k, g in KIND_BY_PATH if fnmatch.fnmatch(path, g)), "reference")


def parse(text):
    """The page's lines with fenced blocks and HTML comments blanked (line numbers kept), its fences as
    (line index of the opener, info word), and its shell blocks as [(line index, the line as the reader copies it)]:
    without the blockquote markers and the indent of the fence (a fence in a list item is indented)."""
    text = text.replace("\r\n", "\n")  # the CLI's read_text() does this; a caller with the bytes may not
    raw = text.split("\n")
    text = re.sub(r"<!--.*?-->", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    outside, fences, blocks, fence, block, indent, quoted = [], [], [], None, None, 0, False
    for i, line in enumerate(text.split("\n")):
        body = re.sub(r"^\s*(?:>\s?)+", "", line)  # a fence may sit in a blockquote
        if fence:
            if re.match(rf"^\s*{re.escape(fence[0])}{{{len(fence)},}}\s*$", body):
                fence = None
            elif block is not None:
                content = re.sub(r"^\s*(?:>\s?)+", "", raw[i]) if quoted else raw[i]
                block.append((i, re.sub(rf"^ {{0,{indent}}}", "", content)))
            outside.append("")
            continue
        m = FENCE.match(body)
        if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
            fence = m.group(1)
            info = (m.group(2).split() or [""])[0]
            fences.append((i, info))
            block, indent, quoted = ([] if info in SHELL else None), len(body) - len(body.lstrip()), body != line
            if block is not None:
                blocks.append(block)
            outside.append("")
            continue
        outside.append(line)
    return outside, fences, blocks


def inline_commands(outside):
    """(line number, command) for each command in a backticked span outside fenced blocks. A table row is read on
    its own; the other lines are read a paragraph at a time, because a span may wrap onto the next line."""
    units, para = [], []
    for i, line in enumerate(outside):
        if line.lstrip().startswith("|"):
            units.append((i, line))
        if not line.strip() or line.lstrip().startswith("|"):
            if para:
                units.append((para[0][0], "\n".join(t for _, t in para)))
            para = []
        else:
            para.append((i, line))
    if para:
        units.append((para[0][0], "\n".join(t for _, t in para)))
    found = []
    for start, unit in units:
        unit = unit.replace("\\`", "  ")
        for m in SPAN.finditer(unit):
            code = " ".join(m.group(2).split())
            if COMMAND.match(code):
                found.append((start + unit.count("\n", 0, m.start()) + 1, code))
    return sorted(found)


def lex(line, quote):
    """Read one line of shell, starting in the quote the line before left open: None, ', ", `, $', or for an
    arithmetic $(( or (( one ) per parenthesis still open. Returns (the column of the # that starts a comment, or
    None; whether a backslash at the end continues the line; the heredocs the line opens, as (delimiter, whether
    <<- strips its tabs); the quote left open)."""
    i, heredocs, word_start = 0, [], quote is None
    while i < len(line):
        c = line[i]
        if quote and quote.startswith(")"):  # inside arithmetic: << is a shift, # is not a comment
            if c == "(":
                quote += ")"
            elif c == ")":
                quote = quote[:-1] or None
        elif quote == "'":
            quote = None if c == "'" else quote
        elif quote:  # ", ` and $' take backslash escapes
            if c == "\\":
                if i == len(line) - 1 and quote in ('"', "`"):
                    return None, True, heredocs, quote
                i += 1
            elif c == quote[-1]:
                quote = None
        elif c == "\\":
            if i == len(line) - 1:
                return None, True, heredocs, None
            i += 1
            word_start = False  # an escaped space or tab does not start a word
        elif c == "#" and word_start:
            return i, False, heredocs, None
        elif line.startswith("$((", i) or (word_start and line.startswith("((", i)):
            i += 2 if c == "$" else 1
            quote, word_start = "))", False
        elif c == "$" and line[i + 1:i + 2] == "'":
            quote, i, word_start = "$'", i + 1, False
        elif c in "'\"`":
            quote, word_start = c, False
        elif m := HEREDOC.match(line, i):
            heredocs.append((m.group(2), line.startswith("<<-", i)))
            i, word_start = m.end(), False
            continue
        else:
            word_start = c in WORD_START
        i += 1
    return None, False, heredocs, quote


def bash_block(block):
    """(line index, normalised description, detail) for each rule-12 problem in one shell block, given as
    [(line index, line)]. A heredoc's body is not read; a line that starts inside a quote is data, so it is not
    checked for a prompt, a continuation's indent or as a blank line."""
    found, trailing = [], []
    quote, pending, heredoc, start, continued, blank = None, [], None, 0, False, False
    for k, (i, line) in enumerate(block):
        if heredoc:  # it ends on its delimiter alone; <<- strips leading tabs, nothing else
            delimiter, strip_tabs = heredoc
            if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                heredoc = pending.pop(0) if pending else None
            blank = False
            continue
        if not line.strip() and quote is None:  # a blank line in quoted data is the data's
            where = "start" if k == 0 else "end" if k == len(block) - 1 else None
            if where:
                found.append((i, f"a blank line at the {where} of the block", ""))
            elif blank:
                found.append((i, "two blank lines in a row", ""))
            blank, continued = True, False
            continue
        blank = False
        if len(line) > WIDTH:
            found.append((i, f"a line over {WIDTH} characters", f" ({len(line)})"))
        indent = len(line) - len(line.lstrip(" "))
        if quote is None:
            if continued and indent != start + 2:
                found.append((i, "a continuation line not indented two spaces from the command's first line",
                              f" ({indent - start})"))
            if not continued:
                start = indent
                prompt = re.match(r"\s*(\$|#)\s+(.*)", line)
                if prompt and prompt.group(1) == "$":
                    found.append((i, "a prompt at the start of a line", " ($)"))
                elif prompt and COMMAND.match(prompt.group(2)):  # rules 12a and 12f
                    found.append((i, "a prompt at the start of a line", " (# before a command: a root prompt or a "
                                  "commented-out command)"))
        col, continued, opened, quote = lex(line, quote)
        if continued and quote is None and not line.endswith(" \\"):
            found.append((i, "no space before a continuation backslash", ""))
        if col is not None and line[:col].strip():
            trailing.append((i, col))
            if not line[:col].endswith("  "):
                found.append((i, "fewer than two spaces before a trailing comment", ""))
        pending += opened
        if pending and not continued and quote is None:
            heredoc = pending.pop(0)
    off = [(i, col) for i, col in trailing if col != trailing[0][1]]
    if off:
        found.append((off[0][0], "trailing comments not on one column",
                      f" (columns {', '.join(str(c + 1) for c in sorted({c for _, c in trailing}))})"))
    return found


def shape(outside, fences, kind):
    """The errors in the page's headings and steps for its kind."""
    errors = []
    heads = [(i, len(m.group(1)), m.group(2).strip().rstrip("#").strip())
             for i, l in enumerate(outside) if (m := re.match(r"^(#{1,6})\s+(.+)$", l))]
    h1 = [t for _, n, t in heads if n == 1]
    if len(h1) != 1:
        errors.append(f"one H1 expected, found {h1}")
    h2 = [(i, t) for i, n, t in heads if n == 2]
    first_h2 = h2[0][0] if h2 else len(outside)
    h1_line = next((i for i, n, _ in heads if n == 1), -1)
    if not any(l.strip() for l in outside[h1_line + 1:first_h2]):
        errors.append("no intro between the H1 and the first H2")
    order, optional, steps_h2 = KINDS[kind]
    if order is None:
        return errors
    titles = [t for _, t in h2]
    if titles != [t for t in order if t in titles] or not set(order) - optional <= set(titles):
        errors.append(f"H2 order must be {order} (optional {sorted(optional)}); found {titles}")
    section = next(((i, (h2 + [(len(outside), "")])[k + 1][0]) for k, (i, t) in enumerate(h2) if t == steps_h2), None)
    if not section:
        return errors + [f"no '{steps_h2}' section"]
    starts = [i for i, n, _ in heads if n == 3 and section[0] < i < section[1]]
    if not starts:
        errors.append(f"'{steps_h2}' has no H3 entries")
    for n, (a, b) in enumerate(zip(starts, starts[1:] + [section[1]]), 1):
        title = outside[a].lstrip("#").strip()
        step_fences = [info for i, info in fences if a < i < b]
        if kind == "guide":
            if not re.match(rf"{n}\. [A-Z]", title):
                errors.append(f"step title must be '{n}. <Imperative...>', found '{title}'")
            if "bash" not in step_fences:
                errors.append(f"step {n} has no ```bash command block")
            if not any(re.match(r"^Result:", l) for l in outside[a:b]):
                errors.append(f"step {n} has no 'Result:' line")
            if re.search(r"(?i)\b(first|second|third|fourth) (apply|run)\b", "\n".join(outside[a:b])):
                errors.append(f"step {n} narrates a numbered run: the guide shows what works, the record the runs")
        else:
            if not re.match(r"[A-Z]{0,2}\d+\. [A-Z0-9]", title):
                errors.append(f"recorded step must be '<N or ID>. <Title>', found '{title}'")
            if "bash" not in step_fences or "text" not in step_fences:
                errors.append(f"recorded step '{title}' needs a ```bash command block and a ```text output block")
    return errors


def check(path, kind):
    """The page's violations, in the baseline's format, and the messages that explain them."""
    outside, fences, blocks = parse((ROOT / path).read_text(encoding="utf-8"))
    entries, messages = [], []
    for line, code in inline_commands(outside):
        entries.append(f"{path}\tinline\t{code}")
        messages.append(f"{path}:{line}: command inline (rule 3, move it to a ```bash block): `{code}`")
    for i, what, detail in sorted(p for b in blocks for p in bash_block(b)):
        entries.append(f"{path}\tblock\t{what}")
        messages.append(f"{path}:{i + 1}: bash block (rule 12): {what}{detail}")
    errors = shape(outside, fences, kind)
    if errors:
        entries.append(f"{path}\tshape\t{kind}")
        messages += [f"{path}: {kind}: {e}" for e in errors]
    return entries, messages


def read_baseline():
    lines = BASELINE.read_text(encoding="utf-8").splitlines() if BASELINE.exists() else []
    return [l for l in lines if l and not l.startswith("#")], [l for l in lines if l.startswith("#")]


def entry_kind(line):
    """The kind of a structure-baseline entry: inline, shape or block."""
    return (line.split("\t") + [""])[1]


def guard(ref):
    """Neither baseline gains an entry against ref. The structure baseline is compared without the pages' paths, so a
    renamed page passes and a fixed violation cannot be traded for a new one; the markdownlint baseline, which is
    paths only, by count. Only the structure baseline's entry kinds that are at ref are compared, so the pull request
    that brings in a check also brings in its baseline; from the next one on, that kind is compared too. A baseline
    that is not at ref yet has nothing to compare; a ref that is not here is an error, never a pass."""
    if subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"], cwd=ROOT,
                      capture_output=True).returncode:
        print(f"--guard: {ref} is not a commit in this clone; fetch it first", file=sys.stderr)
        return 2

    def entries(text):
        return [l for l in text.splitlines() if l.strip() and not l.startswith("#")]

    failed = False
    for path in (BASELINE, LINT_BASELINE):
        rel = path.relative_to(ROOT).as_posix()
        now = entries(path.read_text(encoding="utf-8"))
        shown = subprocess.run(["git", "show", f"{ref}:{rel}"], cwd=ROOT, capture_output=True, text=True)
        if shown.returncode:
            print(f"{rel}: {len(now)} entries; not at {ref}, nothing to compare")
            continue
        then = entries(shown.stdout)
        added, unknown = [], []
        if path == BASELINE:
            kinds = {entry_kind(l) for l in then}
            unknown = [l for l in now if entry_kind(l) not in kinds]
            now = [l for l in now if entry_kind(l) in kinds]
            unpathed = [collections.Counter(l.split("\t", 1)[-1] for l in ls) for ls in (now, then)]
            added = sorted((unpathed[0] - unpathed[1]).elements())
        verdict = ("GREW, fix the page instead" if len(now) > len(then)
                   else f"NEW, fix the page instead: {added}" if added else "ok")
        new_kinds = sorted({entry_kind(l) for l in unknown})
        print(f"{rel}: {len(now)} entries, {len(then)} at {ref}: {verdict}"
              + (f"; {len(unknown)} of a kind not at {ref} {new_kinds}, not compared" if unknown else ""))
        failed |= verdict != "ok"
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--kind", choices=sorted(KINDS))
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--prune", action="store_true")
    ap.add_argument("--guard", metavar="REF")
    ap.add_argument("files", nargs="*")
    args = ap.parse_args()
    if args.kind and not args.files:
        ap.error("--kind needs the files it applies to")
    if args.guard:
        return guard(args.guard)

    if args.files:  # strict: the named files, no baseline
        failed = False
        for f in args.files:
            path = str(Path(f).resolve().relative_to(ROOT))
            kind = args.kind or kind_of(path)
            entries, messages = check(path, kind)
            print("\n".join(messages) if messages else f"PASS ({kind}): {path}")
            failed |= bool(entries)
        return 1 if failed else 0

    entries, messages = [], {}
    for path in tracked():
        e, m = check(path, kind_of(path))
        entries += e
        messages[path] = m
    if args.list:
        print(*sorted(entries), sep="\n")
        return 0
    listed, header = read_baseline()
    now, then = collections.Counter(entries), collections.Counter(listed)
    if args.prune:
        kept = sorted((now & then).elements())
        BASELINE.write_text("\n".join(header + kept) + "\n", encoding="utf-8")
        print(f"baseline: {len(listed)} -> {len(kept)} lines")
        return 0
    new, gone = now - then, then - now
    for entry in sorted(new.elements()):
        path, what, detail = entry.split("\t")
        explain = [m for m in messages[path] if (what == "inline" and m.endswith(f"`{detail}`"))
                   or (what == "shape" and m.startswith(f"{path}: {detail}:"))
                   or (what == "block" and re.search(rf"\(rule 12\): {re.escape(detail)}(?: \(|$)", m))]
        print("NEW:", *sorted(set(explain)) or [entry], sep="\n  ")
    for entry in sorted(gone.elements()):
        print(f"FIXED, still in {BASELINE.relative_to(ROOT)} (remove the line, or run --prune): {entry}")
    total = len(entries)
    if new or gone:
        print(f"FAIL: {sum(new.values())} new, {sum(gone.values())} fixed but listed; {total} violations, "
              f"{len(listed)} listed")
        return 1
    print(f"PASS: {len(messages)} documents; {total} violations, all in the baseline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
