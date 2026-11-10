#!/usr/bin/env bash
# Discard a development worktree that served its purpose: its herdr workspace, the worktree
# and its local branch (and the remote branch, if it is still the merged head).
#
# Part of the multi-agent-herdr plugin (docs/multi-integrator.md, "Cleanup"). A worktree whose
# branch has been merged has done its job; left behind, it keeps a Claude session, its memory
# and its dependencies alive, and the branch list grows without end. The one who dispatched
# the agent cleans up after the merge: the integrator in single mode, the coordinator in pool
# mode (it opened the workspace, so it may close it).
#
# Usage:
#   cleanup-worktree.sh --list               every development worktree: branch, state, path,
#                                            agent; state "ready" means it can be cleaned now
#   cleanup-worktree.sh <branch> [--dry-run]  clean one up (or say what it would do)
#
# Nothing is removed unless every check passes:
#   1. the branch is not main, the base branch or a protected pattern;
#   2. GitHub has a merged pull request from this branch into <base>, and the branch's tip is
#      contained in origin/<base> (fetched first): the work landed and nothing was added
#      after it, so deleting the branch loses nothing. (Ancestry alone is not enough: a
#      branch just dispatched, with no commit yet, is also "contained" in the base.)
#   3. the worktree has no uncommitted or untracked (non-ignored) file;
#   4. every herdr agent in the worktree is idle or done (an agent still working, or blocked
#      at a dialog, is left alone: try again later);
#   5. every pane of each workspace to close is inside the worktree (a workspace that also
#      holds something else is not ours to close).
# Then: close those workspaces, `git worktree remove` (never --force), delete the local branch,
# delete the remote branch only when it still points at the merged tip (with a lease on that
# commit), and clear the agents' resource-board notes. Detached worktrees (the pool's verify
# worktrees) are not handled here: integrator-pool.sh stop --remove-worktree.
#
# Inside Claude Code only the integrator (single mode) or the coordinator (pool mode) may run
# it; the user may run it from a shell. Exit codes: 0 cleaned (or --list); 1 usage, role or a
# protected branch; 2 no such branch; 3 not merged; 4 uncommitted work; 5 an agent is busy, or
# herdr cannot be asked; 6 a workspace holds panes outside the worktree; 7 git failed. Needs
# git, gh, jq, python3 and herdr.
set -uo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
die() { echo "cleanup-worktree: $1" >&2; exit "${2:-1}"; }
config=$("$dir/project-config.py") || exit 1
mode=$(jq -r .mode <<<"$config"); base=$(jq -r .base_branch <<<"$config")
main=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")

if [[ "${CLAUDECODE:-}" == 1 ]]; then
    role="${CLAUDE_ROLE:-}"
    [[ "$role/$mode" == integrator/single || "$role/$mode" == coordinator/pool ]] \
        || die "only the dispatcher cleans up: the integrator (single mode) or the coordinator (pool mode)"
fi

protected() {  # protected <branch>: main, the base branch or a protected_branches pattern
    python3 -c 'import fnmatch, json, sys
c = json.loads(sys.argv[1]); b = sys.argv[2]
sys.exit(0 if any(fnmatch.fnmatchcase(b, p) for p in ["main", c["base_branch"], *c["protected_branches"]]) else 1)' \
        "$config" "$1"
}
worktree_of() { git -C "$main" worktree list --porcelain | awk -v ref="branch refs/heads/$1" '
    /^worktree / { path = substr($0, 10) } $0 == ref { print path; exit }'; }
merged_prs=""
merged_prs() {  # head branch names of the merged PRs into <base> (cached; needs gh)
    [[ -n "$merged_prs" ]] || merged_prs=$(gh pr list --base "$base" --state merged --limit 300 \
        --json headRefName 2>/dev/null | jq -r '.[].headRefName' 2>/dev/null; echo .)
    printf '%s\n' "$merged_prs"
}
contained() { git -C "$main" merge-base --is-ancestor "$1" "origin/$base"; }
merged() {  # merged <branch> <tip>: a merged PR from <branch>, and <tip> is in origin/<base>
    # A here-string, not a pipe: `grep -q` exits at the first match, and under pipefail the
    # writer's SIGPIPE would turn a match into a failure, depending on timing.
    grep -qxF -- "$1" <<<"$(merged_prs)" && contained "$2"
}
dirty() { [[ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]]; }
inside() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }   # inside <path> <worktree>

cmd_list() {
    local path branch tip state agents
    git -C "$main" fetch --quiet origin "$base" 2>/dev/null
    git -C "$main" worktree list --porcelain | awk '
        /^worktree / { path = substr($0, 10); branch = "" }
        /^branch refs\/heads\// { branch = substr($0, 19) }
        /^$/ { if (branch != "") print branch "\t" path; branch = "" }
        END { if (branch != "") print branch "\t" path }' | while IFS=$'\t' read -r branch path; do
        [[ "$path" == "$main" ]] && continue
        tip=$(git -C "$main" rev-parse "refs/heads/$branch")
        agents=$(cd "$main" && "$dir/agents-in-repo.py" --branch "$branch" 2>/dev/null | awk -F'\t' '{ printf "%s%s(%s)", sep, $1, $3; sep = "," }')
        if ! merged "$branch" "$tip"; then state="not-merged"
        elif dirty "$path"; then state="merged-but-dirty"
        elif [[ "$agents" == *"(working)"* || "$agents" == *"(blocked)"* ]]; then state="merged-agent-busy"
        else state="ready"; fi
        printf '%s\t%s\t%s\t%s\n' "$branch" "$state" "$path" "${agents:--}"
    done
}

cmd_clean() {
    local B="$1" dry="$2" tip wt panes agents ws workspaces=() name remote
    protected "$B" && die "refusing to clean up the protected branch $B"
    tip=$(git -C "$main" rev-parse -q --verify "refs/heads/$B") || die "no local branch $B" 2
    git -C "$main" fetch --quiet origin "$base" || die "git fetch origin $base failed" 7
    merged "$B" "$tip" \
        || die "$B (${tip:0:12}) has no merged PR into $base, or commits after it: nothing removed" 3
    wt=$(worktree_of "$B")
    [[ "$wt" != "$main" ]] || die "$B is checked out in the main worktree" 1
    if [[ -n "$wt" ]]; then
        if dirty "$wt"; then
            git -C "$wt" status --short >&2
            die "$wt has uncommitted work: nothing removed (ask its agent or the user)" 4
        fi
        agents=$(cd "$main" && "$dir/agents-in-repo.py" --branch "$B") \
            || die "cannot ask herdr which agents work in $wt: nothing removed" 5
        if awk -F'\t' '$3 != "idle" && $3 != "done" { bad = 1 } END { exit !bad }' <<<"$agents"; then
            die "an agent in $wt is not idle: $(cut -f1,3 <<<"$agents" | tr '\t\n' ' ,')try again later" 5
        fi
        panes=$(herdr pane list 2>/dev/null | jq -c '.result.panes // .result // []') || panes='[]'
        while IFS= read -r ws; do
            [[ -n "$ws" ]] || continue
            while IFS= read -r cwd; do
                inside "$cwd" "$wt" || die "workspace $ws also holds a pane in $cwd: not closing it (ask the user)" 6
            done < <(jq -r --arg w "$ws" '.[] | select(.workspace_id == $w) | (.foreground_cwd // .cwd // "")' <<<"$panes")
            workspaces+=("$ws")
        done < <(jq -r --arg wt "$wt" '.[] | (.foreground_cwd // .cwd // "") as $c
                 | select($c == $wt or ($c | startswith($wt + "/"))) | .workspace_id' <<<"$panes" | sort -u)
    fi
    remote=$(git -C "$main" ls-remote origin "refs/heads/$B" 2>/dev/null | cut -f1)
    if [[ "$dry" == yes ]]; then
        for ws in ${workspaces[@]+"${workspaces[@]}"}; do echo "would close workspace $ws"; done
        [[ -n "$wt" ]] && echo "would remove the worktree $wt"
        echo "would delete the local branch $B (${tip:0:12})"
        [[ "$remote" == "$tip" ]] && echo "would delete origin/$B"
        return 0
    fi
    for ws in ${workspaces[@]+"${workspaces[@]}"}; do
        herdr workspace close "$ws" >/dev/null || die "herdr workspace close $ws failed" 7
        echo "closed workspace $ws"
    done
    if [[ -n "$wt" ]]; then
        git -C "$main" worktree remove "$wt" || die "git worktree remove $wt failed" 7
        echo "removed the worktree $wt"
    fi
    contained "$(git -C "$main" rev-parse "refs/heads/$B")" || die "$B moved during the cleanup: kept" 3
    git -C "$main" branch -D "$B" >/dev/null || die "could not delete the branch $B" 7
    echo "deleted the local branch $B (${tip:0:12}, contained in origin/$base)"
    if [[ "$remote" == "$tip" ]]; then
        git -C "$main" push --quiet --force-with-lease="refs/heads/$B:$tip" origin --delete "$B" \
            && echo "deleted origin/$B"
    fi
    while IFS=$'\t' read -r name _; do
        [[ -n "$name" ]] && "$dir/resource-board.sh" clear --as "$name" >/dev/null 2>&1
    done <<<"${agents:-}"
    return 0
}

case "${1:-}" in
    --list) cmd_list ;;
    ""|-*) sed -n '11,14p' "$0" >&2; exit 1 ;;
    *) dry=no; [[ "${2:-}" == --dry-run ]] && dry=yes; cmd_clean "$1" "$dry" ;;
esac
