#!/usr/bin/env bash
# Merge one pull request into the base branch, verified, or stop with the reason.
#
# Part of the multi-agent-herdr plugin (docs/multi-integrator.md, "integrate-pr.sh"); the
# `integrate` skill runs it after reviewing the diff. It folds in the lessons of the first
# multi-integrator runs: stop on any conflict except mechanical index rows, abort and reset on
# a failed verification, and keep the head branch when it moved during the verification (a
# premature deletion closed PRs twice).
#
# Usage: integrate-pr.sh <PR number> [--union-rows PATH]...
#
# Only for CLAUDE_ROLE=integrator. Single mode: run it in the main worktree (on the base
# branch). Pool mode: run it in your own verify worktree (detached HEAD), holding the PR's
# claim (pool-state.py claim; the script heartbeats it and releases it when it is done).
#
# Steps, each gated on the previous one's exit code:
#  1. Preconditions: settings, role, worktree, no merge in progress (a crashed run's merge is
#     aborted), clean tree, the PR open against the base branch from this repository, and
#     origin/<branch> equal to the PR's head.
#  2. Start from origin/<base> (pool: detached checkout; single: fast-forward of <base>), then
#     `git merge --no-ff --no-commit` the PR head. A conflict stops it (exit 3), unless every
#     conflicted file was given with --union-rows and union-rows.py resolves it.
#  3. verify-merge.sh (--here in pool mode), output in a log file; the exit code is the
#     verdict. A failure aborts the merge and resets the verification state (exit 4). check.sh
#     must not change tracked files (that is a failure too).
#  4. Commit the merge, then push it under the merge lock (pool-state.py lock run). Inside the
#     lock, when origin/<base> moved since the verification started, the PR is merged again
#     onto the new base; if the new merged tree differs from the verified one only in
#     `integrators.reverify_exempt_paths` (default docs/phases/*), it is pushed at once,
#     otherwise the lock is released and the new tree is verified again, up to
#     `integrators.max_reverify` times (exit 7 after that). The push is never forced: a
#     non-fast-forward is rejected by the remote, so only a verified tree can land.
#  5. Delete the head branch only when the PR's head, the remote branch and the merged head
#     are the same commit and it is contained in origin/<base> (the delete itself carries a
#     lease on that commit, so a push that lands meanwhile keeps the branch); else keep it.
#  6. Pool mode: record the plan report for the coordinator (pool-state.py report add, with
#     the PR body's "Plan tasks completed" section) and release the claim. A bounce (exit 3 or
#     4) is recorded in both modes (pool-state.py bounce), so the queue skips that head.
#
# The last line printed is `RESULT <outcome> ...`. Exit codes: 0 merged; 1 usage, role or
# settings; 2 precondition failed (nothing changed); 3 conflict (bounce); 4 verification failed
# (bounce); 5 commit failed; 6 push failed; 7 the base kept moving (requeue: claim released, no
# bounce); 8 merge lock not acquired (requeue); 9 nothing to merge (the head is already in the
# base). Needs git, gh, jq and python3.
set -uo pipefail

here_dir=$(cd "$(dirname "$0")" && pwd)
pc="$here_dir/project-config.py"
ps="$here_dir/pool-state.py"

# Under the merge lock: re-entered through `pool-state.py lock run -- integrate-pr.sh
# --push-under-lock`, with the state of the outer run in the environment (exported below).
if [[ "${1:-}" == --push-under-lock ]]; then
    set -e
    git fetch --quiet origin "$IPR_BASE"
    now=$(git rev-parse "origin/$IPR_BASE")
    if [[ "$now" != "$IPR_BASE_SHA" ]]; then
        echo "origin/$IPR_BASE moved during the verification: $IPR_BASE_SHA -> $now"
        printf '%s\n' "$now" > "$IPR_STATE"
        if [[ "$IPR_MODE" == pool ]]; then git checkout --quiet --detach "$now"
        else git reset --quiet --hard "$now"; fi
        if ! git merge --quiet --no-ff --no-commit "$IPR_HEAD_SHA" >/dev/null 2>&1; then
            git merge --abort 2>/dev/null || true
            echo "the PR no longer merges cleanly onto $now"
            exit 3
        fi
        tree=$(git write-tree)
        changed=$(git diff --name-only "$IPR_VERIFIED_TREE" "$tree")
        if ! python3 -c 'import fnmatch, json, sys
pats = json.loads(sys.argv[1])
paths = [p for p in sys.stdin.read().splitlines() if p]
sys.exit(0 if all(any(fnmatch.fnmatchcase(p, q) for q in pats) for p in paths) else 1)' \
            "$IPR_EXEMPT" <<<"$changed"; then
            echo "the new base changes the verified tree outside the exempt paths:"
            sed 's/^/  /' <<<"$changed" | head -20
            exit 75
        fi
        echo "only exempt paths changed since the verification (${changed//$'\n'/, }); no re-verify"
        git commit --quiet -F "$IPR_MSG"
    fi
    git push --quiet origin "HEAD:refs/heads/$IPR_BASE" || exit 6
    exit 0
fi

usage() { echo "usage: integrate-pr.sh <PR number> [--union-rows PATH]..." >&2; exit 1; }
N="${1:-}"; [[ "$N" =~ ^[0-9]+$ ]] || usage; shift
union=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --union-rows) [[ $# -ge 2 ]] || usage; union+=("$2"); shift 2 ;;
        *) usage ;;
    esac
done

result() { echo "RESULT $*"; }
[[ "${CLAUDE_ROLE:-}" == integrator ]] || { echo "only the integrator (CLAUDE_ROLE=integrator)" >&2; exit 1; }
config=$("$pc") || exit 1
mode=$(jq -r .mode <<<"$config")
base=$(jq -r .base_branch <<<"$config")
max_reverify=$(jq -r '.integrators.max_reverify // 3' <<<"$config")
exempt=$(jq -c '.integrators.reverify_exempt_paths // ["docs/phases/*"]' <<<"$config")
if [[ "$mode" == pool ]]; then me="${MULTI_AGENT_HERDR_NAME:-}"; else me=$(jq -r .integrator_name <<<"$config"); fi
[[ -n "$me" ]] || { echo "pool mode: MULTI_AGENT_HERDR_NAME is not set (spawn integrators with integrator-pool.sh)" >&2; exit 1; }

stop() { echo "STOP: $*" >&2; result precondition "$*"; exit 2; }
top=$(git rev-parse --show-toplevel) || stop "not inside a git repository"
cd "$top" || exit 2
git_dir=$(git rev-parse --absolute-git-dir); common=$(git rev-parse --path-format=absolute --git-common-dir)
if [[ "$mode" == pool ]]; then
    [[ "$git_dir" != "$common" ]] || stop "pool mode: run it in your own verify worktree, not the main worktree (the coordinator's)"
    "$ps" heartbeat "$N" --owner "$me" >/dev/null || stop "PR #$N is not claimed by $me (pool-state.py claim $N --owner $me)"
    verify=("$here_dir/verify-merge.sh" --here)
else
    [[ "$git_dir" == "$common" ]] || stop "single mode: run it in the main worktree"
    verify=("$here_dir/verify-merge.sh")
fi

# A run that crashed mid-merge left MERGE_HEAD behind: abort it (this worktree is ours).
if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    echo "aborting a merge left in progress by an earlier run"
    git merge --abort || stop "could not abort the merge in progress"
    "${verify[@]}" --reset-only >/dev/null 2>&1 || true
fi
[[ -z "$(git status --porcelain)" ]] || { git status --short >&2; stop "the worktree $top is not clean"; }

pr=$(gh pr view "$N" --json number,title,body,headRefName,headRefOid,baseRefName,state,isCrossRepository) \
    || stop "gh pr view $N failed"
B=$(jq -r .headRefName <<<"$pr"); head=$(jq -r .headRefOid <<<"$pr"); title=$(jq -r .title <<<"$pr")
[[ "$(jq -r .state <<<"$pr")" == OPEN ]] || stop "PR #$N is not open"
[[ "$(jq -r .baseRefName <<<"$pr")" == "$base" ]] || stop "PR #$N targets $(jq -r .baseRefName <<<"$pr"), not $base"
[[ "$(jq -r .isCrossRepository <<<"$pr")" == false ]] || stop "PR #$N comes from a fork: integrate it by hand"
git fetch --quiet --prune origin "$base" "refs/heads/$B:refs/remotes/origin/$B" || stop "git fetch failed"
[[ "$(git rev-parse "origin/$B")" == "$head" ]] \
    || stop "origin/$B ($(git rev-parse --short "origin/$B")) is not the PR head (${head:0:12}) yet: retry"

finish_bounce() {  # finish_bounce <outcome> <exit code> <reason>: reset, record, report
    git merge --abort >/dev/null 2>&1 || true
    "${verify[@]}" --reset-only >/dev/null 2>&1 || true
    if [[ "$mode" == pool ]]; then git checkout --quiet --detach "origin/$base"
    else git reset --quiet --hard "origin/$base"; fi
    "$ps" bounce "$N" --head "$head" --owner "$me" >/dev/null   # the queue skips this head
    result "$1" "PR #$N" "$3"; exit "$2"
}
requeue() {  # requeue <outcome> <exit code> <reason>: back to the queue, no bounce
    git merge --abort >/dev/null 2>&1 || true
    if [[ "$mode" == pool ]]; then
        git checkout --quiet --detach "origin/$base"
        "$ps" release "$N" --owner "$me" >/dev/null
    else
        git reset --quiet --hard "origin/$base"
    fi
    result "$1" "PR #$N" "$3"; exit "$2"
}

# 2. Start from origin/<base> and merge.
if [[ "$mode" == pool ]]; then
    git checkout --quiet --detach "origin/$base" || stop "cannot check out origin/$base"
else
    git switch --quiet "$base" && git merge --quiet --ff-only "origin/$base" \
        || stop "$base cannot fast-forward to origin/$base"
fi
base_sha=$(git rev-parse HEAD)
if git merge-base --is-ancestor "$head" "$base_sha"; then
    [[ "$mode" == pool ]] && "$ps" release "$N" --owner "$me" >/dev/null
    result nothing-to-merge "PR #$N: ${head:0:12} is already in origin/$base"; exit 9
fi
if ! git merge --quiet --no-ff --no-commit "$head" >/dev/null 2>&1; then
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        mechanical=false
        for u in ${union[@]+"${union[@]}"}; do [[ "$f" == "$u" ]] && mechanical=true; done
        if $mechanical && "$here_dir/union-rows.py" "$f"; then
            git add -- "$f"; echo "resolved $f mechanically (union of table rows)"
        else
            echo "conflict: $f" >&2
        fi
    done < <(git diff --name-only --diff-filter=U)
    remaining=$(git diff --name-only --diff-filter=U)
    [[ -z "$remaining" ]] || finish_bounce conflict 3 "conflicts with origin/$base in: ${remaining//$'\n'/ }"
    git diff --cached --check >/dev/null 2>&1 || finish_bounce conflict 3 "conflict markers left after resolution"
fi

# 3. Verify, heartbeating the claim meanwhile (a verification can take longer than a TTL).
log="$git_dir/multi-agent-herdr-verify-$N.log"
run_verify() {
    local rc hb=""
    if [[ "$mode" == pool ]]; then
        # Its own stdio is /dev/null and it kills its own sleep when stopped: a child left
        # holding the caller's stdout would keep `$(integrate-pr.sh ...)` waiting.
        (
            exec </dev/null >/dev/null 2>&1
            s=""; trap '[[ -n "$s" ]] && kill "$s"; exit 0' TERM
            while :; do
                sleep 120 & s=$!; wait "$s"
                "$ps" heartbeat "$N" --owner "$me" || exit 0
            done
        ) &
        hb=$!
    fi
    "${verify[@]}" > "$log" 2>&1; rc=$?
    [[ -n "$hb" ]] && kill "$hb" 2>/dev/null
    if [[ $rc -eq 0 ]] && ! git diff --quiet; then
        echo "scripts/check.sh changed tracked files:" >> "$log"; git diff --stat >> "$log"; rc=1
    fi
    tail -n 40 "$log"
    echo "(full verification log: $log)"
    return "$rc"
}
run_verify || finish_bounce verify-failed 4 "verify-merge.sh failed on the merge with origin/$base (${base_sha:0:12}); log: $log"

msg="$git_dir/multi-agent-herdr-merge-msg-$N"
printf 'Merge pull request #%s from %s\n\n%s\n' "$N" "$B" "$title" > "$msg"
export IPR_BASE="$base" IPR_MODE="$mode" IPR_HEAD_SHA="$head" IPR_EXEMPT="$exempt" IPR_MSG="$msg"
export IPR_STATE="$git_dir/multi-agent-herdr-newbase-$N"

# 4. Commit, then push under the merge lock; re-verify when the base moved under us.
attempt=0
while :; do
    export IPR_BASE_SHA="$base_sha" IPR_VERIFIED_TREE; IPR_VERIFIED_TREE=$(git write-tree)
    git commit --quiet -F "$msg" || { result commit-failed "PR #$N"; exit 5; }
    "$ps" lock run --owner "$me" --timeout 900 -- "$0" --push-under-lock; rc=$?
    case $rc in
        0) break ;;
        3) finish_bounce conflict 3 "conflicts with the new origin/$base ($(cat "$IPR_STATE"))" ;;
        6) result push-failed "PR #$N: git push origin HEAD:$base failed; the merge commit is local only"; exit 6 ;;
        124) requeue lock-timeout 8 "merge lock not acquired in 900 s" ;;
        75) ;;
        *) result push-failed "PR #$N: the push under the lock failed (exit $rc)"; exit 6 ;;
    esac
    attempt=$((attempt + 1))
    base_sha=$(cat "$IPR_STATE")
    [[ $attempt -le $max_reverify ]] \
        || requeue base-moving 7 "origin/$base moved $attempt times during verification; back to the queue"
    echo "re-verifying on the new origin/$base (${base_sha:0:12}), attempt $attempt of $max_reverify"
    run_verify || finish_bounce verify-failed 4 "verify-merge.sh failed on the merge with the new origin/$base (${base_sha:0:12}); log: $log"
done
merged=$(git rev-parse HEAD)

# 5. Delete the head branch only when nothing moved; otherwise keep it (and the PR open).
git fetch --quiet --prune origin "$base" "refs/heads/$B:refs/remotes/origin/$B" 2>/dev/null
remote_now=$(git rev-parse -q --verify "origin/$B" || true)
pr_head=$(gh pr view "$N" --json headRefOid -q .headRefOid 2>/dev/null || true)
branch="kept"
if [[ "$remote_now" == "$head" && "$pr_head" == "$head" ]] && git merge-base --is-ancestor "$head" "origin/$base"; then
    # The lease makes the delete conditional on origin/$B still being $head (no history is
    # rewritten; a push that lands in between makes the delete fail and keeps the branch).
    git push --quiet --force-with-lease="refs/heads/$B:$head" origin --delete "$B" 2>/dev/null && branch="deleted"
fi
[[ "$branch" == kept ]] && echo "branch $B KEPT: remote ${remote_now:-?}, PR head ${pr_head:-?}, merged ${head}; the PR stays open if it has new commits"

# 6. Plan report and claim (pool mode).
if [[ "$mode" == pool ]]; then
    tasks=$(jq -r .body <<<"$pr" | awk '/^## /{p = ($0 ~ /^## Plan tasks completed/); next} p' | sed '/^[[:space:]]*$/d')
    "$ps" report add "$N" --sha "$merged" --owner "$me" --tasks "$tasks" >/dev/null
    "$ps" release "$N" --owner "$me" >/dev/null
fi
rm -f "$msg" "$IPR_STATE"
result merged "PR #$N as $merged onto origin/$base; branch $B $branch"
exit 0
