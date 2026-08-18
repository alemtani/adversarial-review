# Adversarial Review

Multi-agent code review. A reviewer inspects the change. The writer rebuts. Then the writer implements agreed fixes.

Based on patterns from [asimov-ralph](https://github.com/frankbria/ralph-claude-code) and research on [AI Debate](https://arxiv.org/abs/2410.04663).

## Concept

A reviewer that is not the writer inspects the code. The writer then answers the findings. This split helps:

- **Find more issues**: Different models catch different problems
- **Eliminate false positives**: Cross-validation filters out incorrect findings
- **Build consensus**: Disagreements are resolved through structured debate
- **Improve confidence**: Issues both agents agree on are high-confidence fixes

## The 4-Phase Loop

```
┌─────────────────────────────────────────────────────────────┐
│  Phase 1: Review                                            │
│    Reviewer inspects the code                               │
├─────────────────────────────────────────────────────────────┤
│  Phase 2: Writer rebuttal                                   │
│    Writer answers the reviewer's findings                   │
├─────────────────────────────────────────────────────────────┤
│  Phase 3: Reviewer response                                 │
│    Reviewer answers the rebuttal                            │
├─────────────────────────────────────────────────────────────┤
│  Phase 4: Synthesis                                         │
│    Writer implements high-confidence fixes                  │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
              Loop back to Phase 1 to verify fixes
              until the reviewer reports NO_ISSUES
```

## Quick Start

```bash
# Clone or copy to your workspace
cd adversarial-review

# Run on a target project (reviews the uncommitted git diff)
./adversarial_review.sh ../my-project

# Pick writer and reviewer (no self-review)
./adversarial_review.sh --writer claude --reviewer grok ../my-project

# Force a spec review
./adversarial_review.sh --kind spec --reviewer grok ../my-project

# With options
./adversarial_review.sh -m 5 -v ../my-project  # 5 iterations, verbose

# Dry run (see what would happen)
./adversarial_review.sh --dry-run ../my-project

# See which agent CLIs are installed
./adversarial_review.sh --list-agents
```

## Requirements

- **jq**: `brew install jq` (macOS) or `apt install jq` (Linux)
- **coreutils** (macOS only, for timeout): `brew install coreutils`
- Writer and reviewer CLIs: `claude`, `codex`, or `grok`
- Default writer: Claude. Default reviewer: Codex, then Grok. The writer cannot review itself.

## Usage

```bash
./adversarial_review.sh [OPTIONS] <target_directory>

OPTIONS:
    -h, --help              Show help
    -m, --max-iters N       Max iterations (default: 3)
    -p, --prompt FILE       Custom initial review prompt
    -v, --verbose           Verbose output
    -t, --timeout MIN       Timeout per agent in minutes (default: 10)
    --writer NAME           Agent that wrote the change (default: claude)
    --reviewer NAME         Agent that reviews (default: Codex, then Grok)
    --kind NAME             editorial, operational, decisional, spec, or code
    --depth NAME            skip, quick, standard, or deep
    --facts FILE            Writer facts card (yes/no claims)
    --status                Show current status
    --reset                 Reset all state
    --reset-circuit         Reset circuit breaker only
    --circuit-status        Show circuit breaker status
    --dry-run               Show what would happen without executing
    --list-agents           Show which agent CLIs are installed
```

## Project Structure

```
adversarial-review/
├── adversarial_review.sh    # Main script
├── lib/
│   ├── agents.sh            # Claude / Codex / Grok CLI adapters
│   ├── roles.sh             # Writer / reviewer resolution
│   ├── diff.sh              # Git diff + changed files
│   ├── triage.sh            # Kind and depth classification
│   ├── facts.sh             # Writer facts and reader block counts
│   ├── date_utils.sh        # Cross-platform date utilities
│   ├── circuit_breaker.sh   # Prevents runaway loops
│   └── response_analyzer.sh # Parses agent outputs
├── prompts/
│   ├── initial_review.md    # Phase 1: Code review prompt
│   ├── spec_review.md       # Phase 1: Spec / ADR / RFC prompt
│   ├── cross_review.md      # Phase 2: Cross-review prompt
│   ├── meta_review.md       # Phase 3: Meta-review prompt
│   └── synthesis.md         # Phase 4: Synthesis prompt
├── artifacts/               # Agent outputs per iteration
├── logs/                    # Execution logs
└── tracking.json            # State tracking
```

## Circuit Breaker

Prevents runaway loops by detecting:

- **No progress**: 3 iterations with no fixes made
- **Persistent disagreement**: 5+ iterations where agents can't agree
- **Same issues**: 3+ iterations finding the same unfixable issues

```bash
# Check circuit breaker status
./adversarial_review.sh --circuit-status

# Reset if stuck
./adversarial_review.sh --reset-circuit
```

## Customization

### Custom Review Prompts

```bash
# Use your own review criteria
./adversarial_review.sh -p my_review_prompt.md ../project
```

### Environment Variables

```bash
MAX_ITERATIONS=5      # Override max iterations
TIMEOUT_MINUTES=15    # Timeout per agent call
VERBOSE=1             # Enable verbose output
DRY_RUN=1            # Show what would happen
```

## How It Works

Phase 1 reviews the uncommitted git diff and the changed files in the target repo. It does not dump the whole tree. The whole diff is always included. Whole file bodies are included until a 10000 line budget. The target must be a git work tree.

The change is classified locally (no model call) as editorial, operational, decisional, or code, and as skip, quick, standard, or deep. Specs use `prompts/spec_review.md` and verdict language `ready` / `ready with nits` / `ready with issues` / `not ready`. Depth `skip` does not review. Depth `quick` runs Phase 1 only.

The writer may leave a yes/no card at `.adversarial-review/writer-facts.yml`. Those facts can raise depth. They cannot lower it. The reader returns counts, not a 1-10 score. Nits do not block.

### Agent Status Blocks

Each agent outputs a structured status block that gets parsed:

```
---REVIEW_STATUS---
ISSUES_FOUND: 3
CRITICAL_COUNT: 1
HIGH_COUNT: 1
MEDIUM_COUNT: 1
LOW_COUNT: 0
CONFIDENCE: HIGH
EXIT_SIGNAL: false
SUMMARY: Found critical type mixing bug
---END_REVIEW_STATUS---
```

### Exit Conditions

The loop exits when:
1. **The reviewer reports NO_ISSUES** in Phase 1
2. **Synthesis completes** with EXIT_SIGNAL: true
3. **Max iterations reached**
4. **Circuit breaker opens** (stagnation detected)

### Artifacts

Each iteration produces:
- `iter{N}_1_{reviewer}_review.md` - Reviewer's findings
- `iter{N}_2_{writer}_on_{reviewer}.md` - Writer rebuttal
- `iter{N}_3_{reviewer}_meta.md` - Reviewer response
- `iter{N}_4_synthesis.md` - Synthesis and fixes

## Research Background

This approach is based on:

- [D3: Debate, Deliberate, Decide](https://arxiv.org/abs/2410.04663) - Adversarial multi-agent evaluation framework
- [ChatEval](https://github.com/thunlp/ChatEval) - Multi-agent debate for LLM evaluation
- [AI Debate Research](https://arxiv.org/html/2410.04663v1) - Shows debating LLMs produce more accurate results

Key findings from research:
- Multi-agent debate reduces hallucinations and false positives
- 3-7 agents offer the best accuracy-to-cost ratio
- Adversarial validation improves consensus quality

## Cost Considerations

Each iteration makes 4 API calls:
- Phase 1: 1 call (reviewer)
- Phase 2: 1 call (writer)
- Phase 3: 1 call (reviewer)
- Phase 4: 1 call (writer)

With 3 iterations max, worst case is 12 API calls per review.

## Contributing

This is an experimental prototype. Ideas for improvement:
- Add support for other models (Gemini, local LLMs)
- Implement weighted voting based on historical accuracy
- Add cost tracking and budgets
- Build a web UI for reviewing artifacts

## License

MIT
