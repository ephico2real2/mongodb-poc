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
# absent <case> <text the output must not contain>
absent() {
  if grep -qF -- "$2" "${TMP}/out"; then
    FAILED=$((FAILED + 1)); echo "FAIL  $1: a line with: $2"; sed 's/^/      /' "${TMP}/out"
  else
    PASSED=$((PASSED + 1)); echo "ok    $1"
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

# --- rule 12: the layout inside a bash, sh or shell block, one page strictly ---
mkdir "${REPO}/fx12"
long="echo $(printf 'x%.0s' $(seq 1 116))"   # 121 characters
# page12 <name> <line>...: a reference page whose one block (```${INFO:-bash}) holds the lines; the first is line 6
page12() {
  local f="${REPO}/fx12/$1.md"
  shift
  { printf '# Rule 12\n\nA page.\n\n```%s\n' "${INFO:-bash}"; printf '%s\n' "$@"; printf '```\n'; } > "${f}"
}

cat > "${REPO}/fx12/clean.md" <<'MD'
# Rule 12

A page.

```bash
# The namespace every later command uses
NS=mongodb-poc

echo "a # b" 'c #d' $'e\'#f' a#b ${#NS}  # a trailing comment
curl -s http://example.invalid/#frag     # on the same column
oc get pods -n "${NS}" \
  -o wide
for c in mesh1 mesh2; do
  kubectl --context "kind-${c}" get pods \
    -n "${NS}"
done
cat <<EOF | oc apply -f -
$ not a prompt LONG
# kubectl get pods is not a commented-out command in a heredoc


EOF
cat <<'END' > /dev/null
LONG
END
mongosh --quiet --eval '
$ x # inside a quote: data, not a prompt or a comment
'
WIDTH
```

1. In a list item:

   ```bash
   oc get pods \
     -n x
   WIDTH
   ```
MD
sed -i.orig -e "s/LONG/${long}/" -e "s/WIDTH$/${long%x}/" "${REPO}/fx12/clean.md" && rm "${REPO}/fx12/clean.md.orig"
check fx12/clean.md
expect "rule 12: quotes, \${#x}, a#b, a URL's #, heredocs, a quoted line, 120 characters, nesting and a list item pass" 0 \
  "PASS (reference): fx12/clean.md"

page12 prompt '$ oc get pods'
check fx12/prompt.md
expect "rule 12: a \$ prompt fails" 1 "fx12/prompt.md:6: bash block (rule 12): a prompt at the start of a line (\$)"

page12 root '# kubectl get pods -n x' '# Check the pods' 'oc get pods'
check fx12/root.md
expect "rule 12: # before a command fails" 1 \
  "fx12/root.md:6: bash block (rule 12): a prompt at the start of a line (# before a command"
absent "rule 12: a comment in words passes" "fx12/root.md:7:"

page12 column 'oc get pods  # a' 'oc get pvc -n x  # b'
check fx12/column.md
expect "rule 12: trailing comments on two columns fail" 1 \
  "fx12/column.md:7: bash block (rule 12): trailing comments not on one column (columns 14, 18)"

page12 spaces 'oc get pods # a'
check fx12/spaces.md
expect "rule 12: one space before a trailing comment fails" 1 \
  "fx12/spaces.md:6: bash block (rule 12): fewer than two spaces before a trailing comment"

page12 quote 'echo "#" # c'
check fx12/quote.md
expect "rule 12: a comment after a closed quote is read" 1 \
  "fx12/quote.md:6: bash block (rule 12): fewer than two spaces before a trailing comment"

page12 length 'echo ${#NS} # c'
check fx12/length.md
expect "rule 12: a comment after \${#x} is read" 1 \
  "fx12/length.md:6: bash block (rule 12): fewer than two spaces before a trailing comment"

page12 width "${long}"
check fx12/width.md
expect "rule 12: a line over 120 characters fails" 1 "fx12/width.md:6: bash block (rule 12): a line over 120 characters (121)"

page12 cont "oc get pods \\" '    -n x'
check fx12/cont.md
expect "rule 12: a continuation indented four spaces fails" 1 \
  "fx12/cont.md:7: bash block (rule 12): a continuation line not indented two spaces from the command's first line (4)"

page12 blanks '' 'oc get pods' '' '' 'oc get pvc' ''
check fx12/blanks.md
expect "rule 12: a blank line at the start fails" 1 "fx12/blanks.md:6: bash block (rule 12): a blank line at the start of the block"
expect "rule 12: two blank lines in a row fail" 1 "fx12/blanks.md:9: bash block (rule 12): two blank lines in a row"
expect "rule 12: a blank line at the end fails" 1 "fx12/blanks.md:11: bash block (rule 12): a blank line at the end of the block"

page12 heredoc 'cat <<EOF' "${long}" 'EOF' "${long}"
check fx12/heredoc.md
expect "rule 12: the line after a heredoc's end is read" 1 "fx12/heredoc.md:9: bash block (rule 12): a line over 120"
absent "rule 12: a heredoc's body is not read" "fx12/heredoc.md:7:"

page12 herestring 'grep -c x <<< mongodb' "${long}"
check fx12/herestring.md
expect "rule 12: a here-string opens no heredoc" 1 "fx12/herestring.md:7: bash block (rule 12): a line over 120"

INFO="sh" page12 sh '$ oc get pods'
INFO="shell" page12 shell '$ oc get pods'
check fx12/sh.md fx12/shell.md
expect "rule 12: an sh block is checked" 1 "fx12/sh.md:6: bash block (rule 12): a prompt"
expect "rule 12: a shell block is checked" 1 "fx12/shell.md:6: bash block (rule 12): a prompt"

INFO="console" page12 console '$ oc get pods'
check fx12/console.md
expect "rule 12: a console block is not checked" 0 "PASS (reference): fx12/console.md"

printf '# Rule 12\n\nA page.\n\n> ```bash\n> $ oc get pods\n> ```\n' > "${REPO}/fx12/quoted.md"
check fx12/quoted.md
expect "rule 12: a block in a blockquote is checked" 1 "fx12/quoted.md:6: bash block (rule 12): a prompt"
reset

# The reader itself, on a page's text as given (a CRLF kept): "L<n>: <what>" per finding, or "none".
read12() {
  run python3 -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("d", "test/doc-structure.py")
d = importlib.util.module_from_spec(s)
s.loader.exec_module(d)
found = [f"L{i + 1}: {w}{x}" for b in d.parse(sys.argv[1])[2] for i, w, x in d.bash_block(b)]
print("\n".join(found) or "none")' "$1"
}
read12 "$(printf '~~~bash\necho $((1<<bits))\n$ oc get pods\n~~~\n')"
expect "rule 12: << in \$(( )) opens no heredoc" 0 "L3: a prompt at the start of a line (\$)"
read12 "$(printf '~~~bash\ncat <<EOF\n EOF\n# kubectl get pods\nEOF\n~~~\n')"
expect "rule 12: a heredoc does not end on ' EOF'" 0 "none"
read12 "$(printf '~~~bash\ncat <<-EOF\n EOF\n# kubectl get pods\nEOF\n~~~\n')"
expect "rule 12: <<- strips tabs only, not a space" 0 "none"
read12 "$(printf '~~~bash\ncat <<-EOF\n\tEOF \n# kubectl get pods\nEOF\n~~~\n')"
expect "rule 12: a heredoc does not end on 'EOF '" 0 "none"
read12 "$(printf '~~~bash\necho a\\ #b\n~~~\n')"
expect "rule 12: an escaped space does not start a word" 0 "none"
read12 "$(printf "~~~bash\necho 'a\n\n\nb'\n~~~\n")"
expect "rule 12: blank lines in quoted data pass" 0 "none"
read12 "$(printf '~~~bash\necho ab\\\n  cd\n~~~\n')"
expect "rule 12: a continuation backslash without a space before it fails" 0 \
  "L2: no space before a continuation backslash"
read12 "$(printf '~~~bash\necho %sa\nb%s\\\n  c\n~~~\n' "'" "'")"
expect "rule 12: so does one after a quote that closes on the line" 0 "L3: no space before a continuation backslash"
read12 "$(printf '~~~bash\r\n%s\r\n~~~\r\n' "${long%x}")"
expect "rule 12: a CRLF is not a character of the line" 0 "none"
read12 "$(printf '~~~bash\r\noc get pods \\\r\n    -n x\r\n~~~\r\n')"
expect "rule 12: a CRLF does not hide a continuation" 0 \
  "L3: a continuation line not indented two spaces from the command's first line (4)"
run python3 -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("d", "test/doc-structure.py")
d = importlib.util.module_from_spec(s)
s.loader.exec_module(d)
print("continues:", d.lex(sys.argv[1], None)[1])' "echo \"a\\"
expect "rule 12: a backslash at the end of a double-quoted line continues it" 0 "continues: True"

printf '\n```bash\n%s\n```\n' "${long}" >> "${REPO}/README.md"
check
expect "rule 12: a new problem in a tracked page fails against the baseline" 1 \
  "README.md:$(($(wc -l < "${REPO}/README.md") - 1)): bash block (rule 12): a line over 120 characters (121)"
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

printf 'README.md\tblock\ta line over 120 characters\n' >> "${REPO}/test/doc-structure-baseline.txt"
check --guard HEAD
expect "a rule-12 line added to the structure baseline fails the guard" 1 \
  "test/doc-structure-baseline.txt: $((before + 1)) entries, ${before} at HEAD: GREW"
reset

# A base without the block kind: the pull request that brings rule 12 in also brings its entries.
blocks="$(grep -c "$(printf '\tblock\t')" "${REPO}/test/doc-structure-baseline.txt")"
grep -v "$(printf '\tblock\t')" "${REPO}/test/doc-structure-baseline.txt" > "${TMP}/no-blocks"
cp "${REPO}/test/doc-structure-baseline.txt" "${TMP}/with-blocks"
cp "${TMP}/no-blocks" "${REPO}/test/doc-structure-baseline.txt"
git -C "${REPO}" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
  commit -q --no-verify -am "a base before rule 12"
cp "${TMP}/with-blocks" "${REPO}/test/doc-structure-baseline.txt"
check --guard HEAD
expect "a kind of entry the base does not have is not compared" 0 \
  "$((before - blocks)) entries, $((before - blocks)) at HEAD: ok; ${blocks} of a kind not at HEAD ['block'], not compared"
printf 'README.md\tinline\toc get pods\n' >> "${REPO}/test/doc-structure-baseline.txt"
check --guard HEAD
expect "beside a new kind, a kind the base has still may not grow" 1 \
  "$((before - blocks + 1)) entries, $((before - blocks)) at HEAD: GREW"
git -C "${REPO}" reset -q --hard HEAD~1
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
