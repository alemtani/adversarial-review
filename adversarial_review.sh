#!/usr/bin/env bash
#
# Adversarial Review: writer + reviewer loop
#
# A reviewer inspects the change. The writer rebuts. The reviewer answers.
# The writer synthesizes and implements fixes.
#
# Based on patterns from asimov-ralph (https://github.com/frankbria/ralph-claude-code)
#
# Usage:
#   ./adversarial_review.sh [OPTIONS] <target_dir>
#
# Options:
#   -h, --help              Show help message
#   -m, --max-iters N       Maximum iterations (default: 3)
#   -p, --prompt FILE       Custom review prompt file
#   -v, --verbose           Verbose output
#   -t, --timeout MIN       Timeout per agent call in minutes (default: 10)
#   --status                Show current status
#   --reset                 Reset artifacts and tracking
#   --reset-circuit         Reset circuit breaker
#   --circuit-status        Show circuit breaker status
#   --writer NAME           Agent that wrote the change (default: claude)
#   --reviewer NAME         Agent that reviews (default: Codex, then Grok)
#   --kind NAME             editorial, operational, decisional, spec, or code
#   --depth NAME            skip, quick, standard, or deep
#   --facts FILE            Writer facts card
#   --file PATH             Review this path instead of the git diff (repeatable)
#   --files PATH...         Review these paths instead of the git diff
#   --no-timeout            Run agents uncapped when no timeout command exists
#   --install-hook          Install the Stop hook into the target repo
#   --apply                 Standalone only. Writer implements agreed fixes.
#   --dry-run               Show what would be done without executing
#   --list-agents           Show which agent CLIs are installed
#
# Exit codes:
#   0  clean review, or nothing to review
#   1  issues found (or max iterations reached with issues open)
#   2  usage or dependency error
#   3  agent failure: no usable review came back
#   4  circuit breaker is open

set -euo pipefail

# Exit codes. Wire these into CI.
EXIT_OK=0
EXIT_ISSUES=1
EXIT_USAGE=2
EXIT_AGENT_FAILURE=3
EXIT_CIRCUIT_OPEN=4

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PROMPTS_DIR="$SCRIPT_DIR/prompts"

# Export AR_DIR for lib scripts
export AR_DIR="$SCRIPT_DIR"
ARTIFACTS_DIR="$AR_DIR/artifacts"
LOGS_DIR="$AR_DIR/logs"
TRACKING_FILE="$AR_DIR/tracking.json"

# Source library components
source "$LIB_DIR/date_utils.sh"
source "$LIB_DIR/circuit_breaker.sh"
source "$LIB_DIR/response_analyzer.sh"
# agents.sh is sourced after log helpers are defined

# Defaults
MAX_ITERATIONS="${MAX_ITERATIONS:-3}"
VERBOSE="${VERBOSE:-0}"
DRY_RUN="${DRY_RUN:-0}"
APPLY="${APPLY:-0}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-10}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD_CYAN='\033[1;36m'
NC='\033[0m'

# Logging
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_claude()  { echo -e "${MAGENTA}[CLAUDE]${NC} $1"; }
log_codex()   { echo -e "${CYAN}[CODEX]${NC} $1"; }
log_grok()    { echo -e "${BOLD_CYAN}[GROK]${NC} $1"; }
log_verbose() { [[ "$VERBOSE" == "1" ]] && echo -e "${BLUE}[VERBOSE]${NC} $1" || true; }

source "$LIB_DIR/agents.sh"
source "$LIB_DIR/roles.sh"
source "$LIB_DIR/diff.sh"
source "$LIB_DIR/triage.sh"
source "$LIB_DIR/status.sh"
source "$LIB_DIR/hook.sh"

# Roles. Resolved after flag parse. Defaults: writer=claude, reviewer=Codex then Grok.
WRITER=""
REVIEWER=""

# Optional overrides for local triage. Empty means classify from the change.
EXPLICIT_KIND=""
EXPLICIT_DEPTH=""
FACTS_FILE=""
PHASE1_PROMPT=""
INSTALL_HOOK=0

# Explicit paths to review (--file / --files). Empty means review the diff.
REVIEW_PATHS=()
USE_PATHS=0

# Check shared dependencies. Writer/reviewer CLIs are checked in validate_roles.
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        log_error "Missing dependency: jq (brew install jq)"
        exit $EXIT_USAGE
    fi

    if ! command -v git &> /dev/null; then
        log_error "Missing dependency: git"
        exit $EXIT_USAGE
    fi
}

# Print the paths passed with --file / --files.
review_paths() {
    printf '%s\n' "${REVIEW_PATHS[@]+"${REVIEW_PATHS[@]}"}"
}

# Loud, distinct failure. An agent that says nothing did not pass the review.
report_agent_failure() {
    local agent="$1" phase="$2" file="$3" status="$4"
    log_error "=============================================="
    log_error "REVIEW FAILED: $agent produced no usable output"
    log_error "Phase: $phase"
    log_error "Reason: $(status_error "$status")"
    log_error "Artifact: $file"
    log_error "This is not a clean review. Do not read it as 0 issues."
    log_error "=============================================="
    update_tracking "status" "review_failed"
}

require_flag_arg() {
    local opt="$1"
    local what="$2"
    local val="${3:-}"
    if [[ -z "$val" || "$val" == -* ]]; then
        log_error "$opt requires $what"
        exit $EXIT_USAGE
    fi
}

require_agent_arg() {
    require_flag_arg "$1" "an agent name" "${2:-}"
}

resolve_roles() {
    WRITER="$(normalize_agent_name "${WRITER:-$DEFAULT_WRITER}")"
    if [[ -n "${REVIEWER:-}" ]]; then
        REVIEWER="$(normalize_agent_name "$REVIEWER")"
    else
        if ! REVIEWER="$(resolve_reviewer "$WRITER")"; then
            log_error "No eligible reviewer. Install Codex or Grok, or pass --reviewer. Writer is $WRITER (no self-review)."
            exit $EXIT_USAGE
        fi
    fi

    if ! validate_roles "$WRITER" "$REVIEWER"; then
        exit $EXIT_USAGE
    fi
}

# Print the phase-1 payload: explicit paths when given, else the git diff.
collect_phase1_input() {
    local target_dir="$1"
    if [[ "$USE_PATHS" -eq 1 ]]; then
        collect_paths_input "$target_dir" "${REVIEW_PATHS[@]}"
    else
        collect_review_input "$target_dir"
    fi
}

phase1_review_file() {
    echo "$ARTIFACTS_DIR/iter${1}_1_${REVIEWER}_review.md"
}

phase2_rebuttal_file() {
    echo "$ARTIFACTS_DIR/iter${1}_2_${WRITER}_on_${REVIEWER}.md"
}

phase3_meta_file() {
    echo "$ARTIFACTS_DIR/iter${1}_3_${REVIEWER}_meta.md"
}

phase4_synthesis_file() {
    echo "$ARTIFACTS_DIR/iter${1}_4_synthesis.md"
}

# Initialize tracking
init_tracking() {
    mkdir -p "$ARTIFACTS_DIR" "$LOGS_DIR"

    if [[ ! -f "$TRACKING_FILE" ]]; then
        cat > "$TRACKING_FILE" << EOF
{
    "iteration": 0,
    "status": "pending",
    "target_dir": null,
    "started_at": null,
    "updated_at": null,
    "phases": [],
    "history": []
}
EOF
    fi
}

# Update tracking JSON
update_tracking() {
    local field="$1"
    local value="$2"
    local timestamp
    timestamp=$(get_iso_timestamp)

    local tmp=$(mktemp)
    jq --arg f "$field" --arg v "$value" --arg ts "$timestamp" '
        .[$f] = (if $v | test("^-?[0-9]+$") then ($v | tonumber)
                 elif $v == "true" then true
                 elif $v == "false" then false
                 elif ($v | startswith("[") or startswith("{")) then ($v | fromjson)
                 else $v end) |
        .updated_at = $ts
    ' "$TRACKING_FILE" > "$tmp" && mv "$tmp" "$TRACKING_FILE"
}

# Add to history
add_to_history() {
    local iteration="$1"
    local phase="$2"
    local agent="$3"
    local result="$4"

    local tmp=$(mktemp)
    jq --arg i "$iteration" --arg p "$phase" --arg a "$agent" --arg r "$result" --arg ts "$(get_iso_timestamp)" '
        .history += [{
            "iteration": ($i | tonumber),
            "phase": $p,
            "agent": $a,
            "result": $r,
            "timestamp": $ts
        }]
    ' "$TRACKING_FILE" > "$tmp" && mv "$tmp" "$TRACKING_FILE"
}

# ============================================================================
# PHASE 1: Independent Reviews
# ============================================================================
run_phase_1() {
    local target_dir="$1"
    local iteration="$2"

    log_info "=== Phase 1: Reviewer ($REVIEWER) ==="

    local input_header="DIFF AND CHANGED FILES TO REVIEW"
    if [[ "$USE_PATHS" -eq 1 ]]; then
        log_verbose "Collecting named paths under $target_dir"
        input_header="FILES TO REVIEW"
    else
        log_verbose "Collecting git diff from $target_dir"
    fi
    local review_input
    if ! review_input=$(collect_phase1_input "$target_dir"); then
        return $EXIT_USAGE
    fi

    local prompt_file="$PROMPTS_DIR/initial_review.md"
    if [[ -n "$PHASE1_PROMPT" ]]; then
        prompt_file="$PHASE1_PROMPT"
    elif [[ "$TRIAGE_MODE" == "spec" ]]; then
        prompt_file="$PROMPTS_DIR/spec_review.md"
        log_info "Using spec review prompt"
    fi
    local prompt_template
    prompt_template=$(cat "$prompt_file")
    local depth_note facts_note
    depth_note=$(depth_guidance "$TRIAGE_DEPTH")
    facts_note=$(format_writer_facts)

    local full_prompt="$prompt_template

$depth_note

$facts_note

---
# $input_header

$review_input
"

    local reviewer_out agent_rc=0
    reviewer_out="$(phase1_review_file "$iteration")"

    run_agent "$REVIEWER" "$full_prompt" "$reviewer_out" "$target_dir" "review" || agent_rc=$?

    local reviewer_status reviewer_exit reviewer_issues reviewer_verdict
    reviewer_status=$(parse_status_block "$reviewer_out" "REVIEW_STATUS") || true
    [[ -n "$reviewer_status" ]] || reviewer_status='{"error": "no status block"}'

    add_to_history "$iteration" "phase_1" "$REVIEWER" "$reviewer_status"

    # No output, a truncated block, or no block at all is a failure, not a pass.
    if status_failed "$reviewer_status"; then
        [[ $agent_rc -ne 0 ]] && log_error "$REVIEWER exited with code $agent_rc" || true
        report_agent_failure "$REVIEWER" "phase 1" "$reviewer_out" "$reviewer_status"
        return $EXIT_AGENT_FAILURE
    fi
    if [[ $agent_rc -ne 0 ]]; then
        log_warning "$REVIEWER exited with code $agent_rc but returned a status block"
    fi

    reviewer_exit=$(echo "$reviewer_status" | jq -r '.exit_signal // false')
    reviewer_verdict=$(echo "$reviewer_status" | jq -r '.verdict // empty' | tr '[:upper:]' '[:lower:]')

    if [[ "$TRIAGE_MODE" == "spec" && -n "$reviewer_verdict" ]]; then
        if review_should_block spec "$reviewer_status"; then
            log_info "Spec verdict: $reviewer_verdict"
            return $EXIT_ISSUES
        fi
        log_success "Spec verdict: $reviewer_verdict"
        return $EXIT_OK
    fi

    if [[ "$reviewer_exit" == "true" ]]; then
        log_success "Reviewer reports NO_ISSUES"
        return $EXIT_OK
    fi

    reviewer_issues=$(echo "$reviewer_status" | jq -r '.issues_found // 0')
    log_info "$REVIEWER found: $reviewer_issues issues"

    return $EXIT_ISSUES
}

# ============================================================================
# PHASE 2: Cross-Review
# ============================================================================
run_phase_2() {
    local target_dir="$1"
    local iteration="$2"

    log_info "=== Phase 2: Writer rebuttal ($WRITER) ==="

    local reviewer_review cross_prompt writer_out writer_status
    reviewer_review="$(phase1_review_file "$iteration")"
    cross_prompt=$(cat "$PROMPTS_DIR/cross_review.md")

    local spec_note=""
    if [[ "$TRIAGE_MODE" == "spec" ]]; then
        spec_note="This was a spec review. Verdict language is ready / ready with nits / ready with issues / not ready. Nits do not block."
    fi

    local writer_prompt="$cross_prompt

You are the writer ($WRITER). Rebut the reviewer's ($REVIEWER) findings.
$spec_note

---
# THE REVIEWER'S FINDINGS TO ANALYZE

$(cat "$reviewer_review")
"

    writer_out="$(phase2_rebuttal_file "$iteration")"
    run_agent "$WRITER" "$writer_prompt" "$writer_out" "$target_dir" "review" || true

    writer_status=$(parse_status_block "$writer_out" "CROSS_REVIEW_STATUS") || true
    [[ -n "$writer_status" ]] || writer_status='{"error": "no status block"}'
    add_to_history "$iteration" "phase_2" "$WRITER" "$writer_status"

    if ! agent_output_ok "$writer_out"; then
        report_agent_failure "$WRITER" "phase 2" "$writer_out" "$writer_status"
        return $EXIT_AGENT_FAILURE
    fi

    log_success "Writer rebuttal complete"
}

# ============================================================================
# PHASE 3: Meta-Review
# ============================================================================
run_phase_3() {
    local target_dir="$1"
    local iteration="$2"

    log_info "=== Phase 3: Reviewer response ($REVIEWER) ==="

    local writer_rebuttal meta_prompt reviewer_out reviewer_status
    writer_rebuttal="$(phase2_rebuttal_file "$iteration")"
    meta_prompt=$(cat "$PROMPTS_DIR/meta_review.md")

    local reviewer_prompt="$meta_prompt

You are the reviewer ($REVIEWER). The writer ($WRITER) rebutted your findings.

---
# FEEDBACK ON YOUR ORIGINAL REVIEW

$(cat "$writer_rebuttal")
"

    reviewer_out="$(phase3_meta_file "$iteration")"
    run_agent "$REVIEWER" "$reviewer_prompt" "$reviewer_out" "$target_dir" "review" || true

    reviewer_status=$(parse_status_block "$reviewer_out" "META_REVIEW_STATUS") || true
    [[ -n "$reviewer_status" ]] || reviewer_status='{"error": "no status block"}'
    add_to_history "$iteration" "phase_3" "$REVIEWER" "$reviewer_status"

    if ! agent_output_ok "$reviewer_out"; then
        report_agent_failure "$REVIEWER" "phase 3" "$reviewer_out" "$reviewer_status"
        return $EXIT_AGENT_FAILURE
    fi

    log_success "Reviewer response complete"
}

# ============================================================================
# PHASE 4: Synthesis & Implementation
# ============================================================================
run_phase_4() {
    local target_dir="$1"
    local iteration="$2"

    log_info "=== Phase 4: Synthesis ($WRITER) ==="

    local synthesis_prompt=$(cat "$PROMPTS_DIR/synthesis.md")

    local context="$synthesis_prompt

---
# ADVERSARIAL REVIEW CHAIN

## Phase 1: Reviewer ($REVIEWER)

$(cat "$(phase1_review_file "$iteration")")

## Phase 2: Writer rebuttal ($WRITER)

$(cat "$(phase2_rebuttal_file "$iteration")")

## Phase 3: Reviewer response ($REVIEWER)

$(cat "$(phase3_meta_file "$iteration")")

---
Working directory: $target_dir
"

    local output_file
    output_file="$(phase4_synthesis_file "$iteration")"

    run_agent "$WRITER" "$context" "$output_file" "$target_dir" "$(resolve_agent_mode)" || true

    local status
    status=$(parse_status_block "$output_file" "SYNTHESIS_STATUS") || true
    [[ -n "$status" ]] || status='{"error": "no status block"}'

    add_to_history "$iteration" "phase_4" "$WRITER" "$status"

    if ! agent_output_ok "$output_file"; then
        report_agent_failure "$WRITER" "phase 4" "$output_file" "$status"
        return $EXIT_AGENT_FAILURE
    fi

    local exit_signal=$(echo "$status" | jq -r '.exit_signal // false')
    local files_modified=$(echo "$status" | jq -r '.files_modified // 0')

    # Record for circuit breaker
    local agents_agree=0
    local reviewer_meta=$(parse_status_block "$(phase3_meta_file "$iteration")" "META_REVIEW_STATUS" 2>/dev/null || echo '{}')
    local consensus=$(echo "$reviewer_meta" | jq -r '.consensus_reached // "NO"')
    [[ "$consensus" == "YES" || "$consensus" == "true" ]] && agents_agree=1

    local issues_hash=$(cat "$(phase1_review_file "$iteration")" "$(phase2_rebuttal_file "$iteration")" | shasum -a 256 | cut -d' ' -f1)

    record_iteration_result "$iteration" "$files_modified" "$agents_agree" "$issues_hash"

    if [[ "$exit_signal" == "true" ]]; then
        log_success "Synthesis complete - no more issues"
        return 0
    fi

    log_info "Fixes applied, will verify in next iteration"
    return 1
}

# ============================================================================
# Main Review Loop
# ============================================================================
run_review_loop() {
    local target_dir="$1"
    target_dir="$(cd "$target_dir" && pwd)"

    log_info "Starting Adversarial Review Loop"
    log_info "Target: $target_dir"
    log_info "Writer: $WRITER"
    log_info "Reviewer: $REVIEWER"
    if [[ "$USE_PATHS" -eq 1 ]]; then
        log_info "Input: named paths"
        review_paths | while read -r p; do
            log_info "  $p"
        done
    else
        log_info "Input: uncommitted git diff"
    fi
    log_info "Kind: $TRIAGE_KIND"
    log_info "Depth: $TRIAGE_DEPTH"
    log_verbose "Triage reason: $TRIAGE_REASON"
    log_info "Max iterations: $MAX_ITERATIONS"
    log_info "Timeout: ${TIMEOUT_MINUTES}m per agent"
    if [[ "$(resolve_agent_mode)" == "apply" ]]; then
        log_info "Apply: yes"
    else
        log_info "Apply: no (pass --apply to implement fixes)"
    fi
    log_info "Agents:"
    print_agent_status | while read -r line; do
        log_info "  $line"
    done
    echo ""

    log_verbose "Initializing tracking..."
    init_tracking
    log_verbose "Initializing circuit breaker..."
    init_circuit_breaker

    log_verbose "Updating tracking state..."
    update_tracking "target_dir" "$target_dir"
    update_tracking "status" "in_progress"
    update_tracking "started_at" "$(get_iso_timestamp)"

    local iteration=0
    log_verbose "Starting main loop (MAX_ITERATIONS=$MAX_ITERATIONS)..."

    while [[ $iteration -lt $MAX_ITERATIONS ]]; do
        ((iteration++)) || true
        log_info "=== Entering iteration $iteration ==="
        update_tracking "iteration" "$iteration"

        # Check circuit breaker
        if ! can_execute; then
            log_error "Circuit breaker is OPEN - halting"
            show_circuit_status
            update_tracking "status" "circuit_open"
            return $EXIT_CIRCUIT_OPEN
        fi

        echo ""
        log_info "=========================================="
        log_info "ITERATION $iteration / $MAX_ITERATIONS"
        log_info "=========================================="
        echo ""

        # Phase 1. An agent failure stops the run with its own exit code.
        local phase_rc=0
        run_phase_1 "$target_dir" "$iteration" || phase_rc=$?
        if [[ $phase_rc -eq $EXIT_OK ]]; then
            log_success "Review complete"
            update_tracking "status" "clean"
            return $EXIT_OK
        fi
        if [[ $phase_rc -ne $EXIT_ISSUES ]]; then
            return $phase_rc
        fi
        echo ""

        if [[ "$TRIAGE_DEPTH" == "quick" ]]; then
            log_info "Depth is quick; skipping debate"
            update_tracking "status" "issues"
            return $EXIT_ISSUES
        fi

        # Phase 2
        phase_rc=0
        run_phase_2 "$target_dir" "$iteration" || phase_rc=$?
        [[ $phase_rc -eq 0 ]] || return $phase_rc
        echo ""

        # Phase 3
        phase_rc=0
        run_phase_3 "$target_dir" "$iteration" || phase_rc=$?
        [[ $phase_rc -eq 0 ]] || return $phase_rc
        echo ""

        # Phase 4 implements fixes. Standalone --apply only. Hook never applies.
        if [[ "$(resolve_agent_mode)" != "apply" ]]; then
            log_info "Review complete. Pass --apply to implement fixes."
            update_tracking "status" "issues"
            return $EXIT_ISSUES
        fi

        # Phase 4
        phase_rc=0
        run_phase_4 "$target_dir" "$iteration" || phase_rc=$?
        if [[ $phase_rc -eq $EXIT_OK ]]; then
            log_success "Synthesis complete"
            update_tracking "status" "clean"
            return $EXIT_OK
        fi
        if [[ $phase_rc -eq $EXIT_AGENT_FAILURE ]]; then
            return $EXIT_AGENT_FAILURE
        fi
        echo ""

        log_info "Iteration $iteration complete, will verify fixes..."
        sleep 2
    done

    log_warning "Reached max iterations ($MAX_ITERATIONS)"
    update_tracking "status" "max_iterations"
    return $EXIT_ISSUES
}

# ============================================================================
# Status & Management Commands
# ============================================================================
show_status() {
    echo ""
    log_info "=== Adversarial Review Status ==="
    echo ""

    if [[ ! -f "$TRACKING_FILE" ]]; then
        echo "No tracking file found. Run a review first."
        return
    fi

    jq -r '
        "Target:     \(.target_dir // "none")",
        "Status:     \(.status // "unknown")",
        "Iteration:  \(.iteration // 0)",
        "Started:    \(.started_at // "never")",
        "Updated:    \(.updated_at // "never")",
        "",
        "Recent History:"
    ' "$TRACKING_FILE"

    jq -r '.history | if length == 0 then "  (none)" else .[-10:] | .[] | "  - Iter \(.iteration) \(.phase) [\(.agent)]: \(.result | if type == "object" then .summary // "ok" else . end)"  end' "$TRACKING_FILE" 2>/dev/null || echo "  (none)"

    echo ""
    echo "Artifacts:"
    if [[ -d "$ARTIFACTS_DIR" ]] && [[ -n "$(ls -A "$ARTIFACTS_DIR" 2>/dev/null)" ]]; then
        ls -1 "$ARTIFACTS_DIR" | head -20 | while read -r f; do
            echo "  $f"
        done
    else
        echo "  (none)"
    fi
}

reset_all() {
    log_info "Resetting all state..."
    rm -rf "$ARTIFACTS_DIR"/* "$TRACKING_FILE"
    rm -f "$AR_DIR/.circuit_breaker.json" "$AR_DIR/.circuit_breaker_history.json"
    rm -f "$AR_DIR/.response_analysis.json"
    mkdir -p "$ARTIFACTS_DIR" "$LOGS_DIR"
    init_tracking
    init_circuit_breaker
    log_success "Reset complete"
}

show_help() {
    cat << 'EOF'
Adversarial Review: writer + reviewer loop

USAGE:
    ./adversarial_review.sh [OPTIONS] <target_directory>

OPTIONS:
    -h, --help              Show this help
    -m, --max-iters N       Max iterations (default: 3)
    -p, --prompt FILE       Custom initial review prompt
    -v, --verbose           Verbose output
    -t, --timeout MIN       Timeout per agent in minutes (default: 10)
    --writer NAME           Agent that wrote the change (default: claude)
    --reviewer NAME         Agent that reviews (default: Codex, then Grok)
    --kind NAME             editorial, operational, decisional, spec, or code
    --depth NAME            skip, quick, standard, or deep
    --facts FILE            Writer facts card (default: .adversarial-review/writer-facts.yml)
    --file PATH             Review this file or directory (repeatable)
    --files PATH...         Review these files or directories
    --no-timeout            Run agents uncapped when no timeout command exists
    --install-hook          Install the Stop hook into the target repo
    --apply                 Standalone only. Writer implements agreed fixes
    --status                Show current status
    --reset                 Reset all state
    --reset-circuit         Reset circuit breaker only
    --circuit-status        Show circuit breaker status
    --dry-run               Show what would happen without executing
    --list-agents           Show which agent CLIs are installed

INPUT:
    Default: the uncommitted git diff of the target, plus the changed files.
    --file / --files: review the named paths instead. Directories expand to
    their files. Git is not required. File bodies stop at a 10000 line budget.
    --files takes every path up to the next flag, so pass the target directory
    first, or leave it out and it defaults to the current directory.

EXIT CODES:
    0   clean review, or nothing to review
    1   issues found, or max iterations reached with issues open
    2   usage or dependency error (bad flag, no jq, no timeout command)
    3   agent failure: no output, a truncated reply, or no status block
    4   circuit breaker is open

PHASES:
    1. Review               Reviewer inspects the uncommitted git diff
    2. Writer rebuttal      Writer answers the reviewer's findings
    3. Reviewer response    Reviewer answers the rebuttal
    4. Synthesis            Writer implements agreed fixes (--apply only)

STANDALONE VS HOOK:
    Standalone: you run this script on a repo.
      Default: review and debate. Does not edit the target.
      --apply: writer implements agreed fixes (phase 4).
    Hook: fires on Stop in Claude, Grok, or Codex.
      Always review only. Never applies. --apply is rejected.
      Blocks Stop on CRITICAL/HIGH or decision issues.

TRIAGE:
    Classified locally from paths, hunks, and decision language.
    Kind:  editorial | operational | decisional | code
    Depth: skip (no review) | quick (phase 1 only) | standard | deep
    Decisional changes use the spec prompt and stay at standard or deep.
    Writer facts are yes/no claims. They may raise depth. They may not lower it.
    The reader returns counts, not a 1-10 score. Nits do not block.

STOP HOOK:
    --install-hook writes a Stop hook for Claude, Grok, and Codex.
    The hook reads writer facts, triages, calls the reader, and blocks
    Stop on CRITICAL/HIGH or decision issues. It does not edit the tree.
    State lives in the target at .adversarial-review/ (gitignored).

CIRCUIT BREAKER:
    Prevents runaway loops by detecting:
    - No progress after 3 iterations
    - Persistent disagreement (5+ iterations)
    - Same issues found 3+ times (unfixable)

REQUIREMENTS:
    - jq: brew install jq
    - git: the target must be a git work tree
    - Writer and reviewer CLIs must be installed (claude, codex, or grok)
    - Default writer: claude. Default reviewer: Codex, then Grok.
    - timeout or gtimeout: brew install coreutils (macOS). Required.
      Without it a hung agent never stops. --no-timeout runs uncapped.

EXAMPLES:
    ./adversarial_review.sh ../my-project
    ./adversarial_review.sh --writer claude --reviewer grok ../my-project
    ./adversarial_review.sh --kind spec --reviewer grok ../my-project
    ./adversarial_review.sh -m 5 -v ../my-project
    ./adversarial_review.sh --dry-run ../my-project
    ./adversarial_review.sh --apply ../my-project
    ./adversarial_review.sh ../my-project --files src/auth.py src/db/
    ./adversarial_review.sh --file src/auth.py --file docs/design.md
    ./adversarial_review.sh --install-hook ../my-project
    ./adversarial_review.sh --list-agents
    ./adversarial_review.sh --status

EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================
main() {
    local target_dir=""
    local custom_prompt=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -m|--max-iters)
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            -p|--prompt)
                custom_prompt="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -t|--timeout)
                TIMEOUT_MINUTES="$2"
                shift 2
                ;;
            --status)
                show_status
                exit 0
                ;;
            --reset)
                reset_all
                exit 0
                ;;
            --reset-circuit)
                init_circuit_breaker
                reset_circuit_breaker "Manual reset"
                exit 0
                ;;
            --circuit-status)
                init_circuit_breaker
                show_circuit_status
                exit 0
                ;;
            --writer)
                require_agent_arg "$1" "${2:-}"
                WRITER="$2"
                shift 2
                ;;
            --reviewer)
                require_agent_arg "$1" "${2:-}"
                REVIEWER="$2"
                shift 2
                ;;
            --kind)
                require_flag_arg "$1" "a kind" "${2:-}"
                EXPLICIT_KIND=$(normalize_kind "$2")
                if [[ -z "$EXPLICIT_KIND" ]]; then
                    log_error "Unknown kind: $2 (known: editorial, operational, decisional, spec, code)"
                    exit 1
                fi
                shift 2
                ;;
            --depth)
                require_flag_arg "$1" "a depth" "${2:-}"
                EXPLICIT_DEPTH=$(normalize_depth "$2")
                if [[ -z "$EXPLICIT_DEPTH" ]]; then
                    log_error "Unknown depth: $2 (known: skip, quick, standard, deep)"
                    exit 1
                fi
                shift 2
                ;;
            --facts)
                require_flag_arg "$1" "a facts file" "${2:-}"
                FACTS_FILE="$2"
                shift 2
                ;;
            --file)
                require_flag_arg "$1" "a path" "${2:-}"
                REVIEW_PATHS+=("$2")
                USE_PATHS=1
                shift 2
                ;;
            --files)
                require_flag_arg "$1" "at least one path" "${2:-}"
                shift
                while [[ $# -gt 0 && "$1" != -* ]]; do
                    REVIEW_PATHS+=("$1")
                    USE_PATHS=1
                    shift
                done
                ;;
            --no-timeout)
                AR_NO_TIMEOUT=1
                shift
                ;;
            --install-hook)
                INSTALL_HOOK=1
                shift
                ;;
            --apply)
                APPLY=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --list-agents)
                print_agent_status
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit $EXIT_USAGE
                ;;
            *)
                target_dir="$1"
                shift
                ;;
        esac
    done

    # --files takes every path up to the next flag. Pass the target directory
    # before it, or leave it out: named paths default the target to $PWD.
    if [[ -z "$target_dir" && "$USE_PATHS" -eq 1 ]]; then
        target_dir="$PWD"
    fi

    if [[ -z "$target_dir" ]]; then
        log_error "No target directory specified"
        echo ""
        show_help
        exit $EXIT_USAGE
    fi

    if [[ ! -d "$target_dir" ]]; then
        log_error "Directory does not exist: $target_dir"
        exit $EXIT_USAGE
    fi

    check_dependencies

    if [[ "$INSTALL_HOOK" -eq 1 && "${APPLY:-0}" == "1" ]]; then
        log_error "--apply is standalone only. The hook never applies."
        exit $EXIT_USAGE
    fi

    if [[ "$INSTALL_HOOK" -eq 1 ]]; then
        install_stop_hook "$target_dir"
        exit $?
    fi

    # Named paths do not need git. The default input is the uncommitted diff.
    if [[ "$USE_PATHS" -eq 1 ]]; then
        local p
        for p in "${REVIEW_PATHS[@]}"; do
            if [[ ! -e "$p" ]]; then
                log_error "Path does not exist: $p"
                exit $EXIT_USAGE
            fi
        done
        if ! triage_paths "$target_dir" "$EXPLICIT_KIND" "$EXPLICIT_DEPTH" "$FACTS_FILE" \
            "${REVIEW_PATHS[@]}" >/dev/null; then
            log_error "Could not read the paths to review"
            exit $EXIT_USAGE
        fi
    else
        if ! is_git_work_tree "$target_dir"; then
            log_error "Target is not a git repository: $target_dir"
            exit $EXIT_USAGE
        fi

        if ! triage_change "$target_dir" "$EXPLICIT_KIND" "$EXPLICIT_DEPTH" "$FACTS_FILE" >/dev/null; then
            log_error "Could not classify the change in $target_dir"
            exit $EXIT_USAGE
        fi
    fi
    log_info "Triage: $TRIAGE_KIND / $TRIAGE_DEPTH"
    log_verbose "Triage reason: $TRIAGE_REASON"

    if [[ "$TRIAGE_DEPTH" == "skip" ]]; then
        log_success "Depth is skip — no review"
        init_tracking
        update_tracking "target_dir" "$(cd "$target_dir" && pwd)"
        update_tracking "status" "skipped"
        exit $EXIT_OK
    fi

    resolve_roles

    # Fail closed before any agent starts. Without a timeout a hung agent
    # runs forever. --no-timeout is the opt-out.
    if ! require_timeout_cmd; then
        exit $EXIT_USAGE
    fi

    if [[ -n "$custom_prompt" ]] && [[ -f "$custom_prompt" ]]; then
        PHASE1_PROMPT="$custom_prompt"
        log_info "Using custom prompt: $custom_prompt"
    fi

    local rc=0
    run_review_loop "$target_dir" || rc=$?
    exit $rc
}

main "$@"
