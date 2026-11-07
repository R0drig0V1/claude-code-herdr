<!--
README of claude-code-herdr: what the multi-agent-herdr plugin does, how to install it,
the coordination rules every agent follows, and where herdr command syntax comes from.
-->

# claude-code-herdr

Claude Code plugin **`multi-agent-herdr`**: native [herdr](https://herdr.dev) support for the
[multi-agent](https://github.com/R0drig0V1/claude-code-multi-agent) workflow. It is layered on
top of `multi-agent`, which it requires and does not modify: `multi-agent` keeps the
integrator, worktree, guard-hook and PR rules; this plugin decides where agents run in herdr
and routes messages between them by **herdr agent name**.

| Skill | Who | What |
|---|---|---|
| `/multi-agent-herdr:dispatch` | integrator | Creates the task's worktree with multi-agent's `new-worktree.sh`, opens it as **its own herdr workspace** (a separate sidebar entry, never a pane split), starts a Claude agent named after the branch short name and sends it the brief. |
| `/multi-agent-herdr:announce` | developers | After `/multi-agent:pr`, sends `PR #N ready: ...` to the herdr agent `integrator` (falls back to `SendMessage` outside herdr). |
| `/multi-agent-herdr:reply` | integrator | Resolves the PR author as branch -> worktree -> live herdr agent, sends the verdict there, and tells the other live agents when `main` moved on shared files. |
| `/multi-agent-herdr:setup` | user only | Checks herdr, herdr's Claude integration and the multi-agent plugin; installs each only after you confirm. |

`scripts/agents-in-repo.py` is the read-only resolver `reply` uses: it lists the live herdr
agents whose pane cwd is inside a worktree of the current repository.

## Cycle

```text
integrator: /multi-agent-herdr:dispatch docs/readme-typo "Fix the typo in README"
  -> ../<repo>-readme-typo (new-worktree.sh) -> herdr workspace "readme-typo" -> agent "readme-typo"
readme-typo: works in its worktree -> /multi-agent:pr -> /multi-agent-herdr:announce
integrator: /multi-agent:integrate (verify, merge or bounce, PR comment) -> /multi-agent-herdr:reply
```

The integrator's herdr agent must be named `integrator` (`herdr agent rename <pane> integrator`).

## Requirements

- [herdr](https://herdr.dev) (built against 0.9.5), with Claude Code running inside it
  (`HERDR_ENV=1`).
- The `multi-agent` plugin, set up in the project (its guard hooks, `scripts/check.sh`,
  `CLAUDE_ROLE=integrator` for the integrator session).
- `git`, `jq`, `python3` (3.9+), and `gh` for PR numbers.

## Install

1. herdr, if missing: `curl -fsSL https://herdr.dev/install.sh | sh` (other methods:
   https://herdr.dev/tui/docs/install/), then `herdr integration install claude`.
   `/multi-agent-herdr:setup` checks both and asks before installing either.
2. The multi-agent plugin:

   ```bash
   claude plugin marketplace add R0drig0V1/claude-code-multi-agent
   claude plugin install multi-agent@claude-code-multi-agent
   ```

3. This plugin, from a local clone (or `R0drig0V1/claude-code-herdr` once published):

   ```bash
   claude plugin marketplace add /path/to/claude-code-herdr
   claude plugin install multi-agent-herdr@claude-code-herdr --scope project
   ```

   To try it without installing: `claude --plugin-dir /path/to/claude-code-herdr`.

No herdr configuration is needed: workspace placement is done by `dispatch`.

## Rules

- **Never answer another agent's approval or question dialog.** Do not `herdr agent
  send-keys`, `pane send-keys` or `pane send-text` into another agent to accept, reject or
  dismiss anything.
- **A `blocked` agent is escalated to the user.** When `herdr agent list` shows `blocked`, or a
  prompt fails with `agent_blocked` / `agent start` with `agent_not_ready`, tell the user which
  agent (and workspace) waits for them, and do not send it anything until it is `idle` again.
- **One agent, one workspace.** `dispatch` never uses `herdr pane split` or `herdr tab create`
  for a development agent.
- **Worktrees come from multi-agent's `new-worktree.sh`**, never from `herdr worktree create`
  and never reimplemented, so naming, `.env` and `scripts/worktree-setup.sh` stay identical.
- **Targets come from live state.** Pane ids are read from herdr's JSON responses and agents
  from `herdr agent list`; nothing is derived from sidebar order. `$HERDR_PANE_ID` can be
  stale after a pane is moved; `herdr pane current --current` resolves the live pane.
- Do not close workspaces, panes or worktrees you did not create, do not stop the herdr
  server, and do not pass `--trust-repository` without the user's say-so.

## herdr syntax

Command syntax comes from the installed binary: `herdr --skill` and `herdr <group>` (for
example `herdr agent`, `herdr pane`, `herdr worktree`, `herdr notification`). The official
herdr skill is not copied into this plugin. Never run bare `herdr` from an agent: it launches
or attaches the TUI.
