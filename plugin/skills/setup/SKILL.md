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

The installer (`install.sh`) already does these checks when a project is set up; this skill
repeats them from inside Claude Code, after a plugin update or to diagnose a project.

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
"${CLAUDE_PLUGIN_ROOT}/scripts/project-config.py" --root "$root"; echo "exit=$?"
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

- **Workflow rules** (`.claude/multi-agent-herdr-workflow.md`, managed by the plugin and
  imported by `CLAUDE.md`). They are versioned files, so check and change the copies of the
  **worktree this session is in**, not the main worktree's:

  ```bash
  wt=$(git rev-parse --show-toplevel)
  cmp "${CLAUDE_PLUGIN_ROOT}/context/workflow.md" "$wt/.claude/multi-agent-herdr-workflow.md"
  grep -nxF '@.claude/multi-agent-herdr-workflow.md' "$wt/CLAUDE.md"
  grep -nE '^## (Plan and workflow|Multi-agent workflow)$' "$wt/CLAUDE.md"
  ```

  In a project that already runs the workflow, any change below is made in a development
  agent's worktree and reaches the base branch through a PR (`/multi-agent-herdr:commit`,
  `/multi-agent-herdr:pr`). If this session is in the main worktree, do not write there
  (the guards block it, and the integrator does not develop): report what is outdated and
  tell the user to have the integrator dispatch an agent for it, e.g.
  `/multi-agent-herdr:dispatch chore/workflow-rules "Run /multi-agent-herdr:setup and open a PR"`.
  Only a project being set up for the first time, with nothing committed yet, is changed in
  place.

  - Missing or different: show `diff` between the two files and, after the user confirms,
    copy the plugin's version over it. Never edit it by hand to merge local changes, they
    belong in `CLAUDE.md`. If the project's copy looks newer than the plugin's, the plugin is
    the outdated side: suggest updating it (`/plugin`) instead.
  - No import line in `CLAUDE.md`: offer to add it (a `## Workflow` section with the line
    `@.claude/multi-agent-herdr-workflow.md`).
  - `## Plan and workflow` or `## Multi-agent workflow` still in `CLAUDE.md` (written by an
    install before the rules moved to the plugin): they duplicate the imported file and will
    drift from it. Show them and offer to remove them, together with the generic bullets of
    `## Rules` that the imported file now carries (document everything, ADRs,
    `scripts/check.sh`). Keep every project-specific line.
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
(plugin enabled, project files, workflow rules up to date or not, base branch and integrator
name, old multi-agent enabled or not), and what was installed or skipped.
