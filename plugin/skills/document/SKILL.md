---
name: document
description: Bring the documentation of this repository up to date with the code - docstrings, README, docs/ pages, phase status, ADRs and CLAUDE.md. Use after implementing or changing something, when the user asks to "documentar", "actualiza la documentación", or before opening a PR.
---

<!--
document skill of the multi-agent-herdr plugin. Unchanged from multi-agent 0.1.0's
`document` skill apart from this header.
-->

# Document

This repository must stay **extremely well documented**. Documentation is in English.

## 1. Find what changed

```bash
git status --short
git diff origin/main...HEAD --stat     # or `git diff` for uncommitted work
```

## 2. Update, in this order

1. **Docstrings and comments in the changed code.** Every module has a docstring (or header
   comment) explaining its role; every public function/class has one stating behaviour,
   arguments and failure modes. Comments explain *why*, not *what*. Match the density of the
   surrounding code.
2. **`docs/` pages affected** (use the map below). Keep examples runnable; if a command or
   output changed, re-run it and paste the real result.
3. **Phase documents** in `docs/phases/`: in a development worktree, do not edit them (the
   integrator owns them); list completed and discovered tasks for the PR body instead. In the
   integrator session: tick tasks, update the status line and the roadmap table in
   `docs/phases/README.md`, and record deviations from the plan with a one-line reason.
4. **Decisions**: a choice that is hard to reverse or that future readers would question gets
   an ADR in `docs/decisions/NNNN-title.md` (Context / Decision / Consequences) and a line in
   `docs/decisions/README.md`.
5. **README.md** (root): only if setup, commands or the feature list changed.
6. **CLAUDE.md**: only if conventions, commands or architecture rules changed. Keep it short.

## Map: code → docs

<!-- TODO: fill in for this project, one row per area of the code. -->

| Change in | Update |
|-----------|--------|
| architecture, module boundaries | `docs/architecture.md` |
| setup, env vars, commands | `README.md`, `.env.example` |
| `.claude/`, `scripts/` | `CLAUDE.md` ("Multi-agent workflow", "Commands") |

## 3. Verify

- Every relative link you touched resolves (`ls` the target).
- Commands you documented actually run.
- Summarise to the user which files were updated and why.
