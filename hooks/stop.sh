#!/usr/bin/env bash
# Thin Stop hook for Claude, Grok, and Codex.
# Reads the event JSON on stdin. Never edits the tree.
set -euo pipefail

# Fail open. A crash must not trap the writer.
trap 'exit 0' ERR

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AR_DIR="${AR_DIR:-$(cd "$HOOK_DIR/.." && pwd)}"

_hook_emit() {
    printf '%s\n' "$1" >&2
    if [[ -n "${HOOK_LOG:-}" ]]; then
        printf '%s\n' "$1" >> "$HOOK_LOG"
    fi
}
log_info()    { _hook_emit "[INFO] $1"; }
log_success() { _hook_emit "[SUCCESS] $1"; }
log_warning() { _hook_emit "[WARNING] $1"; }
log_error()   { _hook_emit "[ERROR] $1"; }
log_claude()  { _hook_emit "[CLAUDE] $1"; }
log_codex()   { _hook_emit "[CODEX] $1"; }
log_grok()    { _hook_emit "[GROK] $1"; }
log_verbose() { [[ "${VERBOSE:-0}" == "1" ]] && _hook_emit "[VERBOSE] $1" || true; }

if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

# shellcheck source=../lib/hook.sh
source "$AR_DIR/lib/hook.sh"

WRITER_ARG="${AR_WRITER:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --writer)
            WRITER_ARG="${2:-}"
            shift 2
            ;;
        claude|codex|grok)
            WRITER_ARG="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

payload=$(cat || true)
run_stop_hook "$payload" "$WRITER_ARG" || true
exit 0
