#!/usr/bin/env bash
# Writer facts and reader judgment.
#
# The writer may pass a yes/no card. Those are claims. They may raise
# kind or depth. They may not lower it. They may not set depth.
# The reader returns counts, not a 1-10 score.
#
# Known keys: api_change, auth, migration, decision, docs_only, tests_only.
# Default sidecar in the target: .adversarial-review/writer-facts.yml

: "${WRITER_FACTS_RELPATH:=.adversarial-review/writer-facts.yml}"

FACT_API_CHANGE=0
FACT_AUTH=0
FACT_MIGRATION=0
FACT_DECISION=0
FACT_DOCS_ONLY=0
FACT_TESTS_ONLY=0
WRITER_FACTS_PRESENT=0
TRIAGE_FACTS_DISPUTED=""

reset_writer_facts() {
    FACT_API_CHANGE=0
    FACT_AUTH=0
    FACT_MIGRATION=0
    FACT_DECISION=0
    FACT_DOCS_ONLY=0
    FACT_TESTS_ONLY=0
    WRITER_FACTS_PRESENT=0
    TRIAGE_FACTS_DISPUTED=""
}

# 1 for true, 0 for false, empty for anything else.
parse_bool() {
    local v
    v=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' | tr -d '"' | tr -d "'")
    case "$v" in
        true|yes|1|on) echo 1 ;;
        false|no|0|off) echo 0 ;;
        *) echo "" ;;
    esac
}

is_known_fact_key() {
    case "${1:-}" in
        api_change|auth|migration|decision|docs_only|tests_only) return 0 ;;
        *) return 1 ;;
    esac
}

# Parse a key: value card. Unknown keys (depth, kind, prose) are ignored.
parse_writer_facts_text() {
    local text="${1:-}"
    local line key val bit

    reset_writer_facts

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="${line%%#*}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" == *:* ]] || continue
        key=$(printf '%s' "$line" | sed 's/[[:space:]]*:.*//' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' | tr -d '"' | tr -d "'")
        val=$(printf '%s' "$line" | sed 's/^[^:]*:[[:space:]]*//')
        is_known_fact_key "$key" || continue
        bit=$(parse_bool "$val")
        [[ -n "$bit" ]] || continue
        WRITER_FACTS_PRESENT=1
        case "$key" in
            api_change) FACT_API_CHANGE=$bit ;;
            auth) FACT_AUTH=$bit ;;
            migration) FACT_MIGRATION=$bit ;;
            decision) FACT_DECISION=$bit ;;
            docs_only) FACT_DOCS_ONLY=$bit ;;
            tests_only) FACT_TESTS_ONLY=$bit ;;
        esac
    done <<< "$text"
}

parse_writer_facts_file() {
    local file="${1:-}"
    reset_writer_facts
    [[ -n "$file" && -f "$file" && ! -L "$file" ]] || return 1
    parse_writer_facts_text "$(cat "$file")"
}

# Resolve the sidecar path. Args: target_dir [explicit_file]
writer_facts_path() {
    local dir="$1"
    local explicit="${2:-}"
    if [[ -n "$explicit" ]]; then
        printf '%s\n' "$explicit"
        return 0
    fi
    if [[ -n "${AR_WRITER_FACTS:-}" ]]; then
        printf '%s\n' "$AR_WRITER_FACTS"
        return 0
    fi
    printf '%s\n' "$dir/$WRITER_FACTS_RELPATH"
}

load_writer_facts() {
    local dir="$1"
    local explicit="${2:-}"
    local path
    path=$(writer_facts_path "$dir" "$explicit")
    parse_writer_facts_file "$path" || reset_writer_facts
}

# Print the card for the reviewer. Empty when the writer sent nothing.
format_writer_facts() {
    [[ "$WRITER_FACTS_PRESENT" -eq 1 ]] || return 0

    cat << EOF
## Writer facts (claims)

The writer marked these. They are claims, not the review. Check them
against the diff. Do not take them as the verdict.

- api_change: $([[ "$FACT_API_CHANGE" -eq 1 ]] && echo yes || echo no)
- auth: $([[ "$FACT_AUTH" -eq 1 ]] && echo yes || echo no)
- migration: $([[ "$FACT_MIGRATION" -eq 1 ]] && echo yes || echo no)
- decision: $([[ "$FACT_DECISION" -eq 1 ]] && echo yes || echo no)
- docs_only: $([[ "$FACT_DOCS_ONLY" -eq 1 ]] && echo yes || echo no)
- tests_only: $([[ "$FACT_TESTS_ONLY" -eq 1 ]] && echo yes || echo no)
EOF

    if [[ -n "$TRIAGE_FACTS_DISPUTED" ]]; then
        echo
        echo "Disputed (the diff disagrees): $TRIAGE_FACTS_DISPUTED"
    fi
}

# Count field from a parsed status JSON. Non-numbers become 0.
status_count() {
    local status="${1:-}"
    local key="$2"
    local v
    v=$(printf '%s' "$status" | jq -r --arg k "$key" '.[$k] // 0' 2>/dev/null) || v=0
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    printf '%s' "$v"
}

# True when the hook should block. Nits do not block.
# Args: mode (spec|code) status_json
review_should_block() {
    local mode="$1"
    local status="${2:-}"
    local n verdict

    [[ -n "$status" ]] || return 1
    if printf '%s' "$status" | jq -e '.error' >/dev/null 2>&1; then
        return 1
    fi

    if [[ "$mode" == "spec" ]]; then
        n=$(status_count "$status" decision_issues)
        [[ "$n" -gt 0 ]] && return 0
        verdict=$(printf '%s' "$status" | jq -r '.verdict // empty' | tr '[:upper:]' '[:lower:]')
        case "$verdict" in
            "ready with issues"|"not ready") return 0 ;;
        esac
        return 1
    fi

    n=$(status_count "$status" critical_count)
    [[ "$n" -gt 0 ]] && return 0
    n=$(status_count "$status" high_count)
    [[ "$n" -gt 0 ]] && return 0
    return 1
}
