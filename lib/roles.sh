#!/usr/bin/env bash
# Writer and reviewer roles.
#
# Default reviewer is Codex. If Codex is missing, use Grok.
# The writer never reviews its own work.

: "${DEFAULT_WRITER:=claude}"

# Trim and lowercase an agent name.
normalize_agent_name() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

# Print the reviewer name, or return 1 if none is eligible.
# Args: writer [explicit_reviewer]
resolve_reviewer() {
    local writer="$1"
    local explicit="${2:-}"

    if [[ -n "$explicit" ]]; then
        printf '%s\n' "$explicit"
        return 0
    fi

    if [[ "$writer" != "codex" ]] && agent_available codex; then
        printf '%s\n' "codex"
        return 0
    fi

    if [[ "$writer" != "grok" ]] && agent_available grok; then
        printf '%s\n' "grok"
        return 0
    fi

    return 1
}

# Validate writer and reviewer. Prints errors via log_error.
# Args: writer reviewer
validate_roles() {
    local writer="$1"
    local reviewer="$2"

    if ! is_known_agent "$writer"; then
        log_error "Unknown writer: $writer (known: ${KNOWN_AGENTS[*]})"
        return 1
    fi
    if ! is_known_agent "$reviewer"; then
        log_error "Unknown reviewer: $reviewer (known: ${KNOWN_AGENTS[*]})"
        return 1
    fi
    if [[ "$writer" == "$reviewer" ]]; then
        log_error "Writer and reviewer cannot be the same agent (no self-review)"
        return 1
    fi
    if ! agent_available "$writer"; then
        log_error "Writer CLI not found: $(agent_cli "$writer")"
        return 1
    fi
    if ! agent_available "$reviewer"; then
        log_error "Reviewer CLI not found: $(agent_cli "$reviewer")"
        return 1
    fi
    return 0
}
