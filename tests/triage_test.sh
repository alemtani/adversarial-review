#!/usr/bin/env bash
# Unit tests for depth triage and spec-prompt selection.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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
    if printf '%s' "$haystack" | grep -Fq "$needle"; then
        pass "$label"
    else
        fail "$label (missing '$needle')"
    fi
}

make_repo() {
    local dir
    dir=$(mktemp -d)
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config commit.gpgsign false
    printf '%s\n' "$dir"
}

commit_file() {
    local dir="$1" path="$2" content="$3"
    local parent
    parent=$(dirname "$dir/$path")
    mkdir -p "$parent"
    printf '%s\n' "$content" > "$dir/$path"
    git -C "$dir" add -- "$path"
    git -C "$dir" commit -q -m "add $path"
}

write_n_lines() {
    local path="$1" n="$2"
    local parent
    parent=$(dirname "$path")
    mkdir -p "$parent"
    awk -v n="$n" 'BEGIN { for (i = 1; i <= n; i++) printf "line %d\n", i }' > "$path"
}

CLEANUP=()
cleanup() {
    local d
    for d in "${CLEANUP[@]+"${CLEANUP[@]}"}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

# --- classifiers ----------------------------------------------------------

assert_eq "$(normalize_kind spec)" "decisional" "spec aliases to decisional"
assert_eq "$(normalize_kind Editorial)" "editorial" "kind is lowercased"
assert_eq "$(normalize_kind nope)" "" "unknown kind is empty"
assert_eq "$(normalize_depth DEEP)" "deep" "depth is lowercased"
assert_eq "$(normalize_depth nope)" "" "unknown depth is empty"
assert_eq "$(max_depth quick standard)" "standard" "max_depth raises"
assert_eq "$(max_depth deep skip)" "deep" "max_depth keeps the higher"

assert_ok "docs/adr is decisional" is_decisional_path "docs/adr/0001-use-postgres.md"
assert_ok "docs/design is decisional" is_decisional_path "docs/design/auth.md"
assert_ok "docs/rfcs is decisional" is_decisional_path "docs/rfcs/0002.md"
assert_ok "ARCHITECTURE.md is decisional" is_decisional_path "ARCHITECTURE.md"
assert_ok "DESIGN.md is decisional" is_decisional_path "src/DESIGN.md"
assert_ok "*.spec.md is decisional" is_decisional_path "foo.spec.md"
assert_fail "README is not decisional" is_decisional_path "README.md"

assert_ok "README is operational" is_operational_path "README.md"
assert_ok "docs/ runbook is operational" is_operational_path "docs/runbook.md"
assert_fail "ADR is not operational" is_operational_path "docs/adr/x.md"

assert_ok "python is code" is_code_path "src/app.py"
assert_fail "markdown is not code" is_code_path "README.md"

assert_ok "auth.py is sensitive" is_sensitive_path "src/auth.py"
assert_ok "user_auth.go is sensitive" is_sensitive_path "pkg/user_auth.go"
assert_ok "workflow is sensitive" is_sensitive_path ".github/workflows/ci.yml"
assert_fail "author.md is not sensitive" is_sensitive_path "docs/author.md"

assert_ok "decision language: we will" has_decision_language "we will ship this"
assert_ok "decision language: MUST" has_decision_language "The writer MUST log out"
assert_ok "decision language: non-goals" has_decision_language "Non-goals include a UI"
assert_fail "no decision language in a typo" has_decision_language "fix a typo in the title"

parse_frontmatter_text $'---\nkind: spec\nreview: deep\n---\n# Title\n'
assert_eq "$_FM_KIND" "spec" "frontmatter kind: spec"
assert_eq "$_FM_REVIEW" "deep" "frontmatter review: deep"

parse_frontmatter_text $'# no frontmatter\nkind: spec\n'
assert_eq "$_FM_KIND" "" "kind outside frontmatter is ignored"

assert_contains "$(depth_guidance quick)" "QUICK" "quick guidance"
assert_contains "$(depth_guidance deep)" "only emits nits" "deep guidance mentions nits-only failure"

# --- repo cases -----------------------------------------------------------

repo=$(make_repo)
CLEANUP+=("$repo")
commit_file "$repo" "a.txt" "hello"
assert_eq "$(triage_change "$repo")" "code skip code" "clean tree is skip"

# Whitespace-only README
commit_file "$repo" "README.md" "hello"
printf 'hello \n' > "$repo/README.md"
assert_eq "$(triage_change "$repo")" "editorial skip code" "whitespace-only README is editorial skip"

# Tiny typo in README
printf 'hella\n' > "$repo/README.md"
got=$(triage_change "$repo")
assert_eq "$got" "editorial skip code" "tiny README typo is editorial skip"

# Small new Python file: code / quick
git -C "$repo" checkout -- README.md
printf 'print("hi")\n' > "$repo/hello.py"
assert_eq "$(triage_change "$repo")" "code quick code" "small code change is quick"
rm -f "$repo/hello.py"

# Sensitive path raises to deep
mkdir -p "$repo/src"
printf 'def login():\n    pass\n' > "$repo/src/auth.py"
assert_eq "$(triage_change "$repo")" "code deep code" "auth.py is deep"
triage_change "$repo" >/dev/null
assert_contains "$TRIAGE_REASON" "sensitive path" "sensitive path is in the reason"

# Reset to a clean tree for isolated cases
git -C "$repo" add -A
git -C "$repo" commit -q -m "checkpoint"

# Decisional path, even when the edit is small
mkdir -p "$repo/docs/adr"
commit_file "$repo" "docs/adr/0001.md" "# ADR\n\nUse Postgres.\n"
printf '# ADR\n\nUse Postgres now.\n' > "$repo/docs/adr/0001.md"
assert_eq "$(triage_change "$repo")" "decisional standard spec" "small ADR edit is standard spec"
git -C "$repo" checkout -- "docs/adr/0001.md"

# New spec file with decision language
printf 'We will adopt Grok.\n\nNon-goals: a UI.\n' > "$repo/notes.md"
assert_eq "$(triage_change "$repo")" "decisional standard spec" "decision language in a new doc is spec"
rm -f "$repo/notes.md"

# New *.spec.md
printf '# API spec\n' > "$repo/api.spec.md"
assert_eq "$(triage_change "$repo")" "decisional standard spec" "*.spec.md is spec"
rm -f "$repo/api.spec.md"

# ARCHITECTURE.md
printf '# Architecture\n' > "$repo/ARCHITECTURE.md"
assert_eq "$(triage_change "$repo")" "decisional standard spec" "ARCHITECTURE.md is spec"
rm -f "$repo/ARCHITECTURE.md"

# Frontmatter kind: spec
printf -- '---\nkind: spec\n---\n# Plan\n' > "$repo/plan.md"
assert_eq "$(triage_change "$repo")" "decisional standard spec" "frontmatter kind: spec"
rm -f "$repo/plan.md"

# Frontmatter review: deep on a README
printf -- '---\nreview: deep\n---\n# Readme\n\nMore than a typo. Install steps and a long operational note.\n' > "$repo/README.md"
got=$(triage_change "$repo")
assert_eq "$(echo "$got" | awk '{print $2}')" "deep" "frontmatter review: deep raises depth"
git -C "$repo" checkout -- README.md

# Explicit --kind spec
printf 'print("x")\n' > "$repo/tiny.py"
assert_eq "$(triage_change "$repo" spec)" "decisional standard spec" "--kind spec forces spec prompt"
assert_eq "$(triage_change "$repo" spec quick)" "decisional quick spec" "--depth quick can lower a spec"

# Explicit --depth skip on a real change
assert_eq "$(triage_change "$repo" "" skip)" "code skip code" "--depth skip wins"
rm -f "$repo/tiny.py"

# Mixed code + spec: code prompt, at least standard
printf 'print("x")\n' > "$repo/app.py"
printf '# ADR\n\nWe will switch stores.\n' > "$repo/docs/adr/0002.md"
got=$(triage_change "$repo")
assert_eq "$(echo "$got" | awk '{print $1, $3}')" "code code" "mixed change uses the code prompt"
rank=$(depth_rank "$(echo "$got" | awk '{print $2}')")
if [[ "$rank" -ge 2 ]]; then
    pass "mixed change is at least standard"
else
    fail "mixed change depth too low: $got"
fi
rm -f "$repo/app.py" "$repo/docs/adr/0002.md"

# Operational docs that are not a typo
write_n_lines "$repo/docs/runbook.md" 40
assert_eq "$(triage_change "$repo")" "operational quick code" "new 40-line runbook is operational quick"
rm -f "$repo/docs/runbook.md"

# Large code change is deep
i=1
while [[ $i -le 12 ]]; do
    printf 'x = %s\n' "$i" > "$repo/file_$i.py"
    i=$((i + 1))
done
assert_eq "$(triage_change "$repo")" "code deep code" "many files are deep"
rm -f "$repo"/file_*.py

# --- CLI ------------------------------------------------------------------

cli="$ROOT_DIR/adversarial_review.sh"

out="$("$cli" --kind 2>&1 || true)"
if echo "$out" | grep -q "requires a kind"; then
    pass "CLI requires --kind value"
else
    fail "CLI --kind value error missing: $out"
fi

out="$("$cli" --depth 2>&1 || true)"
if echo "$out" | grep -q "requires a depth"; then
    pass "CLI requires --depth value"
else
    fail "CLI --depth value error missing: $out"
fi

out="$("$cli" --kind nope "$repo" 2>&1 || true)"
if echo "$out" | grep -q "Unknown kind"; then
    pass "CLI rejects unknown kind"
else
    fail "CLI unknown kind error missing: $out"
fi

out="$("$cli" --depth nope "$repo" 2>&1 || true)"
if echo "$out" | grep -q "Unknown depth"; then
    pass "CLI rejects unknown depth"
else
    fail "CLI unknown depth error missing: $out"
fi

# Clean tree skip does not need a reviewer CLI
clean=$(make_repo)
CLEANUP+=("$clean")
commit_file "$clean" "ok.txt" "ok"
out="$("$cli" "$clean" 2>&1)" || rc=$?
rc=${rc:-0}
if echo "$out" | grep -q "skip" && [[ "$rc" -eq 0 ]]; then
    pass "CLI skips a clean tree without a reviewer"
else
    fail "CLI clean-tree skip failed (rc=$rc): $out"
fi

# --depth skip on a dirty tree
printf 'x\n' > "$clean/ok.txt"
out="$("$cli" --depth skip "$clean" 2>&1)" || rc=$?
rc=${rc:-0}
if echo "$out" | grep -q "skip" && [[ "$rc" -eq 0 ]]; then
    pass "CLI honors --depth skip"
else
    fail "CLI --depth skip failed (rc=$rc): $out"
fi

if grep -q "hooks/stop.sh" "$cli"; then
    fail "stop hook was added in this slice"
else
    pass "stop hook is not in the main script"
fi

if [[ ! -f "$ROOT_DIR/prompts/spec_review.md" ]]; then
    fail "spec prompt is missing"
else
    pass "spec prompt exists"
fi

if grep -q "only emits nits is a failed review" "$ROOT_DIR/prompts/spec_review.md"; then
    pass "spec prompt rejects nits-only reviews"
else
    fail "spec prompt missing nits-only rule"
fi

if grep -q "VERDICT:" "$ROOT_DIR/prompts/spec_review.md"; then
    pass "spec prompt uses verdict language"
else
    fail "spec prompt missing VERDICT"
fi

if [[ $FAILS -gt 0 ]]; then
    echo "$FAILS failed"
    exit 1
fi
echo "all passed"
