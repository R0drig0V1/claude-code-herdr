#!/usr/bin/env bash
# The resource board: a shared, human-readable sheet of what every agent runs on this machine.
#
# Part of the multi-agent-herdr plugin (docs/multi-integrator.md, "Resources"). Resources are
# negotiated, not computed: before an agent starts something heavy or long-lived (a full test
# suite, a build, a container, a dev server, a watcher), it writes one line about it here;
# when it stops, it clears the line. The coordinator reads the board to grant turns, set
# priorities, declare save mode and decide how many integrators the machine can carry, and the
# user reads it to see what is eating the computer. The hard floor underneath is
# resource-budget.py (at most `heavy_slots` heavy commands at once), whose current holders the
# board also shows.
#
# The board is machine-wide (every project of the user), one file per agent under
# ${MULTI_AGENT_HERDR_RESOURCES_DIR:-~/.cache/multi-agent-herdr/resources}/board/, so agents
# never overwrite each other's lines.
#
# Usage:
#   resource-board.sh note "<what>" [--gb N] [--minutes M] [--as NAME]
#                                   write (or replace) your line: what you run, an estimate of
#                                   its memory, and how long you expect it to last
#   resource-board.sh clear [--as NAME]      remove your line (when it stopped)
#   resource-board.sh show          the sheet, as Markdown: memory, heavy slots, notes, live
#                                   agents and the ones that look idle
#   resource-board.sh prune         remove the lines of agents that are no longer live
#
# Your name is --as, else $MULTI_AGENT_HERDR_NAME, else your herdr agent name (from the live
# pane), else "<user>-shell". Exit codes: 0 ok; 1 usage. Needs jq; herdr for the agent list
# (without it the board just says so).
set -uo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
state="${MULTI_AGENT_HERDR_RESOURCES_DIR:-$HOME/.cache/multi-agent-herdr/resources}"
board="$state/board"
mkdir -p "$board" || { echo "resource-board: cannot create $board" >&2; exit 1; }
usage() { sed -n '17,26p' "$0" >&2; exit 1; }

me() {  # me <--as value>: the name this line belongs to
    local pane name
    [[ -n "$1" ]] && { echo "$1"; return; }
    [[ -n "${MULTI_AGENT_HERDR_NAME:-}" ]] && { echo "$MULTI_AGENT_HERDR_NAME"; return; }
    if [[ "${HERDR_ENV:-}" == 1 ]]; then
        pane=$(herdr pane current --current 2>/dev/null | jq -r '.result.pane.pane_id // empty')
        name=$(herdr agent list 2>/dev/null | jq -r --arg p "$pane" '.result.agents[] | select(.pane_id == $p) | .name // empty')
        [[ -n "$name" ]] && { echo "$name"; return; }
    fi
    echo "${USER:-user}-shell"
}
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "resource-board: invalid name '$1'" >&2; exit 1; }; }

memory() {  # prints "<total GB> <available GB>" (available empty when unknown)
    local total avail page
    if [[ "$(uname)" == Darwin ]]; then
        total=$(sysctl -n hw.memsize 2>/dev/null)
        page=$(vm_stat 2>/dev/null | sed -n 's/.*page size of \([0-9]*\).*/\1/p')
        avail=$(vm_stat 2>/dev/null | awk -v pg="${page:-4096}" \
            '/^Pages (free|inactive|speculative):/ { gsub(/\./, "", $NF); n += $NF } END { if (n) print n * pg }')
    else
        total=$(awk '/^MemTotal:/ { print $2 * 1024 }' /proc/meminfo 2>/dev/null)
        avail=$(awk '/^MemAvailable:/ { print $2 * 1024 }' /proc/meminfo 2>/dev/null)
    fi
    awk -v t="${total:-0}" -v a="${avail:-}" 'BEGIN {
        printf "%.1f %s\n", t / 2^30, (a == "" ? "" : sprintf("%.1f", a / 2^30)) }'
}

ago() { awk -v s="$1" -v now="$(date +%s)" 'BEGIN { m = int((now - s) / 60); printf (m < 60 ? "%d min" : "%.1f h"), (m < 60 ? m : m / 60) }'; }

cmd_note() {
    local what="" gb="" minutes="" as="" name
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gb) gb="${2:-}"; shift 2 ;;
            --minutes) minutes="${2:-}"; shift 2 ;;
            --as) as="${2:-}"; shift 2 ;;
            -*) usage ;;
            *) [[ -z "$what" ]] || usage; what="$1"; shift ;;
        esac
    done
    [[ -n "$what" ]] || usage
    [[ -z "$gb" || "$gb" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "resource-board: --gb must be a number" >&2; exit 1; }
    [[ -z "$minutes" || "$minutes" =~ ^[0-9]+$ ]] || { echo "resource-board: --minutes must be an integer" >&2; exit 1; }
    name=$(me "$as"); valid_name "$name"
    jq -n --arg agent "$name" --arg what "$what" --arg gb "$gb" --arg minutes "$minutes" \
        --arg cwd "$PWD" --argjson now "$(date +%s)" \
        '{agent: $agent, what: $what, gb: $gb, cwd: $cwd, since: $now,
          until: (if $minutes == "" then null else $now + ($minutes | tonumber) * 60 end)}' \
        > "$board/$name.json.tmp" && mv -f "$board/$name.json.tmp" "$board/$name.json"
    echo "noted for $name: $what"
}

cmd_clear() {
    local as="" name
    [[ "${1:-}" == --as ]] && as="${2:-}"
    name=$(me "$as"); valid_name "$name"
    rm -f "$board/$name.json"
    echo "cleared the line of $name"
}

live_agents() { herdr agent list 2>/dev/null | jq -c '.result.agents // empty' 2>/dev/null; }

cmd_prune() {
    local agents f name
    agents=$(live_agents)
    [[ -n "$agents" ]] || { echo "resource-board: herdr agent list failed; nothing pruned" >&2; return 0; }
    for f in "$board"/*.json; do
        [[ -e "$f" ]] || continue
        name=$(basename "$f" .json)
        [[ "$name" == *-shell ]] && continue   # a human's line: only they clear it
        jq -e --arg n "$name" 'any(.[]; .name == $n)' <<<"$agents" >/dev/null || { rm -f "$f"; echo "pruned $name"; }
    done
}

cmd_show() {
    local lim total avail slots guideline low agents f owner pid i n used=0 now
    now=$(date +%s)
    lim=$("$dir/resource-budget.py" limits 2>/dev/null) || lim='{"heavy_slots": 1, "sessions_guideline": 0, "low_memory_gb": 0, "source": "invalid resources.json"}'
    slots=$(jq -r .heavy_slots <<<"$lim"); guideline=$(jq -r .sessions_guideline <<<"$lim"); low=$(jq -r .low_memory_gb <<<"$lim")
    read -r total avail <<<"$(memory)"
    echo "# Resource board ($(date '+%Y-%m-%d %H:%M'))"
    echo
    if [[ -n "$avail" ]]; then
        echo "- Memory: $avail GB available of $total GB$(awk -v a="$avail" -v l="$low" 'BEGIN { if (a < l) printf " - **LOW: below %s GB, save mode**", l }')"
    else
        echo "- Memory: $total GB (available: unknown)"
    fi
    agents=$(live_agents)
    n=$([[ -n "$agents" ]] && jq length <<<"$agents" || echo "?")
    echo "- Live herdr agents: $n (guideline for this machine: $guideline)$([[ "$n" != "?" && "$n" -gt "$guideline" ]] && echo " - **over the guideline**")"
    echo "- Limits: $(jq -r .source <<<"$lim")"
    echo
    echo "## Heavy slots (hard limit: $slots at once)"
    echo
    for ((i = 0; i < slots; i++)); do
        owner=$(cat "$state/slot-$i.json" 2>/dev/null) || owner=""
        pid=$(jq -r '.pid // empty' <<<"$owner" 2>/dev/null)
        if [[ -n "$owner" && -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            used=$((used + 1))
            echo "- slot $i: $(jq -r '"\(.label) - \(.agent // "?") in \(.cwd)"' <<<"$owner"), for $(ago "$(jq -r .since <<<"$owner")")"
        else
            echo "- slot $i: free"
        fi
    done
    echo
    echo "## Notes ($used of $slots heavy slots in use)"
    echo
    echo "| agent | running | est. GB | for | until | where |"
    echo "|---|---|---|---|---|---|"
    for f in "$board"/*.json; do
        [[ -e "$f" ]] || continue
        jq -r --argjson now "$now" --argjson live "${agents:-null}" '
            def mins(x): ((x / 60) | floor | tostring) + " min";
            .agent as $a
            | (if $live == null or ($a | endswith("-shell")) or any($live[]; .name == $a) then ""
               else " (gone)" end) as $gone
            | (if .until == null then "-" elif .until < $now then "**overdue**"
               else mins(.until - $now) + " left" end) as $left
            | "| \($a)\($gone) | \(.what) | \(if .gb == "" then "?" else .gb end)"
              + " | \(mins($now - .since)) | \($left) | \(.cwd) |"' "$f" 2>/dev/null
    done
    if [[ -n "$agents" ]]; then
        echo
        echo "## Agents that look idle (candidates to close: ask the user)"
        echo
        jq -r '.[] | select(.agent_status == "done" or .agent_status == "idle" or .agent_status == "unknown")
               | "- \(.name // "(unnamed)") - \(.agent_status) - \(.cwd // "?")"' <<<"$agents"
    fi
}

case "${1:-}" in
    note) shift; cmd_note "$@" ;;
    clear) shift; cmd_clear "$@" ;;
    show) cmd_show ;;
    prune) cmd_prune ;;
    *) usage ;;
esac
