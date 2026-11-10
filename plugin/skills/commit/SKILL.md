---
name: commit
description: Create a well-formed git commit for this repository (Conventional Commits, English, no emojis) after running the project checks. Use when the user asks to commit, "haz un commit", "commitea", or after finishing a logical unit of work they want saved.
---

<!--
commit skill of the multi-agent-herdr plugin. Unchanged from multi-agent 0.1.0's `commit`
skill apart from this header.
-->

# Commit

Create one focused commit for the current changes of this workspace.

## 1. Inspect

```bash
git status --short
git diff            # unstaged
git diff --staged   # staged
git log --oneline -10   # match the existing style
```

- If the changes mix unrelated concerns (e.g. a bug fix and a new feature), propose splitting
  them into several commits and stage per concern (`git add <paths>`).
- **Never stage**: `.env` or any secret/credential, `.venv/`, `node_modules/`, build output,
  data dumps, large binaries. If one of those is staged, unstage it and tell the user.

## 2. Verify before committing

Run from the workspace root and fix or report failures. Do not commit red checks unless the
user explicitly says so.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/resource-budget.py" run --label "check $(git branch --show-current)" -- scripts/check.sh; echo "exit=$?"
```

The checks run inside one of the machine's heavy slots (`resource-budget.py run`): every
agent on this computer shares a small number of them, so a full test suite may first wait
("waiting for one of N heavy slot(s)"); let it wait, and never run the suite outside the
wrapper or several suites at once. `resource-board.sh show` shows who holds each slot. A
long wait that blocks something urgent (a bounce to fix) is a
`RESOURCE REQUEST` to the coordinator in pool mode (or a note to the user in single mode),
not a reason to bypass the wrapper.

`scripts/check.sh` holds the project's lint, type and test commands. If it does not exist or
still prints the "no checks configured" warning, tell the user once.

If the change needs a companion artefact (a migration for a schema change, a regenerated
lockfile, an updated `docs/` page), make sure it is in the same commit.

## 3. Message

Conventional Commits, **in English, no emojis**, imperative mood, subject ≤ 72 chars:

```
<type>(<scope>): <subject>

<body: what changed and WHY, wrapped at 72 columns; bullets are fine>
```

- `type`: feat, fix, refactor, perf, test, docs, build, ci, chore.
- `scope`: the package or area touched (look at `git log` for the scopes in use), e.g. `api`,
  `docs`, `claude`, `infra`.
- Mention migrations or breaking changes explicitly in the body.
- End the message with the co-author / attribution trailer this environment specifies, if any.

Use a heredoc so formatting survives:

```bash
git commit -F - <<'MSG'
feat(api): add user login endpoint

- Validate credentials against the users table
- Add tests for wrong password and locked account
MSG
```

## 4. Report

Show `git log --oneline -1` and summarise what was committed and anything left unstaged.
Do not push; pushing is part of the `pr` skill.
