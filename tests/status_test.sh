#!/usr/bin/env bash
# Unit tests for agent-failure detection.
# An agent that writes nothing did not report zero issues. It failed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/status.sh"
source "$ROOT_DIR/lib/facts.sh"

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

WORK=$(mktemp -d)
CLEANUP=("$WORK")
cleanup() {
    local d
    for d in "${CLEANUP[@]+"${CLEANUP[@]}"}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

write_artifact() {
    local name="$1"
    shift
    printf '%s' "$1" > "$WORK/$name"
    printf '%s\n' "$WORK/$name"
}

GOOD='---REVIEW_STATUS---
ISSUES_FOUND: 2
CRITICAL_COUNT: 0
HIGH_COUNT: 0
MEDIUM_COUNT: 2
LOW_COUNT: 0
CONFIDENCE: HIGH
EXIT_SIGNAL: false
SUMMARY: two nits
---END_REVIEW_STATUS---'

TRUNCATED='Here is the review.

---REVIEW_STATUS---
ISSUES_FOUND: 2
CRITICAL_'

# --- agent_output_ok ------------------------------------------------------

empty=$(write_artifact empty.md "")
spaces=$(write_artifact spaces.md '

')
good=$(write_artifact good.md "$GOOD")

assert_fail "empty file is not usable output" agent_output_ok "$empty"
assert_fail "whitespace-only file is not usable output" agent_output_ok "$spaces"
assert_fail "missing file is not usable output" agent_output_ok "$WORK/gone.md"
assert_ok "a real review is usable output" agent_output_ok "$good"

# --- parse_status_block ---------------------------------------------------

status=$(parse_status_block "$empty" REVIEW_STATUS) || true
assert_contains "$status" "empty agent output" "empty output reports a failure"
assert_ok "empty output is a failed status" status_failed "$status"
assert_fail "empty output returns non-zero" parse_status_block "$empty" REVIEW_STATUS

status=$(parse_status_block "$spaces" REVIEW_STATUS) || true
assert_ok "whitespace-only output is a failed status" status_failed "$status"

prose=$(write_artifact prose.md "The code looks fine to me.")
status=$(parse_status_block "$prose" REVIEW_STATUS) || true
assert_contains "$status" "no status block" "prose without a block is a failure"
assert_ok "prose is a failed status" status_failed "$status"

trunc=$(write_artifact trunc.md "$TRUNCATED")
status=$(parse_status_block "$trunc" REVIEW_STATUS) || true
assert_contains "$status" "truncated status block" "truncated block is a failure"
assert_ok "truncated block is a failed status" status_failed "$status"

status=$(parse_status_block "$good" REVIEW_STATUS)
assert_fail "a real review is not a failed status" status_failed "$status"
assert_eq "$(printf '%s' "$status" | jq -r '.issues_found')" "2" "counts still parse"
assert_eq "$(status_error "$status")" "" "a real review has no error text"

noissues=$(write_artifact noissues.md 'NO_ISSUES')
status=$(parse_status_block "$noissues" REVIEW_STATUS)
assert_eq "$(printf '%s' "$status" | jq -r '.exit_signal')" "true" "NO_ISSUES still exits clean"
assert_fail "NO_ISSUES is not a failed status" status_failed "$status"

# --- review_should_block --------------------------------------------------

assert_ok "code: failed review blocks" \
    review_should_block code '{"error": "empty agent output"}'
assert_ok "spec: failed review blocks" \
    review_should_block spec '{"error": "no status block"}'
assert_ok "empty status blocks" review_should_block code ""
assert_fail "code: nits still do not block" \
    review_should_block code '{"medium_count": 3, "high_count": 0, "critical_count": 0}'

# --- hook -----------------------------------------------------------------

source "$ROOT_DIR/lib/hook.sh"

repo=$(mktemp -d)
CLEANUP+=("$repo")
git -C "$repo" init -q
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
git -C "$repo" config commit.gpgsign false
printf 'print(1)\n' > "$repo/app.py"
git -C "$repo" add app.py
git -C "$repo" commit -q -m init
printf 'print(2)\n' > "$repo/app.py"

# A crashed reader writes nothing and exits non-zero.
run_agent() {
    : > "$3"
    return 1
}
agent_available() { return 0; }
resolve_reviewer() { printf '%s\n' "codex"; }

out=$(run_stop_hook '{"hook_event_name":"Stop","reason":"end_turn","cwd":"'"$repo"'","session_id":"crash"}' claude 2>/dev/null)
assert_contains "$out" '"decision": "block"' "a crashed reader blocks Stop"
assert_contains "$out" "REVIEW FAILED" "block reason names the failure"
assert_contains "$(cat "$repo/.adversarial-review/status.json")" "error" "status file records the failure"

# --- main script ----------------------------------------------------------

cli="$ROOT_DIR/adversarial_review.sh"
assert_contains "$(cat "$cli")" "REVIEW FAILED" "the loop reports review failure"
assert_contains "$("$cli" --help)" "3   agent failure" "help documents the failure exit code"

# A reviewer CLI that crashes must exit 3, not 0.
if command -v claude >/dev/null 2>&1; then
    shim=$(mktemp -d)
    CLEANUP+=("$shim")
    printf '#!/bin/sh\nexit 1\n' > "$shim/grok"
    chmod +x "$shim/grok"

    crash=$(mktemp -d)
    CLEANUP+=("$crash")
    git -C "$crash" init -q
    git -C "$crash" config user.email "test@example.com"
    git -C "$crash" config user.name "Test"
    git -C "$crash" config commit.gpgsign false
    printf 'def f():\n    return 1\n' > "$crash/app.py"
    git -C "$crash" add app.py
    git -C "$crash" commit -q -m init
    printf 'def f():\n    return 2\n\ndef g():\n    return 3\n' > "$crash/app.py"

    rc=0
    out=$(PATH="$shim:$PATH" "$cli" --no-timeout --writer claude --reviewer grok \
        "$crash" 2>&1) || rc=$?
    assert_eq "$rc" "3" "a crashed reviewer exits 3"
    assert_contains "$out" "REVIEW FAILED" "the run says the review failed"
    assert_contains "$out" "0 issues" "the run warns against reading it as 0 issues"
else
    pass "skip: claude CLI is not installed"
fi

if [[ $FAILS -gt 0 ]]; then
    echo "$FAILS failed"
    exit 1
fi
echo "all passed"
