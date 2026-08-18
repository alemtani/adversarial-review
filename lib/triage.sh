#!/usr/bin/env bash
# Local depth triage. Do not call a model to classify.
#
# Kind:  editorial | operational | decisional | code
# Depth: skip | quick | standard | deep
# Mode:  spec | code   (spec prompt vs code-review prompt)
#
# --kind spec is an alias for decisional.

if ! declare -F list_changed_files >/dev/null 2>&1; then
    # shellcheck source=diff.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/diff.sh"
fi

TRIAGE_KIND="code"
TRIAGE_DEPTH="skip"
TRIAGE_MODE="code"
TRIAGE_REASON=""

_STAT_FILES=0
_STAT_ADDED=0
_STAT_DELETED=0
_STAT_REWRITE=0
_STAT_NEW_LARGE=0
_FM_KIND=""
_FM_REVIEW=""

normalize_kind() {
    local k
    k=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "$k" in
        spec) echo "decisional" ;;
        editorial|operational|decisional|code) echo "$k" ;;
        *) echo "" ;;
    esac
}

normalize_depth() {
    local d
    d=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "$d" in
        skip|quick|standard|deep) echo "$d" ;;
        *) echo "" ;;
    esac
}

depth_rank() {
    case "${1:-}" in
        skip) echo 0 ;;
        quick) echo 1 ;;
        standard) echo 2 ;;
        deep) echo 3 ;;
        *) echo -1 ;;
    esac
}

max_depth() {
    local a="${1:-}" b="${2:-}"
    if [[ "$(depth_rank "$a")" -ge "$(depth_rank "$b")" ]]; then
        printf '%s\n' "$a"
    else
        printf '%s\n' "$b"
    fi
}

_norm_path() {
    printf '%s' "${1:-}" | sed -e 's#^\./##' | tr '[:upper:]' '[:lower:]'
}

is_decisional_path() {
    local p base
    p=$(_norm_path "$1")
    [[ -n "$p" ]] || return 1
    base="${p##*/}"

    case "$p" in
        docs/adr/*|*/docs/adr/*) return 0 ;;
        docs/design/*|*/docs/design/*) return 0 ;;
        docs/rfcs/*|*/docs/rfcs/*) return 0 ;;
        docs/rfc/*|*/docs/rfc/*) return 0 ;;
    esac
    [[ "$base" == "architecture.md" || "$base" == "design.md" ]] && return 0
    [[ "$base" == *.spec.md ]] && return 0
    return 1
}

is_operational_path() {
    local p base
    p=$(_norm_path "$1")
    [[ -n "$p" ]] || return 1
    base="${p##*/}"

    is_decisional_path "$1" && return 1

    case "$base" in
        readme|readme.md|readme.rst|readme.txt) return 0 ;;
        contributing.md|changelog.md) return 0 ;;
        *runbook*) return 0 ;;
    esac
    case "$p" in
        docs/*|*/docs/*) return 0 ;;
    esac
    return 1
}

is_doc_path() {
    local p base
    p=$(_norm_path "$1")
    base="${p##*/}"
    case "$base" in
        *.md|*.rst|*.txt|*.adoc) return 0 ;;
    esac
    return 1
}

is_code_path() {
    [[ -n "${1:-}" ]] || return 1
    if is_doc_path "$1"; then
        return 1
    fi
    return 0
}

_path_has_token() {
    local p="$1" token="$2" comp
    local rest="$p"
    while [[ -n "$rest" ]]; do
        comp="${rest%%/*}"
        if [[ "$rest" == */* ]]; then
            rest="${rest#*/}"
        else
            rest=""
        fi
        [[ -n "$comp" ]] || continue
        [[ "$comp" == "$token" ]] && return 0
        [[ "$comp" == "$token".* ]] && return 0
        [[ "$comp" == "$token"_* || "$comp" == "$token"-* ]] && return 0
        [[ "$comp" == *_"$token" || "$comp" == *_"$token".* || "$comp" == *_"$token"_* ]] && return 0
        [[ "$comp" == *-"$token" || "$comp" == *-"$token".* ]] && return 0
    done
    return 1
}

is_sensitive_path() {
    local p base token
    p=$(_norm_path "$1")
    [[ -n "$p" ]] || return 1
    base="${p##*/}"

    case "$p" in
        .github/workflows/*|*/.github/workflows/*) return 0 ;;
        */migrations/*|migrations/*) return 0 ;;
    esac
    case "$base" in
        dockerfile|dockerfile.*|docker-compose|docker-compose.*) return 0 ;;
    esac
    for token in auth oauth jwt session password secret crypto cipher tls ssl \
        cert permission rbac acl billing payment security; do
        if _path_has_token "$p" "$token"; then
            return 0
        fi
    done
    return 1
}

# True when text uses decision language from the handoff list.
has_decision_language() {
    local text="${1:-}"
    [[ -n "$text" ]] || return 1
    printf '%s' "$text" | grep -qiE 'we will|decision|alternatives|trade-?off|non-?goals|(^|[^A-Za-z])MUST([^A-Za-z]|$)'
}

# Parse a leading --- ... --- block. Sets _FM_KIND and _FM_REVIEW.
parse_frontmatter_text() {
    local text="${1:-}"
    local line key val seen_start=0

    _FM_KIND=""
    _FM_REVIEW=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$seen_start" -eq 0 ]]; then
            [[ "$line" == "---" ]] || return 0
            seen_start=1
            continue
        fi
        if [[ "$line" == "---" ]]; then
            return 0
        fi
        [[ -z "$line" || "$line" == \#* ]] && continue
        key=$(printf '%s' "$line" | sed 's/[[:space:]]*:.*//' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        val=$(printf '%s' "$line" | sed 's/^[^:]*:[[:space:]]*//' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' | tr -d '"' | tr -d "'")
        case "$key" in
            kind) _FM_KIND="$val" ;;
            review) _FM_REVIEW="$val" ;;
        esac
    done <<< "$text"
}

parse_frontmatter_file() {
    local file="$1"
    _FM_KIND=""
    _FM_REVIEW=""
    [[ -f "$file" && ! -L "$file" ]] || return 0
    parse_frontmatter_text "$(head -n 40 "$file")"
}

# Depth instructions appended to the phase-1 prompt.
depth_guidance() {
    case "${1:-}" in
        quick)
            cat << 'EOF'
## Review depth: QUICK

Look for obvious defects only. Do not debate style or nits.
EOF
            ;;
        standard)
            cat << 'EOF'
## Review depth: STANDARD

Review correctness, design choices, and risks. Ignore pure style nits
unless they hide a real defect.
EOF
            ;;
        deep)
            cat << 'EOF'
## Review depth: DEEP

Be thorough. Check alternatives, edge cases, invariants, and hidden costs.
A spec review that only emits nits is a failed review.
EOF
            ;;
    esac
}

_added_diff_lines() {
    printf '%s\n' "${1:-}" | grep -E '^\+' | grep -vE '^\+\+\+' || true
}

# Added lines for one path. Untracked files count as a full add.
_file_added_text() {
    local dir="$1" file="$2"
    local text=""

    if _has_head "$dir"; then
        text=$(_added_diff_lines "$(_git "$dir" diff --no-color --relative HEAD -- "$file")")
    fi
    if [[ -n "$text" ]]; then
        printf '%s' "$text"
        return 0
    fi
    if [[ -f "$dir/$file" ]]; then
        if ! _has_head "$dir" || ! _git "$dir" ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
            cat "$dir/$file"
        fi
    fi
}

_is_whitespace_only() {
    local dir="$1"
    local untracked names

    untracked=$(_git "$dir" ls-files --others --exclude-standard -- .)
    if [[ -n "$untracked" ]]; then
        return 1
    fi
    if ! _has_head "$dir"; then
        return 1
    fi
    names=$(_git "$dir" diff -w --name-only --relative HEAD -- .)
    [[ -z "$names" ]]
}

# Fill _STAT_* for the uncommitted change in dir.
_collect_change_stats() {
    local dir="$1"
    local file added deleted current old changed path status

    _STAT_FILES=0
    _STAT_ADDED=0
    _STAT_DELETED=0
    _STAT_REWRITE=0
    _STAT_NEW_LARGE=0

    local files
    files=$(list_changed_files "$dir")
    if [[ -z "$files" ]]; then
        return 0
    fi

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        _STAT_FILES=$((_STAT_FILES + 1))
    done <<< "$files"

    if _has_head "$dir"; then
        while IFS=$'\t' read -r added deleted path; do
            [[ -n "${path:-}" ]] || continue
            [[ "$added" == "-" ]] && added=0
            [[ "$deleted" == "-" ]] && deleted=0
            _STAT_ADDED=$((_STAT_ADDED + added))
            _STAT_DELETED=$((_STAT_DELETED + deleted))
            current=0
            if [[ -f "$dir/$path" ]]; then
                current=$(_file_line_count "$dir/$path")
            fi
            old=$((current - added + deleted))
            [[ "$old" -lt 0 ]] && old=0
            changed=$((added + deleted))
            if [[ "$current" -ge 20 || "$old" -ge 20 ]]; then
                local basis=$current
                [[ "$old" -gt "$basis" ]] && basis=$old
                if [[ "$changed" -ge $((basis * 7 / 10)) ]]; then
                    _STAT_REWRITE=1
                fi
            fi
        done < <(_git "$dir" diff --numstat --relative HEAD -- .)

        while IFS=$'\t' read -r status path; do
            [[ "$status" == "A" ]] || continue
            if [[ -f "$dir/$path" ]]; then
                current=$(_file_line_count "$dir/$path")
                if [[ "$current" -gt 50 ]]; then
                    _STAT_NEW_LARGE=1
                fi
            fi
        done < <(_git "$dir" diff --name-status --relative HEAD -- .)
    fi

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        [[ -f "$dir/$file" ]] || continue
        added=$(_file_line_count "$dir/$file")
        _STAT_ADDED=$((_STAT_ADDED + added))
        if [[ "$added" -gt 50 ]]; then
            _STAT_NEW_LARGE=1
        fi
    done < <(_git "$dir" ls-files --others --exclude-standard -- .)
}

_is_small_change() {
    local lines=$((_STAT_ADDED + _STAT_DELETED))
    [[ "$_STAT_FILES" -le 3 && "$lines" -le 80 && "$_STAT_REWRITE" -eq 0 && "$_STAT_NEW_LARGE" -eq 0 ]]
}

_is_large_change() {
    local lines=$((_STAT_ADDED + _STAT_DELETED))
    [[ "$_STAT_FILES" -ge 10 || "$lines" -ge 400 || "$_STAT_REWRITE" -eq 1 ]]
}

_emit_triage() {
    printf '%s %s %s\n' "$TRIAGE_KIND" "$TRIAGE_DEPTH" "$TRIAGE_MODE"
}

# Classify the uncommitted change.
# Args: target_dir [explicit_kind] [explicit_depth]
# Prints: kind depth mode
# Sets: TRIAGE_KIND TRIAGE_DEPTH TRIAGE_MODE TRIAGE_REASON
triage_change() {
    local dir="$1"
    local explicit_kind explicit_depth
    local files file
    local has_code=0 has_doc=0 has_decisional_path=0 has_sensitive=0
    local has_decision_lang=0 docs_only=1
    local fm_kind="" fm_depth=""
    local computed_kind="" computed_depth=""
    local reasons=()
    local whitespace_only=0
    local file_added=""

    explicit_kind=$(normalize_kind "${2:-}")
    explicit_depth=$(normalize_depth "${3:-}")

    TRIAGE_KIND="code"
    TRIAGE_DEPTH="skip"
    TRIAGE_MODE="code"
    TRIAGE_REASON="no changes"

    if ! is_git_work_tree "$dir"; then
        return 1
    fi

    files=$(list_changed_files "$dir")
    if [[ -z "$files" ]]; then
        _emit_triage
        return 0
    fi

    _collect_change_stats "$dir"
    if _is_whitespace_only "$dir"; then
        whitespace_only=1
    fi

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue

        if is_code_path "$file"; then
            has_code=1
            docs_only=0
        fi
        if is_doc_path "$file"; then
            has_doc=1
        fi
        if is_decisional_path "$file"; then
            has_decisional_path=1
        fi
        if is_sensitive_path "$file"; then
            has_sensitive=1
        fi

        if [[ -f "$dir/$file" ]]; then
            parse_frontmatter_file "$dir/$file"
            if [[ -n "$_FM_KIND" ]]; then
                local nk
                nk=$(normalize_kind "$_FM_KIND")
                if [[ "$nk" == "decisional" ]]; then
                    fm_kind="decisional"
                elif [[ -z "$fm_kind" && -n "$nk" ]]; then
                    fm_kind="$nk"
                fi
            fi
            if [[ -n "$_FM_REVIEW" ]]; then
                local nd
                nd=$(normalize_depth "$_FM_REVIEW")
                if [[ -n "$nd" ]]; then
                    fm_depth=$(max_depth "$fm_depth" "$nd")
                fi
            fi
        fi

        if is_doc_path "$file"; then
            file_added=$(_file_added_text "$dir" "$file")
            if has_decision_language "$file_added"; then
                has_decision_lang=1
            fi
        fi
    done <<< "$files"

    if [[ "$has_decisional_path" -eq 1 ]]; then
        computed_kind="decisional"
        reasons+=("decisional path")
    elif [[ "$has_decision_lang" -eq 1 ]]; then
        computed_kind="decisional"
        reasons+=("decision language")
    elif [[ "$has_code" -eq 1 ]]; then
        computed_kind="code"
        reasons+=("code change")
    elif [[ "$has_doc" -eq 1 ]]; then
        local saw_operational=0
        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            if is_operational_path "$file"; then
                saw_operational=1
                break
            fi
        done <<< "$files"
        if [[ "$saw_operational" -eq 1 ]]; then
            computed_kind="operational"
            reasons+=("operational docs")
        else
            computed_kind="editorial"
            reasons+=("doc change")
        fi
    else
        computed_kind="code"
        reasons+=("non-doc change")
    fi

    if [[ -n "$fm_kind" ]]; then
        computed_kind="$fm_kind"
        reasons+=("frontmatter kind")
    fi

    if [[ "$computed_kind" == "operational" && "$docs_only" -eq 1 ]]; then
        local changed_lines=$((_STAT_ADDED + _STAT_DELETED))
        if [[ "$whitespace_only" -eq 1 ]]; then
            computed_kind="editorial"
            reasons+=("editorial hunks")
        elif [[ "$changed_lines" -le 5 && "$_STAT_FILES" -le 1 && "$_STAT_REWRITE" -eq 0 ]]; then
            computed_kind="editorial"
            reasons+=("editorial hunks")
        fi
    fi

    if [[ "$whitespace_only" -eq 1 ]]; then
        reasons+=("whitespace only")
    fi
    if [[ "$has_sensitive" -eq 1 ]]; then
        reasons+=("sensitive path")
    fi
    if [[ "$_STAT_REWRITE" -eq 1 ]]; then
        reasons+=("rewrite")
    fi

    if [[ "$whitespace_only" -eq 1 && "$docs_only" -eq 1 && "$computed_kind" != "decisional" ]]; then
        computed_kind="editorial"
        computed_depth="skip"
    elif [[ "$computed_kind" == "editorial" ]]; then
        if [[ "$whitespace_only" -eq 1 || $((_STAT_ADDED + _STAT_DELETED)) -le 5 && "$_STAT_FILES" -le 1 ]]; then
            computed_depth="skip"
        else
            computed_depth="quick"
        fi
    elif [[ "$computed_kind" == "operational" ]]; then
        if _is_small_change; then
            computed_depth="quick"
        else
            computed_depth="standard"
        fi
    elif [[ "$computed_kind" == "decisional" ]]; then
        if _is_large_change; then
            computed_depth="deep"
        else
            computed_depth="standard"
        fi
    else
        if [[ "$has_sensitive" -eq 1 ]] || _is_large_change; then
            computed_depth="deep"
        elif _is_small_change && [[ "$has_sensitive" -eq 0 ]]; then
            computed_depth="quick"
        else
            computed_depth="standard"
        fi
    fi

    if [[ "$has_code" -eq 1 && "$has_decisional_path" -eq 1 && -z "$explicit_kind" && "$fm_kind" != "decisional" ]]; then
        computed_kind="code"
        computed_depth=$(max_depth "$computed_depth" "standard")
        reasons+=("mixed code and spec")
    fi

    if [[ "$computed_kind" == "decisional" ]]; then
        computed_depth=$(max_depth "$computed_depth" "standard")
    fi

    if [[ -n "$fm_depth" ]]; then
        computed_depth=$(max_depth "$computed_depth" "$fm_depth")
        reasons+=("frontmatter review")
    fi

    if [[ -n "$explicit_kind" ]]; then
        computed_kind="$explicit_kind"
        reasons+=("explicit kind")
        if [[ "$computed_kind" == "decisional" && -z "$explicit_depth" ]]; then
            computed_depth=$(max_depth "$computed_depth" "standard")
        fi
    fi

    if [[ -n "$explicit_depth" ]]; then
        computed_depth="$explicit_depth"
        reasons+=("explicit depth")
    fi

    TRIAGE_KIND="$computed_kind"
    TRIAGE_DEPTH="$computed_depth"
    if [[ "$TRIAGE_KIND" == "decisional" ]]; then
        TRIAGE_MODE="spec"
    else
        TRIAGE_MODE="code"
    fi
    TRIAGE_REASON=$(IFS=', '; echo "${reasons[*]}")

    _emit_triage
}
