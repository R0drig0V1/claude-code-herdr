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
* `coordinator_name` (default `coordinator-<repository>`, same normalisation): the herdr name
  of the coordinator session in pool mode (docs/multi-integrator.md).
* `integrators` (default: absent, single-integrator mode): an object that turns on **pool
  mode**, where a coordinator owns the main worktree and N integrators merge in parallel, each
  in its own verify worktree. Its keys, all optional: `min` (1), `max` (3, at most
  `POOL_MAX`), `scale_up_when_active_agents_gt` (5), `scale_down_idle_minutes` (30),
  `claim_ttl_minutes` (60), `max_reverify` (3) and `reverify_exempt_paths`
  (`["docs/phases/*"]`, fnmatch patterns).

Derived, never written in the file: `mode` (`single` or `pool`) and `integrator_pool` (the
pool members' herdr names, `<integrator_name>-<n>` for n = 1..max; empty in single mode).

Keys starting with `$` (e.g. `$comment`) are ignored. Any other unknown key, a wrong type or
an invalid value is an error, so a typo cannot silently fall back to a default.

Usage:

    project-config.py [--root DIR] [KEY]

Prints the value of KEY (lists one item per line, objects as JSON; `integrators.max` reads one
field), or every effective setting as JSON when no KEY is given. DIR defaults to the main
worktree of the repository of the current directory.
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
COORDINATOR = "coordinator"
HERDR_NAME_MAX = 32
POOL_MAX = 16
POOL_DEFAULTS: dict[str, Any] = {
    "min": 1,
    "max": 3,
    "scale_up_when_active_agents_gt": 5,
    "scale_down_idle_minutes": 30,
    "claim_ttl_minutes": 60,
    "max_reverify": 3,
    "reverify_exempt_paths": ["docs/phases/*"],
}
DERIVED = ("mode", "integrator_pool")


class ConfigError(ValueError):
    """The settings file exists but cannot be used."""


def _slug(root: str) -> str:
    """The repository part of the default herdr names (see `default_integrator_name`)."""
    base = os.path.basename(os.path.normpath(root)).lower()
    return re.sub(r"[^a-z0-9_-]+", "-", base).strip("-_")


def _role_name(role: str, root: str) -> str:
    slug = _slug(root)
    if not slug:
        return role
    return f"{role}-{slug}"[:HERDR_NAME_MAX].rstrip("-_")


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
    return _role_name(INTEGRATOR, root)


def default_coordinator_name(root: str) -> str:
    """Default herdr name of the coordinator: `coordinator-<slug>`, same rule as above.

    template/scripts/coordinator.sh repeats it in Bash; tests/test-pool.sh checks both agree.
    """
    return _role_name(COORDINATOR, root)


def pool_member_name(prefix: str, n: int) -> str:
    """Herdr name of pool member `n`: `<prefix>-<n>`, the prefix cut so it fits 32 characters.

    `prefix` is `integrator_name`; `integrator-granolax` gives `integrator-granolax-1`, ...
    """
    suffix = f"-{n}"
    return prefix[: HERDR_NAME_MAX - len(suffix)].rstrip("-_") + suffix


def defaults(root: str) -> dict[str, Any]:
    """Every setting at its default for the repository whose main worktree is `root`."""
    return {
        "base_branch": "main",
        "integrator_name": default_integrator_name(root),
        "protected_branches": [],
        "worktree_prefix": os.path.basename(os.path.normpath(root)) + "-",
        "coordinator_name": default_coordinator_name(root),
        "integrators": None,
        "mode": "single",
        "integrator_pool": [],
    }


def _pool_settings(path: str, value: Any) -> dict[str, Any]:
    """Validated `integrators` object with its defaults filled in (raises ConfigError)."""
    if not isinstance(value, dict):
        raise ConfigError(f"{path}: integrators must be an object, got {value!r}")
    pool = dict(POOL_DEFAULTS)
    for key, item in value.items():
        if key.startswith("$"):
            continue
        if key not in POOL_DEFAULTS:
            known = ", ".join(POOL_DEFAULTS)
            raise ConfigError(f"{path}: unknown key integrators.{key} (known: {known})")
        if key == "reverify_exempt_paths":
            if not isinstance(item, list) or not all(isinstance(v, str) and v for v in item):
                raise ConfigError(f"{path}: integrators.{key} must be a list of patterns")
        elif isinstance(item, bool) or not isinstance(item, int) or item < 1:
            raise ConfigError(f"{path}: integrators.{key} must be a positive integer, got {item!r}")
        elif key in ("min", "max") and item > POOL_MAX:
            raise ConfigError(f"{path}: integrators.{key} must be at most {POOL_MAX}, got {item}")
        pool[key] = item
    if pool["min"] > pool["max"]:
        raise ConfigError(f"{path}: integrators.min ({pool['min']}) is above max ({pool['max']})")
    return pool


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


def _checked(path: str, key: str, value: Any) -> Any:
    """`value` of the top-level `key`, validated (raises ConfigError)."""
    if key == "base_branch":
        if not isinstance(value, str) or not valid_branch(value):
            raise ConfigError(f"{path}: base_branch must be a branch name, got {value!r}")
    elif key in ("integrator_name", "coordinator_name"):
        if not isinstance(value, str) or not HERDR_NAME.fullmatch(value):
            raise ConfigError(f"{path}: {key} must match [a-z][a-z0-9_-]{{0,31}}, got {value!r}")
    elif key == "integrators":
        return _pool_settings(path, value)
    elif key == "protected_branches":
        if not isinstance(value, list) or not all(isinstance(v, str) and v for v in value):
            raise ConfigError(f"{path}: protected_branches must be a list of patterns")
    elif key == "worktree_prefix":
        if not isinstance(value, str) or not PREFIX.fullmatch(value):
            raise ConfigError(
                f"{path}: worktree_prefix may only contain letters, digits, '.', '_' and '-'"
            )
    return value


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
        if key not in config or key in DERIVED:
            known = ", ".join(k for k in config if k not in DERIVED)
            raise ConfigError(f"{path}: unknown key {key!r} (known: {known})")
        config[key] = _checked(path, key, value)
    if config["integrators"] is not None:
        config["mode"] = "pool"
        prefix = config["integrator_name"]
        config["integrator_pool"] = [
            pool_member_name(prefix, n) for n in range(1, config["integrators"]["max"] + 1)
        ]
        if config["coordinator_name"] in config["integrator_pool"] + [prefix]:
            raise ConfigError(f"{path}: coordinator_name must differ from the integrators' names")
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
    value: Any = config
    for part in args.key.split("."):
        if not isinstance(value, dict) or part not in value:
            print(f"project-config: unknown key {args.key!r}", file=sys.stderr)
            return 2
        value = value[part]
    if isinstance(value, dict) or value is None:
        print(json.dumps(value))
    elif not isinstance(value, list):
        print(value)
    elif value:  # an empty list prints nothing, not an empty line
        print("\n".join(value))
    return 0


if __name__ == "__main__":
    sys.exit(main())
