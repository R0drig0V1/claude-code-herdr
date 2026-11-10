#!/usr/bin/env bash
# PreToolUse guard for Edit / Write / NotebookEdit. Part of the multi-agent-herdr plugin
# (ported from multi-agent 0.1.0; only the plugin id and the block message differ).
#
# Only the integrator session may modify files in the *main* worktree (the original checkout,
# branch main). Development agents work in their own worktrees and reach main through pull
# requests (see "Multi-agent workflow" in CLAUDE.md). The integrator is recognised by the
# environment variable CLAUDE_ROLE=integrator, set by scripts/integrator.sh. In pool mode (an
# `integrators` object in .claude/multi-agent-herdr.json, docs/multi-integrator.md) the main
# worktree belongs to the coordinator (CLAUDE_ROLE=coordinator, scripts/coordinator.sh)
# instead; the pool's integrators work in their own verify worktrees and are blocked here
# like any other session. An invalid settings file counts as single mode.
#
# The check is on the *target file*, not on the session's directory, so an agent sitting in a
# feature worktree is also stopped from editing the main checkout by absolute path. A file is
# in the main worktree when its repository's git dir equals the common git dir (linked
# worktrees have their own git dir under .git/worktrees/). Files outside any git repository,
# and repositories that did not enable the plugin in their .claude/settings(.local).json
# (plugin-enabled.sh), are
# allowed. Exit code 2 blocks the tool call and shows stderr to the agent.
set -euo pipefail

role="${CLAUDE_ROLE:-}"

file=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
[[ -z "$file" ]] && exit 0

# New files may live in directories that do not exist yet: climb to the nearest one.
dir=$(dirname "$file")
while [[ ! -d "$dir" ]]; do dir=$(dirname "$dir"); done

git_dir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
common_dir=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0

repo_root=$(dirname "$common_dir")
# shellcheck source=plugin-enabled.sh
source "$(dirname "$0")/plugin-enabled.sh"
plugin_enabled "$repo_root" || exit 0

if [[ "$git_dir" == "$common_dir" ]]; then
    if [[ "$role" == integrator || "$role" == coordinator ]]; then
        mode=$("$(dirname "$0")/../scripts/project-config.py" --root "$repo_root" mode 2>/dev/null) || mode=single
        [[ "$role/$mode" == integrator/single || "$role/$mode" == coordinator/pool ]] && exit 0
    fi
    cat >&2 <<MSG
Blocked: $file is in the main worktree, which only the integrator session may modify.
Development happens in a worktree of its own, started by the integrator with
/multi-agent-herdr:dispatch (see "Multi-agent workflow" in CLAUDE.md). If you are the integrator, launch Claude Code
with scripts/integrator.sh (CLAUDE_ROLE=integrator); in pool mode the main worktree is the
coordinator's (scripts/coordinator.sh) and integrators work in their own verify worktrees.
MSG
    exit 2
fi
exit 0
