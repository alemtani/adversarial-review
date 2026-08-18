#!/usr/bin/env bash
# Parse agent status blocks.
# Format: ---REVIEW_STATUS--- ... ---END_REVIEW_STATUS---
#
# An agent that writes nothing, stops mid-block, or omits the block failed.
# That is not a clean review. Every such case returns an "error" field and
# a non-zero status. Callers must treat it as a failure, not as 0 issues.

# True when the file holds something an agent actually wrote.
agent_output_ok() {
    local file="${1:-}"
    [[ -f "$file" ]] || return 1
    [[ -n "$(tr -d '[:space:]' < "$file")" ]]
}

# True when a parsed status JSON reports a failure instead of a review.
status_failed() {
    printf '%s' "${1:-}" | jq -e 'has("error")' >/dev/null 2>&1
}

# Print the failure text from a parsed status JSON. Empty when it parsed.
status_error() {
    printf '%s' "${1:-}" | jq -r '.error // empty' 2>/dev/null || true
}

parse_status_block() {
    local file="$1"
    local block_name="${2:-REVIEW_STATUS}"

    if [[ ! -f "$file" ]]; then
        echo '{"error": "file not found"}'
        return 1
    fi

    if ! agent_output_ok "$file"; then
        echo '{"error": "empty agent output"}'
        return 1
    fi

    local content block
    content=$(cat "$file")

    if grep -Fq -- "---${block_name}---" "$file" \
        && ! grep -Fq -- "---END_${block_name}---" "$file"; then
        echo '{"error": "truncated status block"}'
        return 1
    fi

    block=$(echo "$content" | sed -n "/---${block_name}---/,/---END_${block_name}---/p" | grep -v "^---")

    if [[ -z "$block" ]]; then
        if echo "$content" | grep -qE '^\s*NO_ISSUES\s*$'; then
            echo '{"exit_signal": true, "issues_found": 0}'
            return 0
        fi
        echo '{"error": "no status block"}'
        return 1
    fi

    local json="{"
    local first=true
    local key value
    while IFS=: read -r key value; do
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [[ "$first" == "true" ]] && first=false || json+=","

        if [[ "$value" =~ ^[0-9]+$ ]]; then
            json+="\"$key\": $value"
        elif [[ "$value" == "true" || "$value" == "false" ]]; then
            json+="\"$key\": $value"
        elif [[ "$value" == "YES" || "$value" == "FULL" ]]; then
            json+="\"$key\": true"
        elif [[ "$value" == "NO" || "$value" == "LOW" ]]; then
            json+="\"$key\": false"
        else
            json+="\"$key\": \"$value\""
        fi
    done <<< "$block"
    json+="}"

    echo "$json"
}
