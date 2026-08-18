# Handoff

Read this file in a **new** session. Do not resume the long planning thread.

## Goal

Turn this tool into a **writer + reviewer** stop hook.

- Writer = the model that just produced the change
- Reviewer = a different model
- Review **this turn’s diff**, not the whole tree
- Full four-phase debate is rare

Today the loop is still two outsider reviewers (Claude + Codex) on a source dump. That is the old product. Do not grow that loop. Replace it slice by slice.

## Status

- Slice 1 is on `main`: `lib/agents.sh` (`run_claude`, `run_codex`, `run_grok`, `run_agent`)
- Loop still calls Claude + Codex only
- Grok is optional and not required to run

Next: slice 2, branched from `main`.

## Locked policy

- **No self-review.** The writer does not review its own work.
- **Default code reviewer:** Codex. If Codex is missing, use Grok.
- **Specs:** may set reviewer to Grok (`--reviewer grok` or later `AR_SPEC_REVIEWER=grok`).
- **Hook mode never edits the tree.** Findings go back to the writer (`decision: block`).
- **`--apply` is opt-in** and standalone only.
- **Stop hook:** main-agent `Stop` only. Ignore subagent stops. Ignore session-end Stop (`reason != end_turn`). Check `stopHookActive` so the same finding hash does not loop.

Same-family generate+review shares blind spots. Use a different model as reviewer. Cite only if you change this policy.

## Depth

Do not use line count alone. Specs are not automatically quick.

| Kind | What it is | Default |
|---|---|---|
| Editorial | Typos, stale links, formatting | skip or quick |
| Operational | README, runbooks, API reference | quick or standard |
| Decisional | Spec, ADR, RFC, design doc, PR plan | **standard at least** |

Triage locally (paths, diff hunks, decision language). Do not spend a model call to classify.

Detect decisional docs from:

- Paths: `docs/adr/`, `docs/design/`, `docs/rfcs/`, `ARCHITECTURE.md`, `DESIGN.md`, `*.spec.md`
- Diff: new file, rewrite, `we will` / `decision` / `alternatives` / `trade-off` / `non-goals` / `MUST`
- Explicit: `--kind spec` or frontmatter `kind: spec` / `review: deep`

Code defaults: skip (no code change) → quick (small, no sensitive paths) → standard → deep (risk paths, large diff, or user asked).

**Block Stop** only on CRITICAL/HIGH (code) or decision issues (specs). Nits do not block.

Spec reviews use a spec prompt, not the code-review prompt. Status language: `ready` / `ready with nits` / `ready with issues` / `not ready`. A spec review that only emits nits is a failed review.

## Slices (one PR each)

1. **Agent registry + Grok runner** — on `main`
2. **`--writer` / `--reviewer`** — Phase 1 is reviewer-only. Writer rebuts via later phase or hook block. Default reviewer: Codex, then Grok.
3. **Diff-scoped input** — replace `collect_source_code` with the git diff + changed files
4. **Depth triage + spec prompt** — skip/quick/standard/deep and editorial/operational/decisional
5. **Stop-hook installer** — thin `hooks/stop.sh` for Claude, Grok, and Codex; state in the **target** repo (gitignored)
6. **Standalone vs hook** — hook never applies; standalone `--apply` is explicit

## Citation rule

Cite a source only when the choice changes **agent policy**: who may judge whose work, how hard they work, or what they may conclude.

Do not cite for CLI flags, file layout, parsers, or “we extract an adapter.”

When you do cite: one claim, one reason, one link. No research appendix.

## Next session

```
Read AGENTS.md and docs/handoff.md. Implement slice 2 only: --writer / --reviewer.
Do not add the stop hook, diff collector, or depth triage.
Open one PR. Keep the description short.
```
