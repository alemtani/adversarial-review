#!/usr/bin/env bash
# Unit tests for the timeout policy.
# No timeout command is a hard error. --no-timeout is the opt-out.
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

CLEANUP=()
cleanup() {
    local d
    for d in "${CLEANUP[@]+"${CLEANUP[@]}"}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

# Fake PATHs: one with no timeout at all, one with each command.
# Build them with the real PATH. Only the call under test sees the fake one.
BARE=$(mktemp -d)
WITH_TIMEOUT=$(mktemp -d)
WITH_GTIMEOUT=$(mktemp -d)
CLEANUP+=("$BARE" "$WITH_TIMEOUT" "$WITH_GTIMEOUT")

fake_cmd() {
    printf '#!/bin/sh\nexec "$@"\n' > "$1"
    chmod +x "$1"
}
fake_cmd "$WITH_TIMEOUT/timeout"
fake_cmd "$WITH_GTIMEOUT/timeout"
fake_cmd "$WITH_GTIMEOUT/gtimeout"

# --- get_timeout_cmd ------------------------------------------------------

assert_eq "$(PATH="$BARE" get_timeout_cmd)" "" "no timeout command on a bare PATH"
assert_eq "$(PATH="$WITH_TIMEOUT" get_timeout_cmd)" "timeout" "finds timeout"
assert_eq "$(PATH="$WITH_GTIMEOUT" get_timeout_cmd)" "gtimeout" "gtimeout wins"

# --- require_timeout_cmd --------------------------------------------------

AR_NO_TIMEOUT=0
rc=0
out=$(PATH="$BARE" require_timeout_cmd 2>&1) || rc=$?
assert_eq "$rc" "1" "missing timeout is a hard error"
assert_contains "$out" "brew install coreutils" "error names the fix"
assert_contains "$out" "--no-timeout" "error names the opt-out"

AR_NO_TIMEOUT=1
rc=0
out=$(PATH="$BARE" require_timeout_cmd 2>&1) || rc=$?
assert_eq "$rc" "0" "--no-timeout allows a missing timeout"
assert_contains "$out" "WARNING" "--no-timeout warns instead"
AR_NO_TIMEOUT=0

rc=0
out=$(PATH="$WITH_TIMEOUT" require_timeout_cmd 2>&1) || rc=$?
assert_eq "$rc" "0" "an installed timeout passes"
assert_eq "$out" "" "an installed timeout says nothing"

# --- CLI ------------------------------------------------------------------

cli="$ROOT_DIR/adversarial_review.sh"

help=$("$cli" --help)
assert_contains "$help" "--no-timeout" "help lists --no-timeout"
assert_contains "$help" "brew install coreutils" "help names the dependency"

repo=$(mktemp -d)
CLEANUP+=("$repo")
git -C "$repo" init -q
git -C "$repo" config user.email "test@example.com"
git -C "$repo" config user.name "Test"
git -C "$repo" config commit.gpgsign false
printf 'def f():\n    return 1\n' > "$repo/app.py"
git -C "$repo" add app.py
git -C "$repo" commit -q -m init
printf 'def f():\n    return 2\n\ndef g():\n    return 3\n' > "$repo/app.py"

# The CLI needs a writer and a reviewer CLI before it reaches the timeout gate.
if agent_available claude && agent_available grok; then
    if [[ -z "$(get_timeout_cmd)" ]]; then
        rc=0
        out=$(DRY_RUN=1 "$cli" --writer claude --reviewer grok "$repo" 2>&1) || rc=$?
        assert_eq "$rc" "2" "no timeout command exits 2"
        assert_contains "$out" "hung agent" "CLI says why it stopped"

        rc=0
        out=$(DRY_RUN=1 "$cli" --no-timeout --writer claude --reviewer grok "$repo" 2>&1) || rc=$?
        assert_eq "$rc" "0" "--no-timeout runs the review"
        assert_contains "$out" "Agents run uncapped" "--no-timeout warns once"
    else
        pass "skip: timeout is installed, hard-fail path not exercised here"
        rc=0
        out=$(DRY_RUN=1 "$cli" --writer claude --reviewer grok "$repo" 2>&1) || rc=$?
        assert_eq "$rc" "0" "an installed timeout runs the review"
    fi
else
    pass "skip: claude and grok CLIs are not both installed"
fi

if [[ $FAILS -gt 0 ]]; then
    echo "$FAILS failed"
    exit 1
fi
echo "all passed"
