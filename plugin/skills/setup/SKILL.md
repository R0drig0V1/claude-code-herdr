---
name: setup
description: Check and, with the user's confirmation, install what the multi-agent-herdr plugin needs - the herdr binary, herdr's Claude integration and the project files - and detect the old multi-agent plugin enabled in the same project. Only when the user runs /multi-agent-herdr:setup.
disable-model-invocation: true
---

<!--
setup skill of the multi-agent-herdr plugin. User-invoked only (disable-model-invocation) and
never run from a hook. It checks first and changes anything only after an explicit
confirmation for each step. Install command from https://herdr.dev/agent-guide.md;
integration commands from `herdr integration` (herdr 0.9.5).
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

## 3. The project (only inside a git repository)

```bash
root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
for f in "$root"/.claude/settings.json "$root"/.claude/settings.local.json; do
  [ -f "$f" ] && jq -r --arg f "$f" '.enabledPlugins // {} | to_entries[]
    | select(.key | test("^multi-agent(-herdr)?@")) | "\($f): \(.key) = \(.value)"' "$f"
done
ls "$root"/scripts/check.sh "$root"/scripts/integrator.sh "$root"/.claude/prompts/integrator.md
```

- This plugin not enabled, or project files missing: offer the installer from this plugin's
  repository (`install.sh --dry-run` first, then without it after the user confirms).
- **The old `multi-agent` plugin also enabled**: both plugins' hooks would run, and the old
  ones send sessions to `/multi-agent:worktree` + `EnterWorktree`, which this plugin replaces
  with `dispatch`. Show the user the `enabledPlugins` line to remove (or set to `false`) and
  change it only after they confirm.

## 4. herdr config

No herdr configuration is required: agent placement (one workspace per agent) is done by
`dispatch`. Never edit `~/.config/herdr/config.toml` unless the user asks; if they do, show
the exact diff and get confirmation before writing.

## 5. Report

One line each: herdr version (client/server), Claude integration state, project state
(plugin enabled, project files, old multi-agent enabled or not), and what was installed or
skipped.
