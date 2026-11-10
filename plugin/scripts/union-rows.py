#!/usr/bin/env python3
"""Resolve a merge conflict in a Markdown index table by keeping the rows of both sides.

Part of the multi-agent-herdr plugin: integrate-pr.sh runs it on the files given with
`--union-rows PATH` (for example `docs/decisions/README.md`, where two PRs each add an ADR
row). It is the only conflict the integrator resolves itself, because it is mechanical:

* every conflict hunk of the file must consist of table rows (lines starting with `|`) on
  both sides; the hunk is replaced by the union of both sides' rows, identical rows once,
  sorted by their text (index rows start with their key, e.g. `| [0042](0042-x.md) | ...`);
* two different rows with the same key (the first cell, or the label of the link that starts
  it: two PRs that both took ADR 0042) are a
  numbering collision, not a mechanical conflict: the file is left untouched.

Anything else (a hunk with prose, an unterminated marker) also leaves the file untouched.
Handles the `diff3` / `zdiff3` conflict styles (the `|||||||` base section is dropped).

Usage: union-rows.py PATH        Exit codes: 0 resolved (file rewritten); 1 not mechanical
(reason on stderr, file unchanged); 2 usage or I/O error. Python 3.9 compatible.
"""

from __future__ import annotations

import re
import sys

OURS, BASE, THEIRS, END = "<<<<<<< ", "||||||| ", "=======", ">>>>>>> "


class NotMechanical(ValueError):
    """The conflict needs a human (or a bounce)."""


def first_cell(row: str) -> str:
    """The row's key: its first cell, or the label of a Markdown link that starts it."""
    cell = row.strip().strip("|").split("|", 1)[0].strip()
    link = re.match(r"\[([^\]]*)\]", cell)
    return link.group(1) if link else cell


def union(ours: list[str], theirs: list[str]) -> list[str]:
    rows = [r for r in ours + theirs if r.strip()]
    if not all(r.lstrip().startswith("|") for r in rows):
        raise NotMechanical("a conflict hunk contains lines that are not table rows")
    unique = sorted(set(rows))
    keys = [first_cell(r) for r in unique]
    clashes = sorted({k for k in keys if keys.count(k) > 1})
    if clashes:
        raise NotMechanical(f"two different rows share the key {', '.join(clashes)}")
    return unique


def resolve(lines: list[str]) -> list[str]:
    out: list[str] = []
    i = 0
    while i < len(lines):
        if not lines[i].startswith(OURS):
            out.append(lines[i])
            i += 1
            continue
        sides: dict[str, list[str]] = {"ours": [], "base": [], "theirs": []}
        side = "ours"
        i += 1
        while i < len(lines) and not lines[i].startswith(END):
            line = lines[i]
            if line.startswith(BASE):
                side = "base"
            elif line.rstrip("\n") == THEIRS:
                side = "theirs"
            else:
                sides[side].append(line)
            i += 1
        if i == len(lines):
            raise NotMechanical("unterminated conflict marker")
        out.extend(union(sides["ours"], sides["theirs"]))
        i += 1  # the >>>>>>> line
    return out


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: union-rows.py PATH", file=sys.stderr)
        return 2
    path = sys.argv[1]
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError as exc:
        print(f"union-rows: {exc}", file=sys.stderr)
        return 2
    try:
        resolved = resolve(lines)
    except NotMechanical as exc:
        print(f"union-rows: {path}: {exc}", file=sys.stderr)
        return 1
    with open(path, "w") as f:
        f.writelines(r if r.endswith("\n") else r + "\n" for r in resolved)
    return 0


if __name__ == "__main__":
    sys.exit(main())
