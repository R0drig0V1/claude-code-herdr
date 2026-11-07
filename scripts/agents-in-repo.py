#!/usr/bin/env python3
"""List the live herdr agents that work inside a worktree of the current git repository.

Part of the multi-agent-herdr plugin. The `reply` skill uses it to resolve the author of a
pull request (branch -> worktree -> herdr agent), and to find the other live development
agents to tell that `main` moved. It only reads state: `git worktree list --porcelain` and
`herdr agent list`; it never sends input to any pane.

Usage: agents-in-repo.py [--branch BRANCH] [--exclude NAME ...]

Prints one tab-separated line per matching agent:

    <name>  <pane_id>  <agent_status>  <branch>  <worktree path>

An agent matches a worktree when its pane `cwd` or `foreground_cwd` is that worktree or a
directory below it (the deepest worktree wins, paths compared after `realpath`). Agents
without a herdr name are skipped: herdr commands cannot target them by name.

Exit codes: 0 on success (even with no matches; count the lines), 1 when the current
directory is not inside a git repository, 2 when `herdr agent list` fails or returns
unexpected JSON (for example outside herdr).

Python 3.9 compatible: it runs under the system `python3`.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys


def worktrees() -> list[tuple[str, str]]:
    """(realpath, branch short name or '(detached)') for every worktree of this repository."""
    out = subprocess.run(
        ["git", "worktree", "list", "--porcelain"],
        capture_output=True, text=True, check=True,
    ).stdout  # fmt: skip
    result: list[tuple[str, str]] = []
    path, branch = None, "(detached)"
    for line in out.splitlines() + [""]:
        if line.startswith("worktree "):
            path, branch = line[len("worktree "):], "(detached)"
        elif line.startswith("branch "):
            ref = line[len("branch "):]
            branch = ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref
        elif not line and path:
            result.append((os.path.realpath(path), branch))
            path = None
    return result


def owner(cwd: str, trees: list[tuple[str, str]]) -> tuple[str, str] | None:
    """The deepest worktree containing `cwd`, or None."""
    cwd = os.path.realpath(cwd)
    best = None
    for path, branch in trees:
        if cwd == path or cwd.startswith(path.rstrip(os.sep) + os.sep):
            if best is None or len(path) > len(best[0]):
                best = (path, branch)
    return best


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--branch", help="only the agent(s) in this branch's worktree")
    parser.add_argument("--exclude", action="append", default=[], help="skip this agent name")
    args = parser.parse_args()

    try:
        trees = worktrees()
    except (subprocess.CalledProcessError, OSError) as exc:
        print(f"agents-in-repo: not inside a git repository: {exc}", file=sys.stderr)
        return 1

    try:
        proc = subprocess.run(["herdr", "agent", "list"], capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or f"exit {proc.returncode}")
        agents = json.loads(proc.stdout)["result"]["agents"]
    except (RuntimeError, OSError, ValueError, KeyError, TypeError) as exc:
        print(f"agents-in-repo: `herdr agent list` failed: {exc}", file=sys.stderr)
        return 2

    for agent in agents:
        name = agent.get("name")
        if not name or name in args.exclude:
            continue
        match = None
        for key in ("cwd", "foreground_cwd"):
            if agent.get(key):
                match = owner(agent[key], trees)
                if match:
                    break
        if not match or (args.branch and match[1] != args.branch):
            continue
        print("\t".join([name, agent.get("pane_id", ""), agent.get("agent_status", ""),
                         match[1], match[0]]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
