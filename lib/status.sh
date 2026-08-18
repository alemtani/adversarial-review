#!/usr/bin/env bash
# Parse agent status blocks.
# Format: ---REVIEW_STATUS--- ... ---END_REVIEW_STATUS---

parse_status_block() {
    local file="$1"
    local block_name="${2:-REVIEW_STATUS}"

    if [[ ! -f "$file" ]]; then
        echo '{"error": "file not found"}'
        return 1
    fi

    local content block
    content=$(cat "$file")
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
