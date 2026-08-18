#!/usr/bin/env bash
# Collect the uncommitted git diff and the contents of changed files.
# Review this turn's change, not the whole tree.
#
# The whole diff is always included. Whole file bodies are included until
# the content budget (default 10000 lines). Do not slice the diff.

: "${AR_CONTENT_LINES:=10000}"

if ! declare -F log_error >/dev/null 2>&1; then
    log_error() { echo "[ERROR] $1" >&2; }
fi

# Run git in dir. No pager, no color, literal paths.
_git() {
    local dir="$1"
    shift
    git -C "$dir" --no-pager -c color.ui=never -c core.quotepath=off "$@"
}

_has_head() {
    git -C "$1" rev-parse --verify --quiet HEAD >/dev/null 2>&1
}

# True if the first 8KiB contains a NUL. Do not grep for NUL; BSD grep
# treats that pattern as a match on any file.
_is_binary_file() {
    local file="$1"
    local raw stripped
    [[ -f "$file" && ! -L "$file" ]] || return 1
    raw=$(head -c 8192 "$file" | wc -c)
    stripped=$(head -c 8192 "$file" | tr -d '\000' | wc -c)
    [[ "$raw" -ne "$stripped" ]]
}

is_git_work_tree() {
    local dir="${1:-}"
    [[ -n "$dir" && -d "$dir" ]] || return 1
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Tool state in the target, not part of the change under review.
is_review_state_path() {
    case "${1:-}" in
        .adversarial-review|/*/.adversarial-review/*|.adversarial-review/*) return 0 ;;
    esac
    return 1
}

# Print changed paths relative to dir, one per line.
# Tracked changes vs HEAD (staged and unstaged) plus untracked files.
# Scoped to dir when dir is a subdirectory of the repo.
list_changed_files() {
    local dir="$1"
    {
        if _has_head "$dir"; then
            _git "$dir" diff --name-only --relative HEAD -- .
        fi
        _git "$dir" ls-files --others --exclude-standard -- .
    } | sed '/^$/d' | while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        is_review_state_path "$f" && continue
        printf '%s\n' "$f"
    done | sort -u
}

# Print the unified diff for tracked changes vs HEAD, then untracked files.
collect_git_diff() {
    local dir="$1"
    local file rc

    if _has_head "$dir"; then
        _git "$dir" diff --no-color --relative HEAD -- .
    fi

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        is_review_state_path "$file" && continue
        rc=0
        _git "$dir" diff --no-color --no-index -- /dev/null "$file" || rc=$?
        if [[ $rc -ne 0 && $rc -ne 1 ]]; then
            return "$rc"
        fi
    done < <(_git "$dir" ls-files --others --exclude-standard -- .)
}

_file_line_count() {
    wc -l < "$1" | tr -d '[:space:]'
}

# Emit one file's contents or a skip marker. Sets _EMITTED_LINES to the
# body line count (0 when the file is not dumped).
_EMITTED_LINES=0

_emit_one_file() {
    local path="$1"
    local label="$2"

    _EMITTED_LINES=0
    echo
    if [[ ! -e "$path" ]]; then
        echo "=== FILE: $label (deleted) ==="
        return 0
    fi
    if [[ -d "$path" ]]; then
        echo "=== FILE: $label (directory, skipped) ==="
        return 0
    fi
    if _is_binary_file "$path"; then
        echo "=== FILE: $label (binary, skipped) ==="
        return 0
    fi
    echo "=== FILE: $label ==="
    cat "$path" 2>/dev/null || true
    _EMITTED_LINES=$(_file_line_count "$path")
    [[ -n "$_EMITTED_LINES" ]] || _EMITTED_LINES=0
}

_emit_file_contents() {
    local dir="$1"
    local file="$2"
    _emit_one_file "$dir/$file" "$file"
}

# Print the review payload: changed file list, unified diff, file contents.
# Args: target_dir [max_content_lines]
# The diff is never truncated. File bodies stop at the line budget.
# Returns 1 if target_dir is not a git work tree.
collect_review_input() {
    local target_dir="$1"
    local max_lines="${2:-$AR_CONTENT_LINES}"
    local files file used=0 omitting=0
    local -a omitted=()

    if ! is_git_work_tree "$target_dir"; then
        log_error "Target is not a git repository: $target_dir" >&2
        return 1
    fi

    files=$(list_changed_files "$target_dir")

    echo "# CHANGED FILES"
    if [[ -z "$files" ]]; then
        echo "(none)"
    else
        printf '%s\n' "$files"
    fi

    echo
    echo "# DIFF"
    collect_git_diff "$target_dir"

    echo
    echo "# CHANGED FILE CONTENTS"
    if [[ -z "$files" ]]; then
        echo "(none)"
        return 0
    fi

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        if [[ "$omitting" -eq 1 ]]; then
            omitted+=("$file")
            continue
        fi

        local path="$target_dir/$file" nlines=0
        if [[ -f "$path" && ! -d "$path" ]] && ! _is_binary_file "$path"; then
            nlines=$(_file_line_count "$path")
            [[ -n "$nlines" ]] || nlines=0
            if [[ $((used + nlines)) -gt "$max_lines" ]]; then
                omitting=1
                omitted+=("$file")
                continue
            fi
        fi

        _emit_file_contents "$target_dir" "$file"
        used=$((used + _EMITTED_LINES))
    done <<< "$files"

    if [[ ${#omitted[@]} -gt 0 ]]; then
        echo
        echo "(further file contents omitted; ${max_lines} line budget)"
        local skip
        for skip in "${omitted[@]}"; do
            echo "  $skip"
        done
    fi
}

# ---------------------------------------------------------------------------
# Explicit paths (--files / --file)
#
# Review named files and directories instead of the git diff. Works in any
# directory, git or not, dirty or clean. The same line budget applies.
# ---------------------------------------------------------------------------

# Print one file per line for each named path. Directories expand to their
# files. Skips .git and tool state. Duplicates are dropped, order is kept.
# Returns 1 when a path does not exist.
expand_review_paths() {
    local p rc=0 raw=""
    for p in "$@"; do
        [[ -n "$p" ]] || continue
        p="${p%/}"
        [[ -n "$p" ]] || p="/"
        if [[ -d "$p" ]]; then
            raw+="$(find "$p" -type f \
                ! -path '*/.git/*' \
                ! -path '*/.adversarial-review/*' \
                -print | sort)"$'\n'
        elif [[ -e "$p" ]]; then
            raw+="$p"$'\n'
        else
            log_error "Path does not exist: $p"
            rc=1
        fi
    done
    printf '%s' "$raw" | awk 'NF && !seen[$0]++'
    return $rc
}

# Print the path shown to the reviewer. Relative to base_dir when possible.
_display_path() {
    local base="${1%/}"
    local path="$2"
    if [[ -n "$base" && "$path" == "$base/"* ]]; then
        printf '%s' "${path#"$base"/}"
    else
        printf '%s' "$path"
    fi
}

# Print the review payload for explicit paths: file list, then contents.
# Args: base_dir path... ; budget comes from AR_CONTENT_LINES.
# File bodies stop at the line budget. Returns 1 if a path is missing.
collect_paths_input() {
    local base_dir="$1"
    shift
    local max_lines="${AR_CONTENT_LINES}"
    local files file label used=0 omitting=0
    local -a omitted=()

    files=$(expand_review_paths "$@") || return 1

    echo "# REVIEW PATHS"
    if [[ -z "$files" ]]; then
        echo "(none)"
        echo
        echo "# FILE CONTENTS"
        echo "(none)"
        return 0
    fi
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        printf '%s\n' "$(_display_path "$base_dir" "$file")"
    done <<< "$files"

    echo
    echo "# FILE CONTENTS"

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        label=$(_display_path "$base_dir" "$file")
        if [[ "$omitting" -eq 1 ]]; then
            omitted+=("$label")
            continue
        fi

        local nlines=0
        if [[ -f "$file" && ! -d "$file" ]] && ! _is_binary_file "$file"; then
            nlines=$(_file_line_count "$file")
            [[ -n "$nlines" ]] || nlines=0
            if [[ $((used + nlines)) -gt "$max_lines" ]]; then
                omitting=1
                omitted+=("$label")
                continue
            fi
        fi

        _emit_one_file "$file" "$label"
        used=$((used + _EMITTED_LINES))
    done <<< "$files"

    if [[ ${#omitted[@]} -gt 0 ]]; then
        echo
        echo "(further file contents omitted; ${max_lines} line budget)"
        local skip
        for skip in "${omitted[@]}"; do
            echo "  $skip"
        done
    fi
}
