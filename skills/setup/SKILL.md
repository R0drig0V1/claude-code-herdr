---
name: setup
description: Check and, with the user's confirmation, install what the multi-agent-herdr plugin needs - the herdr binary, herdr's Claude integration and the multi-agent plugin. Only when the user runs /multi-agent-herdr:setup.
disable-model-invocation: true
---

<!--
setup skill of the multi-agent-herdr plugin. User-invoked only (disable-model-invocation) and
never run from a hook. It checks first and installs only after an explicit confirmation for
each step. Install command from https://herdr.dev/agent-guide.md; integration commands from
`herdr integration` (herdr 0.9.5).
-->

# Setup

Check everything first, report, then ask before each change. Any "no" skips that step.

## 1. herdr binary

```bash
command -v herdr && herdr --version
herdr status          # client vs running server version, read-only
```

If `herdr` is missing, show the official installer and run it only after the user confirms
(offer to print the script for review first: `curl -fsSL https://herdr.dev/install.sh`):

```bash
curl -fsSL https://herdr.dev/install.sh | sh
```

Homebrew, mise, Nix and manual downloads: https://herdr.dev/tui/docs/install/. Never stop
or restart a running herdr server (`herdr server stop`) as part of setup.

## 2. Claude integration

```bash
herdr integration status | grep '^claude:'
```

`current` means done. If it says `not installed` or outdated, explain that it writes a hook
under `~/.claude/hooks/` (native session restore for Claude panes) and, after the user
confirms:

```bash
herdr integration install claude
```

## 3. multi-agent plugin

`dispatch` uses multi-agent's `scripts/new-worktree.sh`:

```bash
find ~/.claude/plugins/cache -path '*/multi-agent/*/scripts/new-worktree.sh' 2>/dev/null | sort -V | tail -n 1
```

If nothing is found, show the install steps from this plugin's README (multi-agent's
marketplace and `claude plugin install multi-agent@claude-code-multi-agent`) and run them
only after the user confirms.

## 4. herdr config

No herdr configuration is required: agent placement (one workspace per agent) is done by
`dispatch`. Never edit `~/.config/herdr/config.toml` unless the user asks; if they do, show
the exact diff and get confirmation before writing.

## 5. Report

One line each: herdr version (client/server), Claude integration state, multi-agent
`new-worktree.sh` path, and what was installed or skipped.
