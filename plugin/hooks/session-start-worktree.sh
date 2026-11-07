#!/usr/bin/env bash
# SessionStart hook: tell development sessions opened in the main worktree not to develop there.
#
# Part of the multi-agent-herdr plugin (ported from multi-agent 0.1.0's hook of the same name).
# The main worktree (the original checkout, branch main) belongs to the integrator (see
# "Multi-agent workflow" in CLAUDE.md). In this plugin development agents do not create their
# own worktree from here: the integrator starts each one with /multi-agent-herdr:dispatch,
# already inside its own worktree and its own herdr workspace, because the integrator finds an
# agent by the cwd of its herdr pane (EnterWorktree would leave that cwd in the main worktree).
# A session started here without CLAUDE_ROLE=integrator therefore gets instructions injected
# into its context: read and answer freely, but route any change through the integrator.
#
# Sessions already in a linked worktree, outside a git repository, in a repository that did not
# enable the plugin, or the integrator get nothing. The hook never fails the session: any error
# just skips the instructions.
set -uo pipefail

[[ "${CLAUDE_ROLE:-}" == "integrator" ]] && exit 0

cwd=$(jq -r '.cwd // empty' 2>/dev/null)
[[ -z "$cwd" || ! -d "$cwd" ]] && exit 0

git_dir=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
common_dir=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
[[ "$git_dir" != "$common_dir" ]] && exit 0   # already in a linked worktree

repo_root=$(dirname "$common_dir")

# Only projects that enabled the plugin follow the workflow (a user-scope install must not
# affect every repository's sessions).
grep -qs 'multi-agent-herdr@claude-code-herdr' \
    "$repo_root/.claude/settings.json" "$repo_root/.claude/settings.local.json" || exit 0

read -r -d '' context <<MSG
This session started in the MAIN worktree ($repo_root), which only the integrator may modify
(CLAUDE.md, "Multi-agent workflow"). Questions and reading code are fine here.

Do not change files, commit, switch branches or push from here: hooks block it. When the
user's request needs changes, tell them in one line that development agents are started by
the integrator agent with /multi-agent-herdr:dispatch <type>/<short-kebab-name> <task>, which
creates the worktree and opens a new agent in its own herdr workspace, and suggest the branch
name (type: feat, fix, docs, chore, refactor, test). Do not create a worktree or call
EnterWorktree yourself.
MSG

jq -n --arg ctx "$context" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
