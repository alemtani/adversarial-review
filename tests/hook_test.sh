#!/usr/bin/env bash
# Unit tests for the Stop-hook installer and runtime.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/hook.sh"

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

CLEANUP=()
cleanup() {
    local d
    for d in "${CLEANUP[@]+"${CLEANUP[@]}"}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

# --- payload filters ------------------------------------------------------

assert_ok "ignore SubagentStop" \
    hook_should_ignore '{"hook_event_name":"SubagentStop"}'
assert_ok "ignore camelCase subagentType" \
    hook_should_ignore '{"hookEventName":"Stop","subagentType":"explore"}'
assert_ok "ignore Claude agent_id" \
    hook_should_ignore '{"hook_event_name":"Stop","agent_id":"abc","agent_type":"Explore"}'
assert_ok "ignore session-end reason" \
    hook_should_ignore '{"hookEventName":"Stop","reason":"shutdown"}'
assert_ok "ignore channel_closed" \
    hook_should_ignore '{"reason":"channel_closed"}'
assert_ok "ignore StopFailure" \
    hook_should_ignore '{"hook_event_name":"StopFailure"}'

assert_fail "main Stop snake_case is reviewed" \
    hook_should_ignore '{"hook_event_name":"Stop","reason":"end_turn"}'
assert_fail "main Stop camelCase is reviewed" \
    hook_should_ignore '{"hookEventName":"Stop","reason":"end_turn"}'
assert_fail "Stop without reason is reviewed" \
    hook_should_ignore '{"hook_event_name":"Stop"}'

assert_eq "$(hook_json_field '{"stopHookActive":true}' stopHookActive stop_hook_active)" \
    "true" "reads camelCase stopHookActive"
assert_eq "$(hook_json_field '{"stop_hook_active":true}' stopHookActive stop_hook_active)" \
    "true" "reads snake_case stop_hook_active"
assert_ok "stopHookActive true" hook_stop_active '{"stopHookActive":true}'
assert_fail "stopHookActive false" hook_stop_active '{"stop_hook_active":false}'

# --- writer detection -----------------------------------------------------

unset GROK_HOOK_EVENT GROK_SESSION_ID GROK_WORKSPACE_ROOT AR_WRITER || true
assert_eq "$(hook_detect_writer claude)" "claude" "argv writer claude"
assert_eq "$(hook_detect_writer codex)" "codex" "argv writer codex"
GROK_SESSION_ID=abc
assert_eq "$(hook_detect_writer claude)" "grok" "Grok env overrides argv"
unset GROK_SESSION_ID
assert_eq "$(hook_detect_writer)" "claude" "default writer is claude"

# --- installer ------------------------------------------------------------

repo=$(make_repo)
CLEANUP+=("$repo")
commit_file "$repo" "README.md" "hello"
mkdir -p "$repo/.claude"
cat > "$repo/.claude/settings.json" << 'EOF'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "echo keep-me" }
        ]
      }
    ]
  }
}
EOF

assert_ok "install_stop_hook succeeds" install_stop_hook "$repo"

assert_ok "wrapper exists" test -x "$repo/.adversarial-review/stop.sh"
assert_contains "$(cat "$repo/.gitignore")" ".adversarial-review/" "gitignore lists state dir"
assert_contains "$(cat "$repo/.claude/settings.json")" ".adversarial-review/stop.sh claude" "Claude Stop hook"
assert_contains "$(cat "$repo/.claude/settings.json")" "echo keep-me" "keeps existing Stop hook"
assert_contains "$(cat "$repo/.grok/hooks/adversarial-review.json")" "stop.sh grok" "Grok Stop hook"
assert_contains "$(cat "$repo/.codex/hooks.json")" ".adversarial-review/stop.sh" "Codex Stop hook path"
assert_contains "$(cat "$repo/.codex/hooks.json")" "codex" "Codex Stop hook writer"
assert_not_contains "$(cat "$repo/.claude/settings.json")" "SubagentStop" "does not register SubagentStop"

assert_ok "install is idempotent" install_stop_hook "$repo"
claude_stops=$(jq '[.hooks.Stop[].hooks[].command | select(test("adversarial-review/stop"))] | length' "$repo/.claude/settings.json")
assert_eq "$claude_stops" "1" "reinstall does not duplicate Claude hook"

# --- skip / ignore via stop.sh -------------------------------------------

out=$(printf '%s' '{"hook_event_name":"SubagentStop","cwd":"'"$repo"'"}' | "$ROOT_DIR/hooks/stop.sh" claude) || rc=$?
rc=${rc:-0}
assert_eq "$rc" "0" "stop.sh exits 0 on subagent"
assert_eq "$out" "" "subagent produces no block JSON"

out=$(printf '%s' '{"hookEventName":"Stop","reason":"shutdown","cwd":"'"$repo"'"}' | "$ROOT_DIR/hooks/stop.sh") || rc=$?
rc=${rc:-0}
assert_eq "$rc" "0" "stop.sh exits 0 on session-end"
assert_eq "$out" "" "session-end produces no block JSON"

clean=$(make_repo)
CLEANUP+=("$clean")
commit_file "$clean" "ok.txt" "ok"
out=$(printf '%s' '{"hook_event_name":"Stop","reason":"end_turn","cwd":"'"$clean"'"}' | "$ROOT_DIR/hooks/stop.sh" claude) || rc=$?
rc=${rc:-0}
assert_eq "$rc" "0" "clean tree stop.sh exits 0"
assert_eq "$out" "" "skip depth does not block"

# --- reader gate ----------------------------------------------------------

HIGH_REVIEW='---REVIEW_STATUS---
ISSUES_FOUND: 1
CRITICAL_COUNT: 0
HIGH_COUNT: 1
MEDIUM_COUNT: 0
LOW_COUNT: 0
CONFIDENCE: HIGH
EXIT_SIGNAL: false
SUMMARY: auth check is missing
---END_REVIEW_STATUS---'

NIT_REVIEW='---REVIEW_STATUS---
ISSUES_FOUND: 2
CRITICAL_COUNT: 0
HIGH_COUNT: 0
MEDIUM_COUNT: 2
LOW_COUNT: 0
CONFIDENCE: HIGH
EXIT_SIGNAL: false
SUMMARY: style nits only
---END_REVIEW_STATUS---'

SPEC_BLOCK='---REVIEW_STATUS---
VERDICT: not ready
ISSUES_FOUND: 1
DECISION_ISSUES: 1
NIT_COUNT: 0
CONFIDENCE: HIGH
EXIT_SIGNAL: false
SUMMARY: missing alternatives
---END_REVIEW_STATUS---'

REVIEW_FIXTURE=""
run_agent() {
    printf '%s\n' "$REVIEW_FIXTURE" > "$3"
    return 0
}
agent_available() { return 0; }
resolve_reviewer() { printf '%s\n' "codex"; }

dirty=$(make_repo)
CLEANUP+=("$dirty")
commit_file "$dirty" "app.py" "print(1)"
printf 'print(2)\n' > "$dirty/app.py"

REVIEW_FIXTURE="$HIGH_REVIEW"
out=$(run_stop_hook '{"hook_event_name":"Stop","reason":"end_turn","cwd":"'"$dirty"'","session_id":"s1"}' claude)
assert_contains "$out" '"decision": "block"' "HIGH finding blocks Stop"
assert_contains "$out" "auth check is missing" "block reason includes summary"
assert_ok "review written to target state" test -f "$dirty/.adversarial-review/review.md"
assert_ok "hash written to target state" test -f "$dirty/.adversarial-review/finding.hash"

out=$(run_stop_hook '{"hook_event_name":"Stop","reason":"end_turn","cwd":"'"$dirty"'","session_id":"s1","stop_hook_active":true}' claude)
assert_eq "$out" "" "same finding hash with stopHookActive does not loop"

out=$(run_stop_hook '{"hook_event_name":"Stop","reason":"end_turn","cwd":"'"$dirty"'","session_id":"s2"}' claude)
assert_contains "$out" '"decision": "block"' "new turn can block again"

nits=$(make_repo)
CLEANUP+=("$nits")
commit_file "$nits" "app.py" "print(1)"
printf 'print(2)\n' > "$nits/app.py"
REVIEW_FIXTURE="$NIT_REVIEW"
out=$(run_stop_hook '{"hook_event_name":"Stop","reason":"end_turn","cwd":"'"$nits"'"}' claude)
assert_eq "$out" "" "MEDIUM/LOW do not block"

spec=$(make_repo)
CLEANUP+=("$spec")
commit_file "$spec" "docs/adr/001.md" "title"
printf 'we will use postgres\n' > "$spec/docs/adr/001.md"
REVIEW_FIXTURE="$SPEC_BLOCK"
out=$(run_stop_hook '{"hookEventName":"Stop","reason":"end_turn","cwd":"'"$spec"'"}' claude)
assert_contains "$out" '"decision": "block"' "spec decision issues block Stop"

# --- CLI ------------------------------------------------------------------

cli="$ROOT_DIR/adversarial_review.sh"

out=$("$cli" --help)
assert_contains "$out" "--install-hook" "help lists --install-hook"
assert_not_contains "$out" "--apply" "help does not list --apply"

out=$("$cli" --apply "$repo" 2>&1 || true)
assert_contains "$out" "Unknown option" "CLI rejects --apply"

out=$("$cli" --install-hook "$repo" 2>&1)
assert_contains "$out" "Installed Stop hook" "CLI --install-hook runs"

if grep -nE 'run_agent .* apply|_agent_is_apply_mode' "$ROOT_DIR/lib/hook.sh" "$ROOT_DIR/hooks/stop.sh"; then
    fail "hook calls apply mode"
else
    pass "hook never applies"
fi

if [[ $FAILS -gt 0 ]]; then
    echo "$FAILS failed"
    exit 1
fi
echo "all passed"
