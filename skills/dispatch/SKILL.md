---
name: dispatch
description: Integrator only, inside herdr - start a development agent for one task in its own git worktree and its own herdr workspace (a separate sidebar entry), then send it the brief. Use in the integrator session (main worktree, CLAUDE_ROLE=integrator, HERDR_ENV=1) when the user asks to dispatch, delegate or hand a task to a new agent ("dispatch", "lanza un agente para", "delega esto", "/dispatch").
argument-hint: "<type>/<short-kebab-name> <task description>  e.g. docs/readme-typo Fix the typo in README"
---

<!--
dispatch skill of the multi-agent-herdr plugin. Creates the worktree with multi-agent's
new-worktree.sh (never reimplemented here), opens it as its own herdr workspace, starts a
Claude agent there named after the branch and prompts it with the brief. Command syntax was
taken from `herdr --skill` and `herdr worktree|workspace|agent` (herdr 0.9.5).
-->

# Dispatch

You are the integrator. You do not develop the task yourself: you create its worktree, give it
its own herdr workspace and start one development agent there. The user explicitly wants each
agent as a **separate workspace in the herdr sidebar**: never `herdr pane split`, never a new
tab in your workspace, even though the generic herdr skill defaults to sibling panes.

## 0. Preconditions (stop and tell the user if any fails)

```bash
test "${HERDR_ENV:-}" = 1                              # running inside herdr
[[ "$CLAUDE_ROLE" == integrator ]]                     # the integrator session
[[ "$(git rev-parse --absolute-git-dir)" == "$(git rev-parse --path-format=absolute --git-common-dir)" ]]   # main worktree
MAIN=$(git rev-parse --show-toplevel)
```

Outside herdr, do not improvise: tell the user to use `/multi-agent:worktree` in a new
session instead.

## 1. Name the branch and the agent

From `$ARGUMENTS` (or the user's request) take the branch `<type>/<short-kebab-name>`
(type: feat, fix, docs, chore, refactor, test) and the task. The herdr agent name is the
branch short name, the part after the slash:

```bash
BRANCH=<type>/<short-kebab-name>; NAME=${BRANCH#*/}
[[ "$NAME" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || echo "invalid herdr agent name: $NAME"
herdr agent list | jq -r '.result.agents[].name // empty' | grep -qx "$NAME" && echo "name already live: $NAME"
```

If the name is invalid (herdr requires `[a-z][a-z0-9_-]{0,31}`) or already used by a live
agent, pick a shorter or different branch name with the user before creating anything.

## 2. Create the worktree with multi-agent's script

Locate `new-worktree.sh` in the installed multi-agent plugin. Do not reimplement it and do
not use `herdr worktree create`: the script owns the naming (`../<repo>-<name>`), the `.env`
copy and `scripts/worktree-setup.sh`.

```bash
NW=$(find ~/.claude/plugins/cache -path '*/multi-agent/*/scripts/new-worktree.sh' 2>/dev/null | sort -V | tail -n 1)
[[ -x "$NW" ]] || { echo "FATAL: multi-agent's scripts/new-worktree.sh not found under ~/.claude/plugins/cache; install the multi-agent plugin (see /multi-agent-herdr:setup)" >&2; false; }
"$NW" "$BRANCH"
WT=$(git worktree list --porcelain | awk -v b="branch refs/heads/$BRANCH" '/^worktree /{p=substr($0,10)} $0==b{print p}')
test -d "$WT" && echo "worktree: $WT"
```

If the script fails (branch or path exists), stop and report its output. Do not delete or
reuse an existing worktree without the user's say-so.

## 3. Open it as its own herdr workspace

```bash
OUT=$(herdr worktree open --cwd "$MAIN" --path "$WT" --label "$NAME" --no-focus); echo "exit=$?"; echo "$OUT"
```

If it fails (older herdr, unsupported repository), fall back to a plain workspace:

```bash
OUT=$(herdr workspace create --cwd "$WT" --label "$NAME" --no-focus); echo "exit=$?"; echo "$OUT"
```

Do not add `--trust-repository` on your own: if herdr asks for repository trust, ask the
user. Take the pane from the JSON, never from sidebar order:

```bash
PANE=$(jq -r '.result.root_pane.pane_id' <<<"$OUT")
jq -r '.result.already_open // false' <<<"$OUT"
```

If `already_open` is `true`, the worktree already had a workspace: check
`herdr pane get "$PANE"` and stop if it hosts an agent or a running command (ask the user).

## 4. Start the agent

```bash
herdr agent start "$NAME" --kind claude --pane "$PANE"; echo "exit=$?"
```

The agent starts inside its worktree: it must not call `EnterWorktree`. If `agent start`
returns `agent_not_ready`, the new agent is stuck at a startup dialog (typically Claude's
"trust this folder" prompt or a permission question). **Do not answer it with
`agent send-keys`**: tell the user which workspace (`$NAME`) needs them, wait with
`herdr agent wait "$NAME" --until idle --timeout 600000`, then continue.

## 5. Send the brief

Write the brief, then submit it and confirm the agent picked it up (do not use `--wait`
alone: it would block until the whole task settles):

```bash
herdr agent prompt "$NAME" "$BRIEF"; echo "exit=$?"
herdr agent wait "$NAME" --until working --until blocked --timeout 60000
```

The brief, in English:

```text
You are the development agent "<NAME>" for branch <BRANCH>, already inside its worktree
<WT> (do not call EnterWorktree, do not touch the main worktree).
Goal: <what and why, 1-3 sentences>.
Scope: <files/areas in scope>. Out of scope: <what not to touch>.
Read first: CLAUDE.md, <docs and phase file(s) relevant to the task>.
Rules: never answer another agent's approval dialog; if you are blocked, ask the user.
Finish with /multi-agent:pr, then /multi-agent-herdr:announce so the integrator ("integrator")
gets the PR by herdr message.
```

If the prompt fails with `agent_blocked`, or the wait returns `blocked`, read it with
`herdr agent read "$NAME" --source recent-unwrapped --lines 60` and escalate to the user. A
timeout does not prove the prompt was lost: inspect `herdr agent get "$NAME"` before
resending.

## 6. Report

One line per agent: name, branch, worktree path, workspace id, pane id, and its state after
the prompt (`working`, or `blocked` with what it waits for).

## Never

- `herdr pane split` or `herdr tab create` for a development agent.
- Answer, dismiss or `send-keys` into another agent's approval or question dialog.
- Close workspaces or panes you did not create, or remove a worktree.
