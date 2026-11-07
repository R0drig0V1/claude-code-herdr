#!/usr/bin/env bash
# Launch the integrator session: the only session that may change main and the main worktree
# (see "Multi-agent workflow" in CLAUDE.md).
#
# Usage: scripts/integrator.sh [extra claude arguments]
#
# - Runs in the main worktree whatever directory it is called from.
# - Requires herdr (HERDR_ENV=1): development agents reach the integrator as the herdr agent
#   named `integrator`, which /multi-agent-herdr:integrate takes on its first run.
# - CLAUDE_ROLE=integrator exempts the session from the guard hooks.
# - --name integrator names the Claude Code session the same way.
# - Appends .claude/prompts/integrator.md (the adversarial-auditor stance) to Claude Code's
#   default system prompt. Appended rather than `--agent`, which would replace the default
#   prompt: the integrator keeps the standard tool and git-safety instructions, CLAUDE.md
#   and the project skills (/integrate is its procedure).
set -euo pipefail

repo_root=$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir | xargs dirname)
cd "$repo_root"
[[ "${HERDR_ENV:-}" == 1 ]] || { echo "run it inside a herdr pane (multi-agent-herdr is herdr only)" >&2; exit 1; }
CLAUDE_ROLE=integrator exec claude --name integrator \
    --append-system-prompt-file "$repo_root/.claude/prompts/integrator.md" "$@"
