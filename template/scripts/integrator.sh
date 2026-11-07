#!/usr/bin/env bash
# Launch the integrator session: the only session that may change the base branch and the main
# worktree (see "Multi-agent workflow" in CLAUDE.md).
#
# Usage: scripts/integrator.sh [extra claude arguments]
#        scripts/integrator.sh --print-name   (print the integrator's herdr name and exit)
#
# - Runs in the main worktree whatever directory it is called from.
# - Requires herdr (HERDR_ENV=1): development agents reach the integrator as the herdr agent
#   named after `integrator_name` in .claude/multi-agent-herdr.json (default
#   `integrator-<repository directory name>`, see default_name below), which
#   /multi-agent-herdr:integrate takes on its first run.
# - CLAUDE_ROLE=integrator exempts the session from the guard hooks.
# - --name <integrator_name> names the Claude Code session the same way (read with jq when
#   the settings file exists; this script belongs to the project and cannot reach the plugin).
# - Appends .claude/prompts/integrator.md (the adversarial-auditor stance) to Claude Code's
#   default system prompt. Appended rather than `--agent`, which would replace the default
#   prompt: the integrator keeps the standard tool and git-safety instructions, CLAUDE.md
#   and the project skills (/integrate is its procedure).
set -euo pipefail

repo_root=$(dirname "$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)")
cd "$repo_root"
[[ "${HERDR_ENV:-}" == 1 ]] || { echo "run it inside a herdr pane (multi-agent-herdr is herdr only)" >&2; exit 1; }
# The plugin's default_integrator_name (scripts/project-config.py), repeated here because
# this script belongs to the project and cannot reach the plugin; the plugin's tests check
# that both agree. Lower case, runs outside [a-z0-9_-] become '-', '-'/'_' trimmed at both
# ends, cut to herdr's 32 characters.
default_name() {
    local slug name
    slug=$(basename "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
        | LC_ALL=C sed -E 's/[^a-z0-9_-]+/-/g; s/^[-_]+//; s/[-_]+$//')
    [[ -n "$slug" ]] || { echo integrator; return; }
    name="integrator-$slug"
    name=${name:0:32}
    printf '%s\n' "$name" | sed -E 's/[-_]+$//'
}
name=$(default_name "$repo_root")
if [[ -f .claude/multi-agent-herdr.json ]]; then
    name=$(jq -r --arg d "$name" '.integrator_name // $d' .claude/multi-agent-herdr.json) \
        || { echo "invalid .claude/multi-agent-herdr.json" >&2; exit 1; }
fi
if [[ "${1:-}" == --print-name ]]; then  # used by the plugin's tests; launches nothing
    echo "$name"
    exit 0
fi
CLAUDE_ROLE=integrator exec claude --name "$name" \
    --append-system-prompt-file "$repo_root/.claude/prompts/integrator.md" "$@"
