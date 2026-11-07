#!/usr/bin/env bash
# All the checks that define "green" for this repository: lint, formatting, types, tests.
#
# Usage: scripts/check.sh
#
# The single entry point used by the /multi-agent-herdr:commit and :pr skills and by verify-merge.sh,
# so the definition of green lives in one place. Exit code 0 means every check passed.
# Formatters must run in check mode here (never rewrite files): the integrator runs this in
# the main worktree.
#
# TODO: replace the placeholder below with this project's commands, e.g.
#   uv run ruff check . && uv run ruff format --check . && uv run mypy && uv run pytest -q
#   pnpm lint && pnpm typecheck && pnpm test
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "warning: no checks configured yet; edit scripts/check.sh" >&2
