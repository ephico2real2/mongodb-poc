---
name: doc-guide
description: Write or rewrite a document of this repository in its kind's fixed shape — a guide (how-to and runbooks, the page shape of the Kubernetes docs' tutorial and task pages, GitHub Docs' articles, Google's developer style guide's procedures and Diátaxis' how-to guides: one imperative action per step, its command in a bash block and its recorded result), a record (docs/testing-*.md: the commands and their recorded outputs) or a reference (READMEs, the reference architecture, the business case, design notes). Every command in a fenced bash block, never inline in a sentence or a table cell. Checked by test/doc-structure.py and scripts/mdfmt, in CI. Use for every new or changed .md, and whenever the owner asks for "a proper guide" or says a document is "all over the place".
---

# Doc guide — the page shape for this repository's documents

The owner, 2026-10-22 (#199), on the documents: *"the embedded bash commands are not clearly formatted, everything is
all over the place"*. This skill is cilium-implementation-poc's `demo-guide` skill, adapted: its guide template, its
rules and its engine (markdownlint-cli2 through `scripts/mdfmt`), with this repository's three kinds of page in place
of a demo's three files.

## Where the shape comes from

| Rule | Source |
|---|---|
| A page is one content type. A guide takes the **tutorial** page's frame (its sections are `overview`, `prerequisites`, `objectives`, `lessoncontent`, `cleanup`, `whatsnext`) and the **task** page's steps — *What you get* is the objectives, *Steps* the lesson content | Kubernetes docs, [page content types](https://kubernetes.io/docs/contribute/style/page-content-types/); the task page: *"For `steps`, use numbered lists. Keep the focus on the task itself. If a step requires substantial background, link to the relevant concept page rather than repeating the explanation here."* |
| Title fully describes the page; every page has an intro; prerequisites sit **immediately before** the numbered steps; conceptual → reference → procedural → troubleshooting; a next-steps section when the page is one step of a larger process | GitHub Docs, [contents of an article](https://docs.github.com/en/contributing/style-guide-and-content-model/contents-of-a-github-docs-article) and the [content model](https://docs.github.com/en/contributing/writing-for-github-docs/content-model) |
| One primary action per numbered step, imperative verb first; *"State the action first and the result second. Keep the result in the same paragraph as the action"*; introduce a procedure with a sentence ending in a colon | Google developer documentation style guide, [procedures](https://developers.google.com/style/procedures) |
| Address the goal, not the tool; a logical sequence; *omit the unnecessary* — link to reference instead of embedding it; do not teach concepts in the middle of a procedure | [Diátaxis, how-to guides](https://diataxis.fr/how-to-guides/) |

## The three kinds

| Kind | The pages | Shape |
|---|---|---|
| **guide** | `docs/building-the-kind-mesh-lab.md`, `docs/prerequisite-and-setup-doc.md`, `docs/mongot-envoy-*-runbook.md`, `docs/mongot-envoy-vanity-url.md`, `chart/mongodb-search-helm/volume-expansion-runbook.md` | the guide template below |
| **record** | `docs/testing-*.md`, `chart/mongodb-search-helm/docs/testing-*.md` | the record template below |
| **reference** | every other page: the READMEs, `docs/reference-architecture-*`, `docs/business-case-*`, the design notes and the chart's settings pages | one H1, an intro, then H2s of the page's own |

The list is `KIND_BY_PATH` in `test/doc-structure.py`; a new guide or record is added there and here together. A new
document's file name is lowercase words joined by hyphens (no spaces, no ampersands), under `docs/` unless it
documents a file of the chart, in which case it sits beside that file in `chart/mongodb-search-helm/`.

## The guide — these headings, this order, nothing else at H2

````markdown
# <What the reader will have at the end, in plain words>

<Intro: two to four sentences. What this page builds or changes, on what, and what it proves. No history.>

## What you get

- <one measured fact per bullet; four to seven bullets — the objectives, stated as results>

## Architecture

<The figure (the light PNG, see "Figures"), or an ASCII diagram of the pieces and the path a request takes.>

| Name | Address | What it is | Who answers |
|---|---|---|---|

## Prerequisites

- <tool + version, from the pins>
- <each thing that must exist first — each with the one command that satisfies it, in a bash block>

## Steps

Introduce with one sentence ending in a colon, then one H3 per step:

### 1. <Imperative verb phrase>

<At most one sentence of why, with a link to the concept if it needs more.>

```bash
<the command as recorded>
```

Result: <the recorded output that proves the step, quoted or summarised in one line — numbers exact>.

### 2. …

## Verify

<The two to five commands a reader runs to see it working, each in a bash block with its expected output.>

## Reference

<Only what a reader will look up: names, addresses, certificate fields, the files table. Tables over prose.>

## Troubleshooting

<Optional. At most three items: symptom → cause → fix, each one line.>

## Clean up

```bash
<the cleanup command(s)>
```

## What's next

- <up to five bullets>
````

A runbook keeps this shape: what it changes is its *Steps*; what to check before is its *Prerequisites*; going back
is its *Clean up*.

## The record — `docs/testing-*.md`

For the engineer who runs and re-runs a test. Fixed H2s, this order:

1. intro (two to four sentences: what was tested, on what, when, and the guide it belongs to);
2. **Summary** (optional: the results as a table, one row per test);
3. **Files** (table: file → what — the scripts run and the recorded outputs in `kind-mesh/output/` or
   `kind-mesh-cilium/output/`);
4. **Run it** (the commands, each in a `bash` fenced block, in order);
5. **What was recorded** (one H3 per test, `### <N or ID>. <Title>` — `T1.`, `C4.` and `1.` all do; under each: the
   command in a `bash` fenced block and the recorded output in a `text` fenced block, quoted verbatim from the file
   named in the sentence above it);
6. **Checks** (the recorded check's block);
7. **What is deliberately not here** (bullets);
8. **Runs that did not go to plan** (optional — the only place the history lives: one short paragraph per run with
   its recorded line);
9. **Open** (optional: what was found and not yet fixed, each with its issue);
10. **Clean up**.

Prose between blocks is one or two sentences; an explanation longer than that links to the guide or the design note.

## The reference

One H1, an intro of two to four sentences before the first H2, then the page's own H2s. Rules 3, 4, 6–8 and 11 apply.

## The rules

1. **Imperative, present tense, one action per step.** Step titles are verb phrases ("Create the trust bundle",
   "Grow the volume claims"). A step that needs two commands is two steps or one command block with a result per
   command.
2. **Command, then result.** Every step shows the command as recorded and its result right after it. The result is
   the recorded output (one to five lines) — an address, a status, a count — never a paraphrase of it.
3. **Every command is a `bash` fenced block — never inline in a sentence or a table cell** (cilium-implementation-poc's
   owner, 2026-09-19: *"the commands that you use are not formatted with bash format and you add them to
   paragraphs"*; this repository's, 2026-10-22, the same). Inline backticks are for names only: a file, an object, an
   address, a flag, a value. A span that starts with a command (`kubectl`, `oc`, `helm`, `curl`, `docker`, `kind`,
   `colima`, `openssl`, `git`, `gh`, `cilium`, `cilium-dbg`, `hubble`, `mongosh`, `sudo`, `export`, `make`,
   `python3`, `bash`, `crc`, `cd`, `cat`, `ss`, `jq`, `yq`, `npm`, `grpcurl`, `crictl`, `go run`) or a script and
   goes on with an argument is wrong — move it into a block and keep the sentence about what it does; "the upgrade" names the
   operation, a two-word command does not. A script's path alone is a name. The same for *Verify*, *Prerequisites*
   and *Clean up*.
4. **Every number comes from a recorded output** — `kind-mesh/output/`, `kind-mesh-cilium/output/`, the record pages
   (`docs/testing-*.md`, `chart/mongodb-search-helm/docs/testing-*.md`) — or from the file that sets it, linked
   where used: the pins (`kind-mesh/versions.env`, `chart/mongodb-search-helm/Chart.yaml`), the chart's
   `values.yaml`, a manifest, a script. Not remembered, not rounded, not summed unless the sum is in a source.
5. **No history of the runs** in a guide. What failed on the way, what a reviewer caught, what was retried — none of
   it. The record holds that (*Runs that did not go to plan*). The one exception is *Troubleshooting*: a symptom the
   reader may hit.
6. **Explain in one sentence or link out.** A mechanism gets one sentence at the step that uses it and a link (a
   design note, a source file with line numbers) for the rest. No paragraph of theory inside the steps.
7. **Terms get one gloss, once**, in parentheses, the first time: "mongot (the search process beside mongod)".
8. **No praise, no adjectives of quality.** Results carry the judgement.
9. **Length:** a guide's prose outside code blocks and tables is 500–1,000 words. Longer means the record or a
   reference page is being rewritten into it.
10. **Headings are fixed** for a guide and a record. No H2 outside the template; the optional ones may be omitted;
    nothing else may.
11. **The checks pass after writing**: `scripts/mdfmt` fixes what it can and reports the rest, and
    `test/doc-structure.py` passes (heading order, one H3 per step, a command block and a `Result:` line in every
    guide step, a `bash` and a `text` block in every recorded step, no command inline). The commands are under
    "The checks and their baseline".

## Figures

A figure is drawn with diagram-kit (the `/visual` skill; sources and renders in `docs/diagrams/`, see its README) and
the page embeds the **light** PNG with a plain `<img>` with its `alt` text — not the `<picture>` switch; the dark PNG
is kept beside it:

```markdown
<img alt="<what the figure shows, as a sentence>" src="docs/diagrams/<page>/<name>.light.png">
```

A screenshot is embedded the same way from `docs/screenshots/`.

## The checks and their baseline

```bash
python3 test/doc-structure.py docs/<page>.md          # one page, strictly
python3 test/doc-structure.py                         # every tracked page, against the baseline (CI)
python3 test/doc-structure.py --prune                 # drop the baseline's lines that no longer occur
bash scripts/mdfmt fix docs/<page>.md                 # markdownlint-cli2 with .markdownlint-cli2.yaml
bash scripts/mdfmt baseline                           # every page not in test/markdownlint-baseline.txt (CI)
python3 test/doc-structure.py --guard origin/main     # neither baseline has more entries than main (CI)
bash test/doc-structure-test.sh                       # the checks' own tests (CI)
```

The documents written before #199 do not meet the shape yet. `test/doc-structure-baseline.txt` lists their
violations as they were (one line per inline command, one per page whose headings do not fit its kind), and
`test/markdownlint-baseline.txt` the pages markdownlint does not pass yet. CI fails on a violation that is not
listed, and on a listed one that is gone: after rewriting a page, prune the first list and remove the page from
the second. On a pull request, CI also fails when either list has more entries than at the base. A new violation is
fixed in the page, never added to a list. Vendored, generated and recorded files (`ignores` in `.markdownlint-cli2.yaml`) are skipped
by both tools.

## The process

1. Read in full: the page, the recorded outputs it cites (`kind-mesh/output/`, `kind-mesh-cilium/output/`), and the
   scripts and manifests it runs. Write nothing before they are read.
2. Decide its kind from the table above. For a guide, list the steps as the reader does them, and for each the one
   command and the one recorded result; for a record, the tests and their recorded files.
3. Write the page from the template. Keep every fact: each command, number and record file of the old page is in the
   new one, or moved to the page it belongs to and linked.
4. Check the page, and prune the baseline:

   ```bash
   python3 test/doc-structure.py docs/<page>.md
   bash scripts/mdfmt fix docs/<page>.md
   python3 test/doc-structure.py --prune
   ```
