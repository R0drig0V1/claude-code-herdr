#!/usr/bin/env bash
# Print the path of the worktree that has <branch> checked out, from `git worktree list`.
#
# Usage: worktree-of.sh <branch>     e.g. worktree-of.sh feat/user-login
#
# Part of the multi-agent-herdr plugin. The dispatch skill runs it after new-worktree.sh.
# It is a script, not an inline awk program in SKILL.md, because Claude Code substitutes the
# positional tokens `$0`, `$1`, ... in a skill's content with the skill's arguments
# (https://code.claude.com/docs/en/skills#available-string-substitutions): an awk `$0` in
# the skill arrived as the dispatch arguments. tests/check-skill-substitutions.py keeps
# such tokens out of the skills.
#
# Exit codes: 0 path printed; 1 no worktree has the branch; 2 usage or not in a git repository.
# Paths with spaces are printed as they are (one line).
set -euo pipefail

branch="${1:-}"
[[ -n "$branch" ]] || { echo "usage: worktree-of.sh <branch>" >&2; exit 2; }
list=$(git worktree list --porcelain) || exit 2

path=""
while IFS= read -r line; do
    case "$line" in
        "worktree "*) path="${line#worktree }" ;;
        "branch refs/heads/$branch") printf '%s\n' "$path"; exit 0 ;;
    esac
done <<<"$list"
echo "no worktree has branch $branch checked out" >&2
exit 1
