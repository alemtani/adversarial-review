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

assert_not_contains() {
    local haystack="$1" needle="$2" label="$3"
    if printf '%s' "$haystack" | grep -Fq "$needle"; then
        fail "$label (unexpected '$needle')"
    else
        pass "$label"
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

# --- writer facts and reader judgment -------------------------------------

assert_eq "$(parse_bool yes)" "1" "parse_bool yes"
assert_eq "$(parse_bool false)" "0" "parse_bool false"
assert_eq "$(parse_bool maybe)" "" "parse_bool rejects other words"

parse_writer_facts_text $'decision: true\ndepth: skip\nintent: just a typo\napi_change: no\n'
assert_eq "$FACT_DECISION" "1" "facts parse decision"
assert_eq "$FACT_API_CHANGE" "0" "facts parse api_change no"
assert_eq "$WRITER_FACTS_PRESENT" "1" "facts card is present"

facts_repo=$(make_repo)
CLEANUP+=("$facts_repo")
commit_file "$facts_repo" "README.md" "hello"

# Tiny README typo is editorial skip without facts.
printf 'hella\n' > "$facts_repo/README.md"
assert_eq "$(triage_change "$facts_repo")" "editorial skip code" "tiny README is skip before facts"

mkdir -p "$facts_repo/.adversarial-review"
cat > "$facts_repo/.adversarial-review/writer-facts.yml" << 'EOF'
decision: true
docs_only: true
depth: skip
EOF
assert_not_contains "$(list_changed_files "$facts_repo")" "writer-facts.yml" "facts sidecar is not a changed file"
assert_eq "$(triage_change "$facts_repo")" "decisional standard spec" "decision fact raises a typo to spec"
# depth: skip in the card must not lower
triage_change "$facts_repo" >/dev/null
if [[ "$TRIAGE_DEPTH" == "skip" ]]; then
    fail "writer facts must not set skip"
else
    pass "writer facts cannot set skip"
fi

# Explicit --depth skip still wins (user, not writer)
assert_eq "$(triage_change "$facts_repo" "" skip)" "decisional skip spec" "user --depth skip still wins"

# auth fact raises a small code change
rm -f "$facts_repo/.adversarial-review/writer-facts.yml"
git -C "$facts_repo" checkout -- README.md
printf 'print("hi")\n' > "$facts_repo/hello.py"
cat > "$facts_repo/.adversarial-review/writer-facts.yml" << 'EOF'
auth: true
docs_only: true
EOF
assert_eq "$(triage_change "$facts_repo")" "code deep code" "auth fact raises small code to deep"
triage_change "$facts_repo" >/dev/null
assert_contains "$TRIAGE_FACTS_DISPUTED" "docs_only" "docs_only is disputed when code is present"

# docs_only cannot lower a sensitive path
rm -f "$facts_repo/hello.py"
mkdir -p "$facts_repo/src"
printf 'def login():\n    pass\n' > "$facts_repo/src/auth.py"
cat > "$facts_repo/.adversarial-review/writer-facts.yml" << 'EOF'
docs_only: true
tests_only: true
EOF
assert_eq "$(triage_change "$facts_repo")" "code deep code" "writer facts cannot lower auth.py"
triage_change "$facts_repo" >/dev/null
assert_contains "$TRIAGE_FACTS_DISPUTED" "docs_only" "docs_only disputed on auth.py"
assert_contains "$TRIAGE_FACTS_DISPUTED" "tests_only" "tests_only disputed on auth.py"

# --facts path
alt=$(mktemp)
CLEANUP+=("$alt")
printf 'api_change: true\n' > "$alt"
rm -f "$facts_repo/.adversarial-review/writer-facts.yml"
rm -f "$facts_repo/src/auth.py"
printf 'print("x")\n' > "$facts_repo/tiny.py"
assert_eq "$(triage_change "$facts_repo" "" "" "$alt")" "code standard code" "--facts file raises api_change to standard"
triage_change "$facts_repo" "" "" "$alt" >/dev/null
card=$(format_writer_facts)
assert_contains "$card" "api_change: yes" "facts card lists api_change"
assert_contains "$card" "claims" "facts card says claims"

# Reader judgment: counts, not a score
if review_should_block spec '{"verdict":"ready with nits","decision_issues":0,"nit_count":2}'; then
    fail "spec nits should not block"
else
    pass "spec nits do not block"
fi
if review_should_block spec '{"verdict":"not ready","decision_issues":2,"nit_count":1}'; then
    pass "spec decision issues block"
else
    fail "spec decision issues should block"
fi
if review_should_block code '{"critical_count":0,"high_count":0,"medium_count":2,"low_count":4}'; then
    fail "code medium/low should not block"
else
    pass "code nits do not block"
fi
if review_should_block code '{"critical_count":0,"high_count":1,"low_count":3}'; then
    pass "code HIGH blocks"
else
    fail "code HIGH should block"
fi

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

out="$("$cli" --facts 2>&1 || true)"
if echo "$out" | grep -q "requires a facts file"; then
    pass "CLI requires --facts value"
else
    fail "CLI --facts value error missing: $out"
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
