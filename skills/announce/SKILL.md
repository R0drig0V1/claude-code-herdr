---
name: announce
description: Development agents only - after /multi-agent:pr, announce the pull request to the integrator by herdr agent name (herdr agent prompt integrator), falling back to SendMessage outside herdr. Use right after opening or updating a PR, when a dispatch brief says to finish with announce, or when the user says "announce", "avisa al integrador", "/announce".
---

<!--
announce skill of the multi-agent-herdr plugin. Replaces step 5 of multi-agent's `pr` skill
inside herdr: one naming system (herdr agent names), so the integrator knows which agent
owns the branch. Command syntax from `herdr --skill` and `herdr agent|pane` (herdr 0.9.5).
-->

# Announce

Run it after `/multi-agent:pr` has pushed the branch and opened (or updated) the PR. Never
from the main worktree, never as the integrator.

## 1. Collect the facts

```bash
B=$(git branch --show-current)
gh pr view "$B" --json number,title,url --jq '"\(.number)\t\(.title)\t\(.url)"'
```

If there is no PR (no `gh`, no GitHub remote), say so in the message instead of a number:
`Branch <B> ready (no PR: <reason>)`, plus the compare URL `pr` printed if any.

Your own herdr name, resolved from the live pane (do not trust `$HERDR_PANE_ID`: it goes
stale when a pane is moved to another workspace; `--current` still resolves):

```bash
ME_PANE=$(herdr pane current --current | jq -r '.result.pane.pane_id')
ME=$(herdr agent list | jq -r --arg p "$ME_PANE" '.result.agents[] | select(.pane_id == $p) | .name // empty')
```

## 2. Send it

Message (English, first line is the headline the integrator acts on):

```text
PR #<N> ready: <branch> - <title>
From herdr agent: <ME> (worktree <toplevel>)
Migrations: <none | ...>
Risky: <anything the reviewer should look at, or "nothing special">
Checks: <commands run and their exit codes>
```

Inside herdr (`HERDR_ENV=1`) and with a live agent named `integrator`:

```bash
herdr agent list | jq -e '.result.agents[] | select(.name == "integrator")' >/dev/null && \
  herdr agent prompt integrator "$MSG"; echo "exit=$?"
```

Do not add `--wait`: the integrator's turn (verify and merge) can take long, and you get the
verdict as a herdr prompt and a PR comment anyway. If the prompt fails with `agent_blocked`,
the integrator is waiting at an approval dialog: do **not** answer it; tell the user the
announcement is pending and why.

Outside herdr, or with no `integrator` agent: fall back to multi-agent's announcement,
`ListAgents` then `SendMessage(to="integrator", message=...)` with the same text. If there is
no integrator anywhere, do nothing more: open PRs are its queue.

## 3. Report

Tell the user the PR (or compare) URL, the title, and how the integrator was notified
(`herdr agent prompt` exit code, `SendMessage`, or not notified and why).

On a bounce, fix the branch in your worktree, push, and announce again.
