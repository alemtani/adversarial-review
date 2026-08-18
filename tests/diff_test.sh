#!/usr/bin/env bash
# Unit tests for git-diff review input.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/diff.sh"

FAILS=0
pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; FAILS=$((FAILS + 1)); }

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
    if printf '%s' "$haystack" | grep -Fq "$needle"; then
        pass "$label"
    else
        fail "$label (missing '$needle')"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="$3"
    if printf '%s' "$haystack" | grep -Fq "$needle"; then
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

# Not a git repo
plain=$(mktemp -d)
CLEANUP+=("$plain")
assert_fail "plain directory is not a work tree" is_git_work_tree "$plain"
assert_fail "collect rejects a non-git directory" collect_review_input "$plain"

# Empty path
assert_fail "empty path is not a work tree" is_git_work_tree ""

repo=$(make_repo)
CLEANUP+=("$repo")
assert_ok "fresh repo is a work tree" is_git_work_tree "$repo"

commit_file "$repo" "a.txt" "hello"
assert_ok "clean tree lists no files" test -z "$(list_changed_files "$repo")"

clean_input=$(collect_review_input "$repo")
assert_contains "$clean_input" "(none)" "clean tree payload notes no files"

# Unstaged edit
printf 'hello\nworld\n' > "$repo/a.txt"
changed=$(list_changed_files "$repo")
assert_contains "$changed" "a.txt" "unstaged edit is listed"

unstaged=$(collect_review_input "$repo")
assert_contains "$unstaged" "a.txt" "unstaged edit is in the payload"
assert_contains "$unstaged" "+world" "unstaged edit is in the diff"
assert_contains "$unstaged" "=== FILE: a.txt ===" "unstaged edit includes file contents"
assert_contains "$unstaged" "world" "file contents show the new line"

# Staged-only edit (reset working tree match by staging)
git -C "$repo" add a.txt
staged=$(list_changed_files "$repo")
assert_contains "$staged" "a.txt" "staged edit is listed"
staged_diff=$(collect_git_diff "$repo")
assert_contains "$staged_diff" "+world" "staged edit is in git diff HEAD"

# Untracked file
printf 'new\n' > "$repo/b.txt"
untracked=$(list_changed_files "$repo")
assert_contains "$untracked" "b.txt" "untracked file is listed"
untracked_input=$(collect_review_input "$repo")
assert_contains "$untracked_input" "b.txt" "untracked file is in the payload"
assert_contains "$untracked_input" "=== FILE: b.txt ===" "untracked file includes contents"
assert_contains "$untracked_input" "+new" "untracked file appears as a new-file diff"

# File with a space in the name
printf 'spaced\n' > "$repo/my file.txt"
assert_contains "$(list_changed_files "$repo")" "my file.txt" "path with spaces is listed"
space_input=$(collect_review_input "$repo")
assert_contains "$space_input" "my file.txt" "path with spaces is in the payload"
assert_contains "$space_input" "=== FILE: my file.txt ===" "path with spaces includes contents"

# Ignored files stay out
printf '*.tmp\n' > "$repo/.gitignore"
printf 'nope\n' > "$repo/foo.tmp"
assert_not_contains "$(list_changed_files "$repo")" "foo.tmp" "ignored file is not listed"

# Deleted tracked file
git -C "$repo" rm -f -q a.txt
assert_contains "$(list_changed_files "$repo")" "a.txt" "deleted file is listed"
deleted_input=$(collect_review_input "$repo")
assert_contains "$deleted_input" "=== FILE: a.txt (deleted) ===" "deleted file is marked, not dumped"

# Binary untracked file
printf 'text\0bin\n' > "$repo/data.bin"
assert_contains "$(list_changed_files "$repo")" "data.bin" "binary file is listed"
bin_input=$(collect_review_input "$repo")
assert_contains "$bin_input" "=== FILE: data.bin (binary, skipped) ===" "binary contents are skipped"

# Subdirectory scope: changes outside the subdir are omitted
commit_file "$repo" "lib/in.txt" "inside"
printf 'outside\n' > "$repo/root-only.txt"
printf 'inside-edit\n' >> "$repo/lib/in.txt"
sub_list=$(list_changed_files "$repo/lib")
assert_contains "$sub_list" "in.txt" "subdir lists its own change"
assert_not_contains "$sub_list" "root-only.txt" "subdir omits sibling changes"

# File-contents cap
cap_repo=$(make_repo)
CLEANUP+=("$cap_repo")
commit_file "$cap_repo" "keep.txt" "keep"
printf 'changed\n' > "$cap_repo/keep.txt"
printf 'one\n' > "$cap_repo/extra.txt"
capped=$(collect_review_input "$cap_repo" 1 500)
assert_contains "$capped" "(further file contents omitted; 1 file cap)" "file-contents cap is noted"
assert_contains "$capped" "extra.txt" "capped run still lists every changed path"

# CLI rejects a non-git target before the loop
cli="$ROOT_DIR/adversarial_review.sh"
out="$("$cli" "$plain" 2>&1 || true)"
if echo "$out" | grep -q "not a git repository"; then
    pass "CLI rejects a non-git target"
else
    fail "CLI non-git error missing: $out"
fi

# Old tree dump is gone
if grep -q "collect_source_code" "$cli"; then
    fail "collect_source_code is still in the main script"
else
    pass "collect_source_code was removed"
fi

if [[ $FAILS -gt 0 ]]; then
    echo "$FAILS failed"
    exit 1
fi
echo "all passed"
