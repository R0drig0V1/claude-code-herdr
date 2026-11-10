#!/usr/bin/env bash
# Verify the working tree of the main worktree (normally a PR merged with --no-commit) before
# the integrator commits the merge; with --here, the worktree of the current directory instead
# (a pool integrator's own verify worktree, docs/multi-integrator.md). Exit code 0 means every check passed; anything else means
# do not merge. Gate the commit on the exit code, never on grepped output:
#
#   if "$CLAUDE_PLUGIN_ROOT"/scripts/verify-merge.sh; then git commit ...; else git merge --abort; fi
#
# Usage:
#   verify-merge.sh [--here]               full verification
#   verify-merge.sh [--here] --reset-only  only reset shared verification state (after
#                                          `git merge --abort`)
#
# With --here, several integrators verify in parallel, so the project's scripts below must be
# parallel-safe: no fixed ports, no shared database or directory that one run wipes under
# another (docs/multi-integrator.md, "Parallel verification").
#
# Steps, stopping at the first failure:
# 1. scripts/verify-reset.sh, if the project has one: recreate shared state (e.g. the
#    integrator's test database) from scratch, so state left by an earlier, aborted
#    verification cannot break (or fake) this one.
# 2. scripts/worktree-setup.sh, if present: install dependencies the PR may have added. It
#    receives the project's base branch (project-config.py base_branch, default main) as $1.
# 3. scripts/check.sh: lint, formatting, types and tests. A project without one only gets a
#    warning, so configure it before trusting a VERIFY OK.
# Steps 2 and 3 run inside one of the machine's heavy slots (resource-budget.py run), so they
# may first wait for another agent's check to finish.
#
# Part of the multi-agent-herdr plugin (unchanged from multi-agent 0.1.0); the scripts above belong to the project and are resolved
# from the repository of the current directory.
#
# Only for the integrator.
set -euo pipefail

here=false reset_only=false
for arg in "$@"; do
    case "$arg" in
        --here) here=true ;;
        --reset-only) reset_only=true ;;
        *) echo "usage: verify-merge.sh [--here] [--reset-only]" >&2; exit 2 ;;
    esac
done

main_root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
if $here; then
    repo_root=$(git rev-parse --show-toplevel)
else
    repo_root=$main_root
    cd "$repo_root"
    [[ "$(git rev-parse --absolute-git-dir)" == "$repo_root/.git" ]] \
        || { echo "run it in the main worktree ($repo_root), or pass --here" >&2; exit 2; }
fi
cd "$repo_root"

step() { echo; echo "==> $*"; }

reset_state() {
    if [[ -x scripts/verify-reset.sh ]]; then
        step "reset verification state"
        scripts/verify-reset.sh
    fi
}

if $reset_only; then
    reset_state
    exit 0
fi

failed_step="setup"
report_failure() {
    local status=$?
    if [[ $status -ne 0 ]]; then
        echo
        echo "VERIFY FAILED at: $failed_step (exit $status)" >&2
    fi
}
trap report_failure EXIT

# The heavy steps hold one of the machine's heavy slots (resource-budget.py): with many
# agents and integrators on one computer, at most `heavy_slots` of them run at once.
heavy() { "$(dirname "$0")/resource-budget.py" run --label "verify-merge $repo_root" -- "$@"; }
failed_step="reset verification state"; reset_state
if [[ -x scripts/worktree-setup.sh ]]; then
    failed_step="worktree setup"; step "$failed_step"
    heavy scripts/worktree-setup.sh "$("$(dirname "$0")/project-config.py" --root "$main_root" base_branch)"
fi
failed_step="checks"; step "$failed_step"
if [[ -x scripts/check.sh ]]; then
    heavy scripts/check.sh
else
    echo "warning: scripts/check.sh not found; nothing was checked" >&2
fi

echo
echo "VERIFY OK"
