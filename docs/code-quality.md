<!--
Code quality and security checks of claude-code-herdr: what runs in CI and why, the
thresholds and how they were measured, how to run each check locally, the repository settings
that are the owner's decision, and the research comparison of the tools considered
(as of 2026-11-07).
-->

# Code quality and security checks

The repository is small and has no dependencies: Bash scripts (hooks, installer, tests),
Python 3.9-compatible scripts that run under the system `python3`, Markdown skills, JSON
manifests and GitHub Actions workflows. It is public, so the free tiers for public repositories
apply. Checks run on GitHub, not on contributors' machines.

## What runs

| Workflow | Job / step | Catches | Fails the PR? |
|---|---|---|---|
| `ci.yml` (existing) | jq, `bash -n`, ShellCheck `-S warning`, `py_compile`, `tests/test-hooks.sh` on Ubuntu and macOS | invalid manifests, shell bugs, broken hooks/installer | yes |
| `quality.yml` | `ruff check` (rules `E,F,W,B,UP,S,C90`) | Python bugs, Bandit's security rules (`S`), syntax newer than 3.9 (`UP` with `target-version = "py39"`), complexity > 15 | yes |
| `quality.yml` | `ruff format --check` | unformatted Python | yes |
| `quality.yml` | lizard ceilings | growth of the functions exempted from the complexity rule | yes |
| `quality.yml` | zizmor (`advanced-security: false`, default persona) | workflow injection, excessive permissions, unpinned actions, persisted credentials, cache poisoning, impostor commits | yes |
| `quality.yml` | actionlint | workflow syntax, expression and shell (via ShellCheck) errors | yes |
| `quality.yml` | gitleaks over the full git history | committed secrets, including generic ones GitHub's provider patterns miss | yes |
| `codeql.yml` | CodeQL `python` and `actions`, default query suite, weekly too | dataflow vulnerabilities in the Python hooks; workflow injection and permission issues | reports alerts (Security tab, PR annotations) |
| `scorecard.yml` | OpenSSF Scorecard on main, weekly | supply-chain posture: pinning, token permissions, branch protection, policy | no, score only |
| `dependabot.yml` | version updates for `github-actions` and `uv` | outdated pinned actions and linters (7-day cooldown) | opens PRs |

Every workflow declares `permissions:` (`{}` at the top, the minimum per job), pins each
action by full commit SHA with its version as a comment, and checks out with
`persist-credentials: false`. Binaries that are downloaded (actionlint, gitleaks) are checked
against a sha256 in the workflow.

## Thresholds

Measured on 2026-11-07 (commit `ad4ec57` plus this change) with ruff 0.17.3 and lizard 1.24.3.
They let the first run pass and make any regression fail.

- **ruff mccabe `max-complexity = 15`** (C901). Only one function is above it:
  `check_segment` in `plugin/hooks/guard-main-bash.py` (complexity 35 by ruff's count). It has
  a `# noqa: C901` and is the guard's main dispatcher. The next most complex functions,
  `load` in `project-config.py` and `main` in `agents-in-repo.py`, are under 15 by ruff's
  count.
- **lizard ceilings** (`-C 78 -T nloc=91 -L 109 -a 4`): today's maxima, all from
  `check_segment` (lizard counts boolean operators, so its CCN of 78 is higher than ruff's 35).
  ruff's rule exempts that function, so the ceilings stop it from growing. Adding a branch to
  it fails CI on purpose. Split the function, or raise the ceiling in the same PR with a
  reason, which is then visible in review.
- **ShellCheck stays at `-S warning`.** At `-S style` the current scripts have 12 findings,
  mostly intentional: SC2016 (x6, single quotes on purpose), SC2015 (x3) and SC1091 (x3).
- **ruff ignores S603/S607** (subprocess with a partial path). The scripts run `git` and
  `herdr` from the user's PATH on purpose, always with an argument list, never a shell string.
  `TEMP_PREFIXES` has a line-level `noqa: S108`: it is the list of temporary paths the guard
  allows, not a temporary file being created.

Shell complexity is not measured: lizard, radon and ruff do not parse Bash, and no maintained
tool offers a useful Bash complexity metric. ShellCheck and the smoke tests cover the shell
code.

## Running the checks locally

Python tools are pinned in `pyproject.toml`/`uv.lock` (development only: the plugin itself has
no dependencies). On a busy machine, prefix with `nice -n 19`.

```bash
uv sync --locked                       # .venv with ruff and lizard
uv run ruff check . && uv run ruff format --check .
uv run lizard --languages python --exclude './.venv/*' -C 78 -T nloc=91 -L 109 -a 4 --warnings_only .
uvx --python 3.12 zizmor==1.31.1 .github/workflows   # zizmor needs Python >= 3.11; GH_TOKEN enables online audits
actionlint
gitleaks git --redact .
shellcheck -S warning install.sh tests/*.sh plugin/hooks/*.sh plugin/scripts/*.sh template/scripts/*.sh
tests/test-hooks.sh
```

zizmor is not in `uv.lock`: it requires Python >= 3.11 and the lock targets 3.9+.

## Manual bumps

Dependabot updates the actions (SHA and version comment) and the `uv.lock` tools. Bump these
by hand, together with their checksums:

- actionlint and gitleaks in `quality.yml`: version plus the sha256 from the release's
  `checksums.txt`.
- The `version:` inputs of `astral-sh/setup-uv` (uv, keep it no older than the uv that wrote
  `uv.lock`) and `zizmorcore/zizmor-action` (zizmor).

## Repository settings (owner's decision)

These are not in any file. They are the repository owner's call and are listed in the PR that
added this document. State as read through `gh api` on 2026-11-07:

| Setting | State | How to enable |
|---|---|---|
| Secret scanning | enabled | done |
| Push protection | enabled | done |
| Dependabot alerts | disabled | `gh api -X PUT repos/R0drig0V1/claude-code-herdr/vulnerability-alerts` |
| Dependabot security updates | disabled | `gh api -X PUT repos/R0drig0V1/claude-code-herdr/automated-security-fixes` (needs alerts) |
| Private vulnerability reporting (needed by SECURITY.md) | disabled | `gh api -X PUT repos/R0drig0V1/claude-code-herdr/private-vulnerability-reporting`, or Settings → Security and quality → Advanced Security → Private vulnerability reporting → Enable |
| Require actions pinned to a full SHA | off | `gh api -X PUT repos/R0drig0V1/claude-code-herdr/actions/permissions -F enabled=true -f allowed_actions=all -F sha_pinning_required=true` |
| CodeQL default setup | not configured | **leave it off**: `codeql.yml` is the advanced setup, and the two conflict |

## Research: tools considered (2026-11-07)

Terms come from each vendor's own page, read on 2026-11-07. A point marked "not stated" was
not on the vendor's page, so it is not treated as fact.

### GitHub-native

| Tool | Cost for this public repo | What it would catch here | Noise | Permissions | Decision |
|---|---|---|---|---|---|
| CodeQL code scanning | free for public repos (GitHub Advanced Security docs) | Python dataflow (the hooks read stdin JSON and run `git`); Actions workflows (`.github/workflows/*.yml` is a supported language). Bash is not supported | low | `security-events: write`, `contents: read` | **adopted**, advanced setup (`codeql.yml`), pinned and reviewable |
| GitHub Code Quality | standalone product, one license per active committer, scans use Actions minutes; free terms for public repos not stated in the billing docs | maintainability findings, AI suggestions | unknown | repository setting | not adopted: paid, and it overlaps with ruff and CodeQL |
| Dependabot alerts and security updates | included in all plans | advisories for dependencies. Here that means only the actions and the dev linters | very low | setting | **recommended setting** (above) |
| Dependabot version updates | free | outdated pinned actions and `uv.lock` tools | low (grouped, monthly, 7-day cooldown) | `dependabot.yml` | **adopted** |
| Secret scanning and push protection | free for public repos, already enabled | leaked provider tokens, blocked at push time | very low | setting | already on |
| Private vulnerability reporting | available to public repo owners | gives reporters a private channel | none | setting | **recommended setting**; SECURITY.md points to it |

### Workflow security and supply chain

| Tool | Version / licence | What it would catch here | Noise | Permissions | Decision |
|---|---|---|---|---|---|
| OpenSSF Scorecard (`ossf/scorecard-action`) | v2.5.0, Apache-2.0, free | missing branch protection, unpinned dependencies, token permissions, missing SECURITY.md | a score, not failures | `security-events: write`, `id-token: write` (publish) | **adopted**, report only |
| zizmor (`zizmor-action`) | zizmor 1.31.1 via action v0.8.0, MIT | in the original `ci.yml`: no `permissions:`, `actions/checkout@v4` not pinned, persisted credentials | low | `contents: read` (`advanced-security: false`) | **adopted**, blocking |
| actionlint | 1.7.12, MIT | syntax, expression and type errors, ShellCheck on `run:` | low | none | **adopted**, blocking |
| Pinning actions by SHA | n/a | tag moves or a compromised action release | none (Dependabot keeps them fresh) | n/a | **adopted** in every workflow; SHA-pinning setting recommended |

### SAST, shell and secrets

| Tool | Version / licence | What it would catch here | Noise | Decision |
|---|---|---|---|---|
| ruff (`S`, `B`, `E`, `F`, `UP`, `C90`) | 0.17.3, MIT | Bandit's rules, bugs, 3.10+ syntax that would break the 3.9 hooks, complexity | low after the two documented ignores | **adopted** |
| Bandit | 1.9.4, Apache-2.0 | the same checks as ruff's `S` port | duplicates ruff | not adopted: covered by ruff `S` |
| Semgrep CE | engine 1.184; registry rules under the Semgrep Rules License (custom, internal use only, no redistribution) | Python and Actions patterns; Bash support is *experimental* | medium | not adopted: overlaps with CodeQL, ruff and zizmor, and the rules licence is restrictive |
| ShellCheck | 0.11.0 (preinstalled on Ubuntu runners), GPL-3.0 | shell bugs | low at `warning` | already in `ci.yml` |
| shfmt | 3.14.1, BSD-3-Clause | shell formatting only | n/a | not adopted yet: the diff against the current style was not measured; adopting it would be a separate reformat PR |
| gitleaks (CLI) | 8.30.1, MIT; `gitleaks-action` needs a licence key for organizations (not for personal accounts) | committed secrets in all history; 0 findings in 7 commits today | low | **adopted** (CLI, not the action) |
| TruffleHog | 3.99.x, AGPL-3.0 | secrets, confirmed by calling the provider APIs (`--no-verification` to skip) | low | not adopted: gitleaks plus GitHub secret scanning cover it, and live verification sends found secrets to external APIs |

### Complexity and maintainability

| Tool | Notes | Decision |
|---|---|---|
| ruff mccabe (C901) | per-function cyclomatic complexity for Python, in the tool already adopted | **adopted**, max 15 |
| lizard 1.24.3 (MIT) | CCN, NLOC, length and arguments; supports Python but **not shell** (README language list) | **adopted** as a ceiling on the existing outliers |
| radon / xenon | radon 6.0.1: CC and maintainability index for Python; xenon gates on radon's CC ranks | not adopted: CC duplicates ruff and lizard, and the MI score is noisy on small scripts |

### Hosted platforms and AI review bots (each needs a GitHub App installation)

None is adopted: each installs a third-party app with access to the code, which is the
owner's decision. The gates above already cover what they would add for this repository.

| Service | Free for public OSS (vendor page) | Languages relevant here | GitHub App permissions | Notes |
|---|---|---|---|---|
| SonarQube Cloud | "Free forever" for public, OSI-licensed repos (OSS plan: unlimited branch and PR analysis) | Python, Shell, GitHub Actions, YAML (pricing FAQ) | not stated on the pages read | strongest of the four for shell; one more dashboard |
| Qlty Cloud | free for community open source ("install the Qlty GitHub App") | not stated | not stated | the Qlty CLI is free. Qlty may restrict free use |
| Codacy | "Free forever for open-source projects", unlimited public repos | language list not on the pricing page | not stated ("requires org admin permissions" for organizations) | |
| DeepSource | "free for open-source projects", 1,000 PR reviews/month, no secrets detection on that plan | not stated on the pricing page | not stated | |
| CodeRabbit | "free reviews forever for public repositories" | all (LLM review) | read: actions, discussions, members, metadata; **read and write: checks, code, commit statuses, issues, pull requests, workflows** | does not retain code after review unless caching is on. Its write access to code and workflows is broad for a repo whose integrator merges by hand |
| GitHub Copilot code review | not on Copilot Free. Paid plans; consumes AI credits (about $0.25 to $10 per review by mode) | all | built in | reviews do not count toward required approvals by default |
| Gemini Code Assist on GitHub | only an enterprise version through Google Cloud is documented now; consumer free tier not stated | all | not stated | |

If one of these is wanted later, SonarQube Cloud (shell plus Python plus Actions in one
place) or CodeRabbit (PR review) are the candidates. Weigh CodeRabbit's write permissions
first.
