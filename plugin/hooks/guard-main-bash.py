#!/usr/bin/env python3
"""PreToolUse guard for Bash: shell-side counterpart of guard-main-worktree.sh.

Part of the multi-agent-herdr plugin (ported from multi-agent 0.1.0; only the plugin id
and the block message differ).

Only the integrator session (CLAUDE_ROLE=integrator) may change the main worktree or the
protected branches (see "Multi-agent workflow" in CLAUDE.md). It only acts on repositories
that enabled the plugin in `.claude/settings.json` or `.claude/settings.local.json`
(`enabledPlugins` value `true`; `settings.local.json` wins when it sets the key). There, for
every other session, it blocks:

* from any worktree: `git push` to a protected branch (`main`, the project's `base_branch`
  and its `protected_branches` patterns, from `.claude/multi-agent-herdr.json`; see
  scripts/project-config.py), `git push --all` / `--mirror`, and `gh pr merge`.
* from any worktree, herdr commands that type into another pane or take over another agent:
  `herdr agent send-keys|attach|rename`, `herdr pane run|send-keys|send-text`,
  `herdr terminal attach|session`, and `herdr agent prompt` to any target but the project's
  integrator (`integrator_name`, default `integrator`).
  Without this, a development agent could run `git push origin main` in the integrator's pane
  or answer its approval dialog, outside any guarded Bash call.
* in the main worktree: git commands that change the checkout or its history (commit, merge,
  checkout, switch, reset, stash...), dependency changes (`uv add|remove|lock|sync`,
  `npm|pnpm|yarn install|add|remove`...), formatters that rewrite files, and file writes
  (`>`, `sed -i`, `tee`, `rm`, `mv`, `cp`, `touch`, `mkdir`) whose target is inside the main
  worktree. Writes to temporary directories are allowed.

It is a guardrail against mistakes, not a sandbox: the command is parsed with `shlex` per
`&&`/`||`/`;`/`|` segment, following `cd <dir>`, `git -C <dir>`, the `env`/`command`/`exec`/
`builtin`/`nohup`/`time` prefixes and `sh|bash|zsh -c` / `eval` strings (up to 3 levels).
herdr is recognised by name or path, by `$HERDR_BIN_PATH`, and as any unresolved `$VAR`
program given an input-sending herdr subcommand; the herdr rules apply whenever the session
itself, or the directory the command `cd`s to, is in an enabled repository. A creative
command (another language, a script file, an alias, `xargs`) can still get through. Exit
code 2 blocks the call and shows stderr to the agent. Any internal error allows the command
(the hook must never wedge a session).

Python 3.9 compatible: it runs under the system `python3`, not a project virtualenv.
"""

from __future__ import annotations

import fnmatch
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
from typing import Any

GIT_MUTATING = {
    "add", "am", "apply", "checkout", "cherry-pick", "clean", "commit", "merge", "mv", "pull",
    "rebase", "reset", "restore", "revert", "rm", "stash", "switch",
}  # fmt: skip
FILE_WRITERS = {"rm", "mv", "cp", "touch", "mkdir", "ln", "truncate", "tee", "rmdir"}
# Package managers and the subcommands that rewrite manifests, lockfiles or installed deps.
DEP_CHANGERS = {
    "uv": {"add", "remove", "lock", "sync"},
    "npm": {"install", "i", "add", "uninstall", "remove", "update", "ci"},
    "pnpm": {"install", "i", "add", "remove", "update"},
    "yarn": {"install", "add", "remove", "upgrade"},
    "poetry": {"add", "remove", "lock", "install", "update"},
    "cargo": {"add", "remove", "update"},
}  # fmt: skip
# Writes under these prefixes are allowed: a list of paths to match, not a file being created.
TEMP_PREFIXES = ("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", "/dev/")  # noqa: S108
SEPARATORS = {"&&", "||", ";", "|", "&"}
PLUGIN_ID = "multi-agent-herdr@claude-code-herdr"


def git_dirs(path: str) -> tuple[str, str] | None:
    """(git dir, common git dir) of the repository containing `path`, or None."""
    while path and not os.path.isdir(path):
        path = os.path.dirname(path)
    try:
        out = subprocess.run(
            ["git", "-C", path, "rev-parse", "--absolute-git-dir",
             "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, check=True, timeout=5,
        ).stdout.split()  # fmt: skip
    except (subprocess.SubprocessError, OSError):
        return None
    return (out[0], out[1]) if len(out) == 2 else None


def enabled(common_dir: str) -> bool:
    """Whether the repository with this common git dir enabled the plugin for the project.

    A user-scope install must not lock the main checkout of every repository, so the guards
    only apply where `enabledPlugins` maps the plugin id to `true`. `settings.local.json`
    overrides `settings.json` when it sets the key (as in Claude Code); a missing or
    unparseable file counts as not setting it.
    """
    root = os.path.dirname(common_dir)
    for name in ("settings.local.json", "settings.json"):
        try:
            with open(os.path.join(root, ".claude", name)) as f:
                value = (json.load(f).get("enabledPlugins") or {}).get(PLUGIN_ID)
        except (OSError, ValueError, AttributeError):
            continue
        if value is not None:
            return value is True
    return False


def guarded_repo(path: str) -> bool:
    """Whether `path` is inside a repository that follows the multi-agent workflow."""
    dirs = git_dirs(path)
    return dirs is not None and enabled(dirs[1])


def _load_project_config() -> Any:
    """The plugin's scripts/project-config.py as a module (one reader for every component)."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts",
                        "project-config.py")  # fmt: skip
    spec = importlib.util.spec_from_file_location("project_config", path)
    module = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


project_config = _load_project_config()


def settings(path: str) -> dict[str, Any] | None:
    """Project settings of the enabled repository containing `path`, or None.

    An invalid `.claude/multi-agent-herdr.json` falls back to the defaults: the guard must not
    wedge every session, and the defaults still protect `main` (the skills and scripts stop on
    the invalid file and report it).
    """
    dirs = git_dirs(path)
    if dirs is None or not enabled(dirs[1]):
        return None
    root = os.path.dirname(dirs[1])
    try:
        return project_config.load(root)  # type: ignore[no-any-return]
    except project_config.ConfigError:
        return project_config.defaults(root)  # type: ignore[no-any-return]


def protected(config: dict[str, Any]) -> list[str]:
    """Branch patterns only the integrator may push: main, base_branch, protected_branches."""
    return ["main", config["base_branch"], *config["protected_branches"]]


def push_target(refspec: str) -> str:
    """Branch a `git push` refspec writes: the part after `:`, without `+` and `refs/heads/`."""
    dest = refspec.lstrip("+").rsplit(":", 1)[-1]
    return dest[len("refs/heads/") :] if dest.startswith("refs/heads/") else dest


def in_main_worktree(path: str) -> bool:
    dirs = git_dirs(path)
    return dirs is not None and dirs[0] == dirs[1] and enabled(dirs[1])


def resolve(cwd: str, path: str) -> str:
    return os.path.normpath(os.path.join(cwd, os.path.expanduser(path)))


def is_temp(path: str) -> bool:
    tmpdir = os.environ.get("TMPDIR", "")
    return path.startswith(TEMP_PREFIXES) or bool(tmpdir and path.startswith(tmpdir))


def writes_into_main(cwd: str, target: str) -> bool:
    path = resolve(cwd, target)
    return not is_temp(path + "/") and in_main_worktree(path)


def rewrites_files(prog: str, args: list[str]) -> bool:
    """Whether a formatter / linter invocation rewrites files in place."""
    if prog == "ruff":
        return (args[:1] == ["format"] and "--check" not in args) or "--fix" in args
    if prog in {"black", "isort"}:
        return "--check" not in args and "--diff" not in args
    if prog in {"prettier", "eslint", "biome"}:
        return bool({"--write", "-w", "--fix", "--apply"} & set(args)) or args[:1] == ["format"]
    if prog in {"gofmt", "rustfmt"}:
        return "-w" in args or prog == "rustfmt"
    return False


# herdr commands that type into, or take over, a pane other than the caller's own.
HERDR_INPUT = {
    ("agent", "send-keys"), ("agent", "attach"), ("agent", "rename"), ("pane", "run"),
    ("pane", "send-keys"), ("pane", "send-text"), ("terminal", "attach"), ("terminal", "session"),
}  # fmt: skip
HERDR_VALUE_OPTS = {"--session", "--machine", "--remote", "--remote-keybindings"}


def herdr_reason(args: list[str], integrators: set[str] | None = None) -> str | None:
    """Reason to block a `herdr ...` invocation from a non-integrator session, or None.

    `integrators` are the herdr names development agents may `agent prompt` (the integrator of
    each enabled repository involved); default `{"integrator"}`.
    """
    integrators = integrators or {"integrator"}
    words = list(args)
    while words and words[0].startswith("-"):  # global options such as --machine <label>
        opt = words.pop(0)
        if opt in HERDR_VALUE_OPTS and words:
            words.pop(0)
    group, sub = (words + ["", ""])[:2]
    if (group, sub) in HERDR_INPUT:
        return f"`herdr {group} {sub}` sends input to another pane; only the integrator may"
    if (group, sub) == ("agent", "prompt"):
        target = next((w for w in words[2:] if not w.startswith("-")), "")
        if target not in integrators:
            names = ", ".join(f"`{n}`" for n in sorted(integrators))
            return f"development agents may `herdr agent prompt` only the integrator ({names})"
    return None


HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?\n\s*\2\s*(?=\n|$)", re.S)
REDIRECT = re.compile(r"^&?>+[&|]?$")


def segments(command: str) -> list[list[str]]:
    """Split a command line into simple commands (lists of words).

    Heredoc bodies are dropped (they are data, e.g. a commit message), and newlines separate
    commands like `;` does.
    """
    command = HEREDOC.sub(lambda m: m.group(0).split("\n", 1)[0].split("<<", 1)[0], command)
    command = command.replace("\n", " ; ")
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|<>")
    lexer.whitespace_split = True
    result: list[list[str]] = [[]]
    for token in lexer:
        if token in SEPARATORS:
            result.append([])
        else:
            result[-1].append(token)
    return [s for s in result if s]


WRAPPERS = {"command", "exec", "builtin", "nohup", "time"}  # run their argument as the command
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
MAX_DEPTH = 3  # nested `bash -c` / `eval` strings followed


def is_herdr(word: str, args: list[str]) -> bool:
    """Whether the program word `word` runs herdr.

    Covers a path ending in `herdr`, the `$HERDR_BIN_PATH` / `${HERDR_...}` variables herdr
    injects into its panes (expanded with this hook's environment when set), and any other
    unresolved `$VAR` program whose arguments are a herdr subcommand that sends input.
    """
    if os.path.basename(os.path.expandvars(word)) == "herdr":
        return True
    if re.fullmatch(r"\$\{?HERDR_\w*\}?", word):
        return True
    return word.startswith("$") and herdr_reason(args) is not None


def check_segment(  # noqa: C901 (complexity 35; capped by lizard, see docs/code-quality.md)
    words: list[str], cwd: str, session: str = "", depth: int = 0
) -> str | None:
    """Reason to block this simple command, or None.

    `cwd` follows `cd` within the command line; `session` is the session's own directory (the
    hook payload's cwd), which decides whether the herdr rules apply: herdr commands act on
    the herdr server, not on a directory, so a `cd` elsewhere must not disable them.
    """
    session = session or cwd
    # Redirections (`> f`, `>> f`, `2> f`, `&> f`; shlex splits the operator off). Drop the
    # operator, its target and a file-descriptor number before it from the words.
    kept: list[str] = []
    i = 0
    while i < len(words):
        word = words[i]
        if REDIRECT.match(word) or word == "<":
            target = words[i + 1] if i + 1 < len(words) else ""
            if word != "<" and target and not target.isdigit() and writes_into_main(cwd, target):
                return f"writes {target} inside the main worktree"
            if kept and kept[-1].isdigit():
                kept.pop()
            i += 2
            continue
        kept.append(word)
        i += 1
    words = kept
    while words:
        if words[0] == "env" or words[0] in WRAPPERS:
            # `env VAR=value cmd`, `command cmd`, `exec cmd`...: the argument is the command.
            words = words[1:]
            while words and words[0].startswith("-"):
                words = words[1:]  # wrapper options (`command -p`, `env -i`)
        elif re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
            words = words[1:]  # leading VAR=value assignments
        else:
            break
    if not words:
        return None
    prog, args = os.path.basename(words[0]), words[1:]

    # `bash -c '<command>'` and `eval '<command>'`: check the command string itself.
    inner = None
    if prog in SHELLS and "-c" in args[:-1]:
        inner = args[args.index("-c") + 1]
    elif prog == "eval":
        inner = " ".join(args)
    if inner is not None and depth < MAX_DEPTH:
        return check_command(inner, cwd, session, depth + 1)

    if is_herdr(words[0], args):
        # Either directory being in an enabled repository is enough: a `cd` out of the repo
        # must not disable the rule, and neither must starting outside it and `cd`-ing in.
        configs = [c for c in (settings(session), settings(cwd)) if c is not None]
        if not configs:
            return None
        return herdr_reason(args, {c["integrator_name"] for c in configs})
    if prog == "npx" or (prog in {"uv", "pnpm"} and args[:1] in (["run"], ["exec"], ["dlx"])):
        # `uv run ruff ...`, `npx prettier ...`: check the tool that actually runs.
        args = args[1:] if prog != "npx" else args
        while args and args[0].startswith("-"):
            args = args[1:]  # runner options (--quiet, --frozen...)
        prog, args = (os.path.basename(args[0]), args[1:]) if args else ("", [])

    if prog == "gh" and args[:2] == ["pr", "merge"] and guarded_repo(cwd):
        return "only the integrator merges pull requests"

    if prog == "git":
        git_cwd = cwd
        while len(args) >= 2 and args[0] in {"-C", "-c"}:
            if args[0] == "-C":
                git_cwd = resolve(git_cwd, args[1])
            args = args[2:]
        sub = args[0] if args else ""
        config = settings(git_cwd) if sub == "push" else None
        if config is not None:
            refs = [a for a in args[1:] if not a.startswith("-")]
            if {"--all", "--mirror"} & set(args):
                return "`git push --all/--mirror` would push protected branches"
            patterns = protected(config)
            for ref in refs[1:]:
                branch = push_target(ref)
                if any(fnmatch.fnmatchcase(branch, p) for p in patterns):
                    return (f"pushing to the protected branch {branch}; open a pull request "
                            "with /multi-agent-herdr:pr instead")  # fmt: skip
        if sub in GIT_MUTATING and in_main_worktree(git_cwd):
            return f"`git {sub}` in the main worktree"
        changes_branch = sub == "branch" and {"-d", "-D", "-m", "-M", "-f"} & set(args)
        if changes_branch and in_main_worktree(git_cwd):
            return "`git branch` changes in the main worktree"
        return None

    if not in_main_worktree(cwd):
        return None
    if prog in DEP_CHANGERS and args[:1] and args[0] in DEP_CHANGERS[prog]:
        return f"`{prog} {args[0]}` changes the main worktree's dependencies"
    if rewrites_files(prog, args):
        return f"`{prog}` rewriting files in the main worktree"
    if prog in {"sed", "perl"} and any(a == "-i" or a.startswith("-i") for a in args):
        targets = [a for a in args if not a.startswith("-")][1:]
        if any(writes_into_main(cwd, t) for t in targets) or not targets:
            return f"`{prog} -i` editing files in the main worktree"
    if prog in FILE_WRITERS:
        targets = [a for a in args if not a.startswith("-")]
        if prog in {"cp", "mv", "ln"}:
            targets = targets[-1:]  # only the destination is written
        if not targets or any(writes_into_main(cwd, t) for t in targets):
            return f"`{prog}` writing inside the main worktree"
    return None


def check_command(command: str, cwd: str, session: str, depth: int = 0) -> str | None:
    """Reason to block a whole command line, or None; follows `cd` from segment to segment."""
    for words in segments(command):
        if words[0] == "cd":
            cwd = resolve(cwd, words[1]) if len(words) > 1 else os.path.expanduser("~")
            continue
        reason = check_segment(words, cwd, session, depth)
        if reason:
            return reason
    return None


def main() -> int:
    if os.environ.get("CLAUDE_ROLE") == "integrator":
        return 0
    try:
        payload = json.load(sys.stdin)
        command = payload.get("tool_input", {}).get("command", "")
        cwd = payload.get("cwd") or os.getcwd()
        reason = check_command(command, cwd, session=cwd)
    except Exception:  # a broken guard must not block the session
        return 0
    if not reason:
        return 0
    print(
        f"Blocked: {reason}.\n"
        "Only the integrator agent may change the main worktree or the protected branches. "
        "Development happens "
        "in a worktree of its own, started by the integrator with /multi-agent-herdr:dispatch "
        '(one git worktree and one herdr workspace per agent). See "Multi-agent workflow" in '
        "CLAUDE.md. If you are the integrator, launch Claude Code with scripts/integrator.sh "
        "(CLAUDE_ROLE=integrator).",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
