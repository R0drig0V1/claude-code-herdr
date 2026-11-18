#!/usr/bin/env bash
# SessionStart hook: check the project's copy of the workflow rules, and tell development
# sessions opened in the main worktree not to develop there.
#
# Part of the multi-agent-herdr plugin (the main-worktree part is ported from multi-agent
# 0.1.0's session-start-worktree.sh). Only repositories that enable the plugin are touched.
#
# 1. Workflow rules. The rules live in the project, in .claude/multi-agent-herdr-workflow.md,
#    imported by CLAUDE.md, so Claude Code loads them in every session and subagent without
#    depending on this hook. That copy comes from the plugin (context/workflow.md) and goes
#    stale when the plugin changes. When the copy in this worktree is missing or differs from
#    the installed plugin's, the session is told to mention it to the user once and point to
#    /multi-agent-herdr:setup. The hook never rewrites the file: the update goes through a PR.
# 2. Main worktree. It belongs to the integrator (see .claude/multi-agent-herdr-workflow.md).
#    Development agents do not create their own worktree from here: the integrator starts each
#    one with /multi-agent-herdr:dispatch, already inside its own worktree and herdr workspace,
#    because the integrator finds an agent by the cwd of its herdr pane. A session started
#    here without CLAUDE_ROLE=integrator is told to read freely but route changes through it.
#
# Outside a git repository or in a repository that did not enable the plugin the hook prints
# nothing. It never fails the session: any error just skips the instructions.
set -uo pipefail

cwd=$(jq -r '.cwd // empty' 2>/dev/null)
[[ -z "$cwd" || ! -d "$cwd" ]] && exit 0

git_dir=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
common_dir=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
worktree_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
repo_root=$(dirname "$common_dir")

# Only projects that enabled the plugin follow the workflow (a user-scope install must not
# affect every repository's sessions).
# shellcheck source=plugin-enabled.sh
source "$(dirname "$0")/plugin-enabled.sh"
plugin_enabled "$repo_root" || exit 0

context=""

rules_rel=".claude/multi-agent-herdr-workflow.md"
plugin_rules="$(dirname "$0")/../context/workflow.md"
if [[ -f "$plugin_rules" ]]; then
    state=""
    if [[ ! -f "$worktree_root/$rules_rel" ]]; then
        state="is missing"
    elif ! cmp -s "$plugin_rules" "$worktree_root/$rules_rel"; then
        state="differs from the installed multi-agent-herdr plugin's version"
    fi
    if [[ -n "$state" ]]; then
        context+="The workflow rules file $rules_rel $state. Tell the user once, in one line,
that /multi-agent-herdr:setup brings it up to date (the change goes through a pull request
like any other), or that the plugin itself may be the outdated side (/plugin to update it).
Until then follow the rules CLAUDE.md loads. Do not edit that file yourself."
    fi
fi

if [[ "${CLAUDE_ROLE:-}" != "integrator" && "$git_dir" == "$common_dir" ]]; then
    [[ -n "$context" ]] && context+=$'\n\n'
    context+="This session started in the MAIN worktree ($repo_root), which only the integrator may modify
($rules_rel, \"Multi-agent workflow\"). Questions and reading code are fine here.

Do not change files, commit, switch branches or push from here: hooks block it. When the
user's request needs changes, tell them in one line that development agents are started by
the integrator agent with /multi-agent-herdr:dispatch <type>/<short-kebab-name> <task>, which
creates the worktree and opens a new agent in its own herdr workspace, and suggest the branch
name (type: feat, fix, docs, chore, refactor, test). Do not create a worktree or call
EnterWorktree yourself."
fi

[[ -z "$context" ]] && exit 0
jq -n --arg ctx "$context" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
