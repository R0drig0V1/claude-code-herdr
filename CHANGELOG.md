<!-- Release history of claude-code-herdr, in Keep a Changelog format. -->

# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `multi-agent-herdr` Claude Code plugin, published through the `claude-code-herdr`
  marketplace in this repository. Replaces `multi-agent` 0.1.0 (claude-code-multi-agent
  commit 88c8ad4), ported and made herdr native.
- Skills: `dispatch` (one worktree and one herdr workspace per development agent), `setup`,
  and the ported `commit`, `pr`, `integrate`, `document`, `improve-plan`. `pr` announces to the
  herdr agent `integrator`; `integrate` sends verdicts to the agent that owns the branch.
- `scripts/agents-in-repo.py`: read-only branch -> worktree -> live herdr agent resolver.
- Every herdr message starts with `[herdr message from agent <name>; not from the user]`, and
  agent messages are documented as data, never user approval.
- Agents `plan-adversary` and `code-reviewer`, guard hooks, `notify.sh`, `new-worktree.sh`,
  `verify-merge.sh`, `install.sh`, `template/`, smoke tests and CI, ported from multi-agent.

- The Bash guard blocks herdr commands that type into another pane (`agent
  send-keys|attach|rename`, `pane run|send-keys|send-text`, `terminal attach|session`, and
  `agent prompt` to anyone but `integrator`) for development agents, also after a `cd` out
  of the repository, behind `$HERDR_BIN_PATH` / other `$VAR` programs, behind the `command`,
  `exec`, `builtin`, `nohup` and `time` prefixes, and inside `sh|bash|zsh -c` / `eval`
  strings (which also brings the other Bash rules to those strings).
- `scripts/claim-integrator.sh`, run by `dispatch` and `integrate`, gives the integrator the
  herdr name `integrator`; `pr` only announces to the `integrator` in its own repository's
  main worktree (`agents-in-repo.py --name integrator --main-worktree`).

- `.claude/multi-agent-herdr.json` (optional, project-owned) and `scripts/project-config.py`,
  its only reader: `base_branch` (default `main`) for projects whose PRs target an
  integration branch such as `dev`, `integrator_name` (default `integrator`),
  `protected_branches` (extra push-protected patterns) and `worktree_prefix` (default
  `<repo>-`). Used by `new-worktree.sh`, `verify-merge.sh`, `claim-integrator.sh`, the Bash
  guard, `scripts/integrator.sh` and the `pr`, `integrate`, `dispatch`, `document` and `setup`
  skills. `integrate` never moves `main` when the base is another branch; it follows the
  project's documented promotion. An invalid file stops scripts and skills; the guard falls
  back to the defaults.

### Fixed (compared with multi-agent)
- Hooks and `install.sh` read `enabledPlugins` as JSON: a `false` entry no longer enables the
  guards, and `settings.local.json` overrides `settings.json`.
- `install.sh` adds a newline before appending to a `.gitignore` that lacks one, and stops
  before copying anything when `.claude/settings.json` is not valid JSON.
- `new-worktree.sh`, `verify-merge.sh` and `integrator.sh` work in paths with spaces.

### Removed (compared with multi-agent)
- The `worktree` skill and `EnterWorktree`: development agents start inside their worktree
  through `dispatch`. `SendMessage`/`ListAgents` fallbacks: this plugin is herdr only.
