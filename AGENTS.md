# AGENTS.md

Shared instructions for Grok, Claude Code, Codex, and other agents in this repo.

Remaining work and locked policy: **[docs/handoff.md](docs/handoff.md)**. Start a new session from that file.

## What this is

Multi-agent code review. A reviewer inspects the change. The writer rebuts. The reviewer answers. The writer synthesizes. The destination is a writer + reviewer stop hook. See the handoff.

Based on [asimov-ralph](https://github.com/frankbria/ralph-claude-code).

## Run

```bash
./adversarial_review.sh ../some-project
./adversarial_review.sh --writer claude --reviewer grok ../project
./adversarial_review.sh --dry-run ../project
./adversarial_review.sh --list-agents
./adversarial_review.sh --status
./adversarial_review.sh --reset
```

Options: `-m` max iterations, `-v` verbose, `-t` timeout minutes, `--writer`, `--reviewer`.

## Dependencies

- **jq**: `brew install jq`
- **coreutils** (macOS): `brew install coreutils` (for `gtimeout`)
- Writer and reviewer CLIs: `claude`, `codex`, or `grok`. Default writer is Claude. Default reviewer is Codex, then Grok.

## Layout

```
adversarial_review.sh    # 4-phase loop
lib/agents.sh            # KNOWN_AGENTS + run_<name> adapters
lib/roles.sh             # --writer / --reviewer resolution
lib/circuit_breaker.sh
lib/response_analyzer.sh
lib/date_utils.sh
prompts/                 # initial_review, cross_review, meta_review, synthesis
docs/handoff.md          # remaining slices and locked policy
```

Do not add a third peer reviewer. The writer does not review its own work.

## Architecture

1. **Review** — reviewer only
2. **Writer rebuttal** — writer answers the findings
3. **Reviewer response** — reviewer answers the rebuttal
4. **Synthesis** — writer implements fixes

Status blocks in agent output are parsed (`---REVIEW_STATUS---` …).

Artifacts: `iter{N}_{phase}_{agent}_{type}.md` under `artifacts/`.

## Adding an agent

1. Append the name to `KNOWN_AGENTS` in `lib/agents.sh`
2. Add `run_<name>()` in the same file (each CLI has its own flags)
3. Optional: append the name to `DEFAULT_REVIEWER_ORDER` if it may be the default reviewer

## Bash notes

- `((iteration++)) || true` — increment from 0 returns 1 under `set -e`
- No GNU `head -z` on macOS
- Background agent jobs must not block on stdin

## Citation rule

Cite a source only when the choice changes agent policy (who reviews, how deep, what may block). Not for CLI flags or file layout. One claim, one link.

## Related

- [asimov-ralph](https://github.com/frankbria/ralph-claude-code)
- [D3 Framework](https://arxiv.org/abs/2410.04663)
- [ChatEval](https://github.com/thunlp/ChatEval)
