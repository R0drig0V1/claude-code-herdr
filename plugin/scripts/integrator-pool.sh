#!/usr/bin/env bash
# Manage the integrator pool: list, route an announcement, spawn, stop and scale its members.
#
# Part of the multi-agent-herdr plugin (docs/multi-integrator.md). In pool mode (an
# `integrators` object in .claude/multi-agent-herdr.json) the coordinator owns the main
# worktree and integrators `<integrator_name>-<n>` (n = 1..integrators.max) merge in parallel,
# each in its own herdr workspace and its own verify worktree
# `../<worktree_prefix>integrator-<n>`, detached at origin/<base_branch>.
#
# Usage:
#   integrator-pool.sh list            one line per member: n name status worktree claims idle-s
#   integrator-pool.sh route           the integrator the `pr` skill announces to (both modes):
#                                      prints "<name>\t<status>"; exit 1 none live, 3 all blocked
#   integrator-pool.sh desired         the rule-of-thumb member count (see below), one line
#   integrator-pool.sh scale           the facts the coordinator weighs before it spawns or stops a
#                                      member (live members and their load, the open queue,
#                                      development agents, the machine), and a suggestion
#   integrator-pool.sh spawn <n>       create the verify worktree if missing, open its workspace,
#                                      start the agent and send it its kickoff message
#   integrator-pool.sh stop <n> [--remove-worktree]
#                                      close the workspace of an idle member that holds no
#                                      claim; with --remove-worktree also discard its verify
#                                      worktree (when the pool shrinks for good), else it is
#                                      kept so the next spawn reuses its dependencies
#
# Scaling is the coordinator's decision, taken in conversation (docs/multi-integrator.md,
# "Scaling"): it asks the members about their load, reads the resource board
# (resource-board.sh) and then runs spawn or stop. `scale` only gathers the facts and prints a
# suggestion: ceil(development agents / integrators.scale_up_when_active_agents_gt) within
# [min, max] (a rule of thumb, not a policy), plus the members that have been idle for
# integrators.scale_down_idle_minutes. "Development agents" are the live herdr agents in a
# linked worktree of this repository that is on a branch (agents-in-repo.py --dev-only).
# `max` is the one hard bound: spawn refuses a number above it.
#
# spawn and stop act on herdr workspaces, so inside Claude Code only the
# coordinator (CLAUDE_ROLE=coordinator) may run them; the user may run them from a shell. stop
# only closes a workspace this script opened (it records it under the pool's state directory).
#
# Exit codes: 0 ok; 1 usage, settings, wrong mode or role; 2 herdr or git failed; 3 route: every
# live integrator is blocked; 4 spawn: the agent waits at a startup dialog (tell the user); 5
# stop: the member is busy or was not started by this script. Needs git, herdr, jq, python3.
set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
die() { echo "integrator-pool: $*" >&2; exit "${2:-1}"; }
config=$("$dir/project-config.py") || exit 1
cfg() { jq -r "$1" <<<"$config"; }
mode=$(cfg .mode)
main=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
state="$(git rev-parse --path-format=absolute --git-common-dir)/multi-agent-herdr"
mkdir -p "$state/members"

need_pool() { [[ "$mode" == pool ]] || die "single-integrator mode (no \"integrators\" in .claude/multi-agent-herdr.json)"; }
may_act() {
    if [[ "${CLAUDECODE:-}" == 1 && "${CLAUDE_ROLE:-}" != coordinator ]]; then
        die "only the coordinator (CLAUDE_ROLE=coordinator) manages the pool from Claude Code"
    fi
    [[ "${HERDR_ENV:-}" == 1 ]] || die "not inside herdr (HERDR_ENV != 1)"
}
member_name() { cfg ".integrator_pool[$(($1 - 1))] // empty"; }
member_worktree() { printf '%s/%sintegrator-%s\n' "$(dirname "$main")" "$(cfg .worktree_prefix)" "$1"; }
valid_n() { [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le "$(cfg .integrators.max)" ]] || die "member number must be 1..$(cfg .integrators.max)"; }

# Live members: "<name>\t<status>" for pool members whose pane is in a detached worktree here.
live_members() {
    local names
    names=$(cfg '.integrator_pool | join(" ")')
    "$dir/agents-in-repo.py" --detached | while IFS=$'\t' read -r name _pane status _branch _wt; do
        [[ " $names " == *" $name "* ]] && printf '%s\t%s\n' "$name" "$status"
    done
    return 0
}
status_of() { live_members | awk -F'\t' -v n="$1" '$1 == n { print $2 }'; }
claims_of() { "$dir/pool-state.py" claims | awk -F'\t' -v n="$1" '$2 == n { printf "%s#%s", sep, $1; sep = "," }'; }

cmd_route() {
    local lines name status best="" best_rank=9 blocked=0 rank
    if [[ "$mode" == single ]]; then
        name=$(cfg .integrator_name)
        lines=$("$dir/agents-in-repo.py" --name "$name" --main-worktree) || exit 2
        [[ -n "$lines" ]] || die "no live integrator $name in this repository's main worktree" 1
        status=$(cut -f3 <<<"${lines%%$'\n'*}")
        [[ "$status" != blocked ]] || die "the integrator $name is blocked at a dialog" 3
        printf '%s\t%s\n' "$name" "$status"; return 0
    fi
    lines=$(live_members) || exit 2
    [[ -n "$lines" ]] || die "no live pool integrator; the open PRs wait for the next one that starts" 1
    # Pool order is the tie-break: the first idle member, else the first working one.
    for name in $(cfg '.integrator_pool[]'); do
        status=$(awk -F'\t' -v n="$name" '$1 == n { print $2 }' <<<"$lines")
        case "$status" in
            "") continue ;;
            idle|done) rank=0 ;;
            blocked) blocked=$((blocked + 1)); continue ;;
            *) rank=1 ;;
        esac
        if [[ $rank -lt $best_rank ]]; then best="$name"; best_rank=$rank; fi
    done
    [[ -n "$best" ]] || die "every live pool integrator ($blocked) is blocked at a dialog" 3
    printf '%s\t%s\n' "$best" "$(awk -F'\t' -v n="$best" '$1 == n { print $2 }' <<<"$lines")"
}

desired() {  # prints "<desired> <development agents> <live members>"
    local dev gt min max want live
    dev=$("$dir/agents-in-repo.py" --dev-only | grep -c . || true)
    gt=$(cfg .integrators.scale_up_when_active_agents_gt)
    min=$(cfg .integrators.min); max=$(cfg .integrators.max)
    want=$(( (dev + gt - 1) / gt ))
    (( want < min )) && want=$min
    (( want > max )) && want=$max
    live=$(live_members | grep -c . || true)
    echo "$want $dev $live"
}

cmd_list() {
    need_pool
    local n name status claims idle
    for ((n = 1; n <= $(cfg .integrators.max); n++)); do
        name=$(member_name "$n")
        status=$(status_of "$name"); claims=$(claims_of "$name")
        idle=$("$dir/pool-state.py" idle-seconds "$name")
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$name" "${status:-down}" "$(member_worktree "$n")" "${claims:--}" "$idle"
    done
}

ensure_worktree() {  # ensure_worktree <path>: a detached verify worktree at origin/<base>
    local wt="$1" base
    base=$(cfg .base_branch)
    if [[ -d "$wt" ]]; then
        git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$wt exists and is not a worktree" 2
        [[ "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" == "$(git -C "$main" rev-parse --path-format=absolute --git-common-dir)" ]] \
            || die "$wt belongs to another repository" 2
        git -C "$wt" symbolic-ref -q HEAD >/dev/null && die "$wt is on a branch; a verify worktree must be detached" 2
        return 0
    fi
    git -C "$main" fetch --quiet origin "$base" || die "git fetch origin $base failed" 2
    git -C "$main" worktree add --quiet --detach "$wt" "origin/$base" || die "git worktree add $wt failed" 2
    [[ -f "$main/.env" ]] && cp "$main/.env" "$wt/.env"
    if [[ -x "$wt/scripts/worktree-setup.sh" ]]; then
        (cd "$wt" && "$dir/resource-budget.py" run --label "worktree-setup $wt" -- scripts/worktree-setup.sh "$base") \
            || echo "warning: scripts/worktree-setup.sh failed in $wt; the member's first verification reruns it" >&2
    fi
}

cmd_spawn() {
    need_pool; may_act
    local n="$1" name wt out ws pane prompt_file coordinator rc kickoff args
    valid_n "$n"
    name=$(member_name "$n"); wt=$(member_worktree "$n")
    if [[ -n "$(status_of "$name")" ]]; then echo "$name is already running"; return 0; fi
    herdr agent list | jq -e --arg n "$name" '.result.agents[] | select(.name == $n)' >/dev/null \
        && die "the herdr name $name is held by an agent outside this repository's verify worktrees" 2
    ensure_worktree "$wt"
    out=$(herdr workspace create --cwd "$wt" --label "$name" --no-focus \
        --env CLAUDE_ROLE=integrator --env "MULTI_AGENT_HERDR_NAME=$name") || die "herdr workspace create failed" 2
    ws=$(jq -r '.result.workspace.workspace_id' <<<"$out"); pane=$(jq -r '.result.root_pane.pane_id' <<<"$out")
    jq -n --arg name "$name" --argjson n "$n" --arg ws "$ws" --arg pane "$pane" --arg wt "$wt" \
        '{name: $name, n: $n, workspace_id: $ws, pane_id: $pane, worktree: $wt, spawned_at: now}' \
        > "$state/members/$name.json"
    "$dir/pool-state.py" activity "$name"
    args=(--name "$name")
    prompt_file="$main/.claude/prompts/integrator.md"
    [[ -f "$prompt_file" ]] && args+=(--append-system-prompt-file "$prompt_file")
    rc=0; out=$(herdr agent start "$name" --kind claude --pane "$pane" -- "${args[@]}" 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
        if grep -q agent_not_ready <<<"$out"; then
            die "$name (workspace $ws) waits at a startup dialog: tell the user; do not answer it" 4
        fi
        die "herdr agent start $name failed: $out" 2
    fi
    coordinator="${MULTI_AGENT_HERDR_NAME:-$(cfg .coordinator_name)}"
    kickoff="[herdr message from agent $coordinator; not from the user]
You are $name, member $n of the integrator pool of $(basename "$main"), in your own verify worktree $wt (detached at origin/$(cfg .base_branch); never touch the main worktree $main, it is the coordinator's).
Run /multi-agent-herdr:integrate now: claim the oldest unclaimed PR, review it, merge it with integrate-pr.sh, send the verdict to its author and the merge report to $coordinator. When the queue is empty, stay idle: announcements wake you up."
    herdr agent prompt "$name" "$kickoff" >/dev/null || die "the kickoff prompt to $name failed" 2
    echo "spawned $name: workspace $ws, pane $pane, worktree $wt"
}

cmd_stop() {
    need_pool; may_act
    local n="$1" name record ws pane status held
    valid_n "$n"
    name=$(member_name "$n"); record="$state/members/$name.json"
    [[ -f "$record" ]] || die "$name was not started by integrator-pool.sh (no $record): not closing it" 5
    ws=$(jq -r .workspace_id "$record"); pane=$(jq -r .pane_id "$record")
    status=$(status_of "$name")
    if [[ -n "$status" ]]; then
        [[ "$status" == idle || "$status" == "done" ]] || die "$name is $status, not idle: not stopping it" 5
        held=$(claims_of "$name")
        [[ -z "$held" ]] || die "$name holds the claim(s) $held: not stopping it" 5
        herdr agent list | jq -e --arg n "$name" --arg p "$pane" \
            '.result.agents[] | select(.name == $n and .pane_id == $p)' >/dev/null \
            || die "$name no longer runs in pane $pane of workspace $ws: not closing it" 5
    fi
    herdr workspace close "$ws" >/dev/null || die "herdr workspace close $ws failed" 2
    rm -f "$record"
    if [[ "${2:-}" == --remove-worktree ]]; then
        local wt; wt=$(member_worktree "$n")
        if [[ -d "$wt" ]]; then
            git -C "$main" worktree remove "$wt" || die "stopped $name, but git worktree remove $wt failed (uncommitted files?)" 2
        fi
        echo "stopped $name (closed workspace $ws, removed its verify worktree $wt)"
    else
        echo "stopped $name (closed workspace $ws; its worktree $(member_worktree "$n") is kept for reuse)"
    fi
}

cmd_scale() {
    need_pool
    local want dev live n name status idle limit queue claims note
    read -r want dev live <<<"$(desired)"
    queue=$("$dir/pool-state.py" queue --base "$(cfg .base_branch)" 2>/dev/null | grep -c . || true)
    limit=$(( $(cfg .integrators.scale_down_idle_minutes) * 60 ))
    echo "facts: $live live member(s) (min $(cfg .integrators.min), max $(cfg .integrators.max)); $queue claimable open PR(s); $dev development agent(s)"
    for ((n = 1; n <= $(cfg .integrators.max); n++)); do
        name=$(member_name "$n"); status=$(status_of "$name")
        [[ -n "$status" ]] || continue
        idle=$("$dir/pool-state.py" idle-seconds "$name"); claims=$(claims_of "$name")
        note=""
        if [[ ( "$status" == idle || "$status" == "done" ) && -z "$claims" && $idle -ge $limit ]]; then
            note=" (idle long enough to stop)"
        fi
        echo "  $name: $status, claims ${claims:--}, inactive $((idle / 60)) min$note"
    done
    echo "suggestion: $want member(s) (one per $(cfg .integrators.scale_up_when_active_agents_gt) development agents); weigh it against the queue, what the members say about their load and the resource board (resource-board.sh show), then spawn or stop"
}

case "${1:-}" in
    list) cmd_list ;;
    route) cmd_route ;;
    desired) need_pool; read -r want dev live <<<"$(desired)"; echo "desired=$want development_agents=$dev live=$live" ;;
    scale) cmd_scale ;;
    spawn) [[ $# == 2 ]] || die "usage: integrator-pool.sh spawn <n>"; cmd_spawn "$2" ;;
    stop) [[ $# == 2 || ( $# == 3 && "$3" == --remove-worktree ) ]] \
              || die "usage: integrator-pool.sh stop <n> [--remove-worktree]"; cmd_stop "$2" "${3:-}" ;;
    *) sed -n '10,22p' "$0" >&2; exit 1 ;;
esac
