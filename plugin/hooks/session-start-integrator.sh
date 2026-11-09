#!/usr/bin/env bash
# SessionStart hook: give the integrator session its herdr agent name from the start.
#
# Part of the multi-agent-herdr plugin. Development agents announce their PRs to the herdr
# agent named after `integrator_name` (scripts/claim-integrator.sh). scripts/integrator.sh
# cannot rename that agent itself: before `exec claude` there is no herdr agent yet. This hook
# runs inside the new session, on every SessionStart (startup, resume, clear, compact), so a
# relaunched or resumed integrator holds its name without waiting for /multi-agent-herdr:integrate
# or dispatch (which still claim it, as a fallback).
#
# herdr already lists the Claude agent of the pane when SessionStart hooks run (it detects the
# process before herdr's own Claude hook reports the session; measured with herdr 0.9.5), so the
# first attempt normally succeeds. The claim runs in a detached worker that retries exit 2
# ("no herdr agent detected in pane") every 2 s for up to 60 s; the hook itself waits at most
# about 0.8 s for the worker's first result, so session start is never blocked by herdr. Its
# own fixed cost is kept small (one jq, one git, the plugin_enabled check): the worker, not the
# hook, looks up integrator_name (project-config.py, a Python start-up) for the messages.
#
# Only for CLAUDE_ROLE=integrator inside herdr (HERDR_ENV=1), in the main worktree of a
# repository that enables the plugin; any other session gets nothing. Outcome, as
# additionalContext: exit 0 one line naming the session's herdr agent; exit 3 another live
# agent holds the name (ask the user); anything else a short warning. The hook always exits 0.
set -uo pipefail

[[ "${CLAUDE_ROLE:-}" == integrator && "${HERDR_ENV:-}" == 1 ]] || exit 0

agent_id="" cwd=""
{ IFS= read -r agent_id; IFS= read -r cwd; } < <(jq -r '(.agent_id // ""), (.cwd // "")' 2>/dev/null)
[[ -z "$agent_id" ]] || exit 0   # subagent
[[ -n "$cwd" && -d "$cwd" ]] || exit 0

git_dir="" common_dir=""
{ IFS= read -r git_dir; IFS= read -r common_dir; } < <(git -C "$cwd" rev-parse --absolute-git-dir \
    --path-format=absolute --git-common-dir 2>/dev/null)
[[ -n "$git_dir" && "$git_dir" == "$common_dir" ]] || exit 0   # a linked worktree is not the integrator's
repo_root=$(dirname "$common_dir")

# shellcheck source=plugin-enabled.sh
source "$(dirname "$0")/plugin-enabled.sh"
plugin_enabled "$repo_root" || exit 0

plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
claim="$plugin_root/scripts/claim-integrator.sh"

say() {  # say <context>
    jq -n --arg ctx "$1" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
    exit 0
}

status_dir=$(mktemp -d "${TMPDIR:-/tmp}/multi-agent-herdr-claim.XXXXXX") \
    || say "multi-agent-herdr: could not claim the integrator's herdr name (no temporary directory). Run \"\${CLAUDE_PLUGIN_ROOT}/scripts/claim-integrator.sh\" (or /multi-agent-herdr:integrate) before development agents announce PRs."

# The worker writes the first attempt's exit code, integrator_name and output to
# $status_dir/first (renamed into place, so the hook never reads half a file), then keeps
# retrying exit 2 alone. The hook owns $status_dir and removes it; later writes into a removed
# directory just fail.
(
    cd "$repo_root" || exit 0
    for attempt in $(seq 1 31); do
        out=$("$claim" 2>&1); rc=$?
        if [[ $attempt == 1 ]]; then
            name=$("$plugin_root/scripts/project-config.py" --root "$repo_root" integrator_name \
                2>/dev/null) || name="(integrator_name)"
            printf '%s\n%s\n%s\n' "$rc" "$name" "$out" > "$status_dir/first.tmp" 2>/dev/null \
                && mv -f "$status_dir/first.tmp" "$status_dir/first" 2>/dev/null
        fi
        [[ $rc == 2 ]] || break
        sleep 2
    done
) </dev/null >/dev/null 2>&1 &
disown

for _ in $(seq 1 16); do
    [[ -f "$status_dir/first" ]] && break
    sleep 0.05
done
if [[ ! -f "$status_dir/first" ]]; then
    rm -rf "$status_dir"
    say "multi-agent-herdr: claiming the integrator's herdr name (integrator_name) is still running in the background (herdr answered slowly). Check with \`herdr agent list\`; /multi-agent-herdr:integrate and dispatch claim it again."
fi
{ IFS= read -r rc; IFS= read -r name; out=$(cat); } < "$status_dir/first"
rm -rf "$status_dir"

case "$rc" in
    0) say "You are the herdr agent $name (the integrator): development agents announce their PRs to this name." ;;
    3) say "multi-agent-herdr: another live herdr agent already holds the integrator name $name, so development agents' PR announcements go to it, not to you. claim-integrator.sh: $out
Do not integrate or dispatch until the user decides: ask the user whether to stop that agent or give this project its own integrator_name." ;;
    2) say "multi-agent-herdr: herdr has not detected this session yet, so it does not hold the name $name; a background retry claims it for up to 60 s (claim-integrator.sh: $out). /multi-agent-herdr:integrate and dispatch claim it again." ;;
    *) say "multi-agent-herdr warning: could not claim the herdr name $name (claim-integrator.sh exit $rc: $out). Development agents may not reach this session until /multi-agent-herdr:integrate or dispatch claims it." ;;
esac
