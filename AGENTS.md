# AGENTS.md

Shared instructions for Grok, Claude Code, Codex, and other agents in this repo.

Remaining work and locked policy: **[docs/handoff.md](docs/handoff.md)**. Start a new session from that file.

## What this is

Multi-agent code review. Today Claude and Codex review independently, cross-review, meta-review, then Claude synthesizes. The destination is a writer + reviewer stop hook. See the handoff.

Based on [asimov-ralph](https://github.com/frankbria/ralph-claude-code).

## Run

```bash
./adversarial_review.sh ../some-project
./adversarial_review.sh --dry-run ../project
./adversarial_review.sh --list-agents
./adversarial_review.sh --status
./adversarial_review.sh --reset
```

Options: `-m` max iterations, `-v` verbose, `-t` timeout minutes.

## Dependencies

- **claude CLI**: `npm install -g @anthropic-ai/claude-code` (required for the current loop)
- **codex CLI**: `npm install -g @openai/codex` (required for the current loop)
- **jq**: `brew install jq`
- **coreutils** (macOS): `brew install coreutils` (for `gtimeout`)
- **grok CLI**: optional until a reviewer role selects it

## Layout

```
adversarial_review.sh    # 4-phase loop
lib/agents.sh            # run_claude / run_codex / run_grok / run_agent
lib/circuit_breaker.sh
lib/response_analyzer.sh
lib/date_utils.sh
prompts/                 # initial_review, cross_review, meta_review, synthesis
docs/handoff.md          # remaining slices and locked policy
```

The loop still calls Claude and Codex only. Do not add a third peer reviewer.

## Architecture

1. **Independent reviews** — Claude and Codex in parallel
2. **Cross-review** — each reviews the other's findings
3. **Meta-review** — each answers feedback
4. **Synthesis** — Claude implements fixes (`--dangerously-skip-permissions`)

Status blocks in agent output are parsed (`---REVIEW_STATUS---` …).

Artifacts: `iter{N}_{phase}_{agent}_{type}.md` under `artifacts/`.

## Adding an agent

1. Add `run_<name>()` in `lib/agents.sh`
2. Register it in `KNOWN_AGENTS`, `agent_cli`, and `run_agent`
3. Do not wire it into the 4-phase loop until writer/reviewer roles exist

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
