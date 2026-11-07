#!/usr/bin/env bash
# PreToolUse guard for Edit / Write / NotebookEdit. Part of the multi-agent-herdr plugin
# (ported from multi-agent 0.1.0; only the plugin id and the block message differ).
#
# Only the integrator session may modify files in the *main* worktree (the original checkout,
# branch main). Development agents work in their own worktrees and reach main through pull
# requests (see "Multi-agent workflow" in CLAUDE.md). The integrator is recognised by the
# environment variable CLAUDE_ROLE=integrator, set by scripts/integrator.sh.
#
# The check is on the *target file*, not on the session's directory, so an agent sitting in a
# feature worktree is also stopped from editing the main checkout by absolute path. A file is
# in the main worktree when its repository's git dir equals the common git dir (linked
# worktrees have their own git dir under .git/worktrees/). Files outside any git repository,
# and repositories that did not enable the plugin in their .claude/settings(.local).json, are
# allowed. Exit code 2 blocks the tool call and shows stderr to the agent.
set -euo pipefail

[[ "${CLAUDE_ROLE:-}" == "integrator" ]] && exit 0

file=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
[[ -z "$file" ]] && exit 0

# New files may live in directories that do not exist yet: climb to the nearest one.
dir=$(dirname "$file")
while [[ ! -d "$dir" ]]; do dir=$(dirname "$dir"); done

git_dir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
common_dir=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0

repo_root=$(dirname "$common_dir")
grep -qs 'multi-agent-herdr@claude-code-herdr' \
    "$repo_root/.claude/settings.json" "$repo_root/.claude/settings.local.json" || exit 0

if [[ "$git_dir" == "$common_dir" ]]; then
    cat >&2 <<MSG
Blocked: $file is in the main worktree, which only the integrator session may modify.
Development happens in a worktree of its own, started by the integrator with
/multi-agent-herdr:dispatch (see "Multi-agent workflow" in CLAUDE.md). If you are the integrator, launch Claude Code
with scripts/integrator.sh (CLAUDE_ROLE=integrator).
MSG
    exit 2
fi
exit 0
