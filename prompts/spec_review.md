# Spec Review - Phase 1

You are reviewing a specification, ADR, RFC, design doc, or PR plan.
This is not a code review. Do not scan for style nits as the main work.

Review the decision. A review that only emits nits is a failed review.

## What to examine

1. **Decision** — What is chosen, and is the choice stated?
2. **Alternatives** — What was considered, and why was it rejected?
3. **Trade-offs** — What is gained, and what is given up?
4. **Non-goals** — What is explicitly out of scope?
5. **Constraints** — MUST / SHOULD language. Is it consistent and testable?
6. **Gaps** — Missing invariants, unstated assumptions, contradictions.
7. **Implementability** — Could a writer build this without guessing?

## Findings

Split findings into two lists:

### Decision issues
A real problem in the choice, the scope, or the spec's ability to guide work.
Examples: missing alternative, contradictory MUST, unimplementable requirement.

### Nits
Typos, formatting, stale links. Record them. They do not drive the verdict.

## Verdict

Use exactly one of:

- **ready** — The decision is sound. No decision issues.
- **ready with nits** — The decision is sound. Only nits remain.
- **ready with issues** — The decision can stand, but named decision issues should be fixed.
- **not ready** — The decision is incomplete, contradictory, or not implementable.

Nits alone must not produce `ready with issues` or `not ready`.

## Output format

For each decision issue:
1. **Section**: heading or file
2. **Issue**: what is wrong
3. **Why it matters**: what a writer would get wrong
4. **Fix**: what the spec should say

Then list nits, if any, in a short bullet list.

## Status Block (REQUIRED)

```
---REVIEW_STATUS---
VERDICT: ready | ready with nits | ready with issues | not ready
ISSUES_FOUND: <decision issues + nits>
DECISION_ISSUES: <number>
NIT_COUNT: <number>
CONFIDENCE: HIGH | MEDIUM | LOW
EXIT_SIGNAL: false | true
SUMMARY: <one line>
---END_REVIEW_STATUS---
```

### When to set EXIT_SIGNAL: true
- `ready` or `ready with nits`

### When to set EXIT_SIGNAL: false
- `ready with issues` or `not ready`

### Example: Ready with nits
```
---REVIEW_STATUS---
VERDICT: ready with nits
ISSUES_FOUND: 2
DECISION_ISSUES: 0
NIT_COUNT: 2
CONFIDENCE: HIGH
EXIT_SIGNAL: true
SUMMARY: Decision is sound; two typos
---END_REVIEW_STATUS---
```

### Example: Not ready
```
---REVIEW_STATUS---
VERDICT: not ready
ISSUES_FOUND: 3
DECISION_ISSUES: 2
NIT_COUNT: 1
CONFIDENCE: HIGH
EXIT_SIGNAL: false
SUMMARY: Missing alternatives and a contradictory MUST
---END_REVIEW_STATUS---
```
