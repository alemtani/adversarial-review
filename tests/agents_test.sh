#!/usr/bin/env bash
# Registry tests: a new name in KNOWN_AGENTS plus run_<name>() is enough.
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

assert_eq "$(agent_cli claude)" "claude" "CLI binary matches registry name"
assert_fail "unknown name has no CLI" agent_cli gemini

KNOWN_AGENTS+=(gemini)
assert_ok "appended name is known" is_known_agent gemini
assert_eq "$(agent_cli gemini)" "gemini" "appended name maps to same CLI"
assert_fail "known name without runner fails" run_agent gemini "p" /dev/null

out="$(mktemp)"
run_gemini() {
    printf 'fake-ran\n' > "$2"
}
if run_agent gemini "prompt" "$out" && [[ "$(cat "$out")" == "fake-ran" ]]; then
    pass "run_agent dispatches to run_<name>"
else
    fail "run_agent did not call run_gemini"
fi
rm -f "$out"

assert_fail "unknown agent is rejected" run_agent nope "p" /dev/null

if [[ $FAILS -gt 0 ]]; then
    echo "$FAILS failed"
    exit 1
fi
echo "all passed"
