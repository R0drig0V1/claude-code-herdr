---
name: improve-plan
description: Improve the development plan (docs/phases/) through adversarial review - the plan-adversary agent attacks it, you defend or amend, repeat until no high-severity findings remain. Use when the user asks to "mejorar el plan", "revisar el plan", "red team the plan", or before starting a new phase.
argument-hint: "[phase file or folder under docs/phases/] (default: all)"
---

<!--
improve-plan skill of the multi-agent-herdr plugin. Unchanged from multi-agent 0.1.0's
`improve-plan` skill apart from this header.
-->

# Improve the plan (adversarial)

Goal: a plan that survives a hostile, well-informed reviewer. You play the **defender/editor**;
the `plan-adversary` agent plays the **attacker**. The adversary never edits files; you do.

Scope: `$ARGUMENTS` → that file or folder under `docs/phases/`, or all of `docs/phases/`
(default), always plus `docs/phases/README.md`.

## Round loop (max 3 rounds)

1. **Attack.** Launch the `plan-adversary` agent. Give it: the scope, the round number, and
   for rounds ≥ 2 the list of findings already resolved or rejected (so it does not repeat
   them and instead probes your fixes). Ask for its structured findings report.
2. **Triage each finding.** For every finding decide one of:
   - **Accept** → amend the phase docs (tasks, acceptance criteria, risks, ordering). Make the
     smallest change that fully addresses it.
   - **Partially accept** → amend what is valid, explain the rest.
   - **Reject** → only with a concrete reason grounded in the repo, the user's stated goals
     (see `CLAUDE.md` / `docs/phases/README.md`) or evidence. "Out of scope" is valid only if
     the finding is recorded in a later phase's backlog.
   Verify factual claims before accepting them (read the code, check the docs, run the
   command). The adversary may be wrong.
3. **Stop condition.** Stop when a round produces no `critical`/`high` findings that you
   accepted, or after 3 rounds.

Do not let the plan grow without bound: prefer sharpening acceptance criteria and reordering
over adding scope. Any decision that changes what the user asked for must be surfaced to the
user, not decided silently.

## Record

Write `docs/plan-reviews/YYYY-MM-DD-<scope>.md`:

```markdown
# Plan review — <scope> — <date>

## Summary
<rounds run, counts by severity, overall verdict>

## Findings
| # | Round | Severity | Finding | Decision | Change made |
|---|-------|----------|---------|----------|-------------|

## Open questions for the user
- ...
```

Then update `docs/plan-reviews/README.md` (index) and tell the user the key changes and the
open questions. Do not commit unless asked.
