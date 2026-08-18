#!/usr/bin/env bash
# Unit tests for writer/reviewer role policy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/agents.sh"
source "$ROOT_DIR/lib/roles.sh"

FAILS=0

pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; FAILS=$((FAILS + 1)); }

AVAILABLE=()
agent_available() {
    local name="$1"
    local a
    for a in "${AVAILABLE[@]+"${AVAILABLE[@]}"}"; do
        [[ "$a" == "$name" ]] && return 0
    done
    return 1
}

assert_eq() {
    local got="$1" want="$2" label="$3"
    if [[ "$got" == "$want" ]]; then
        pass "$label"
    else
        fail "$label (got '$got', want '$want')"
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

assert_ok() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$label"
    else
        fail "$label (expected success)"
    fi
}

AVAILABLE=(claude codex grok)
assert_eq "$(resolve_reviewer claude)" "codex" "default reviewer is Codex when available"

AVAILABLE=(claude grok)
assert_eq "$(resolve_reviewer claude)" "grok" "falls back to Grok when Codex is missing"

AVAILABLE=(codex grok)
assert_eq "$(resolve_reviewer codex)" "grok" "writer Codex uses Grok"

AVAILABLE=(codex)
if resolve_reviewer codex >/dev/null 2>&1; then
    fail "writer Codex with no Grok should fail"
else
    pass "writer Codex with no Grok fails"
fi

AVAILABLE=(grok)
if resolve_reviewer grok >/dev/null 2>&1; then
    fail "writer Grok with no Codex should fail"
else
    pass "writer Grok with no Codex fails"
fi

AVAILABLE=(claude)
if resolve_reviewer claude >/dev/null 2>&1; then
    fail "no eligible reviewer should fail"
else
    pass "no eligible reviewer fails"
fi

assert_eq "$(resolve_reviewer claude grok)" "grok" "explicit reviewer wins"

KNOWN_AGENTS+=(gemini)
DEFAULT_REVIEWER_ORDER=(gemini codex grok)
AVAILABLE=(claude gemini)
assert_eq "$(resolve_reviewer claude)" "gemini" "reviewer order is the preference list"
DEFAULT_REVIEWER_ORDER=(codex grok)
# keep gemini in KNOWN_AGENTS so later unknown-name checks stay about "gpt"

AVAILABLE=(claude codex)
assert_ok "distinct available roles" validate_roles claude codex
assert_fail "self-review rejected" validate_roles claude claude
assert_fail "unknown writer rejected" validate_roles gpt codex
assert_fail "unknown reviewer rejected" validate_roles claude gpt

AVAILABLE=(claude)
assert_fail "missing reviewer CLI rejected" validate_roles claude codex

AVAILABLE=(codex)
assert_fail "missing writer CLI rejected" validate_roles claude codex

assert_eq "$(normalize_agent_name ' Claude ')" "claude" "normalize trims and lowercases"
assert_ok "claude is known" is_known_agent claude
assert_fail "unknown name is not known" is_known_agent gpt

# CLI rejects self-review and missing args before the loop starts
cli="$ROOT_DIR/adversarial_review.sh"

out="$("$cli" --writer claude --reviewer claude "$ROOT_DIR" 2>&1 || true)"
if echo "$out" | grep -q "no self-review"; then
    pass "CLI rejects self-review"
else
    fail "CLI self-review error missing: $out"
fi

out="$("$cli" --writer 2>&1 || true)"
if echo "$out" | grep -q "requires an agent name"; then
    pass "CLI requires --writer value"
else
    fail "CLI --writer value error missing: $out"
fi

out="$("$cli" --reviewer 2>&1 || true)"
if echo "$out" | grep -q "requires an agent name"; then
    pass "CLI requires --reviewer value"
else
    fail "CLI --reviewer value error missing: $out"
fi

out="$("$cli" --writer nope --reviewer grok "$ROOT_DIR" 2>&1 || true)"
if echo "$out" | grep -q "Unknown writer"; then
    pass "CLI rejects unknown writer"
else
    fail "CLI unknown writer error missing: $out"
fi

if [[ $FAILS -gt 0 ]]; then
    echo "$FAILS failed"
    exit 1
fi
echo "all passed"
