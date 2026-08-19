#!/usr/bin/env bash
# Unit tests for reviewing named paths instead of the git diff.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/agents.sh"
source "$ROOT_DIR/lib/diff.sh"
source "$ROOT_DIR/lib/triage.sh"

FAILS=0
pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; FAILS=$((FAILS + 1)); }

assert_eq() {
    local got="$1" want="$2" label="$3"
    if [[ "$got" == "$want" ]]; then
        pass "$label"
    else
        fail "$label (got '$got', want '$want')"
    fi
}

assert_ok() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$label"
    else
        fail "$label (expected success)"
    fi
}

assert_fail() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$label (expected failure)"
    else
        pass "$label"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        pass "$label"
    else
        fail "$label (missing '$needle')"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        fail "$label (unexpected '$needle')"
    else
        pass "$label"
    fi
}

CLEANUP=()
cleanup() {
    local d
    for d in "${CLEANUP[@]+"${CLEANUP[@]}"}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

write_lines() {
    local path="$1" n="$2"
    awk -v n="$n" 'BEGIN { for (i = 1; i <= n; i++) printf "line %d\n", i }' > "$path"
}

# A plain directory. No git anywhere.
plain=$(mktemp -d)
CLEANUP+=("$plain")
mkdir -p "$plain/src/util" "$plain/docs/adr" "$plain/.git"
printf 'def f():\n    return 1\n' > "$plain/src/app.py"
printf 'def g():\n    return 2\n' > "$plain/src/util/helper.py"
printf 'we will use postgres\nalternatives: mysql\n' > "$plain/docs/adr/001.md"
printf 'ignore me\n' > "$plain/.git/config"
printf 'bin\0ary\n' > "$plain/src/blob.dat"

# --- expand_review_paths --------------------------------------------------

files=$(expand_review_paths "$plain/src/app.py")
assert_eq "$files" "$plain/src/app.py" "a single file expands to itself"

files=$(expand_review_paths "$plain/src")
assert_contains "$files" "src/app.py" "a directory expands to its files"
assert_contains "$files" "src/util/helper.py" "a directory expands recursively"

files=$(expand_review_paths "$plain")
assert_not_contains "$files" ".git/config" ".git is skipped"

files=$(expand_review_paths "$plain/src" "$plain/src/app.py")
assert_eq "$(printf '%s\n' "$files" | grep -c 'src/app.py')" "1" "duplicate paths appear once"

files=$(expand_review_paths "$plain/src/")
assert_contains "$files" "src/app.py" "a trailing slash is fine"

assert_fail "a missing path fails" expand_review_paths "$plain/nope.py"
out=$(expand_review_paths "$plain/nope.py" 2>&1 || true)
assert_contains "$out" "Path does not exist" "a missing path is named"

# --- collect_paths_input --------------------------------------------------

payload=$(collect_paths_input "$plain" "$plain/src" "$plain/docs/adr/001.md")
assert_contains "$payload" "# REVIEW PATHS" "payload lists the paths"
assert_contains "$payload" "# FILE CONTENTS" "payload has a contents section"
assert_contains "$payload" "=== FILE: src/app.py ===" "paths are shown relative to the target"
assert_contains "$payload" "def g():" "file bodies are included"
assert_contains "$payload" "=== FILE: src/blob.dat (binary, skipped) ===" "binary files are skipped"
assert_not_contains "$payload" "# DIFF" "no diff section in paths mode"

# Paths outside the target keep their full path.
outside=$(collect_paths_input "$plain/src" "$plain/docs/adr/001.md")
assert_contains "$outside" "$plain/docs/adr/001.md" "outside paths stay absolute"

# The content budget applies here too.
budget=$(mktemp -d)
CLEANUP+=("$budget")
write_lines "$budget/aaa.txt" 40
write_lines "$budget/zzz.txt" 40
capped=$(AR_CONTENT_LINES=50 collect_paths_input "$budget" "$budget")
assert_contains "$capped" "=== FILE: aaa.txt ===" "the first file fits the budget"
assert_contains "$capped" "(further file contents omitted; 50 line budget)" "over-budget contents are noted"
assert_not_contains "$capped" "=== FILE: zzz.txt ===" "over-budget file body is not dumped"
assert_contains "$capped" "  zzz.txt" "over-budget file is listed as omitted"

# --- triage_paths ---------------------------------------------------------

out=$(triage_paths "$plain" "" "" "" "$plain/src/app.py")
assert_eq "$TRIAGE_KIND" "code" "code file is code"
assert_eq "$TRIAGE_MODE" "code" "code file uses the code prompt"
assert_contains "$out" "code" "triage prints its answer"

triage_paths "$plain" "" "" "" "$plain/docs/adr/001.md" >/dev/null
assert_eq "$TRIAGE_KIND" "decisional" "an ADR is decisional"
assert_eq "$TRIAGE_MODE" "spec" "an ADR uses the spec prompt"
assert_eq "$TRIAGE_DEPTH" "standard" "a decisional path is standard at least"

# Named paths are never skipped by accident. Only --depth can say skip.
tiny=$(mktemp -d)
CLEANUP+=("$tiny")
printf 'typo fix\n' > "$tiny/NOTES.md"
triage_paths "$tiny" "" "" "" "$tiny/NOTES.md" >/dev/null
assert_eq "$TRIAGE_DEPTH" "quick" "a named path is reviewed, not skipped"
triage_paths "$tiny" "" "skip" "" "$tiny/NOTES.md" >/dev/null
assert_eq "$TRIAGE_DEPTH" "skip" "--depth skip still wins"

triage_paths "$plain" "spec" "" "" "$plain/src/app.py" >/dev/null
assert_eq "$TRIAGE_KIND" "decisional" "--kind spec still wins"

triage_paths "$plain" "" "deep" "" "$plain/src" >/dev/null
assert_eq "$TRIAGE_DEPTH" "deep" "--depth deep still wins"

assert_fail "triage_paths fails on a missing path" \
    triage_paths "$plain" "" "" "" "$plain/nope.py"

# The git diff path is untouched.
repo=$(mktemp -d)
CLEANUP+=("$repo")
git -C "$repo" init -q
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
git -C "$repo" config commit.gpgsign false
printf 'ok\n' > "$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" commit -q -m init
triage_change "$repo" >/dev/null
assert_eq "$TRIAGE_DEPTH" "skip" "a clean tree still skips"

# --- resolve_review_path --------------------------------------------------

# Same relative name under the target and under the caller's directory.
base=$(mktemp -d)
CLEANUP+=("$base")
mkdir -p "$base/target/docs" "$base/here/docs"
printf 'target copy\n' > "$base/target/docs/SPEC.md"
printf 'cwd copy\n' > "$base/here/docs/SPEC.md"
printf 'cwd only\n' > "$base/here/only-here.md"

pushd "$base/here" >/dev/null

got=$(resolve_review_path "$base/target" "docs/SPEC.md")
assert_eq "$got" "$base/target/docs/SPEC.md" "target-relative wins over the caller's directory"

got=$(resolve_review_path "$base/target" "only-here.md")
assert_eq "$got" "$PWD/only-here.md" "the caller's directory is the fallback"

got=$(resolve_review_path "$base/target" "$base/here/docs/SPEC.md")
assert_eq "$got" "$base/here/docs/SPEC.md" "an absolute path is used as given"

assert_fail "an unresolvable path fails" resolve_review_path "$base/target" "nowhere.md"
assert_fail "a missing absolute path fails" resolve_review_path "$base/target" "/nope/nowhere.md"

bases=$(review_path_bases "$base/target" "docs/SPEC.md")
assert_contains "$bases" "$base/target/docs/SPEC.md" "the error names the target base"
assert_contains "$bases" "$PWD/docs/SPEC.md" "the error names the caller base"
assert_eq "$(review_path_bases "$PWD" "x.md")" "$PWD/x.md" "one base is named once"

popd >/dev/null

# --- CLI ------------------------------------------------------------------

cli="$ROOT_DIR/adversarial_review.sh"

help=$("$cli" --help)
assert_contains "$help" "--file PATH" "help lists --file"
assert_contains "$help" "--files PATH..." "help lists --files"

out=$("$cli" --file 2>&1 || true)
assert_contains "$out" "--file requires a path" "--file needs a value"

out=$("$cli" --files "$plain/nope.py" 2>&1 || true)
assert_contains "$out" "Path does not exist" "the CLI names a missing path"
assert_contains "$out" "Tried:" "the CLI names the bases it tried"

# A path relative to the target, from a different working directory.
target_repo=$(mktemp -d)
CLEANUP+=("$target_repo")
mkdir -p "$target_repo/docs"
printf 'we will use postgres\nalternatives: none\n' > "$target_repo/docs/SPEC.md"

if agent_available claude && agent_available grok; then
    rc=0
    out=$(cd "$ROOT_DIR" && DRY_RUN=1 "$cli" --no-timeout --writer claude --reviewer grok \
        "$target_repo" --files docs/SPEC.md 2>&1) || rc=$?
    assert_eq "$rc" "0" "a target-relative path resolves"
    assert_contains "$out" "$target_repo/docs/SPEC.md" "the path resolves under the target"

    rc=0
    out=$(cd "$ROOT_DIR" && DRY_RUN=1 "$cli" --no-timeout --writer claude --reviewer grok \
        --file docs/SPEC.md "$target_repo" 2>&1) || rc=$?
    assert_eq "$rc" "0" "--file resolves against the target whatever the order"

    rc=0
    out=$(cd "$ROOT_DIR" && DRY_RUN=1 "$cli" --no-timeout --writer claude --reviewer grok \
        --files docs/GONE.md "$target_repo" 2>&1) || rc=$?
    assert_eq "$rc" "2" "--files swallowing the target still fails loudly"
    assert_contains "$out" "Pass the target" "the error explains the --files rule"
else
    pass "skip: claude and grok CLIs are not both installed"
fi

# A dry run reviews named paths in a directory that is not a git repo.
if agent_available claude && agent_available grok; then
    rc=0
    out=$(DRY_RUN=1 "$cli" --no-timeout --writer claude --reviewer grok \
        "$plain" --files "$plain/src/app.py" 2>&1) || rc=$?
    assert_eq "$rc" "0" "dry run over named paths succeeds without git"
    assert_contains "$out" "Input: named paths" "the run reports its input mode"

    rc=0
    out=$(DRY_RUN=1 "$cli" --no-timeout --writer claude --reviewer grok "$plain" 2>&1) || rc=$?
    assert_eq "$rc" "2" "without --files a non-git target is still rejected"
else
    pass "skip: claude and grok CLIs are not both installed"
fi

if [[ $FAILS -gt 0 ]]; then
    echo "$FAILS failed"
    exit 1
fi
echo "all passed"
