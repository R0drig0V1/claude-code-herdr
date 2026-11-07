#!/usr/bin/env python3
"""Read the project's multi-agent-herdr settings: `.claude/multi-agent-herdr.json`.

Part of the multi-agent-herdr plugin. The workflow assumes, by default, that pull requests
merge into `main` and that the integrator's herdr agent is named `integrator-<repository>`
(see `default_integrator_name`). A project that integrates into another branch (for example
`dev`, promoted to `main` separately) or names its integrator differently says so in this
optional, versioned file at the root of the main worktree:

    {
      "base_branch": "dev",
      "integrator_name": "integrador",
      "protected_branches": ["promote/*"],
      "worktree_prefix": "chat-"
    }

Keys (all optional; a missing file means every default):

* `base_branch` (default `main`): the branch pull requests target, worktrees start from and
  the integrator merges into and pushes.
* `integrator_name` (default `integrator-<repository directory name>`, normalised by
  `default_integrator_name`): the integrator's herdr agent name. herdr names must match
  `[a-z][a-z0-9_-]{0,31}` and are unique per herdr server, so the default carries the
  repository: two projects on one server get two integrators instead of colliding on one
  name.
* `protected_branches` (default `[]`): extra branch patterns (`fnmatch`, e.g. `release/*`)
  that only the integrator may push. `main` and `base_branch` are always protected.
* `worktree_prefix` (default `<repository directory name>-`): development worktrees are
  created as `../<worktree_prefix><short name>`.

Keys starting with `$` (e.g. `$comment`) are ignored. Any other unknown key, a wrong type or
an invalid value is an error, so a typo cannot silently fall back to a default.

Usage:

    project-config.py [--root DIR] [KEY]

Prints the value of KEY (lists one item per line), or every effective setting as JSON when no
KEY is given. DIR defaults to the main worktree of the repository of the current directory.
Exit codes: 0 ok, 1 invalid file or not inside a git repository, 2 unknown KEY.

The guard hook imports `load()` and uses `defaults()` when the file is invalid (a broken file
must not wedge every session). Python 3.9 compatible: it runs under the system `python3`.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Any

FILE = os.path.join(".claude", "multi-agent-herdr.json")
HERDR_NAME = re.compile(r"[a-z][a-z0-9_-]{0,31}")
PREFIX = re.compile(r"[A-Za-z0-9._-]*")
INTEGRATOR = "integrator"
HERDR_NAME_MAX = 32


class ConfigError(ValueError):
    """The settings file exists but cannot be used."""


def default_integrator_name(root: str) -> str:
    """Default herdr name of the integrator of the repository whose main worktree is `root`.

    `integrator-<slug>`, where the slug is the main worktree's directory name in lower case
    with every run of characters outside `[a-z0-9_-]` replaced by `-` and leading or trailing
    `-`/`_` removed; the result is cut to herdr's 32 characters (trailing `-`/`_` removed
    again). A directory name with no usable character gives plain `integrator`. Examples:
    `Astro-SimCLR` -> `integrator-astro-simclr`, `MC SDDP` -> `integrator-mc-sddp`.

    Two repositories whose slugs share the first 21 characters get the same default; set
    `integrator_name` explicitly in one of them (claim-integrator.sh says so on a clash).
    template/scripts/integrator.sh repeats this rule in Bash (it cannot reach the plugin);
    tests/test-hooks.sh checks that both agree.
    """
    base = os.path.basename(os.path.normpath(root)).lower()
    slug = re.sub(r"[^a-z0-9_-]+", "-", base).strip("-_")
    if not slug:
        return INTEGRATOR
    return f"{INTEGRATOR}-{slug}"[:HERDR_NAME_MAX].rstrip("-_")


def defaults(root: str) -> dict[str, Any]:
    """Every setting at its default for the repository whose main worktree is `root`."""
    return {
        "base_branch": "main",
        "integrator_name": default_integrator_name(root),
        "protected_branches": [],
        "worktree_prefix": os.path.basename(os.path.normpath(root)) + "-",
    }


def valid_branch(name: str) -> bool:
    """Whether `name` is a usable branch name (`git check-ref-format --branch` rules, offline)."""
    return bool(
        name
        and not name.startswith(("-", "/"))
        and not name.endswith((".", "/", ".lock"))
        and ".." not in name
        and "//" not in name
        and "@{" not in name
        and not re.search(r"[\s~^:?*\[\\\x00-\x1f\x7f]", name)
    )


def load(root: str) -> dict[str, Any]:
    """Effective settings of the repository whose main worktree is `root`.

    Raises ConfigError when the file exists but is not valid JSON, is not an object, has an
    unknown key, or a value of the wrong type or format.
    """
    config = defaults(root)
    path = os.path.join(root, FILE)
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        return config
    except (OSError, ValueError) as exc:
        raise ConfigError(f"{path}: {exc}") from exc
    if not isinstance(data, dict):
        raise ConfigError(f"{path}: must be a JSON object")
    for key, value in data.items():
        if key.startswith("$"):
            continue
        if key not in config:
            raise ConfigError(f"{path}: unknown key {key!r} (known: {', '.join(config)})")
        if key == "base_branch":
            if not isinstance(value, str) or not valid_branch(value):
                raise ConfigError(f"{path}: base_branch must be a branch name, got {value!r}")
        elif key == "integrator_name":
            if not isinstance(value, str) or not HERDR_NAME.fullmatch(value):
                raise ConfigError(
                    f"{path}: integrator_name must match [a-z][a-z0-9_-]{{0,31}}, got {value!r}"
                )
        elif key == "protected_branches":
            if not isinstance(value, list) or not all(isinstance(v, str) and v for v in value):
                raise ConfigError(f"{path}: protected_branches must be a list of patterns")
        elif key == "worktree_prefix":
            if not isinstance(value, str) or not PREFIX.fullmatch(value):
                raise ConfigError(
                    f"{path}: worktree_prefix may only contain letters, digits, '.', '_' and '-'"
                )
        config[key] = value
    return config


def main_worktree(cwd: str = ".") -> str:
    """Root of the main worktree of the repository containing `cwd` (raises on failure)."""
    out = subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()  # fmt: skip
    return os.path.dirname(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", help="main worktree of the repository (default: from cwd)")
    parser.add_argument("key", nargs="?", help="setting to print (default: all, as JSON)")
    args = parser.parse_args()
    try:
        root = args.root or main_worktree()
    except (subprocess.CalledProcessError, OSError) as exc:
        print(f"project-config: not inside a git repository: {exc}", file=sys.stderr)
        return 1
    try:
        config = load(root)
    except ConfigError as exc:
        print(f"project-config: {exc}", file=sys.stderr)
        return 1
    if args.key is None:
        print(json.dumps(config, indent=2))
        return 0
    if args.key not in config:
        print(f"project-config: unknown key {args.key!r}", file=sys.stderr)
        return 2
    value = config[args.key]
    if not isinstance(value, list):
        print(value)
    elif value:  # an empty list prints nothing, not an empty line
        print("\n".join(value))
    return 0


if __name__ == "__main__":
    sys.exit(main())
