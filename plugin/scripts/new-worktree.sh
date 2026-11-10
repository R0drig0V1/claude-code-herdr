#!/usr/bin/env bash
# Create a development worktree for one branch, ready to code and test in isolation.
#
# Usage: new-worktree.sh <type>/<short-kebab-name>   e.g. feat/user-login
#
# Part of the multi-agent-herdr plugin (ported from multi-agent 0.1.0). The integrator's
# /multi-agent-herdr:dispatch skill runs it from the main worktree, then opens the new worktree
# as its own herdr workspace. It works on the repository of the current directory.
#
# - Creates ../<worktree_prefix><short-kebab-name> (default prefix: "<repo>-") on a new branch
#   <type>/<short-kebab-name>, from origin/<base_branch> when it exists (the integrator pushes
#   the base branch there), else the local base branch. base_branch defaults to main; both
#   settings come from .claude/multi-agent-herdr.json (project-config.py), and an invalid file
#   stops the script before anything is created.
# - Copies the main checkout's .env, if there is one (it is not tracked by git).
# - Runs scripts/worktree-setup.sh inside the new worktree when the project has one: the
#   place for per-worktree setup such as `uv sync`, `pnpm install` or creating a private test
#   database (worktrees must never share one: tests usually wipe it). It receives the branch
#   name as $1. A failing setup only warns, so the worktree is still usable. It runs inside
#   one of the machine's heavy slots (resource-budget.py run): installs are heavy too.
set -euo pipefail

branch="${1:?usage: new-worktree.sh <type>/<short-kebab-name>}"
[[ "$branch" == */* ]] || { echo "branch must look like <type>/<name>, got: $branch" >&2; exit 1; }

repo_root=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
config="$(dirname "$0")/project-config.py"
base_branch=$("$config" --root "$repo_root" base_branch)
prefix=$("$config" --root "$repo_root" worktree_prefix)
name="${branch#*/}"
worktree="$(dirname "$repo_root")/${prefix}${name}"

git -C "$repo_root" fetch --quiet origin "$base_branch" 2>/dev/null || true
base=$base_branch
git -C "$repo_root" rev-parse --verify --quiet "origin/$base_branch" >/dev/null && base="origin/$base_branch"

git -C "$repo_root" worktree add --no-track -b "$branch" "$worktree" "$base"

[[ -f "$repo_root/.env" ]] && cp "$repo_root/.env" "$worktree/.env"

if [[ -x "$worktree/scripts/worktree-setup.sh" ]]; then
    (cd "$worktree" && "$(dirname "$0")/resource-budget.py" run --label "worktree-setup $branch" \
        -- scripts/worktree-setup.sh "$branch") \
        || echo "warning: scripts/worktree-setup.sh failed; rerun it in $worktree" >&2
fi

echo
echo "worktree ready: $worktree  (branch $branch, from $base)"
echo "next: open it as its own herdr workspace (/multi-agent-herdr:dispatch does)"
