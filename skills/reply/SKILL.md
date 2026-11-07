---
name: reply
description: Integrator only, inside herdr - send a PR verdict (merged or bounced) to the herdr agent that owns the branch, resolved as branch -> worktree -> agent, and tell the other live agents when main moved on shared files. Use after /multi-agent:integrate merges or bounces a PR, or when the user says "reply", "responde al autor", "/reply".
argument-hint: "<PR number or branch> <merged|bounced> [details]"
---

<!--
reply skill of the multi-agent-herdr plugin. Replaces the SendMessage part of step 5 of
multi-agent's `integrate` skill inside herdr. The author is resolved from git and herdr
state by scripts/agents-in-repo.py, never guessed from names. Command syntax from
`herdr --skill` and `herdr agent` (herdr 0.9.5).
-->

# Reply

Run it from the integrator session, in the main worktree, after the PR comment of
`/multi-agent:integrate` step 5 is posted (the comment is the durable record; this is the
immediate one).

## 0. Preconditions

```bash
test "${HERDR_ENV:-}" = 1 && [[ "$CLAUDE_ROLE" == integrator ]]
```

Outside herdr, use multi-agent's `SendMessage` reply (copy the announcement's `from` as `to`).

## 1. Resolve the author

```bash
B=$(gh pr view <N> --json headRefName --jq .headRefName)      # or the branch you were given
"${CLAUDE_PLUGIN_ROOT}/scripts/agents-in-repo.py" --branch "$B"; echo "exit=$?"
```

The script maps the branch to its worktree (`git worktree list`) and lists the live herdr
agents whose pane cwd is inside it: `name  pane_id  status  branch  worktree`.

- One line: that agent is the author.
- No line: no live agent owns the branch. The PR comment is enough; tell the user.
- Several lines: do not pick one; ask the user.

## 2. Send the verdict

If the author's status is `blocked`, do not send anything and do not answer its dialog:
tell the user that agent `<name>` is blocked and waits for them. Otherwise:

```bash
herdr agent prompt "<name>" "$VERDICT"; echo "exit=$?"
```

`$VERDICT`: first line `PR #<N> merged as <sha>` or `PR #<N> bounced: <reason>`, then the
details (failing step, exact command and its output, what to change). No `--wait`. An
`agent_blocked` error means the same as status `blocked`: escalate, do not retry.

## 3. Tell the others that main moved

After a merge, when it touched files other branches are likely to share (migrations, shared
models, lockfiles, `CLAUDE.md`, `docs/phases/`):

```bash
git diff --name-only <sha>^1 <sha>
"${CLAUDE_PLUGIN_ROOT}/scripts/agents-in-repo.py" --exclude integrator --exclude "<author>"
```

Skip the line whose branch is `main` (the main worktree). To each remaining agent that is
not `blocked`:

```bash
herdr agent prompt "<name>" "main moved to <sha> (PR #<N>: <title>) and touched <files>. Rebase onto origin/main before your PR."
```

List the blocked ones for the user instead of prompting them.

## 4. Report

Who got the verdict (name and exit code), who was told that main moved, and who was
skipped (blocked, or no live agent) and why.
