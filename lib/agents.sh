#!/usr/bin/env bash
# Agent adapters. One function per CLI. Callers use run_agent or the wrappers.
#
# Isolate each CLI here so the review loop does not hardcode flags.
# This follows the provider-registry pattern used by LiteLLM and Ragas:
# callers name an agent; this file translates that name into a CLI invocation.
#
# Registry. To add a provider: append the name here and add run_<name>().
# The CLI binary is the same as the name. Modes: review | apply.
#
# Grok review calls use --tools to restrict to read/search. That is least
# privilege: a reviewer should not edit the tree. See Grok headless docs.

KNOWN_AGENTS=(claude codex grok)
: "${DEFAULT_WRITER:=claude}"
DEFAULT_REVIEWER_ORDER=(codex grok)

# Defaults if sourced outside the main script
: "${DRY_RUN:=0}"
: "${TIMEOUT_MINUTES:=10}"

if ! declare -F log_agent >/dev/null 2>&1; then
    log_agent() {
        local name="$1"
        shift
        local tag
        tag=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
        echo "[$tag] $*"
    }
fi
if ! declare -F log_warning >/dev/null 2>&1; then
    log_warning() { echo "[WARNING] $1"; }
    log_error()   { echo "[ERROR] $1"; }
fi

is_known_agent() {
    local name="$1"
    local known
    for known in "${KNOWN_AGENTS[@]}"; do
        [[ "$known" == "$name" ]] && return 0
    done
    return 1
}

# Cross-platform timeout command
get_timeout_cmd() {
    if command -v gtimeout &> /dev/null; then
        echo "gtimeout"
    elif command -v timeout &> /dev/null; then
        echo "timeout"
    else
        echo ""
    fi
}

# Map agent name to CLI binary. The binary matches the registry name.
agent_cli() {
    is_known_agent "$1" || return 1
    printf '%s\n' "$1"
}

agent_available() {
    local bin
    bin=$(agent_cli "$1") || return 1
    command -v "$bin" &>/dev/null
}

# Print one "name: available|missing" line per known agent
print_agent_status() {
    local name bin
    for name in "${KNOWN_AGENTS[@]}"; do
        bin=$(agent_cli "$name")
        if command -v "$bin" &>/dev/null; then
            echo "$name: available ($(command -v "$bin"))"
        else
            echo "$name: missing"
        fi
    done
}

# True when 4th-arg mode means "may edit files"
# Accepts legacy run_claude 4th arg "true" and the new "apply" name.
_agent_is_apply_mode() {
    local mode="${1:-review}"
    [[ "$mode" == "true" || "$mode" == "apply" ]]
}

# Run a command with optional timeout. Merges stdout and stderr into output_file.
# Args: working_dir output_file command [args...]
_run_timed_merged() {
    local working_dir="$1"
    local output_file="$2"
    shift 2

    local timeout_cmd timeout_secs exit_code=0
    timeout_cmd=$(get_timeout_cmd)
    timeout_secs=$(( ${TIMEOUT_MINUTES:-10} * 60 ))

    if [[ -n "$timeout_cmd" ]]; then
        (cd "$working_dir" && "$timeout_cmd" "${timeout_secs}s" "$@") > "$output_file" 2>&1 || exit_code=$?
    else
        (cd "$working_dir" && "$@") > "$output_file" 2>&1 || exit_code=$?
    fi
    return $exit_code
}

# Run a command with optional timeout. Keeps stdout and stderr separate.
# Args: working_dir stdout_file stderr_file command [args...]
_run_timed_split() {
    local working_dir="$1"
    local stdout_file="$2"
    local stderr_file="$3"
    shift 3

    local timeout_cmd timeout_secs exit_code=0
    timeout_cmd=$(get_timeout_cmd)
    timeout_secs=$(( ${TIMEOUT_MINUTES:-10} * 60 ))

    if [[ -n "$timeout_cmd" ]]; then
        (cd "$working_dir" && "$timeout_cmd" "${timeout_secs}s" "$@") > "$stdout_file" 2>"$stderr_file" || exit_code=$?
    else
        (cd "$working_dir" && "$@") > "$stdout_file" 2>"$stderr_file" || exit_code=$?
    fi
    return $exit_code
}

_agent_dry_run() {
    local name="$1"
    local prompt="$2"
    local output_file="$3"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_agent "$name" "[DRY RUN] Would run ${name} (${#prompt} chars) -> $output_file"
        echo "DRY RUN: ${name} output" > "$output_file"
        return 0
    fi
    return 1
}

_log_agent_result() {
    local name="$1"
    local exit_code="$2"
    local output_file="$3"

    if [[ $exit_code -eq 0 ]]; then
        log_agent "$name" "Complete ($(wc -l < "$output_file" | tr -d ' ') lines)"
    elif [[ $exit_code -eq 124 ]]; then
        log_warning "${name} timed out after ${TIMEOUT_MINUTES:-10}m"
    else
        log_warning "${name} exited with code $exit_code"
    fi
}

# Run Claude
# Args: prompt output_file [working_dir] [mode]
# mode: review (default) | apply | true (legacy apply)
run_claude() {
    local prompt="$1"
    local output_file="$2"
    local working_dir="${3:-$PWD}"
    local mode="${4:-review}"

    _agent_dry_run claude "$prompt" "$output_file" && return 0

    log_agent claude "Running..."

    local cmd_args=(--print)
    if _agent_is_apply_mode "$mode"; then
        cmd_args+=(--dangerously-skip-permissions)
    fi

    local exit_code=0
    # Claude reads the prompt from stdin
    local timeout_cmd timeout_secs
    timeout_cmd=$(get_timeout_cmd)
    timeout_secs=$(( ${TIMEOUT_MINUTES:-10} * 60 ))
    if [[ -n "$timeout_cmd" ]]; then
        (cd "$working_dir" && echo "$prompt" | "$timeout_cmd" "${timeout_secs}s" claude "${cmd_args[@]}") > "$output_file" 2>&1 || exit_code=$?
    else
        (cd "$working_dir" && echo "$prompt" | claude "${cmd_args[@]}") > "$output_file" 2>&1 || exit_code=$?
    fi

    _log_agent_result claude "$exit_code" "$output_file"
    return $exit_code
}

# Run Codex
# Args: prompt output_file [working_dir] [mode]
# Codex --full-auto is used for both modes. The CLI has no read-only flag
# equivalent to Grok --tools. Mode is accepted for a uniform run_agent API.
run_codex() {
    local prompt="$1"
    local output_file="$2"
    local working_dir="${3:-$PWD}"

    _agent_dry_run codex "$prompt" "$output_file" && return 0

    log_agent codex "Running..."

    local exit_code=0
    _run_timed_merged "$working_dir" "$output_file" \
        codex -q --full-auto --prompt "$prompt" || exit_code=$?

    _log_agent_result codex "$exit_code" "$output_file"
    return $exit_code
}

# Write Grok's response text into output_file.
# Headless --output-format json puts the answer in .text and logs on stderr.
# Keep .text only so later status-block parsing sees markdown, not the envelope.
_extract_grok_text() {
    local raw_json="$1"
    local err_file="$2"
    local output_file="$3"

    if jq -e 'type == "object" and has("text")' "$raw_json" >/dev/null 2>&1; then
        jq -r '.text // ""' "$raw_json" > "$output_file"
        return 0
    fi

    cat "$raw_json" > "$output_file"
    if [[ -s "$err_file" ]]; then
        {
            echo ""
            echo "--- grok stderr ---"
            cat "$err_file"
        } >> "$output_file"
    fi
}

# Run Grok
# Args: prompt output_file [working_dir] [mode]
# review: read_file, grep, list_dir only; no subagents
# apply:  --always-approve (needed later for optional --apply)
run_grok() {
    local prompt="$1"
    local output_file="$2"
    local working_dir="${3:-$PWD}"
    local mode="${4:-review}"

    _agent_dry_run grok "$prompt" "$output_file" && return 0

    log_agent grok "Running..."

    local prompt_file raw_json err_file
    prompt_file=$(mktemp)
    raw_json=$(mktemp)
    err_file=$(mktemp)
    printf '%s' "$prompt" > "$prompt_file"

    # --prompt-file avoids ARG_MAX on large review prompts
    local cmd=(
        grok
        --prompt-file "$prompt_file"
        --cwd "$working_dir"
        --output-format json
        --verbatim
        --no-subagents
    )
    if _agent_is_apply_mode "$mode"; then
        cmd+=(--always-approve)
    else
        cmd+=(--tools "read_file,grep,list_dir")
    fi

    local exit_code=0
    _run_timed_split "$working_dir" "$raw_json" "$err_file" "${cmd[@]}" || exit_code=$?

    _extract_grok_text "$raw_json" "$err_file" "$output_file"
    rm -f "$prompt_file" "$raw_json" "$err_file"

    _log_agent_result grok "$exit_code" "$output_file"
    return $exit_code
}

# Dispatch by agent name. Calls run_<name>.
# Args: name prompt output_file [working_dir] [mode]
run_agent() {
    local name="$1"
    shift

    if ! is_known_agent "$name"; then
        log_error "Unknown agent: $name"
        return 1
    fi

    local runner="run_${name}"
    if ! declare -F "$runner" >/dev/null 2>&1; then
        log_error "No runner for agent: $name (add ${runner}())"
        return 1
    fi

    "$runner" "$@"
}
