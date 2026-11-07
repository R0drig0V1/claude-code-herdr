#!/usr/bin/env bash
# Make sure the calling integrator session holds the project's integrator herdr agent name.
#
# Part of the multi-agent-herdr plugin. Development agents announce PRs to the herdr agent
# named after `integrator_name` in .claude/multi-agent-herdr.json (default
# `integrator-<repository>`;
# project-config.py), but scripts/integrator.sh can only name the Claude Code session, not the
# herdr agent. The `dispatch` and `integrate` skills run this first, so an agent dispatched
# right after launch can still reach the integrator.
#
# Usage: claim-integrator.sh       (inside herdr, CLAUDE_ROLE=integrator)
#
# Exit codes: 0 the caller holds the name (already, or renamed now); 1 not the integrator, not
# inside herdr or an invalid settings file; 2 the caller's pane or agent cannot be resolved; 3 another live agent
# holds the name (herdr names are unique per server, so there can be one integrator per herdr
# server: ask the user). Needs herdr and jq.
set -euo pipefail

[[ "${CLAUDE_ROLE:-}" == integrator ]] || { echo "only the integrator (CLAUDE_ROLE=integrator)" >&2; exit 1; }
[[ "${HERDR_ENV:-}" == 1 ]] || { echo "not inside herdr (HERDR_ENV != 1)" >&2; exit 1; }
name=$("$(dirname "$0")/project-config.py" integrator_name) || exit 1

# Not $HERDR_PANE_ID: it goes stale when a pane is moved; --current resolves the live pane.
pane=$(herdr pane current --current | jq -r '.result.pane.pane_id // empty')
[[ -n "$pane" ]] || { echo "cannot resolve the current herdr pane" >&2; exit 2; }

agents=$(herdr agent list)
jq -e --arg p "$pane" '.result.agents[] | select(.pane_id == $p)' <<<"$agents" >/dev/null \
    || { echo "no herdr agent detected in pane $pane" >&2; exit 2; }
mine=$(jq -r --arg p "$pane" '.result.agents[] | select(.pane_id == $p) | .name // empty' <<<"$agents")
if [[ "$mine" == "$name" ]]; then
    echo "integrator: pane $pane (already named $name)"
    exit 0
fi

holder=$(jq -r --arg n "$name" '.result.agents[] | select(.name == $n) | "\(.pane_id) \(.cwd)"' <<<"$agents")
if [[ -n "$holder" ]]; then
    echo "the herdr name '$name' is held by pane ${holder%% *} (cwd ${holder#* });" \
        "herdr names are unique per server: give this project its own name with" \
        "\"integrator_name\" in .claude/multi-agent-herdr.json (for example" \
        "\"integrator-<repository>\", the default when the key is absent)," \
        "or run its integrator on another herdr server" >&2
    exit 3
fi

herdr agent rename "$pane" "$name" >/dev/null
echo "integrator: pane $pane (renamed to $name from '${mine:-unnamed}')"
