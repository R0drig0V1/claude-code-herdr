#!/usr/bin/env bash
# Make sure the calling session holds the herdr agent name of its role in this project.
#
# Part of the multi-agent-herdr plugin. Messages travel by herdr agent name, so each role's
# session must hold its name (project-config.py, .claude/multi-agent-herdr.json):
#
# - single mode (no `integrators` setting), CLAUDE_ROLE=integrator: `integrator_name`
#   (default `integrator-<repository>`), the name development agents announce PRs to.
# - pool mode, CLAUDE_ROLE=coordinator: `coordinator_name` (default `coordinator-<repository>`).
# - pool mode, CLAUDE_ROLE=integrator: the pool member name in $MULTI_AGENT_HERDR_NAME, which
#   must be one of `integrator_pool` (`<integrator_name>-<n>`); integrator-pool.sh sets it
#   when it spawns the member, and `herdr agent start` already gives the name, so this
#   normally finds it held.
#
# The launch scripts (scripts/integrator.sh, scripts/coordinator.sh) cannot name the herdr
# agent (it does not exist before `exec claude`). The SessionStart hook
# session-start-integrator.sh runs this as each such session starts; the dispatch, integrate
# and coordinate skills run it again first, as a fallback.
#
# Usage: claim-integrator.sh       (inside herdr, CLAUDE_ROLE=integrator or coordinator)
#
# Exit codes: 0 the caller holds the name (already, or renamed now); 1 wrong role or mode, not
# inside herdr or an invalid settings file; 2 the caller's pane or agent cannot be resolved; 3
# another live agent holds the name (herdr names are unique per server: ask the user). Needs
# herdr and jq.
set -euo pipefail

role="${CLAUDE_ROLE:-}"
[[ "$role" == integrator || "$role" == coordinator ]] \
    || { echo "only the integrator or the coordinator (CLAUDE_ROLE=integrator|coordinator)" >&2; exit 1; }
[[ "${HERDR_ENV:-}" == 1 ]] || { echo "not inside herdr (HERDR_ENV != 1)" >&2; exit 1; }
config=$("$(dirname "$0")/project-config.py") || exit 1
mode=$(jq -r .mode <<<"$config")

case "$role/$mode" in
    integrator/single) name=$(jq -r .integrator_name <<<"$config"); key=integrator_name ;;
    coordinator/pool) name=$(jq -r .coordinator_name <<<"$config"); key=coordinator_name ;;
    integrator/pool)
        name="${MULTI_AGENT_HERDR_NAME:-}"; key=integrator_name
        if ! jq -e --arg n "$name" '.integrator_pool | index($n)' <<<"$config" >/dev/null; then
            echo "pool mode: an integrator is a pool member started by integrator-pool.sh" \
                "(MULTI_AGENT_HERDR_NAME one of $(jq -r '.integrator_pool | join(", ")' <<<"$config")," \
                "got '${name}'); the main worktree belongs to the coordinator (scripts/coordinator.sh)" >&2
            exit 1
        fi ;;
    coordinator/single)
        echo "the coordinator exists only in pool mode (an \"integrators\" object in" \
            ".claude/multi-agent-herdr.json); in single mode launch scripts/integrator.sh" >&2
        exit 1 ;;
esac

# Not $HERDR_PANE_ID: it goes stale when a pane is moved; --current resolves the live pane.
pane=$(herdr pane current --current | jq -r '.result.pane.pane_id // empty')
[[ -n "$pane" ]] || { echo "cannot resolve the current herdr pane" >&2; exit 2; }

agents=$(herdr agent list)
jq -e --arg p "$pane" '.result.agents[] | select(.pane_id == $p)' <<<"$agents" >/dev/null \
    || { echo "no herdr agent detected in pane $pane" >&2; exit 2; }
mine=$(jq -r --arg p "$pane" '.result.agents[] | select(.pane_id == $p) | .name // empty' <<<"$agents")
if [[ "$mine" == "$name" ]]; then
    echo "$role: pane $pane (already named $name)"
    exit 0
fi

holder=$(jq -r --arg n "$name" '.result.agents[] | select(.name == $n) | "\(.pane_id) \(.cwd)"' <<<"$agents")
if [[ -n "$holder" ]]; then
    echo "the herdr name '$name' is held by pane ${holder%% *} (cwd ${holder#* });" \
        "herdr names are unique per server: give this project its own name with" \
        "\"$key\" in .claude/multi-agent-herdr.json (for example" \
        "\"${key%_name}-<repository>\", the default when the key is absent)," \
        "or run it on another herdr server" >&2
    exit 3
fi

herdr agent rename "$pane" "$name" >/dev/null
echo "$role: pane $pane (renamed to $name from '${mine:-unnamed}')"
