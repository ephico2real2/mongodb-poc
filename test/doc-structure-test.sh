#!/usr/bin/env bash
# Tests for test/doc-structure.py and scripts/mdfmt's baseline mode, no cluster needed:  test/doc-structure-test.sh
# Every case runs on a copy of the tracked files in a throwaway git repository under mktemp — the working tree's
# copy, so an edited checker is what gets tested — and never edits a page in place. Each case asserts the exit code
# and a line of the output. Needs python3, git and markdownlint-cli2.
# The backticks in single quotes are Markdown, not command substitution:
# shellcheck disable=SC2016
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
command -v markdownlint-cli2 >/dev/null || { echo "needs markdownlint-cli2 (npm i -g markdownlint-cli2)" >&2; exit 2; }
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "${TMP:?}"' EXIT
REPO="${TMP}/repo"
mkdir "${REPO}"
git ls-files -z | tar --null -T - -cf - | tar -xf - -C "${REPO}" || exit 2
# Without its own .git, every git -C "${REPO}" below (reset --hard, clean) would act on a repository above mktemp's.
git -C "${REPO}" init -q && git -C "${REPO}" add -A \
  && git -C "${REPO}" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
       commit -q --no-verify -m base || exit 2

PASSED=0
FAILED=0
run() { (cd "${REPO}" && "$@") >"${TMP}/out" 2>&1; echo "$?" >"${TMP}/rc"; }
# expect <case> <exit code> <text the output must contain>
expect() {
  local got; got="$(cat "${TMP}/rc")"
  if [ "${got}" = "$2" ] && grep -qF -- "$3" "${TMP}/out"; then
    PASSED=$((PASSED + 1)); echo "ok    $1"
  else
    FAILED=$((FAILED + 1)); echo "FAIL  $1: exit ${got} (want $2), no line with: $3"; sed 's/^/      /' "${TMP}/out"
  fi
}
reset() { git -C "${REPO}" reset -q --hard && git -C "${REPO}" clean -qfd; }
check() { run python3 test/doc-structure.py "$@"; }
entries() { grep -cvE '^(#|$)' "${REPO}/$1"; }

# --- rule 3, every tracked page against the baseline ---
check
expect "the tree as committed passes" 0 "violations, all in the baseline"

line=$(($(wc -l < "${REPO}/README.md") + 2))
printf '\nRun `kubectl get\npods -n x` to see them.\n' >> "${REPO}/README.md"
check
expect "a command in prose, wrapped onto the next line, fails" 1 \
  "README.md:${line}: command inline (rule 3, move it to a \`\`\`bash block): \`kubectl get pods -n x\`"
reset

printf '\n| a | b |\n|---|---|\n| x | `helm upgrade foo` |\n' >> "${REPO}/README.md"
check
expect "a command in a table cell fails" 1 '(rule 3, move it to a ```bash block): `helm upgrade foo`'
reset

cat >> "${REPO}/README.md" <<'EOF'

The `--expand` flag, `kind-mesh/scripts/up.sh`, `kubectl` and `kind: Pod` are names.

<!-- `oc get pods -A` in a comment is not shown -->

~~~bash
oc get pods -A
~~~
EOF
check
expect "names, flags, a script path, a comment and a fenced block pass" 0 "violations, all in the baseline"
reset

printf '\n> ```bash\n> oc get pods -A\n> ```\n' >> "${REPO}/README.md"
check
expect "a fenced block in a blockquote is a block, not inline" 0 "violations, all in the baseline"
reset

printf '\nRun `for c in a b; do oc get pods; done`, `mkdir -m 700 x`, `test/doc-structure.py --prune` and `SKIP_X=1 ./test/run.sh`.\n' \
  >> "${REPO}/README.md"
check
expect "a loop, a mkdir, a .py script and a VAR= script run inline fail" 1 "FAIL: 4 new, 0 fixed but listed"
reset

# --- the baseline only says what is left ---
fixed="$(grep -vE '^(#|$)' "${REPO}/test/doc-structure-baseline.txt" | head -1 | cut -f1)"
before="$(entries test/doc-structure-baseline.txt)"
listed="$(grep -c "^${fixed}"$'\t' "${REPO}/test/doc-structure-baseline.txt")"
printf '# Rewritten\n\nA page with nothing left to fix.\n' > "${REPO}/${fixed}"
check
expect "a fixed violation still in the baseline fails" 1 "FIXED, still in test/doc-structure-baseline.txt"
check --prune
expect "--prune removes the fixed page's lines" 0 "baseline: ${before} -> $((before - listed)) lines"
check
expect "after --prune, the tree passes" 0 "violations, all in the baseline"
reset

printf '\nThen `oc get pods -A` again.\n' >> "${REPO}/README.md"
check --prune
check
expect "--prune never adds a new violation" 1 "FAIL: 1 new, 0 fixed but listed"
reset

# --- each kind's shape, one page strictly ---
mkdir "${REPO}/fx"
cat > "${REPO}/fx/guide.md" <<'EOF'
# Grow mongot's volumes

The page's intro.

## What you get

- one fact

## Architecture

Text.

## Prerequisites

- a tool

## Steps

Do this:

### 1. Grow the claims

1. In a list item:

   ```bash
   # a comment, not a heading
   kubectl get pvc -n x
   ```

Result: three claims at 20Gi.

### 2. Restart the pods

~~~bash
oc rollout restart sts/x
~~~

Result: the pods are ready.

## Verify

```bash
oc get pods
```

## Reference

| Name | Value |
|---|---|
| StatefulSet | `mongot-search-0` |

## Clean up

```bash
true
```

## What's next

- more
EOF
check --kind guide fx/guide.md
expect "a guide in the template passes" 0 "PASS (guide): fx/guide.md"

sed -e 's/^Result: the pods are ready.//' -e 's/^### 2. Restart/### 3. restart/' -e 's/^## Verify/## Verification/' \
  "${REPO}/fx/guide.md" > "${REPO}/fx/guide-bad.md"
check --kind guide fx/guide-bad.md
expect "a guide step without a Result: line fails" 1 "guide: step 2 has no 'Result:' line"
expect "a guide step title out of number fails" 1 "step title must be '2. <Imperative...>', found '3. restart the pods'"
expect "a guide H2 outside the template fails" 1 "H2 order must be ['What you get'"
sed 's/^~~~bash$/~~~text/' "${REPO}/fx/guide.md" > "${REPO}/fx/guide-text.md"
check --kind guide fx/guide-text.md
expect "a guide step whose only block is not bash fails" 1 "guide: step 2 has no \`\`\`bash command block"

cat > "${REPO}/fx/record.md" <<'EOF'
# Testing: one thing

The page's intro.

## Files

| File | What |
|---|---|

## Run it

```bash
kind-mesh/drills.sh mongot mesh2 one
```

## What was recorded

### T1. The lab is healthy

```bash
kind-mesh/check.sh
```

```text
PASS 12/12
```

### C4. A cluster loses its mongot

```bash
kind-mesh-cilium/drills.sh mongot mesh2 all
```

```text
searches: 0 failed
```

## Checks

```text
ok
```

## What is deliberately not here

- x

## Clean up

```bash
true
```
EOF
check --kind record fx/record.md
expect "a record in the template passes" 0 "PASS (record): fx/record.md"

sed 's/^```text$/```/' "${REPO}/fx/record.md" > "${REPO}/fx/record-bad.md"
check --kind record fx/record-bad.md
expect "a recorded step without a text block fails" 1 \
  "recorded step 'T1. The lab is healthy' needs a \`\`\`bash command block and a \`\`\`text output block"

{ sed '/^## Clean up$/,$d' "${REPO}/fx/record.md"; printf '## Summary\n\n- x\n\n'; sed -n '/^## Clean up$/,$p' "${REPO}/fx/record.md"; } \
  > "${REPO}/fx/record-order.md"
check --kind record fx/record-order.md
expect "an optional H2 out of its place fails" 1 "record: H2 order must be ['Summary', 'Files'"

printf '# Title\n## First\ntext\n' > "${REPO}/fx/reference.md"
check fx/reference.md
expect "a reference without an intro fails" 1 "reference: no intro between the H1 and the first H2"
reset

# --- the baselines never grow (counts, not lines) ---
check --guard HEAD
expect "baselines as at the base pass the guard" 0 "test/doc-structure-baseline.txt: $(entries test/doc-structure-baseline.txt) entries"

printf 'README.md\tinline\toc get pods\n' >> "${REPO}/test/doc-structure-baseline.txt"
check --guard HEAD
expect "a line added to the structure baseline fails the guard" 1 "test/doc-structure-baseline.txt: $((before + 1)) entries, ${before} at HEAD: GREW"
reset

lint="$(entries test/markdownlint-baseline.txt)"
printf 'TLS.md\n' >> "${REPO}/test/markdownlint-baseline.txt"
check --guard HEAD
expect "a line added to the markdownlint baseline fails the guard" 1 \
  "test/markdownlint-baseline.txt: $((lint + 1)) entries, ${lint} at HEAD: GREW"
expect "the guard says which baseline grew" 1 "GREW, fix the page instead"
reset

swap="$(grep "$(printf '\tinline\t')" "${REPO}/test/doc-structure-baseline.txt" | head -1)"
grep -vxF -- "${swap}" "${REPO}/test/doc-structure-baseline.txt" > "${TMP}/swapped"
printf 'README.md\tinline\toc delete namespace mongodb-poc\n' >> "${TMP}/swapped"
cp "${TMP}/swapped" "${REPO}/test/doc-structure-baseline.txt"
check --guard HEAD
expect "a fixed violation traded for a new one fails the guard" 1 "NEW, fix the page instead: ['inline\toc delete namespace mongodb-poc']"
reset

check --guard no-such-ref
expect "a base that is not in the clone is an error, not a pass" 2 "no-such-ref is not a commit in this clone"

sed -i.orig "s|^${fixed}"$'\t'"|docs/renamed-page.md"$'\t'"|" "${REPO}/test/doc-structure-baseline.txt"
rm "${REPO}/test/doc-structure-baseline.txt.orig"
check --guard HEAD
expect "a renamed page in the baseline does not trip the guard" 0 "${before} entries, ${before} at HEAD: ok"
reset

# --- mdfmt baseline: every page not listed passes; a listed page still fails ---
run bash scripts/mdfmt baseline
expect "mdfmt baseline passes on the tree as committed" 0 "listed in test/markdownlint-baseline.txt"

# The list is empty once every page passes: the cases below list a page of their own.
printf '# Listed\n\n\n\nStill failing.\n' > "${REPO}/docs/listed-page.md"
printf 'docs/listed-page.md\n' >> "${REPO}/test/markdownlint-baseline.txt"
git -C "${REPO}" add docs/listed-page.md
run "${BASH_UNDER_TEST:-bash}" scripts/mdfmt baseline docs/listed-page.md
expect "mdfmt baseline on listed pages only checks none and passes" 0 "mdfmt baseline: 0 pages not listed and checked"
reset

printf '# New page\n\n\n\nText.\n' > "${REPO}/docs/new-page.md"
git -C "${REPO}" add docs/new-page.md
run bash scripts/mdfmt baseline
expect "a lint error in a page not listed fails" 1 "docs/new-page.md:3 error MD012/no-multiple-blanks"
reset

clean=TLS.md
printf '%s\n' "${clean}" >> "${REPO}/test/markdownlint-baseline.txt"
run bash scripts/mdfmt baseline
expect "a listed page that passes now fails" 1 "mdfmt: ${clean} passes now: remove it from test/markdownlint-baseline.txt"
reset

echo "${PASSED} passed, ${FAILED} failed"
[ "${FAILED}" -eq 0 ]
