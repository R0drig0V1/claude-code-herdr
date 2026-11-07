#!/usr/bin/env python3
"""Fail when a skill contains an argument placeholder that Claude Code would substitute by mistake.

Claude Code replaces these tokens in a skill's SKILL.md content when the skill is invoked
(https://code.claude.com/docs/en/skills#available-string-substitutions):

- ``$ARGUMENTS``: all arguments as typed;
- ``$ARGUMENTS[N]`` and its shorthand ``$N`` (``$0``, ``$1``, ...): one argument by index;
- ``$name`` for each name declared in the ``arguments`` frontmatter field.

Shell and awk use the same spelling (awk ``$0``, a script's ``$1``), so a snippet that uses them
reaches the agent with the arguments pasted in. The dispatch skill's
``awk '... substr($0,10) ... $0==b ...'`` broke exactly that way. Rules, per SKILL.md:

1. No positional token anywhere: ``$N``, ``${N}`` or ``$ARGUMENTS[N]``. Move such code into
   a script under plugin/scripts/ and call it from the skill. The documented backslash escape
   (``\\$1``) is rejected too: it is easy to lose in a shell snippet, so reword instead.
2. ``$ARGUMENTS`` only in prose, never inside a fenced code block: it is meant for Claude to
   read, not for a shell to run with the user's text spliced in.
3. A name declared in ``arguments:`` is never used as ``$name`` inside a fenced code block.

Usage: check-skill-substitutions.py [skills dir]   (default: plugin/skills next to tests/)
Exit codes: 0 clean; 1 findings (printed as ``file:line: message``); 2 no SKILL.md found.
Agent definitions (plugin/agents/*.md) are not checked: the docs describe these substitutions
for skills only.
"""

from __future__ import annotations

import pathlib
import re
import sys

POSITIONAL = re.compile(r"\$(?:\d+|\{\d+\}|ARGUMENTS\[\d*\]?)")
ARGUMENTS = re.compile(r"\$ARGUMENTS(?![\w\[])")
FENCE = re.compile(r"^\s*(```|~~~)")


def declared_arguments(text: str) -> list[str]:
    """Names from the ``arguments`` frontmatter field (space-separated string or YAML list)."""
    match = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not match:
        return []
    names: list[str] = []
    lines = match.group(1).splitlines()
    for i, line in enumerate(lines):
        if not line.startswith("arguments:"):
            continue
        value = line.split(":", 1)[1].strip()
        if value:
            names += re.findall(r"[A-Za-z_]\w*", value)
        else:  # block list on the following "- name" lines
            for item in lines[i + 1 :]:
                if not item.lstrip().startswith("- "):
                    break
                names.append(item.strip()[2:].strip().strip("'\""))
    return names


def check_file(path: pathlib.Path) -> list[str]:
    """Return one ``file:line: message`` string per finding in one SKILL.md."""
    text = path.read_text(encoding="utf-8")
    named = [(n, re.compile(rf"\${re.escape(n)}(?!\w)")) for n in declared_arguments(text)]
    findings = []
    in_code = False
    for number, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line):
            in_code = not in_code
            continue
        where = f"{path}:{number}"
        for m in POSITIONAL.finditer(line):
            findings.append(f"{where}: positional token {m.group(0)!r}")
        if not in_code:
            continue
        if ARGUMENTS.search(line):
            findings.append(f"{where}: $ARGUMENTS inside a code block")
        findings += [
            f"{where}: declared argument ${n} in a code block" for n, p in named if p.search(line)
        ]
    return findings


def main() -> int:
    """Check every */SKILL.md under the skills directory and print the findings."""
    default = pathlib.Path(__file__).resolve().parent.parent / "plugin" / "skills"
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else default
    files = sorted(root.glob("*/SKILL.md"))
    if not files:
        print(f"no */SKILL.md under {root}", file=sys.stderr)
        return 2
    findings = [f for path in files for f in check_file(path)]
    for finding in findings:
        print(finding)
    if findings:
        print(
            "Claude Code substitutes these tokens with the skill's arguments; see "
            "tests/check-skill-substitutions.py for the rules.",
            file=sys.stderr,
        )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
