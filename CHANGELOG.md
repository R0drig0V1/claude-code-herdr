<!-- Release history of claude-code-herdr, in Keep a Changelog format. -->

# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Guideline "move work forward proactively", in the `dispatch` skill, the integrator prompt,
  the template `CLAUDE.md` and the README. The integrator starts agents for every task that
  can start now, without waiting to be asked, and always starts writing code early. It does
  not force work: no agents for undecided designs, for collisions with branches in flight,
  or for work a pending decision would make us amend.
- SessionStart hook `session-start-integrator.sh`: an integrator session (`CLAUDE_ROLE=integrator`,
  inside herdr, in the main worktree of a repository that enables the plugin) takes its herdr
  name with `scripts/claim-integrator.sh` as it starts, relaunches and resumed sessions
  included. Before, a relaunched integrator stayed an unnamed herdr agent until
  `/multi-agent-herdr:integrate` or `dispatch` ran, and development agents' PR announcements
  to `integrator_name` were lost meanwhile. herdr already lists the Claude agent at
  SessionStart (checked live with herdr 0.9.5), so the first claim normally succeeds; a
  detached worker retries "agent not detected" every 2 s for up to 60 s, and the hook waits at
  most about 0.8 s, so it never holds session start. The session gets one line naming its
  herdr agent, a note to ask the user when another live agent holds the name (exit 3), or a
  short warning on any other failure. `dispatch` and `integrate` keep the claim as a fallback;
  `template/scripts/integrator.sh` and `claim-integrator.sh` document the hook.

### Changed
- `integrator_name` defaults to `integrator-<repository>` (the main worktree's directory name,
  lower case, runs outside `[a-z0-9_-]` replaced by `-`, cut to 32 characters) instead of
  `integrator`. herdr agent names are unique per server, so with the old default a second
  project on the same server could not dispatch (`claim-integrator.sh` exit 3).
  `project-config.py` computes it (`default_integrator_name`), `template/scripts/integrator.sh`
  repeats the rule and gains `--print-name`, and the template settings file no longer writes
  the key. Existing projects with `"integrator_name": "integrator"` keep it;
  `/multi-agent-herdr:setup` offers to remove it, and `claim-integrator.sh` explains the fix
  when the name is taken.

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

- Automated quality and security checks (docs/code-quality.md): `quality.yml` (ruff
  check/format with mccabe <= 15, lizard complexity ceilings, zizmor, actionlint, gitleaks),
  `codeql.yml` (CodeQL for Python and Actions), `scorecard.yml` (OpenSSF Scorecard) and
  Dependabot version updates for actions and the uv-locked dev tools (`pyproject.toml`,
  `uv.lock`). `ci.yml` now runs with `contents: read`, pins `actions/checkout` by SHA and
  does not persist credentials. `SECURITY.md`: private vulnerability reporting.

### Fixed
- `install.sh` sets an enabled `multi-agent@claude-code-multi-agent` (the plugin this one
  replaces) to `false` in `.claude/settings.json` and reports `disabled ...`; before, it added
  `multi-agent-herdr` next to it and both plugins' guards ran. Idempotent: a rerun finds it
  `false` and writes nothing. A `.claude/settings.local.json` that still enables it gets a
  warning, not an edit.
- `dispatch` found the new worktree with an inline `awk '... substr($0,10) ... $0==b ...'`.
  Claude Code substitutes `$N` (shorthand for `$ARGUMENTS[N]`), `$ARGUMENTS[N]`, `$ARGUMENTS`
  and declared `$name` arguments in a skill's content
  ([Available string substitutions](https://code.claude.com/docs/en/skills#available-string-substitutions),
  [Pass arguments to skills](https://code.claude.com/docs/en/skills#pass-arguments-to-skills)),
  so the integrator received the dispatch arguments in place of `$0` and a broken command.
  The lookup moved to `plugin/scripts/worktree-of.sh <branch>`. An audit of every SKILL.md and
  agent found no other such token; the two `$ARGUMENTS` uses (`dispatch`, `improve-plan`) are
  prose meant for substitution.
- `tests/check-skill-substitutions.py`, run by `tests/test-hooks.sh` in CI, fails on a
  positional token (`$N`, `${N}`, `$ARGUMENTS[N]`) anywhere in a SKILL.md, on `$ARGUMENTS` in
  a fenced code block, and on a declared `arguments` name used in a code block.

### Fixed (compared with multi-agent)
- Hooks and `install.sh` read `enabledPlugins` as JSON: a `false` entry no longer enables the
  guards, and `settings.local.json` overrides `settings.json`.
- `install.sh` adds a newline before appending to a `.gitignore` that lacks one, and stops
  before copying anything when `.claude/settings.json` is not valid JSON.
- `new-worktree.sh`, `verify-merge.sh` and `integrator.sh` work in paths with spaces.

### Removed (compared with multi-agent)
- The `worktree` skill and `EnterWorktree`: development agents start inside their worktree
  through `dispatch`. `SendMessage`/`ListAgents` fallbacks: this plugin is herdr only.
