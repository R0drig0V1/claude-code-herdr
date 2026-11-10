#!/usr/bin/env python3
"""The machine's hard floor for heavy commands: at most `heavy_slots` of them at once.

Part of the multi-agent-herdr plugin (docs/multi-integrator.md, "Resources"). Resources are
mostly negotiated: agents note what they run on the resource board (resource-board.sh) and
ask the coordinator for a turn. This script is the one thing that is not negotiated, because a
conversation cannot stop a process that is already eating memory: however the negotiation
goes, no more than `heavy_slots` heavy commands (a full test suite, a build, an install) run
at once on this computer, across every agent and project of the user.

`verify-merge.sh` and `new-worktree.sh` run the project's `scripts/check.sh` and
`scripts/worktree-setup.sh` through `run`, and the `commit` and `pr` skills run the checks
the same way. A command waits for a free slot. Slots are `flock`ed files, so the kernel frees
the slot of a crashed holder. A command started inside a slot (`$MULTI_AGENT_HERDR_SLOT`
set) runs at once, so a nested call cannot deadlock. Waiters poll every 2 s: there is no FIFO
order (the coordinator arbitrates priorities by conversation).

Limits, machine-wide, from `~/.config/multi-agent-herdr/resources.json` (or the file in
`$MULTI_AGENT_HERDR_RESOURCES_CONFIG`), each key optional:

    {"heavy_slots": 2, "sessions_guideline": 12, "low_memory_gb": 2.4}

Only `heavy_slots` is enforced; the other two are the guidelines the resource board shows and
the coordinator weighs (live sessions for this RAM; the free memory below which it declares
save mode). Defaults from the machine's RAM (R GB): heavy_slots = max(1, (R - 8) // 8),
sessions_guideline = max(2, R // 2), low_memory_gb = R / 10; a 24 GB machine gets 2, 12 and
2.4. `$MULTI_AGENT_HERDR_HEAVY_SLOTS` overrides heavy_slots. Slot state lives in
`~/.cache/multi-agent-herdr/resources` (or `$MULTI_AGENT_HERDR_RESOURCES_DIR`), not in a
temporary directory: a sandboxed session may get its own `$TMPDIR`. Each held slot has an
owner file `slot-<i>.json` (label, cwd, agent, pid, since) that resource-board.sh shows.

Usage:

    resource-budget.py run [--label TEXT] [--timeout S] -- CMD [ARG...]
    resource-budget.py limits                   effective limits as JSON

Exit codes: 0 ok; 1 usage or invalid config; 124 `run` got no slot within --timeout;
otherwise CMD's own exit code. Python 3.9 compatible, no dependencies.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import platform
import subprocess
import sys
import time
from typing import Any

GB = 1024**3
EXIT_TIMEOUT = 124
KEYS = ("heavy_slots", "sessions_guideline", "low_memory_gb")


def total_gb() -> float:
    """Physical memory in GB (8 when it cannot be read)."""
    try:
        if platform.system() == "Darwin":
            out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True)
            return int(out.stdout.strip()) / GB
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) * 1024 / GB
    except (OSError, ValueError):
        pass
    return 8.0


def config_path() -> str:
    home = os.path.expanduser("~")
    default = os.path.join(home, ".config", "multi-agent-herdr", "resources.json")
    return os.environ.get("MULTI_AGENT_HERDR_RESOURCES_CONFIG", default)


def limits() -> dict[str, Any]:
    """Effective limits: the config file over the RAM-based defaults (raises ValueError)."""
    ram = total_gb()
    result: dict[str, Any] = {
        "heavy_slots": max(1, int((ram - 8) // 8)),
        "sessions_guideline": max(2, int(ram // 2)),
        "low_memory_gb": round(ram / 10, 1),
        "ram_gb": round(ram, 1),
        "source": f"defaults for {ram:.0f} GB of RAM",
    }
    path = config_path()
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        data = {}
    if not isinstance(data, dict):
        raise ValueError(f"{path}: must be a JSON object")
    for key, value in data.items():
        if key.startswith("$"):
            continue
        if key not in KEYS:
            raise ValueError(f"{path}: unknown key {key!r} (known: {', '.join(KEYS)})")
        floor = 0 if key == "low_memory_gb" else 1
        if isinstance(value, bool) or not isinstance(value, (int, float)) or value < floor:
            raise ValueError(f"{path}: {key} must be a number >= {floor}, got {value!r}")
        result[key] = value if key == "low_memory_gb" else int(value)
        result["source"] = path
    env = os.environ.get("MULTI_AGENT_HERDR_HEAVY_SLOTS", "")
    if env:
        if not env.isdigit() or int(env) < 1:
            raise ValueError(f"MULTI_AGENT_HERDR_HEAVY_SLOTS must be a positive integer: {env!r}")
        result["heavy_slots"] = int(env)
    return result


def state_dir() -> str:
    home = os.path.expanduser("~")
    default = os.path.join(home, ".cache", "multi-agent-herdr", "resources")
    path = os.environ.get("MULTI_AGENT_HERDR_RESOURCES_DIR", default)
    os.makedirs(path, exist_ok=True)
    return path


def take_slot(slots: int) -> tuple[int, int] | None:
    """(slot, fd) of a free slot now held by this process, or None when all are busy."""
    for i in range(slots):
        fd = os.open(os.path.join(state_dir(), f"slot-{i}.lock"), os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return i, fd
        except BlockingIOError:
            os.close(fd)
    return None


def busy_with(slots: int) -> str:
    """Who holds the slots, from their owner files (for the waiting message)."""
    holders = []
    for i in range(slots):
        try:
            with open(os.path.join(state_dir(), f"slot-{i}.json")) as f:
                owner = json.load(f)
            holders.append(f"{owner.get('label', '?')} ({owner.get('agent') or '?'})")
        except (OSError, ValueError):
            holders.append("?")
    return "; ".join(holders)


def cmd_run(args: argparse.Namespace) -> int:
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        print("resource-budget: run needs a command after --", file=sys.stderr)
        return 1
    if os.environ.get("MULTI_AGENT_HERDR_SLOT"):  # already inside a slot: no nesting deadlock
        return subprocess.call(command)
    try:
        state_dir()
    except OSError as exc:  # the floor must never be the reason a check cannot run
        print(f"resource-budget: warning: no state directory ({exc}); unbudgeted", file=sys.stderr)
        return subprocess.call(command)
    slots = int(limits()["heavy_slots"])
    deadline = time.monotonic() + args.timeout if args.timeout else None
    taken = take_slot(slots)
    if taken is None:
        print(
            f"resource-budget: waiting for one of {slots} heavy slot(s), held by: "
            f"{busy_with(slots)}. Long wait? Ask the coordinator (resource-board.sh show).",
            file=sys.stderr,
        )
    while taken is None:
        if deadline is not None and time.monotonic() >= deadline:
            print(f"resource-budget: no heavy slot within {args.timeout:g} s", file=sys.stderr)
            return EXIT_TIMEOUT
        time.sleep(2)
        taken = take_slot(slots)
    slot, fd = taken
    owner_file = os.path.join(state_dir(), f"slot-{slot}.json")
    owner = {
        "label": args.label or " ".join(command)[:80],
        "cwd": os.getcwd(),
        "pid": os.getpid(),
        "agent": os.environ.get("MULTI_AGENT_HERDR_NAME", ""),
        "since": time.time(),
    }
    try:
        with open(owner_file, "w") as f:
            json.dump(owner, f)
        return subprocess.call(command, env=dict(os.environ, MULTI_AGENT_HERDR_SLOT=str(slot)))
    finally:
        with contextlib.suppress(OSError):
            os.remove(owner_file)
        os.close(fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("limits")
    run = sub.add_parser("run")
    run.add_argument("--label", default="")
    run.add_argument("--timeout", type=float, default=0, help="seconds to wait; 0 = no limit")
    run.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        lim = limits()
    except ValueError as exc:
        print(f"resource-budget: {exc}", file=sys.stderr)
        return 1
    if args.cmd == "run":
        return cmd_run(args)
    print(json.dumps(lim, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
