<!-- Release history of claude-code-herdr, in Keep a Changelog format. -->

# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-11-09

### Added
- **Pool mode** (opt-in, docs/multi-integrator.md): an `integrators` object in
  `.claude/multi-agent-herdr.json` splits the single integrator into a **coordinator** (the
  session the user talks to: dispatch, `docs/phases/`, scaling; it never merges) and N
  **integrators** `<integrator_name>-<n>` that claim, verify and merge PRs in parallel, each in
  its own verify worktree detached at `origin/<base>`. Announcements go straight to the pool,
  verdicts straight from the integrator to the author, questions to the coordinator.
- `scripts/integrate-pr.sh`: one PR merged step by step, each step gated on the previous exit
  code: merge, `verify-merge.sh`, commit, push under the merge lock. When `<base>` moved during
  the verification it re-merges, pushes at once if only `reverify_exempt_paths` changed (the
  plan), and otherwise re-verifies, up to `max_reverify` times. A conflict stops it unless it
  is index-table rows (`--union-rows`, `union-rows.py`). A failed verification aborts and
  resets. The head branch is deleted only when the PR head, the remote head and the merged
  head agree, with a lease on that commit; otherwise it is kept. Used in both modes.
- `scripts/pool-state.py`: pool state in the git common dir. It holds atomic PR claims
  (`mkdir`), stale-claim takeover (dead owner or expired heartbeat, moved aside with an atomic
  `rename`), bounced heads (the queue skips a head until it changes), the merge lock (`lock
  run`, a kernel `flock` with `--expect-base`) and plan reports for the coordinator.
- `scripts/integrator-pool.sh`: `list`, `route` (the integrator the `pr` skill announces to,
  in both modes), `scale` (the facts and a rule-of-thumb suggestion; the coordinator decides
  after asking the members), `spawn <n>` (verify worktree, own workspace with
  `CLAUDE_ROLE=integrator`, `herdr agent start`, kickoff) and `stop <n>` (only idle members
  without claims, only workspaces it opened).
- **Resources, negotiated with one hard floor**, after an out-of-memory crash with about 20
  agents on a 24 GB machine:
  - `scripts/resource-budget.py run`: at most `heavy_slots` heavy commands at once, across all
    agents and projects (`verify-merge.sh`, `new-worktree.sh`, and the `commit` and `pr`
    skills run the project's scripts through it);
  - `scripts/resource-board.sh`: the shared, machine-wide resource sheet where agents note
    what they run, and `show` prints memory, slot holders, notes and idle agents;
  - a conversational protocol through the coordinator: `RESOURCE REQUEST` / `GO` / `WAIT` /
    `YIELD` and `SAVE MODE ON/OFF`, with the coordinator's priorities.

  Limits go in `~/.config/multi-agent-herdr/resources.json`, with defaults from the RAM. Only
  `heavy_slots` is enforced; `sessions_guideline` and `low_memory_gb` are guidelines.
- Skill `coordinate`; template `scripts/coordinator.sh` and `.claude/prompts/coordinator.md`.
- `project-config.py`: keys `coordinator_name` and `integrators`, derived `mode` and
  `integrator_pool`, dotted keys (`integrators.max`).
- `verify-merge.sh --here` (verify the current worktree); `agents-in-repo.py --detached` and
  `--dev-only`.
- `tests/test-pool.sh` (also in CI); docs/multi-integrator.md (design, failure modes, open
  questions) and docs/migration-multi-integrator.md (switching a project, granolax as the
  example).
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
- `integrate` merges with `integrate-pr.sh` in both modes and rebuilds the queue with
  `pool-state.py queue`. It records bounces, so a bounced head is not verified again. In pool
  mode it claims first, never touches the main worktree or `docs/phases/`, and reports merges
  to the coordinator.
- `dispatch` belongs to the coordinator in pool mode, reads the resource board first, and its
  brief routes questions and resource requests to the dispatcher. `pr` announces through `integrator-pool.sh route`.
- Guards: in pool mode the coordinator owns the main worktree. Integrators are held to the
  main-worktree rules. Both push a protected branch only through `pool-state.py lock run --`.
  `gh pr merge` stays blocked for both. Development agents may prompt the coordinator and the
  pool members. Single mode is unchanged.
- `claim-integrator.sh` and the SessionStart hooks handle the coordinator and pool members.
  `template/scripts/integrator.sh` refuses to launch in pool mode.
- `guard-main-bash.py`: `check_segment` split into `check_git`, `check_push`, `check_locked`
  and `check_writers` (it stays under the lizard ceilings).
- `integrator_name` defaults to `integrator-<repository>` (the main worktree's directory name,
  lower case, runs outside `[a-z0-9_-]` replaced by `-`, cut to 32 characters) instead of
  `integrator`. herdr agent names are unique per server, so with the old default a second
  project on the same server could not dispatch (`claim-integrator.sh` exit 3).
  `project-config.py` computes it (`default_integrator_name`), `template/scripts/integrator.sh`
  repeats the rule and gains `--print-name`, and the template settings file no longer writes
  the key. Existing projects with `"integrator_name": "integrator"` keep it;
  `/multi-agent-herdr:setup` offers to remove it, and `claim-integrator.sh` explains the fix
  when the name is taken.

## [0.1.0]

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
