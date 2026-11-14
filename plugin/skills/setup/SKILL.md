---
name: setup
description: Check and, with the user's confirmation, install what the multi-agent-herdr plugin needs - the herdr binary, herdr's Claude integration and the project files - and detect the old multi-agent plugin enabled in the same project. Only when the user runs /multi-agent-herdr:setup.
disable-model-invocation: true
---

<!--
setup skill of the multi-agent-herdr plugin. User-invoked only (disable-model-invocation) and
never run from a hook. It checks first and changes anything only after an explicit
confirmation for each step. Install commands from https://herdr.dev/docs/install/;
integration commands from `herdr integration` (herdr 0.9.5).
-->

# Setup

Check everything first, report, then ask before each change. Any "no" skips that step.

## 1. Platform and herdr binary

```bash
uname -s              # Darwin: macOS; Linux (also WSL); MINGW*/MSYS*: Windows through Git Bash
command -v herdr && herdr --version
herdr status          # client vs running server version, read-only
```

On Windows, the plugin's hooks and scripts run in Git Bash (Git for Windows), the shell Claude
Code uses there, and need Python 3.9+ as `python3`, `python` or `py`
(`"${CLAUDE_PLUGIN_ROOT}/run" scripts/project-config.py` fails with exit 127 without one)
and `jq` (`winget install jqlang.jq`). Report what is missing; do not install those yourself.

If `herdr` is missing, show the official installer for the platform and run it only after the
user confirms (offer to print the script for review first):

```bash
# macOS and Linux (review: curl -fsSL https://herdr.dev/install.sh)
curl -fsSL https://herdr.dev/install.sh | sh
# Windows, from Git Bash (review: curl -fsSL https://herdr.dev/install.ps1)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://herdr.dev/install.ps1 | iex"
```

If Windows endpoint security blocks the PowerShell one-liner, herdr's fallback is
`curl.exe -fsSLo install.cmd https://herdr.dev/install.cmd && install.cmd && del install.cmd`
(from cmd.exe). Homebrew (`brew install herdr`), mise, Nix and manual downloads:
https://herdr.dev/docs/install/. The installer may put herdr in a directory this shell does not
have on PATH yet: then ask the user to restart the terminal (and Claude Code) before step 2.
Never stop or restart a running herdr server (`herdr server stop`) as part of setup.

Native Windows herdr works but is younger than the Unix build: `herdr terminal attach` and live
server handoff are not supported there (https://herdr.dev/docs/windows-beta/). Mention it once
when the platform is Windows; WSL runs the Linux build.

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
"${CLAUDE_PLUGIN_ROOT}/run" scripts/project-config.py --root "$root"; echo "exit=$?"
```

- The settings (`.claude/multi-agent-herdr.json`): report `base_branch` and
  `integrator_name`. A non-zero exit means the file is invalid: show the error. A project
  whose pull requests do not target `main` (an integration branch such as `dev`) or whose
  integrator has another herdr name needs this file; offer to write it and only write it
  after the user confirms the values.
- **`integrator_name` set to plain `integrator`** (the old default, written explicitly by
  earlier installs): herdr names are unique per server, so a second project with the same name
  cannot dispatch (`claim-integrator.sh` exits 3). Offer to remove the key, which gives the
  per-repository default `integrator-<repository>`, or to set another unique name. Change it
  only after the user confirms, and tell them the running integrator takes the new name the
  next time a session starts (the SessionStart hook) or it runs `dispatch` or `integrate`.

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
(plugin enabled, project files, base branch and integrator name, old multi-agent enabled or
not), and what was installed or skipped.
