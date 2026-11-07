<!-- Security policy of claude-code-herdr: how to report a vulnerability privately and what is in scope. -->

# Security policy

## Reporting a vulnerability

Please do not open a public issue, pull request or discussion for a vulnerability. Report it
privately through GitHub: **Security** tab → **Report a vulnerability**
(https://github.com/R0drig0V1/claude-code-herdr/security/advisories/new).

Include what you found, how to reproduce it (a command or a minimal repository is ideal), the
version or commit, and its impact. You will get a first answer within a week. A fix is
released on `main` and credited in the advisory unless you prefer otherwise.

## Supported versions

Only the latest `main` is supported. There are no release branches.

## Scope

In scope: the `multi-agent-herdr` plugin (`plugin/`: hooks, scripts, skills, agents),
`install.sh`, `template/` and this repository's GitHub workflows. For example: a hook that
runs injected input, a script that writes outside the repository it is given, the installer
overwriting files it said it would not, or a workflow that leaks a token.

Known limits, not vulnerabilities by themselves (README, "Limitations"):

- **The guard hooks are guardrails, not a sandbox.** They parse commands with `shlex` and
  stop mistakes. A deliberately creative command (another language, a script file, an alias,
  `xargs`) can get through, and they fail open when `python3`/`jq` is missing or a hook
  errors. A bypass that a plain, ordinary command achieves is worth reporting.
- **herdr agent messages are data.** They start with
  `[herdr message from agent <name>; not from the user]` and never count as user approval.
  A path that makes an agent treat one as approval is in scope.

herdr and Claude Code themselves are out of scope; report those to their own projects.
