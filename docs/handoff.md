# Handoff

Read this file in a **new** session. Do not resume the long planning thread.

## Goal

Turn this tool into a **writer + reviewer** stop hook.

- Writer = the model that just produced the change
- Reviewer = a different model
- Review **this turn’s diff**, not the whole tree
- Full four-phase debate is rare

The loop now has writer and reviewer roles. Input is the uncommitted git diff and the changed files. Do not grow the old two-reviewer loop. Replace it slice by slice.

## Status

- Slice 1 is on `main`: `lib/agents.sh` (`run_claude`, `run_codex`, `run_grok`, `run_agent`)
- Slice 2 is on `main`: `--writer` / `--reviewer`. Phase 1 is reviewer-only. Writer rebuts in Phase 2.
- Slice 3 is on `main`: diff-scoped input. Phase 1 gets the git diff and changed files, not a tree dump.
- Slice 4: depth triage + spec prompt. Writer facts raise only. Reader returns counts, not a score.
- Default writer: Claude. Default reviewer: Codex, then Grok. No self-review.

Next: slice 5, branched from `main` after this merges.

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

**Writer facts.** The writer may pass a yes/no card. Those are claims, not the review. True facts may **raise** kind or depth. They may not lower it. They may not set `skip` or send a paragraph of intent. Unknown keys are ignored.

```yaml
# .adversarial-review/writer-facts.yml in the target
api_change: false
auth: false
migration: false
decision: true
docs_only: true
tests_only: false
```

If a claim disagrees with the diff (`docs_only: true` plus `src/auth.py`), mark it disputed and keep the local floor.

**Reader judgment.** The reader returns an ordinal plus counts, not a 1–10 score.

- Spec: `ready` / `ready with nits` / `ready with issues` / `not ready`, plus `DECISION_ISSUES` and `NIT_COUNT`
- Code: `CRITICAL_COUNT` / `HIGH_COUNT` / `MEDIUM_COUNT` / `LOW_COUNT`

**Block Stop** only on CRITICAL/HIGH (code) or decision issues (specs). Nits do not block. The hook (slice 5) reads the sidecar, runs this triage, calls the reader, and tests those counts.

Detect decisional docs from:

- Paths: `docs/adr/`, `docs/design/`, `docs/rfcs/`, `ARCHITECTURE.md`, `DESIGN.md`, `*.spec.md`
- Diff: new file, rewrite, `we will` / `decision` / `alternatives` / `trade-off` / `non-goals` / `MUST`
- Explicit: `--kind spec` or frontmatter `kind: spec` / `review: deep`

Code defaults: skip (no code change) → quick (small, no sensitive paths) → standard → deep (risk paths, large diff, or user asked).

Spec reviews use a spec prompt, not the code-review prompt. Status language: `ready` / `ready with nits` / `ready with issues` / `not ready`. A spec review that only emits nits is a failed review.

## Slices (one PR each)

1. **Agent registry + Grok runner** — on `main`
2. **`--writer` / `--reviewer`** — on `main`. Phase 1 is reviewer-only. Writer rebuts in Phase 2. Default reviewer: Codex, then Grok.
3. **Diff-scoped input** — on `main`. Replace `collect_source_code` with the git diff + changed files
4. **Depth triage + spec prompt** — this PR. skip/quick/standard/deep, writer facts (raise-only), reader counts
5. **Stop-hook installer** — thin `hooks/stop.sh` for Claude, Grok, and Codex; state in the **target** repo (gitignored). Read the facts sidecar, run triage, call the reader, block on the counts.
6. **Standalone vs hook** — hook never applies; standalone `--apply` is explicit

## Citation rule

Cite a source only when the choice changes **agent policy**: who may judge whose work, how hard they work, or what they may conclude.

Do not cite for CLI flags, file layout, parsers, or “we extract an adapter.”

When you do cite: one claim, one reason, one link. No research appendix.

## Next session

```
Read AGENTS.md and docs/handoff.md. Implement slice 5 only: the stop-hook installer.
Thin hooks/stop.sh for Claude, Grok, and Codex. State in the target repo (gitignored).
Read writer facts, run local triage, call the reader, block Stop on decision issues or CRITICAL/HIGH.
Do not implement standalone --apply.
Open one PR. Keep the description short.
```
