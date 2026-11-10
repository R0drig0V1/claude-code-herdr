#!/usr/bin/env bash
# SessionStart hook: give the integrator (or coordinator) session its herdr agent name from the start.
#
# Part of the multi-agent-herdr plugin. Development agents announce their PRs to the herdr
# agent named after `integrator_name` (scripts/claim-integrator.sh); in pool mode
# (docs/multi-integrator.md) they announce to the pool members and ask the coordinator.
# The launch scripts cannot rename that agent themselves: before `exec claude` there is no herdr agent yet. This hook
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
# Only inside herdr (HERDR_ENV=1), in a repository that enables the plugin, for
# CLAUDE_ROLE=integrator or coordinator in the main worktree, or CLAUDE_ROLE=integrator with
# MULTI_AGENT_HERDR_NAME set (a pool member, set by integrator-pool.sh) in a linked worktree;
# claim-integrator.sh then checks the role against the mode. Any other session gets nothing. Outcome, as
# additionalContext: exit 0 one line naming the session's herdr agent; exit 3 another live
# agent holds the name (ask the user); anything else a short warning. The hook always exits 0.
set -uo pipefail

role="${CLAUDE_ROLE:-}"
[[ ( "$role" == integrator || "$role" == coordinator ) && "${HERDR_ENV:-}" == 1 ]] || exit 0
member="${MULTI_AGENT_HERDR_NAME:-}"
[[ "$role" == integrator ]] || member=""

agent_id="" cwd=""
{ IFS= read -r agent_id; IFS= read -r cwd; } < <(jq -r '(.agent_id // ""), (.cwd // "")' 2>/dev/null)
[[ -z "$agent_id" ]] || exit 0   # subagent
[[ -n "$cwd" && -d "$cwd" ]] || exit 0

git_dir="" common_dir=""
{ IFS= read -r git_dir; IFS= read -r common_dir; } < <(git -C "$cwd" rev-parse --absolute-git-dir \
    --path-format=absolute --git-common-dir 2>/dev/null)
[[ -n "$git_dir" ]] || exit 0
# The main worktree belongs to the integrator (single mode) or the coordinator (pool mode); a
# linked worktree only to a pool member (its verify worktree).
if [[ "$git_dir" == "$common_dir" ]]; then member=""; else [[ -n "$member" ]] || exit 0; fi
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
            key=integrator_name
            [[ "$role" == coordinator ]] && key=coordinator_name
            if [[ -n "$member" ]]; then name=$member
            else
                name=$("$plugin_root/scripts/project-config.py" --root "$repo_root" "$key" \
                    2>/dev/null) || name="($key)"
            fi
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

case "$rc/$role/${member:+pool}" in
    0/integrator/) say "You are the herdr agent $name (the integrator): development agents announce their PRs to this name." ;;
    0/integrator/pool) say "You are the herdr agent $name, a member of the integrator pool working in its own verify worktree: claim, verify and merge PRs with /multi-agent-herdr:integrate; never touch the main worktree (the coordinator's)." ;;
    0/coordinator/) say "You are the herdr agent $name (the coordinator): you talk to the user, dispatch agents, own docs/phases/ and scale the integrator pool with /multi-agent-herdr:coordinate; integrators merge, you never do." ;;
    3/*) say "multi-agent-herdr: another live herdr agent already holds the $role name $name, so development agents' PR announcements go to it, not to you. claim-integrator.sh: $out
Do not integrate or dispatch until the user decides: ask the user whether to stop that agent or give this project its own name in .claude/multi-agent-herdr.json." ;;
    2/*) say "multi-agent-herdr: herdr has not detected this session yet, so it does not hold the name $name; a background retry claims it for up to 60 s (claim-integrator.sh: $out). /multi-agent-herdr:integrate and dispatch claim it again." ;;
    *) say "multi-agent-herdr warning: could not claim the herdr name $name (claim-integrator.sh exit $rc: $out). Development agents may not reach this session until /multi-agent-herdr:integrate or dispatch claims it." ;;
esac
