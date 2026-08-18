#!/usr/bin/env bash
# Stop-hook runtime and installer.
#
# Hook mode never edits the tree. Findings go back to the writer
# as decision: block. State lives in the target repo and is gitignored.

_HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${AR_DIR:=$(cd "$_HOOK_LIB/.." && pwd)}"
: "${AR_STATE_RELPATH:=.adversarial-review}"

if ! declare -F log_info >/dev/null 2>&1; then
    _hook_emit() { printf '%s\n' "$1" >&2; }
    log_info()    { _hook_emit "[INFO] $1"; }
    log_success() { _hook_emit "[SUCCESS] $1"; }
    log_warning() { _hook_emit "[WARNING] $1"; }
    log_error()   { _hook_emit "[ERROR] $1"; }
    log_claude()  { _hook_emit "[CLAUDE] $1"; }
    log_codex()   { _hook_emit "[CODEX] $1"; }
    log_grok()    { _hook_emit "[GROK] $1"; }
    log_verbose() { [[ "${VERBOSE:-0}" == "1" ]] && _hook_emit "[VERBOSE] $1" || true; }
fi

if ! declare -F run_agent >/dev/null 2>&1; then
    # shellcheck source=agents.sh
    source "$_HOOK_LIB/agents.sh"
fi
if ! declare -F resolve_reviewer >/dev/null 2>&1; then
    # shellcheck source=roles.sh
    source "$_HOOK_LIB/roles.sh"
fi
if ! declare -F triage_change >/dev/null 2>&1; then
    # shellcheck source=triage.sh
    source "$_HOOK_LIB/triage.sh"
fi
if ! declare -F parse_status_block >/dev/null 2>&1; then
    # shellcheck source=status.sh
    source "$_HOOK_LIB/status.sh"
fi

# First present key wins. Accepts Claude snake_case and Grok camelCase.
hook_json_field() {
    local payload="$1"
    shift
    local key val
    for key in "$@"; do
        val=$(printf '%s' "$payload" | jq -r --arg k "$key" '
            if has($k) and .[$k] != null then .[$k] | tostring
            else empty end
        ' 2>/dev/null) || val=""
        if [[ -n "$val" && "$val" != "null" ]]; then
            printf '%s' "$val"
            return 0
        fi
    done
    return 0
}

hook_event_norm() {
    hook_json_field "$1" hookEventName hook_event_name \
        | tr '[:upper:]' '[:lower:]' | tr -d '_'
}

# True when this Stop fire should not run a review.
hook_should_ignore() {
    local payload="$1"
    local event reason field

    event=$(hook_event_norm "$payload")
    case "$event" in
        stop|"") ;;
        *) return 0 ;;
    esac

    for field in subagentType subagent_type agentType agent_type agentId agent_id; do
        if [[ -n "$(hook_json_field "$payload" "$field")" ]]; then
            return 0
        fi
    done

    reason=$(hook_json_field "$payload" reason)
    if [[ -n "$reason" && "$reason" != "end_turn" ]]; then
        return 0
    fi
    return 1
}

hook_stop_active() {
    local v
    v=$(hook_json_field "$1" stopHookActive stop_hook_active)
    [[ "$v" == "true" ]]
}

hook_target_dir() {
    local payload="$1"
    local d
    for d in \
        "$(hook_json_field "$payload" workspaceRoot workspace_root)" \
        "$(hook_json_field "$payload" cwd)" \
        "${CLAUDE_PROJECT_DIR:-}" \
        "${GROK_WORKSPACE_ROOT:-}" \
        "$PWD"
    do
        if [[ -n "$d" && -d "$d" ]]; then
            printf '%s' "$d"
            return 0
        fi
    done
    return 1
}

# Grok env wins over the installer argv. Grok also loads Claude settings.
hook_detect_writer() {
    local arg="${1:-}"
    if [[ -n "${GROK_HOOK_EVENT:-}${GROK_SESSION_ID:-}${GROK_WORKSPACE_ROOT:-}" ]]; then
        printf '%s' "grok"
        return 0
    fi
    if [[ -n "$arg" ]]; then
        printf '%s' "$(normalize_agent_name "$arg")"
        return 0
    fi
    if [[ -n "${AR_WRITER:-}" ]]; then
        printf '%s' "$(normalize_agent_name "$AR_WRITER")"
        return 0
    fi
    printf '%s' "claude"
}

hook_state_dir() {
    printf '%s/%s' "$1" "$AR_STATE_RELPATH"
}

hook_ensure_state() {
    mkdir -p "$(hook_state_dir "$1")"
}

hook_stop_key() {
    local payload="$1"
    local session prompt active
    session=$(hook_json_field "$payload" sessionId session_id)
    prompt=$(hook_json_field "$payload" promptId prompt_id)
    active=false
    hook_stop_active "$payload" && active=true
    printf '%s:%s:%s' "${session:-none}" "${prompt:-none}" "$active"
}

hook_already_handled() {
    local dir="$1" key="$2"
    local file
    file="$(hook_state_dir "$dir")/last-stop-key"
    [[ -f "$file" && "$(cat "$file")" == "$key" ]]
}

hook_mark_handled() {
    local dir="$1" key="$2"
    hook_ensure_state "$dir"
    printf '%s\n' "$key" > "$(hook_state_dir "$dir")/last-stop-key"
}

hook_finding_hash() {
    local mode="$1"
    local status="$2"
    local diff="$3"
    local counts
    counts=$(printf '%s' "$status" | jq -c '{
        critical: (.critical_count // 0),
        high: (.high_count // 0),
        decision: (.decision_issues // 0),
        verdict: (.verdict // "")
    }' 2>/dev/null) || counts=""
    printf '%s\n%s\n%s\n' "$mode" "$counts" "$diff" | shasum -a 256 | awk '{print $1}'
}

hook_stored_hash() {
    local file
    file="$(hook_state_dir "$1")/finding.hash"
    [[ -f "$file" ]] || return 0
    cat "$file"
}

hook_write_hash() {
    hook_ensure_state "$1"
    printf '%s\n' "$2" > "$(hook_state_dir "$1")/finding.hash"
}

hook_clear_hash() {
    rm -f "$(hook_state_dir "$1")/finding.hash"
}

hook_block_json() {
    jq -n --arg reason "$1" '{decision:"block", reason:$reason}'
}

# Reviewer only. The writer CLI need not be installed.
hook_resolve_reviewer() {
    local writer="$1"
    local reviewer

    writer=$(normalize_agent_name "$writer")
    if [[ -n "${AR_REVIEWER:-}" ]]; then
        reviewer=$(normalize_agent_name "$AR_REVIEWER")
    else
        reviewer=$(resolve_reviewer "$writer") || return 1
    fi
    if [[ "$writer" == "$reviewer" ]]; then
        return 1
    fi
    if ! is_known_agent "$reviewer"; then
        return 1
    fi
    if ! agent_available "$reviewer"; then
        return 1
    fi
    printf '%s\n' "$reviewer"
}

# Phase 1 only. Always review mode. Never apply.
hook_run_reader() {
    local target="$1"
    local reviewer="$2"
    local out="$3"
    local review_input prompt_file prompt_template depth_note facts_note full_prompt

    review_input=$(collect_review_input "$target") || return 1

    prompt_file="$AR_DIR/prompts/initial_review.md"
    if [[ "$TRIAGE_MODE" == "spec" ]]; then
        prompt_file="$AR_DIR/prompts/spec_review.md"
    fi
    [[ -f "$prompt_file" ]] || return 1

    prompt_template=$(cat "$prompt_file")
    depth_note=$(depth_guidance "$TRIAGE_DEPTH")
    facts_note=$(format_writer_facts)

    full_prompt="$prompt_template

$depth_note

$facts_note

---
# DIFF AND CHANGED FILES TO REVIEW

$review_input
"

    run_agent "$reviewer" "$full_prompt" "$out" "$target" "review"
}

hook_block_reason() {
    local mode="$1" kind="$2" depth="$3" reviewer="$4" status="$5" review_file="$6"
    local summary body
    summary=$(printf '%s' "$status" | jq -r '.summary // empty' 2>/dev/null) || summary=""

    body="Adversarial review blocked Stop ($mode).
Kind: $kind  Depth: $depth  Reviewer: $reviewer"

    if [[ "$mode" == "spec" ]]; then
        body+="
Verdict: $(printf '%s' "$status" | jq -r '.verdict // empty')
Decision issues: $(status_count "$status" decision_issues)
Nits: $(status_count "$status" nit_count)"
    else
        body+="
CRITICAL: $(status_count "$status" critical_count)  HIGH: $(status_count "$status" high_count)
MEDIUM: $(status_count "$status" medium_count)  LOW: $(status_count "$status" low_count)"
    fi

    [[ -n "$summary" ]] && body+="

$summary"
    body+="

Full review: $AR_STATE_RELPATH/review.md"

    if [[ -f "$review_file" ]]; then
        body+="

$(head -n 120 "$review_file")"
        if [[ "$(wc -l < "$review_file" | tr -d ' ')" -gt 120 ]]; then
            body+=$'\n\n... (truncated)'
        fi
    fi

    printf '%s' "$body"
}

# Read stdin payload, review the target, print block JSON or nothing.
# Always returns 0. Failures allow Stop.
run_stop_hook() {
    local payload="${1:-}"
    local writer_arg="${2:-}"
    local target writer reviewer state review_file status_file
    local status hash stored key diff

    if [[ -z "$payload" ]]; then
        payload='{}'
    fi
    if ! printf '%s' "$payload" | jq -e . >/dev/null 2>&1; then
        return 0
    fi
    if hook_should_ignore "$payload"; then
        return 0
    fi

    target=$(hook_target_dir "$payload") || return 0
    target="$(cd "$target" && pwd)"
    if ! is_git_work_tree "$target"; then
        return 0
    fi

    hook_ensure_state "$target"
    state=$(hook_state_dir "$target")
    HOOK_LOG="$state/hook.log"

    key=$(hook_stop_key "$payload")
    if hook_already_handled "$target" "$key"; then
        return 0
    fi
    hook_mark_handled "$target" "$key"

    if ! triage_change "$target" >/dev/null; then
        return 0
    fi
    if [[ "$TRIAGE_DEPTH" == "skip" ]]; then
        hook_clear_hash "$target"
        return 0
    fi

    writer=$(hook_detect_writer "$writer_arg")
    reviewer=$(hook_resolve_reviewer "$writer") || return 0

    review_file="$state/review.md"
    status_file="$state/status.json"
    if ! hook_run_reader "$target" "$reviewer" "$review_file"; then
        return 0
    fi

    status=$(parse_status_block "$review_file" "REVIEW_STATUS") || status='{"error":"no status block"}'
    printf '%s\n' "$status" > "$status_file"

    if ! review_should_block "$TRIAGE_MODE" "$status"; then
        hook_clear_hash "$target"
        return 0
    fi

    diff=$(collect_git_diff "$target" 2>/dev/null || true)
    hash=$(hook_finding_hash "$TRIAGE_MODE" "$status" "$diff")
    stored=$(hook_stored_hash "$target")
    if hook_stop_active "$payload" && [[ -n "$stored" && "$hash" == "$stored" ]]; then
        return 0
    fi
    hook_write_hash "$target" "$hash"

    hook_block_json "$(hook_block_reason \
        "$TRIAGE_MODE" "$TRIAGE_KIND" "$TRIAGE_DEPTH" "$reviewer" \
        "$status" "$review_file")"
    return 0
}

ensure_gitignore_line() {
    local gi="$1"
    local line="$2"
    if [[ -f "$gi" ]] && grep -Fxq "$line" "$gi"; then
        return 0
    fi
    mkdir -p "$(dirname "$gi")"
    if [[ -f "$gi" && -s "$gi" ]]; then
        local last
        last=$(tail -c 1 "$gi" 2>/dev/null || true)
        [[ "$last" == $'\n' || -z "$last" ]] || printf '\n' >> "$gi"
    fi
    printf '%s\n' "$line" >> "$gi"
}

write_stop_wrapper() {
    local target="$1"
    local dest src
    dest="$(hook_state_dir "$target")/stop.sh"
    src="$AR_DIR/hooks/stop.sh"
    mkdir -p "$(dirname "$dest")"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' '# Generated by adversarial-review --install-hook. Do not commit.'
        printf 'exec %q "$@"\n' "$src"
    } > "$dest"
    chmod +x "$dest"
}

# Merge our Stop handler into a Claude / Codex hooks JSON file.
merge_stop_hook_file() {
    local file="$1"
    local cmd="$2"
    local current="{}"
    local tmp

    if [[ -f "$file" && -s "$file" ]]; then
        current=$(cat "$file")
        if ! printf '%s' "$current" | jq -e . >/dev/null 2>&1; then
            log_error "Invalid JSON: $file"
            return 1
        fi
    fi

    tmp=$(mktemp)
    if ! printf '%s' "$current" | jq --arg cmd "$cmd" '
        .hooks.Stop //= []
        | .hooks.Stop = [
            .hooks.Stop[]
            | .hooks = [
                (.hooks // [])[]
                | select((.command // "")
                    | test("adversarial-review/stop\\.sh|\\.adversarial-review/stop\\.sh")
                    | not)
              ]
            | select((.hooks | length) > 0)
          ]
        | .hooks.Stop += [{
            hooks: [{
                type: "command",
                command: $cmd,
                timeout: 600
            }]
          }]
    ' > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mkdir -p "$(dirname "$file")"
    mv "$tmp" "$file"
}

install_claude_stop_hook() {
    local target="$1"
    local cmd='${CLAUDE_PROJECT_DIR}/.adversarial-review/stop.sh claude'
    merge_stop_hook_file "$target/.claude/settings.json" "$cmd"
}

install_grok_stop_hook() {
    local target="$1"
    local dest="$target/.grok/hooks/adversarial-review.json"
    mkdir -p "$(dirname "$dest")"
    cat > "$dest" << 'EOF'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PROJECT_DIR}/.adversarial-review/stop.sh grok",
            "timeout": 600
          }
        ]
      }
    ]
  }
}
EOF
}

install_codex_stop_hook() {
    local target="$1"
    local cmd='"$(git rev-parse --show-toplevel)/.adversarial-review/stop.sh" codex'
    merge_stop_hook_file "$target/.codex/hooks.json" "$cmd"
}

install_stop_hook() {
    local target="$1"
    target="$(cd "$target" && pwd)"

    if ! is_git_work_tree "$target"; then
        log_error "Target is not a git repository: $target"
        return 1
    fi

    mkdir -p "$(hook_state_dir "$target")"
    write_stop_wrapper "$target"
    ensure_gitignore_line "$target/.gitignore" ".adversarial-review/"
    install_claude_stop_hook "$target"
    install_grok_stop_hook "$target"
    install_codex_stop_hook "$target"

    log_success "Installed Stop hook in $target"
    log_info "State: $target/$AR_STATE_RELPATH (gitignored)"
    log_info "Claude: .claude/settings.json"
    log_info "Grok:   .grok/hooks/adversarial-review.json"
    log_info "Codex:  .codex/hooks.json"
}
