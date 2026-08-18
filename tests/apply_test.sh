#!/usr/bin/env bash
# Unit tests for standalone --apply vs hook never-apply.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/agents.sh"

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

# --- resolve_agent_mode ---------------------------------------------------

APPLY=0
AR_HOOK=0
assert_eq "$(resolve_agent_mode)" "review" "default is review"

APPLY=1
AR_HOOK=0
assert_eq "$(resolve_agent_mode)" "apply" "standalone APPLY=1 is apply"

APPLY=0
AR_HOOK=1
assert_eq "$(resolve_agent_mode)" "review" "hook is review"

APPLY=1
AR_HOOK=1
assert_eq "$(resolve_agent_mode)" "review" "hook stays review when APPLY=1"

# --- hook guard -----------------------------------------------------------

APPLY=0
AR_HOOK=1
assert_fail "hook refuses apply mode" _guard_hook_never_applies apply
assert_fail "hook refuses legacy true mode" _guard_hook_never_applies true
assert_ok "hook allows review mode" _guard_hook_never_applies review

APPLY=1
AR_HOOK=0
assert_ok "standalone allows apply mode" _guard_hook_never_applies apply

# run_agent must refuse apply in hook context before any CLI starts.
APPLY=0
AR_HOOK=1
if run_agent claude "prompt" "/tmp/ar-apply-test-out" "$PWD" apply >/dev/null 2>&1; then
    fail "run_agent apply in hook context should fail"
else
    pass "run_agent apply in hook context fails"
fi

# --- CLI ------------------------------------------------------------------

cli="$ROOT_DIR/adversarial_review.sh"

help=$("$cli" --help)
assert_contains "$help" "--apply" "help lists --apply"
assert_contains "$help" "Standalone only" "help marks --apply standalone only"
assert_contains "$help" "Never applies" "help says hook never applies"

repo=$(mktemp -d)
git -C "$repo" init -q
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
git -C "$repo" config commit.gpgsign false
printf 'ok\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m "init"

out=$("$cli" --apply --install-hook "$repo" 2>&1 || true)
assert_contains "$out" "standalone only" "--apply --install-hook is rejected"

out=$("$cli" --install-hook --apply "$repo" 2>&1 || true)
assert_contains "$out" "standalone only" "--install-hook --apply is rejected"

out=$(APPLY=1 "$cli" --install-hook "$repo" 2>&1 || true)
assert_contains "$out" "standalone only" "APPLY=1 env with --install-hook is rejected"

rm -rf "$repo"

# Phase 4 must not hardcode apply. Hook path must not call apply.
if grep -nE 'run_agent .* "apply"' "$ROOT_DIR/adversarial_review.sh"; then
    fail "standalone hardcodes apply mode"
else
    pass "standalone uses resolve_agent_mode"
fi

if grep -nE 'run_agent .* apply|_agent_is_apply_mode' "$ROOT_DIR/lib/hook.sh" "$ROOT_DIR/hooks/stop.sh"; then
    fail "hook calls apply mode"
else
    pass "hook never applies"
fi

if ! grep -Fq 'resolve_agent_mode' "$ROOT_DIR/adversarial_review.sh"; then
    fail "loop does not consult resolve_agent_mode"
else
    pass "loop consults resolve_agent_mode"
fi

if ! grep -Fq 'export AR_HOOK=1' "$ROOT_DIR/hooks/stop.sh"; then
    fail "stop.sh does not mark hook context"
else
    pass "stop.sh marks hook context"
fi

if [[ $FAILS -gt 0 ]]; then
    echo "$FAILS failed"
    exit 1
fi
echo "all passed"
