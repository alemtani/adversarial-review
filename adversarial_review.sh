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
#   --dry-run               Show what would be done without executing
#   --list-agents           Show which agent CLIs are installed

set -euo pipefail

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

# Roles. Resolved after flag parse. Defaults: writer=claude, reviewer=Codex then Grok.
WRITER=""
REVIEWER=""

# Check shared dependencies. Writer/reviewer CLIs are checked in validate_roles.
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        log_error "Missing dependency: jq (brew install jq)"
        exit 1
    fi

    if [[ -z "$(get_timeout_cmd)" ]]; then
        log_warning "No timeout command found. Install coreutils for timeout support."
    fi
}

require_agent_arg() {
    local opt="$1"
    local val="${2:-}"
    if [[ -z "$val" || "$val" == -* ]]; then
        log_error "$opt requires an agent name"
        exit 1
    fi
}

resolve_roles() {
    WRITER="$(normalize_agent_name "${WRITER:-$DEFAULT_WRITER}")"
    if [[ -n "${REVIEWER:-}" ]]; then
        REVIEWER="$(normalize_agent_name "$REVIEWER")"
    else
        if ! REVIEWER="$(resolve_reviewer "$WRITER")"; then
            log_error "No eligible reviewer. Install Codex or Grok, or pass --reviewer. Writer is $WRITER (no self-review)."
            exit 1
        fi
    fi

    if ! validate_roles "$WRITER" "$REVIEWER"; then
        exit 1
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

# Parse status block from agent output
# Format: ---REVIEW_STATUS--- ... ---END_REVIEW_STATUS---
parse_status_block() {
    local file="$1"
    local block_name="${2:-REVIEW_STATUS}"

    if [[ ! -f "$file" ]]; then
        echo '{"error": "file not found"}'
        return 1
    fi

    # Extract the status block
    local content=$(cat "$file")
    local block=$(echo "$content" | sed -n "/---${block_name}---/,/---END_${block_name}---/p" | grep -v "^---")

    if [[ -z "$block" ]]; then
        # No status block found, try to detect NO_ISSUES
        if echo "$content" | grep -qE '^\s*NO_ISSUES\s*$'; then
            echo '{"exit_signal": true, "issues_found": 0}'
            return 0
        fi
        echo '{"error": "no status block"}'
        return 1
    fi

    # Parse key: value pairs into JSON
    local json="{"
    local first=true
    while IFS=: read -r key value; do
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [[ "$first" == "true" ]] && first=false || json+=","

        # Determine type
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

# Collect source code from target directory
collect_source_code() {
    local target_dir="$1"
    local max_files="${2:-30}"
    local max_lines="${3:-500}"
    local output=""
    local count=0

    log_verbose "Collecting source code from $target_dir"

    # Python files
    count=0
    while IFS= read -r file && [[ $count -lt $max_files ]]; do
        [[ -z "$file" ]] && continue
        local rel="${file#$target_dir/}"
        output+="
=== FILE: $rel ===
$(head -$max_lines "$file" 2>/dev/null)
"
        ((count++))
    done < <(find "$target_dir" -name "*.py" -type f ! -path "*/\.*" ! -path "*/__pycache__/*" ! -path "*/venv/*" ! -path "*/.venv/*" 2>/dev/null | sort)

    # TypeScript/JavaScript
    count=0
    while IFS= read -r file && [[ $count -lt $max_files ]]; do
        [[ -z "$file" ]] && continue
        local rel="${file#$target_dir/}"
        output+="
=== FILE: $rel ===
$(head -$max_lines "$file" 2>/dev/null)
"
        ((count++))
    done < <(find "$target_dir" \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \) -type f ! -path "*/node_modules/*" ! -path "*/\.*" 2>/dev/null | sort)

    # Shell scripts
    count=0
    while IFS= read -r file && [[ $count -lt 10 ]]; do
        [[ -z "$file" ]] && continue
        local rel="${file#$target_dir/}"
        output+="
=== FILE: $rel ===
$(head -300 "$file" 2>/dev/null)
"
        ((count++))
    done < <(find "$target_dir" -name "*.sh" -type f ! -path "*/\.*" 2>/dev/null | sort)

    echo "$output"
}

# ============================================================================
# PHASE 1: Independent Reviews
# ============================================================================
run_phase_1() {
    local target_dir="$1"
    local iteration="$2"

    log_info "=== Phase 1: Reviewer ($REVIEWER) ==="

    local source_code=$(collect_source_code "$target_dir")
    local prompt_template=$(cat "$PROMPTS_DIR/initial_review.md")

    local full_prompt="$prompt_template

---
# SOURCE CODE TO REVIEW

$source_code
"

    local reviewer_out
    reviewer_out="$(phase1_review_file "$iteration")"

    run_agent "$REVIEWER" "$full_prompt" "$reviewer_out" "$target_dir" "review"

    local reviewer_status reviewer_exit reviewer_issues
    reviewer_status=$(parse_status_block "$reviewer_out" "REVIEW_STATUS")
    reviewer_exit=$(echo "$reviewer_status" | jq -r '.exit_signal // false')

    add_to_history "$iteration" "phase_1" "$REVIEWER" "$reviewer_status"

    if [[ "$reviewer_exit" == "true" ]]; then
        log_success "Reviewer reports NO_ISSUES"
        return 0
    fi

    reviewer_issues=$(echo "$reviewer_status" | jq -r '.issues_found // 0')
    log_info "$REVIEWER found: $reviewer_issues issues"

    return 1
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

    local writer_prompt="$cross_prompt

You are the writer ($WRITER). Rebut the reviewer's ($REVIEWER) findings.

---
# THE REVIEWER'S FINDINGS TO ANALYZE

$(cat "$reviewer_review")
"

    writer_out="$(phase2_rebuttal_file "$iteration")"
    run_agent "$WRITER" "$writer_prompt" "$writer_out" "$target_dir" "review"

    writer_status=$(parse_status_block "$writer_out" "CROSS_REVIEW_STATUS")
    add_to_history "$iteration" "phase_2" "$WRITER" "$writer_status"

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
    run_agent "$REVIEWER" "$reviewer_prompt" "$reviewer_out" "$target_dir" "review"

    reviewer_status=$(parse_status_block "$reviewer_out" "META_REVIEW_STATUS")
    add_to_history "$iteration" "phase_3" "$REVIEWER" "$reviewer_status"

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

    run_agent "$WRITER" "$context" "$output_file" "$target_dir" "apply"

    local status=$(parse_status_block "$output_file" "SYNTHESIS_STATUS")
    local exit_signal=$(echo "$status" | jq -r '.exit_signal // false')
    local files_modified=$(echo "$status" | jq -r '.files_modified // 0')

    add_to_history "$iteration" "phase_4" "$WRITER" "$status"

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
    log_info "Max iterations: $MAX_ITERATIONS"
    log_info "Timeout: ${TIMEOUT_MINUTES}m per agent"
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
            return 1
        fi

        echo ""
        log_info "=========================================="
        log_info "ITERATION $iteration / $MAX_ITERATIONS"
        log_info "=========================================="
        echo ""

        # Phase 1
        if run_phase_1 "$target_dir" "$iteration"; then
            log_success "Review complete - reviewer reports clean code"
            update_tracking "status" "clean"
            return 0
        fi
        echo ""

        # Phase 2
        run_phase_2 "$target_dir" "$iteration"
        echo ""

        # Phase 3
        run_phase_3 "$target_dir" "$iteration"
        echo ""

        # Phase 4
        if run_phase_4 "$target_dir" "$iteration"; then
            log_success "Synthesis complete"
            update_tracking "status" "clean"
            return 0
        fi
        echo ""

        log_info "Iteration $iteration complete, will verify fixes..."
        sleep 2
    done

    log_warning "Reached max iterations ($MAX_ITERATIONS)"
    update_tracking "status" "max_iterations"
    return 1
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
    --status                Show current status
    --reset                 Reset all state
    --reset-circuit         Reset circuit breaker only
    --circuit-status        Show circuit breaker status
    --dry-run               Show what would happen without executing
    --list-agents           Show which agent CLIs are installed

PHASES:
    1. Review               Reviewer inspects the code
    2. Writer rebuttal      Writer answers the reviewer's findings
    3. Reviewer response    Reviewer answers the rebuttal
    4. Synthesis            Writer implements agreed fixes

CIRCUIT BREAKER:
    Prevents runaway loops by detecting:
    - No progress after 3 iterations
    - Persistent disagreement (5+ iterations)
    - Same issues found 3+ times (unfixable)

REQUIREMENTS:
    - jq: brew install jq
    - Writer and reviewer CLIs must be installed (claude, codex, or grok)
    - Default writer: claude. Default reviewer: Codex, then Grok.
    - coreutils (macOS): brew install coreutils (for timeout)

EXAMPLES:
    ./adversarial_review.sh ../my-project
    ./adversarial_review.sh --writer claude --reviewer grok ../my-project
    ./adversarial_review.sh -m 5 -v ../my-project
    ./adversarial_review.sh --dry-run ../my-project
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
                exit 1
                ;;
            *)
                target_dir="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$target_dir" ]]; then
        log_error "No target directory specified"
        echo ""
        show_help
        exit 1
    fi

    if [[ ! -d "$target_dir" ]]; then
        log_error "Directory does not exist: $target_dir"
        exit 1
    fi

    check_dependencies
    resolve_roles

    if [[ -n "$custom_prompt" ]] && [[ -f "$custom_prompt" ]]; then
        cp "$custom_prompt" "$PROMPTS_DIR/initial_review.md"
        log_info "Using custom prompt: $custom_prompt"
    fi

    run_review_loop "$target_dir"
}

main "$@"
