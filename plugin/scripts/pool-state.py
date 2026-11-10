#!/usr/bin/env python3
"""Shared state of the integrator pool: PR claims, bounced heads, the merge lock, plan reports.

Part of the multi-agent-herdr plugin (docs/multi-integrator.md). Every integrator of a
repository runs on the same machine (herdr is local), so they share the repository's git common
dir; this script keeps the pool's state there, in `<git common dir>/multi-agent-herdr/`:

    claims/pr-<N>/owner.json   one directory per claimed PR; `mkdir` is the atomic claim
    bounced/pr-<N>.json        the head SHA last bounced, so the PR is not re-verified until
                               its author pushes a new head
    lock/merge.lock            `flock`ed by `lock run` around every push to the base branch;
    lock/merge.owner.json      who holds it (informational; the flock is the lock)
    reports/pr-<N>.json        "PR merged, tick its plan tasks", until the coordinator ticks
    reports/done/pr-<N>.json   them (`report done`), so a coordinator that was down catches up
    members/<name>.activity    touched on every claim, release and bounce (scale-down idleness)

Commands:

    claim N --owner NAME [--head SHA]   exit 0 claimed (or already ours); 3 held by a live owner
    release N --owner NAME              exit 0 released or not claimed; 3 held by another owner
    heartbeat N --owner NAME            exit 0 refreshed; 3 not ours
    claims                              one line per claim: N owner head heartbeat-age state
    bounce N --head SHA --owner NAME    record a bounce of head SHA (and release the claim)
    queue --base BRANCH [--owner NAME]  claimable open PRs, oldest first (runs `gh pr list`):
                                        N  headRefName  headRefOid  free|mine|stale  title
    lock run --owner NAME [--timeout S] [--expect-base SHA --base BRANCH] -- CMD [ARG...]
                                        run CMD holding the merge lock; with --expect-base,
                                        fetch origin BRANCH first and exit 75 without running
                                        CMD when origin/BRANCH is not SHA any more
    lock status                         exit 0 free; 1 held (prints the owner)
    report add N --sha SHA --owner NAME [--tasks TEXT] | report list | report done N
    report known N                      exit 0 when PR N was reported (pending or done)
    activity NAME | idle-seconds NAME   touch / read a member's last activity

A claim is **stale** when its heartbeat is older than `integrators.claim_ttl_minutes` (default
60), or when its owner is not a live herdr agent (`herdr agent list`; when herdr cannot be
asked, only the age counts). A stale claim is moved aside with one atomic `rename` before it is
claimed again, so two integrators that both find it stale cannot both take it.

The merge lock is a kernel `flock`: the kernel releases it when its holder dies, so a crashed
integrator never wedges the pool. It only orders pushes; correctness comes from git itself,
since a push that is not a fast-forward is rejected (the plugin never force-pushes).

Exit codes: 0 ok; 1 usage, I/O or not inside a git repository; 3 held by another owner;
75 base moved (`lock run --expect-base`); 124 the lock was not acquired within --timeout;
otherwise CMD's own exit code (`lock run`). Python 3.9 compatible, no dependencies.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import importlib.util
import json
import os
import subprocess
import sys
import time
from typing import Any

STATE = "multi-agent-herdr"
EXIT_HELD = 3
EXIT_BASE_MOVED = 75
EXIT_LOCK_TIMEOUT = 124
FRESH_CLAIM_SECONDS = 60  # a claim directory without owner.json yet is being created


def _load_project_config() -> Any:
    """The plugin's scripts/project-config.py as a module (one reader for every component)."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "project-config.py")
    spec = importlib.util.spec_from_file_location("project_config", path)
    module = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


def git(*args: str) -> str:
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout.strip()


def common_dir() -> str:
    return git("rev-parse", "--path-format=absolute", "--git-common-dir")


def pool_settings() -> dict[str, Any]:
    """`integrators` settings of this repository (the pool defaults in single mode)."""
    pc = _load_project_config()
    config = pc.load(os.path.dirname(common_dir()))
    return config["integrators"] or dict(pc.POOL_DEFAULTS)


def live_names() -> set[str] | None:
    """Names of the live herdr agents, or None when herdr cannot be asked."""
    try:
        proc = subprocess.run(["herdr", "agent", "list"], capture_output=True, text=True)
        if proc.returncode != 0:
            return None
        agents = json.loads(proc.stdout)["result"]["agents"]
        return {a["name"] for a in agents if a.get("name")}
    except (OSError, ValueError, KeyError, TypeError):
        return None


def write_json(path: str, data: dict[str, Any]) -> None:
    """Write `data` to `path` atomically (a reader never sees half a file)."""
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def read_json(path: str) -> dict[str, Any] | None:
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


class State:
    """The pool's state directory and the operations on it."""

    def __init__(self, root: str, ttl_minutes: int) -> None:
        self.root = root
        self.ttl = ttl_minutes * 60
        self._live: set[str] | None | bool = False  # False: not asked yet
        for sub in ("claims", "bounced", "lock", "reports/done", "members"):
            os.makedirs(os.path.join(root, sub), exist_ok=True)

    def path(self, *parts: str) -> str:
        return os.path.join(self.root, *parts)

    def live(self) -> set[str] | None:
        if self._live is False:
            self._live = live_names()
        return self._live  # type: ignore[return-value]

    def touch(self, name: str) -> None:
        path = self.path("members", f"{name}.activity")
        with open(path, "a"):
            os.utime(path)

    # Claims ---------------------------------------------------------------------------------

    def claim_dir(self, pr: int) -> str:
        return self.path("claims", f"pr-{pr}")

    def owner_of(self, pr: int) -> dict[str, Any] | None:
        """The claim of `pr` ({} while it is being created), or None when unclaimed."""
        directory = self.claim_dir(pr)
        if not os.path.isdir(directory):
            return None
        return read_json(os.path.join(directory, "owner.json")) or {}

    def is_stale(self, pr: int, owner: dict[str, Any]) -> bool:
        now = time.time()
        if not owner:  # being created, or its creator died before writing owner.json
            try:
                return now - os.path.getmtime(self.claim_dir(pr)) > FRESH_CLAIM_SECONDS
            except OSError:
                return True
        if now - float(owner.get("heartbeat", 0)) > self.ttl:
            return True
        live = self.live()
        return live is not None and owner.get("owner") not in live

    def write_owner(self, pr: int, name: str, head: str) -> None:
        """(Re)write the claim of `pr` by `name`, keeping its `since` when it was ours."""
        now = time.time()
        old = self.owner_of(pr) or {}
        since = old.get("since", now) if old.get("owner") == name else now
        data = {"pr": pr, "owner": name, "head": head, "since": since, "heartbeat": now}
        write_json(os.path.join(self.claim_dir(pr), "owner.json"), data)
        self.touch(name)

    def claim(self, pr: int, name: str, head: str) -> tuple[int, str]:
        owner = self.owner_of(pr)
        if owner is not None and owner.get("owner") == name:
            self.write_owner(pr, name, head or owner.get("head", ""))
            return 0, f"PR #{pr}: already claimed by {name}"
        if owner is not None:
            if not self.is_stale(pr, owner):
                return EXIT_HELD, f"PR #{pr}: claimed by {owner.get('owner', '(being created)')}"
            aside = self.path("claims", f".stale-pr-{pr}-{time.time():.6f}-{os.getpid()}")
            with contextlib.suppress(OSError):  # another integrator moved it first
                os.rename(self.claim_dir(pr), aside)
        try:
            os.mkdir(self.claim_dir(pr))
        except FileExistsError:
            holder = (self.owner_of(pr) or {}).get("owner", "(being created)")
            return EXIT_HELD, f"PR #{pr}: claimed by {holder}"
        self.write_owner(pr, name, head)
        stolen = f" (re-claimed from {owner.get('owner', '?')})" if owner is not None else ""
        return 0, f"PR #{pr}: claimed by {name}{stolen}"

    def release(self, pr: int, name: str) -> tuple[int, str]:
        owner = self.owner_of(pr)
        if owner is None:
            return 0, f"PR #{pr}: not claimed"
        if owner.get("owner") != name:
            return EXIT_HELD, f"PR #{pr}: claimed by {owner.get('owner', '(being created)')}"
        aside = self.path("claims", f".released-pr-{pr}-{time.time():.6f}-{os.getpid()}")
        os.rename(self.claim_dir(pr), aside)
        for leftover in os.listdir(aside):
            os.remove(os.path.join(aside, leftover))
        os.rmdir(aside)
        self.touch(name)
        return 0, f"PR #{pr}: released by {name}"

    def heartbeat(self, pr: int, name: str) -> tuple[int, str]:
        owner = self.owner_of(pr)
        if not owner or owner.get("owner") != name:
            holder = (owner or {}).get("owner", "nobody")
            return EXIT_HELD, f"PR #{pr}: not claimed by {name} (held by {holder})"
        self.write_owner(pr, name, owner.get("head", ""))
        return 0, f"PR #{pr}: heartbeat"

    def claims(self) -> list[tuple[int, dict[str, Any]]]:
        result = []
        for entry in sorted(os.listdir(self.path("claims"))):
            if entry.startswith("pr-") and entry[3:].isdigit():
                pr = int(entry[3:])
                result.append((pr, self.owner_of(pr) or {}))
        return result

    # Bounces and the queue ------------------------------------------------------------------

    def bounce(self, pr: int, head: str, name: str) -> tuple[int, str]:
        data = {"pr": pr, "head": head, "owner": name, "at": time.time()}
        write_json(self.path("bounced", f"pr-{pr}.json"), data)
        self.release(pr, name)
        return 0, f"PR #{pr}: bounced at {head[:12]}"

    def bounced_head(self, pr: int) -> str:
        return str((read_json(self.path("bounced", f"pr-{pr}.json")) or {}).get("head", ""))

    def queue_state(self, pr: dict[str, Any], name: str) -> str | None:
        """free, mine or stale for a claimable PR; None when it must be skipped."""
        if pr.get("isDraft"):
            return None
        number = int(pr["number"])
        if pr.get("headRefOid") and self.bounced_head(number) == pr["headRefOid"]:
            return None
        owner = self.owner_of(number)
        if owner is None:
            return "free"
        if name and owner.get("owner") == name:
            return "mine"
        return "stale" if self.is_stale(number, owner) else None

    # Plan reports ---------------------------------------------------------------------------

    def report_add(self, pr: int, fields: dict[str, str]) -> tuple[int, str]:
        """Record that PR `pr` merged (`fields`: sha, owner, tasks) for the coordinator."""
        data = {"pr": pr, **fields, "at": time.time()}
        write_json(self.path("reports", f"pr-{pr}.json"), data)
        return 0, f"PR #{pr}: plan report pending for the coordinator"

    def report_done(self, pr: int) -> tuple[int, str]:
        src = self.path("reports", f"pr-{pr}.json")
        if not os.path.exists(src):
            return 1, f"PR #{pr}: no pending plan report"
        os.replace(src, self.path("reports", "done", f"pr-{pr}.json"))
        return 0, f"PR #{pr}: plan report done"

    def report_known(self, pr: int) -> bool:
        name = f"pr-{pr}.json"
        return any(
            os.path.exists(p)
            for p in (self.path("reports", name), self.path("reports", "done", name))
        )

    def reports(self) -> list[dict[str, Any]]:
        found = []
        for entry in sorted(os.listdir(self.path("reports"))):
            data = read_json(self.path("reports", entry)) if entry.endswith(".json") else None
            if data:
                found.append(data)
        return sorted(found, key=lambda d: d.get("at", 0))


# The merge lock -------------------------------------------------------------------------------


def acquire(fd: int, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.2)


def lock_run(state: State, args: argparse.Namespace) -> int:
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        print("pool-state: lock run needs a command after --", file=sys.stderr)
        return 1
    fd = os.open(state.path("lock", "merge.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        if not acquire(fd, args.timeout):
            holder = read_json(state.path("lock", "merge.owner.json")) or {}
            print(
                f"pool-state: merge lock not acquired in {args.timeout:g} s"
                f" (held by {holder.get('owner', '?')})",
                file=sys.stderr,
            )
            return EXIT_LOCK_TIMEOUT
        owner = {"owner": args.owner, "pid": os.getpid(), "cwd": os.getcwd(), "since": time.time()}
        write_json(state.path("lock", "merge.owner.json"), owner)
        try:
            if args.expect_base:
                subprocess.run(["git", "fetch", "--quiet", "origin", args.base], check=False)
                now = git("rev-parse", f"origin/{args.base}")
                if now != args.expect_base:
                    print(f"base moved: origin/{args.base} is {now}, expected {args.expect_base}")
                    return EXIT_BASE_MOVED
            return subprocess.call(command)
        finally:
            with contextlib.suppress(OSError):
                os.remove(state.path("lock", "merge.owner.json"))
    finally:
        os.close(fd)  # releases the flock


def lock_status(state: State) -> int:
    fd = os.open(state.path("lock", "merge.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            holder = read_json(state.path("lock", "merge.owner.json")) or {}
            age = time.time() - float(holder.get("since", time.time()))
            print(f"held by {holder.get('owner', '?')} for {age:.0f} s")
            return 1
        print("free")
        return 0
    finally:
        os.close(fd)


# Command line ---------------------------------------------------------------------------------


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--state-dir", help="default: <git common dir>/multi-agent-herdr")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("claim", "release", "heartbeat", "bounce"):
        c = sub.add_parser(name)
        c.add_argument("pr", type=int)
        c.add_argument("--owner", required=True)
        c.add_argument("--head", default="", required=name == "bounce")
    sub.add_parser("claims")
    q = sub.add_parser("queue")
    q.add_argument("--base", required=True)
    q.add_argument("--owner", default="")
    lock = sub.add_parser("lock")
    lock_sub = lock.add_subparsers(dest="lock_cmd", required=True)
    run = lock_sub.add_parser("run")
    run.add_argument("--owner", required=True)
    run.add_argument("--timeout", type=float, default=600)
    run.add_argument("--expect-base", default="")
    run.add_argument("--base", default="main")
    run.add_argument("command", nargs=argparse.REMAINDER)
    lock_sub.add_parser("status")
    report = sub.add_parser("report")
    report_sub = report.add_subparsers(dest="report_cmd", required=True)
    add = report_sub.add_parser("add")
    add.add_argument("pr", type=int)
    add.add_argument("--sha", required=True)
    add.add_argument("--owner", required=True)
    add.add_argument("--tasks", default="")
    report_sub.add_parser("list")
    for name in ("done", "known"):
        report_sub.add_parser(name).add_argument("pr", type=int)
    for name in ("activity", "idle-seconds"):
        sub.add_parser(name).add_argument("name")
    return p


def queue(state: State, base: str, name: str) -> int:
    fields = "number,title,headRefName,headRefOid,isDraft,createdAt"
    proc = subprocess.run(
        ["gh", "pr", "list", "--base", base, "--state", "open", "--limit", "200", "--json", fields],
        capture_output=True, text=True,
    )  # fmt: skip
    if proc.returncode != 0:
        print(f"pool-state: gh pr list failed: {proc.stderr.strip()}", file=sys.stderr)
        return 1
    for pr in sorted(json.loads(proc.stdout), key=lambda p: p.get("createdAt", "")):
        status = state.queue_state(pr, name)
        if status:
            fields_out = [str(pr["number"]), pr.get("headRefName", ""), pr.get("headRefOid", "")]
            print("\t".join([*fields_out, status, pr.get("title", "")]))
    return 0


def run(state: State, args: argparse.Namespace) -> int:
    result: tuple[int, str] | None = None
    if args.cmd == "claim":
        result = state.claim(args.pr, args.owner, args.head)
    elif args.cmd == "release":
        result = state.release(args.pr, args.owner)
    elif args.cmd == "heartbeat":
        result = state.heartbeat(args.pr, args.owner)
    elif args.cmd == "bounce":
        result = state.bounce(args.pr, args.head, args.owner)
    elif args.cmd == "claims":
        for pr, owner in state.claims():
            age = time.time() - float(owner.get("heartbeat", 0)) if owner else 0
            status = "stale" if state.is_stale(pr, owner) else "live"
            print(f"{pr}\t{owner.get('owner', '?')}\t{owner.get('head', '')}\t{age:.0f}\t{status}")
        return 0
    elif args.cmd == "queue":
        return queue(state, args.base, args.owner)
    elif args.cmd == "lock":
        return lock_run(state, args) if args.lock_cmd == "run" else lock_status(state)
    elif args.cmd == "report":
        return report(state, args)
    elif args.cmd == "activity":
        state.touch(args.name)
        return 0
    elif args.cmd == "idle-seconds":
        try:
            mtime = os.path.getmtime(state.path("members", f"{args.name}.activity"))
        except OSError:
            mtime = 0
        print(int(time.time() - mtime))
        return 0
    code, message = result or (1, "unknown command")
    print(message, file=sys.stdout if code == 0 else sys.stderr)
    return code


def report(state: State, args: argparse.Namespace) -> int:
    if args.report_cmd == "add":
        fields = {"sha": args.sha, "owner": args.owner, "tasks": args.tasks}
        code, message = state.report_add(args.pr, fields)
    elif args.report_cmd == "done":
        code, message = state.report_done(args.pr)
    elif args.report_cmd == "known":
        return 0 if state.report_known(args.pr) else 1
    else:
        for item in state.reports():
            tasks = " ".join(str(item.get("tasks", "")).split())
            print(f"{item['pr']}\t{item.get('sha', '')}\t{item.get('owner', '')}\t{tasks}")
        return 0
    print(message, file=sys.stdout if code == 0 else sys.stderr)
    return code


def main() -> int:
    args = parser().parse_args()
    try:
        root = args.state_dir or os.path.join(common_dir(), STATE)
        settings = pool_settings()
    except (subprocess.CalledProcessError, OSError) as exc:
        print(f"pool-state: not inside a git repository: {exc}", file=sys.stderr)
        return 1
    except ValueError as exc:  # project_config.ConfigError
        print(f"pool-state: {exc}", file=sys.stderr)
        return 1
    return run(State(root, int(settings["claim_ttl_minutes"])), args)


if __name__ == "__main__":
    sys.exit(main())
