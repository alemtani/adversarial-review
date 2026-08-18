#!/usr/bin/env bash
# Collect the uncommitted git diff and the contents of changed files.
# Review this turn's change, not the whole tree.
#
# File contents: whole file if it is at or under max_lines (default 2000).
# Larger files get the changed regions plus context. Do not head -n from
# line 1 — that drops edits further down.

: "${AR_HUNK_CONTEXT:=80}"

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
    } | sed '/^$/d' | sort -u
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

_is_untracked() {
    local dir="$1"
    local file="$2"
    local out
    out=$(_git "$dir" ls-files --others --exclude-standard -- "$file")
    [[ -n "$out" ]]
}

# New-side line ranges from git diff -U0. Prints "start end" (inclusive).
# Deletion-only hunks pin to the nearby new-side line so context still shows.
_new_side_ranges() {
    local dir="$1"
    local file="$2"
    _git "$dir" diff -U0 --relative HEAD -- "$file" | awk '
        /^@@ / {
            new = $3
            sub(/^\+/, "", new)
            n = split(new, p, ",")
            start = p[1] + 0
            count = (n >= 2 ? p[2] + 0 : 1)
            if (start < 1) start = 1
            if (count < 1) {
                print start, start
                next
            }
            print start, start + count - 1
        }
    '
}

# Expand ranges by context and merge overlaps. Reads "start end" lines.
_expand_and_merge_ranges() {
    local nlines="$1"
    local context="$2"
    awk -v n="$nlines" -v c="$context" '
        {
            s = $1 - c
            e = $2 + c
            if (s < 1) s = 1
            if (n > 0 && e > n) e = n
            if (e < s) e = s
            print s, e
        }
    ' | sort -n | awk '
        NR == 1 { cs = $1; ce = $2; next }
        $1 <= ce + 1 {
            if ($2 > ce) ce = $2
            next
        }
        { print cs, ce; cs = $1; ce = $2 }
        END { if (NR > 0) print cs, ce }
    '
}

_emit_slice() {
    local path="$1"
    local start="$2"
    local end="$3"
    sed -n "${start},${end}p" "$path" 2>/dev/null || true
}

_emit_file_contents() {
    local dir="$1"
    local file="$2"
    local max_lines="$3"
    local path="$dir/$file"
    local nlines ranges merged start end

    echo
    if [[ ! -e "$path" ]]; then
        echo "=== FILE: $file (deleted) ==="
        return 0
    fi
    if [[ -d "$path" ]]; then
        echo "=== FILE: $file (directory, skipped) ==="
        return 0
    fi
    if _is_binary_file "$path"; then
        echo "=== FILE: $file (binary, skipped) ==="
        return 0
    fi

    nlines=$(_file_line_count "$path")
    [[ -n "$nlines" ]] || nlines=0

    if [[ "$nlines" -le "$max_lines" ]]; then
        echo "=== FILE: $file ==="
        cat "$path" 2>/dev/null || true
        return 0
    fi

    if ! _has_head "$dir" || _is_untracked "$dir" "$file"; then
        echo "=== FILE: $file ($nlines lines; full contents are in the DIFF) ==="
        return 0
    fi

    ranges=$(_new_side_ranges "$dir" "$file")
    if [[ -z "$ranges" ]]; then
        echo "=== FILE: $file ($nlines lines; no new-side hunks) ==="
        return 0
    fi

    merged=$(printf '%s\n' "$ranges" | _expand_and_merge_ranges "$nlines" "${AR_HUNK_CONTEXT}")
    if [[ -z "$merged" ]]; then
        echo "=== FILE: $file ($nlines lines; no new-side hunks) ==="
        return 0
    fi

    if [[ $(printf '%s\n' "$merged" | wc -l | tr -d '[:space:]') -eq 1 ]]; then
        read -r start end <<< "$merged"
        if [[ "$start" -eq 1 && "$end" -eq "$nlines" ]]; then
            echo "=== FILE: $file ==="
            cat "$path" 2>/dev/null || true
            return 0
        fi
    fi

    echo "=== FILE: $file ($nlines lines; changed regions) ==="
    while read -r start end; do
        [[ -z "$start" ]] && continue
        echo
        echo "--- lines ${start}-${end} ---"
        _emit_slice "$path" "$start" "$end"
    done <<< "$merged"
}

# Print the review payload: changed file list, unified diff, file contents.
# Args: target_dir [max_files] [max_lines]
# max_lines is the whole-file include threshold, not a head -n cap.
# Returns 1 if target_dir is not a git work tree.
collect_review_input() {
    local target_dir="$1"
    local max_files="${2:-30}"
    local max_lines="${3:-2000}"
    local files file count=0

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
        if [[ $count -ge $max_files ]]; then
            echo
            echo "(further file contents omitted; $max_files file cap)"
            break
        fi
        _emit_file_contents "$target_dir" "$file" "$max_lines"
        count=$((count + 1))
    done <<< "$files"
}
