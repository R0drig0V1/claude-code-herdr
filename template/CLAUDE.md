# CLAUDE.md

<!-- Project rules for Claude Code agents, installed by multi-agent-herdr's install.sh. -->

<!-- TODO: one paragraph on what this repository is and its main constraints. -->

## Layout

```
<!-- TODO: top-level folders and what lives in each -->
docs/        architecture, phases/ (the plan), decisions/ (ADRs), plan-reviews/
scripts/     check.sh (all checks), integrator.sh; optional worktree-setup.sh, verify-reset.sh
.claude/     settings.json (enables the multi-agent-herdr plugin), multi-agent-herdr.json
             (base branch, integrator name), multi-agent-herdr-workflow.md (managed by the
             plugin), prompts/integrator.md
```

The workflow itself (skills, agents, guard hooks, notifications, `new-worktree.sh`,
`verify-merge.sh`) comes from the `multi-agent-herdr` plugin
(https://github.com/R0drig0V1/claude-code-herdr), enabled in `.claude/settings.json`. It runs
inside herdr (https://herdr.dev).

## Commands (run from the repo root)

```bash
scripts/check.sh                   # lint + types + tests; must stay green (edit it per project)
scripts/integrator.sh              # launch the integrator agent (inside herdr, main worktree)
/multi-agent-herdr:dispatch <type>/<name> <task>   # integrator: start a development agent
# TODO: build, run, test commands of this project
```

## Workflow

The multi-agent-herdr workflow rules (documentation, ADRs, `scripts/check.sh`, the plan, the
integrator and the development agents) are managed by the plugin and imported here; do not edit
the imported file, `/multi-agent-herdr:setup` updates it:

@.claude/multi-agent-herdr-workflow.md

## Rules

- **Language:** code, identifiers, comments, docs and commits in **English**.
  <!-- TODO: language to answer the user in, if not English. -->
<!-- TODO: project-specific rules (architecture boundaries, invariants, conventions) -->
