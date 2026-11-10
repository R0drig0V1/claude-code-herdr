#!/usr/bin/env bash
# Launch the coordinator session (pool mode only): the session the user talks to. It plans,
# dispatches development agents, owns docs/phases/ and scales the integrator pool; it never
# merges (see "Multi-agent workflow" in CLAUDE.md and the plugin's docs/multi-integrator.md).
#
# Usage: scripts/coordinator.sh [extra claude arguments]
#        scripts/coordinator.sh --print-name   (print the coordinator's herdr name and exit)
#
# - Pool mode is on when .claude/multi-agent-herdr.json has an "integrators" object; without
#   one, launch scripts/integrator.sh instead (single-integrator mode).
# - Runs in the main worktree whatever directory it is called from, and requires herdr
#   (HERDR_ENV=1). The plugin's SessionStart hook gives the session its herdr name,
#   `coordinator_name` (default `coordinator-<repository directory name>`, see default_name
#   below); --name names the Claude Code session the same way.
# - CLAUDE_ROLE=coordinator lets the session change the main worktree in pool mode (the guard
#   hooks), and push the base branch only under the plugin's merge lock (plan commits).
# - Appends .claude/prompts/coordinator.md to Claude Code's default system prompt, as
#   scripts/integrator.sh does for the integrator.
set -euo pipefail

repo_root=$(dirname "$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)")
cd "$repo_root"
# The plugin's default_coordinator_name (scripts/project-config.py), repeated here because
# this script belongs to the project and cannot reach the plugin; the plugin's tests check
# that both agree. Same rule as integrator.sh's default_name, with the "coordinator" prefix.
default_name() {
    local slug name
    slug=$(basename "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
        | LC_ALL=C sed -E 's/[^a-z0-9_-]+/-/g; s/^[-_]+//; s/[-_]+$//')
    [[ -n "$slug" ]] || { echo coordinator; return; }
    name="coordinator-$slug"
    name=${name:0:32}
    printf '%s\n' "$name" | sed -E 's/[-_]+$//'
}
name=$(default_name "$repo_root")
settings=.claude/multi-agent-herdr.json
pool=false
if [[ -f "$settings" ]]; then
    name=$(jq -r --arg d "$name" '.coordinator_name // $d' "$settings") \
        || { echo "invalid $settings" >&2; exit 1; }
    [[ "$(jq -r '.integrators | type' "$settings")" == object ]] && pool=true
fi
if [[ "${1:-}" == --print-name ]]; then  # used by the plugin's tests; launches nothing
    echo "$name"
    exit 0
fi
$pool || { echo "single-integrator mode (no \"integrators\" in $settings): run scripts/integrator.sh" >&2; exit 1; }
[[ "${HERDR_ENV:-}" == 1 ]] || { echo "run it inside a herdr pane (multi-agent-herdr is herdr only)" >&2; exit 1; }
CLAUDE_ROLE=coordinator exec claude --name "$name" \
    --append-system-prompt-file "$repo_root/.claude/prompts/coordinator.md" "$@"
