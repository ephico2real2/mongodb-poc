#!/usr/bin/env python3
"""The doc-guide skill's checks (.claude/skills/doc-guide/SKILL.md), no cluster needed.

  test/doc-structure.py                      every tracked .md, against test/doc-structure-baseline.txt (CI)
  test/doc-structure.py [--kind K] FILE...   the named files, strictly: no baseline
  test/doc-structure.py --list               today's violations, one per line, in the baseline's format
  test/doc-structure.py --prune              remove the baseline's lines that no longer occur (never adds one)
  test/doc-structure.py --guard REF          neither baseline has more entries than at REF (CI, on a pull request)

Two checks:
  rule 3   no command inline in prose or in a table cell: a backticked span that starts with a command word
           (kubectl, helm, oc, bash, curl, ...) or a repository script path and goes on with an argument. A name, a
           flag or a script's path alone is fine.
  shape    the page's kind (guide, record or reference; decided by KIND_BY_PATH, or --kind) has its H2s in order,
           and for a guide each step is "### N. <Imperative...>" with a fenced block and a "Result:" line.

The baseline lists the violations that were already there when the checks came in (#199), so CI passes while the
documents are rewritten. A violation that is not in it fails; so does a line of it that no longer occurs, so the
list always says what is left. --guard keeps it, and test/markdownlint-baseline.txt, from growing: it compares
counts, not lines, so a renamed page does not trip it. Exit 0 = passes, 1 = fails, 2 = usage.
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
    """The page's lines with fenced blocks and HTML comments blanked (line numbers kept), and its fences as
    (line index of the opener, info word)."""
    text = re.sub(r"<!--.*?-->", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    outside, fences, fence = [], [], None
    for i, line in enumerate(text.split("\n")):
        body = re.sub(r"^\s*(?:>\s?)+", "", line)  # a fence may sit in a blockquote
        if fence:
            if re.match(rf"^\s*{re.escape(fence[0])}{{{len(fence)},}}\s*$", body):
                fence = None
            outside.append("")
            continue
        m = FENCE.match(body)
        if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
            fence = m.group(1)
            fences.append((i, (m.group(2).split() or [""])[0]))
            outside.append("")
            continue
        outside.append(line)
    return outside, fences


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
    outside, fences = parse((ROOT / path).read_text(encoding="utf-8"))
    entries, messages = [], []
    for line, code in inline_commands(outside):
        entries.append(f"{path}\tinline\t{code}")
        messages.append(f"{path}:{line}: command inline (rule 3, move it to a ```bash block): `{code}`")
    errors = shape(outside, fences, kind)
    if errors:
        entries.append(f"{path}\tshape\t{kind}")
        messages += [f"{path}: {kind}: {e}" for e in errors]
    return entries, messages


def read_baseline():
    lines = BASELINE.read_text(encoding="utf-8").splitlines() if BASELINE.exists() else []
    return [l for l in lines if l and not l.startswith("#")], [l for l in lines if l.startswith("#")]


def guard(ref):
    """Neither baseline gains an entry against ref. The structure baseline is compared without the pages' paths, so a
    renamed page passes and a fixed violation cannot be traded for a new one; the markdownlint baseline, which is
    paths only, by count. A baseline that is not at ref yet has nothing to compare; a ref that is not here is an
    error, never a pass."""
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
        added = []
        if path == BASELINE:
            unpathed = [collections.Counter(l.split("\t", 1)[-1] for l in ls) for ls in (now, then)]
            added = sorted((unpathed[0] - unpathed[1]).elements())
        verdict = ("GREW, fix the page instead" if len(now) > len(then)
                   else f"NEW, fix the page instead: {added}" if added else "ok")
        print(f"{rel}: {len(now)} entries, {len(then)} at {ref}: {verdict}")
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
                   or (what == "shape" and m.startswith(f"{path}: {detail}:"))]
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
