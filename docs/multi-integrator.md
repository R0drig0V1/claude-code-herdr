<!--
Design of pool mode in multi-agent-herdr: a coordinator plus N parallel integrators. Roles,
message flows, the PR claim and merge lock protocols, failure modes, the scaling policy,
parallel verification, the machine-wide resource budget and the open policy questions.
-->

# Multi-integrator (pool mode)

## Why

With one integrator, every step of the workflow goes through a single session: it talks to
the user, plans, dispatches, reviews, verifies and merges. On granolax (November 2026) about 20
development agents produced 8 open PRs while one full verification (`scripts/check.sh`) took
8-11 minutes under load: the queue grows faster than one session can drain it, and the user
waits behind merges to talk to it.

Pool mode splits the work. It is **opt-in**: a project with no `integrators` setting keeps
exactly the single-integrator behaviour (same names, hooks and skills).

## Roles

| Role | Session | Worktree | Owns | Never |
|------|---------|----------|------|-------|
| **Coordinator** | `scripts/coordinator.sh`, `CLAUDE_ROLE=coordinator`, herdr name `coordinator_name` (default `coordinator-<repo>`) | the main worktree | the user's attention, `dispatch`, `docs/phases/`, the pool's size | merges, reviews a PR's verdict away |
| **Integrator** (N of them) | spawned by `integrator-pool.sh spawn <n>`, `CLAUDE_ROLE=integrator`, `MULTI_AGENT_HERDR_NAME=<integrator_name>-<n>` | its own verify worktree `../<worktree_prefix>integrator-<n>`, detached at `origin/<base>` | the PRs it claimed: review, verification, merge, verdict | touches the main worktree or `docs/phases/`, pushes `<base>` outside the merge lock |
| **Development agent** | started by `dispatch` | `../<worktree_prefix><name>` on its branch | its branch and PR | merges, pushes a protected branch, prompts anyone but the coordinator and the pool |

Settings (`.claude/multi-agent-herdr.json`, read only by `project-config.py`):

```json
{
  "coordinator_name": "coordinator-granolax",
  "integrators": {
    "min": 1,
    "max": 3,
    "scale_up_when_active_agents_gt": 5,
    "scale_down_idle_minutes": 30,
    "claim_ttl_minutes": 60,
    "max_reverify": 3,
    "reverify_exempt_paths": ["docs/phases/*"]
  }
}
```

The `integrators` object turns pool mode on; every key in it is optional (the values above
are the defaults). `project-config.py` derives `mode` (`single`/`pool`) and `integrator_pool`
(`<integrator_name>-1` .. `-max`, each cut to herdr's 32 characters).

## Message flows

The chain of command is short: nothing hops through the coordinator that does not need it.

```mermaid
sequenceDiagram
    actor User
    participant C as coordinator-repo
    participant D as dev agent (feat/x)
    participant I1 as integrator-repo-1
    participant I2 as integrator-repo-2
    participant GH as GitHub (queue)
    participant S as pool state (git common dir)

    User->>C: "build X"
    C->>C: resource-board.sh show (room for one more?)
    C->>D: dispatch (worktree, workspace, brief)
    D-->>C: question (herdr prompt)
    C-->>D: answer (or the user's decision)
    D->>C: RESOURCE REQUEST: dev server + e2e, ~3 GB, ~20 min
    C-->>D: RESOURCE WAIT: 2 verifications running; ask again after PR #12 lands
    D->>GH: gh pr create
    D->>I1: "PR #12 ready" (integrator-pool.sh route: first idle member)
    I1->>S: claim 12 (mkdir, atomic)
    I2->>S: claim 12
    S-->>I2: exit 3 (held): next PR
    I1->>I1: review, integrate-pr.sh: merge + verify in its own worktree
    I1->>S: lock run (flock) + origin/base unchanged?
    I1->>GH: git push origin HEAD:main (fast-forward only)
    I1->>S: report add 12, release 12
    I1->>GH: PR comment (durable verdict)
    I1->>D: "PR #12 merged as abc123" (direct)
    I1->>C: "PR #12 merged; plan tasks: ..."
    C->>C: tick docs/phases, commit
    C->>S: lock run -- git push (plan commit)
    C->>S: report done 12
```

| Message | From | To | How |
|---------|------|----|-----|
| PR announcement | development agent | one pool member | `pr` -> `integrator-pool.sh route` (first `idle`/`done` member, else the first `working` one; never a `blocked` one) |
| Question, blocked state | development agent | coordinator | `herdr agent prompt <coordinator_name>` |
| Verdict | the integrator that handled the PR | the author | PR comment + `herdr agent prompt` (resolved with `agents-in-repo.py --branch`) |
| "base moved" | the integrator that merged | other development agents | `agents-in-repo.py --dev-only` |
| Merge report | integrator | coordinator | `pool-state.py report add` (durable) + `herdr agent prompt` (wake-up) |
| Kickoff, nudge | coordinator | pool member | `integrator-pool.sh spawn`, or a prompt when PRs wait and every member is idle |
| `RESOURCE REQUEST` / `GO` / `WAIT` / `YIELD`, `SAVE MODE ON/OFF` | any agent <-> coordinator | negotiated against the resource board (see "Resources") |
| Load, priority for a push | pool member <-> coordinator | the coordinator asks before scaling; a member that lost the race for the base (exit 7) asks for priority |

The announcement is only a wake-up: GitHub's open PRs are the queue, and every member reads
it (`pool-state.py queue`) and claims before working, so announcing to one member is enough
and a lost announcement only delays a PR until the next member looks.

## PR claims

State lives in the repository's git common dir, `<common>/multi-agent-herdr/`: every
integrator runs on the same machine (herdr is local), so a directory there is shared by all
of them and by nobody else.

- **Claim** = `mkdir claims/pr-<N>` (atomic on any POSIX file system: exactly one of several
  concurrent `mkdir`s succeeds), then `owner.json` (`owner`, `head`, `since`, `heartbeat`),
  written to a temporary file and renamed in place.
- **Heartbeat**: `integrate-pr.sh` refreshes it at the start and every 2 minutes during a
  verification.
- **Stale** = the heartbeat is older than `claim_ttl_minutes`, or the owner is not a live
  herdr agent (`herdr agent list`; when herdr cannot be asked, only the age counts). A claim
  directory without `owner.json` is "being created" for 60 s, then stale.
- **Re-claim** of a stale claim: `rename` the directory aside (atomic; when two integrators
  race, only one rename succeeds and the other one's `mkdir` then fails), then `mkdir` again.
- **Release** = rename aside and delete. Only the owner can release.
- **Bounce record**: `bounced/pr-<N>.json` keeps the bounced head SHA. `queue` skips the PR
  until its head changes (the author pushed a fix), so a bounced PR is not re-verified in a
  loop by the next free integrator.

Alternatives considered: a GitHub label or assignee is not atomic (two integrators can both
add it; GitHub has no compare-and-swap on labels), costs API calls and needs write
permissions; a `flock` on a per-PR file would release the claim whenever the Bash command
holding it ends, while a claim must outlive many commands (review, then merge).

## Merge lock and the base-moved policy

Each integrator verifies in its own worktree, so verifications run in parallel; only the
**push to `<base>`** is serialized, by a short merge lock: `pool-state.py lock run --owner
<me> -- <command>` holds a kernel `flock` on `lock/merge.lock` while the command runs and
records the holder in `lock/merge.owner.json`. The kernel releases the lock when the holder
dies, so a crashed integrator cannot wedge the pool.

**Correctness does not depend on the lock.** The plugin never force-pushes, so a push whose
merge commit does not have the current `origin/<base>` as its first parent is rejected by the
remote as a non-fast-forward. Only a tree that was verified can land. The lock adds ordering
and a clear "base moved" signal, and keeps two integrators from re-merging at the same time.

`integrate-pr.sh` under the lock:

1. `git fetch origin <base>`; if `origin/<base>` is still the commit the verification started
   from, push the verified merge commit. Done.
2. Otherwise merge the PR head again onto the new `origin/<base>`. A conflict now is a
   bounce (the author rebases).
3. Compare the new merged tree with the verified one (`git diff --name-only`). When every
   difference matches `reverify_exempt_paths` (default `docs/phases/*`: the coordinator's
   plan commits, which cannot change the result of the checks), commit and push at once.
4. Otherwise release the lock and verify the new tree, then go back to 1; after
   `max_reverify` re-verifications, give the PR back to the queue (claim released, no
   bounce; exit 7).

This is the merge-queue rule ("the tree that lands is the tree that was tested"), applied
per PR. Trade-offs of the policies considered:

| Policy when the base moved | Cost | Risk |
|----------------------------|------|------|
| **Re-verify** (chosen, except for exempt paths) | one more full check per collision (8-11 min on granolax) | starvation under heavy merge traffic, bounded by `max_reverify` |
| Rebase/re-merge and push without verifying | none | a semantic conflict (both PRs green alone, red together) lands on `<base>` |
| Re-merge, re-verify only when the PRs touch the same files | small | the same semantic-conflict risk, through imports and shared fixtures |
| Exempt paths only (part of the chosen policy) | none | only as large as the exempt patterns: keep them to files no check reads |

Starvation: with N integrators finishing at similar times, the last one to push re-verifies
up to N-1 times. With 3 integrators and 10-minute checks the expected extra cost is small;
`max_reverify` caps the worst case and an exit 7 is visible to the coordinator.

### Speculative batching (evaluated, not implemented)

A merge queue can verify "A", "A+B" and "A+B+C" in parallel and land the longest green
prefix. That needs a shared ordering (the batch), a way to cancel the speculative runs that
depend on a failed one, and N times the machine resources at once. On one laptop the
resource budget, not the integrator count, is the limit (see below), so speculative runs
would mostly wait for heavy slots. Per-PR verification with re-verification on collision is
simpler and fails more legibly. Revisit on a machine with spare capacity: open question 3.

## Who owns the plan

The coordinator owns `docs/phases/`. Integrators never write it: after a merge,
`integrate-pr.sh` records a **plan report** (`reports/pr-<N>.json`: the merge sha and the PR
body's "Plan tasks completed" section) and the integrator prompts the coordinator. The
coordinator ticks the tasks in the main worktree, commits `docs(plan): ...`, rebases onto
`origin/<base>`, pushes under the merge lock, and marks the reports done
(`reports/done/`). Because plan commits only touch `docs/phases/`, they never cost an
integrator a re-verification. Reports survive a coordinator that is down; on restart it
also compares recently merged PRs with the known reports (`pool-state.py report known`).

## Guards

| Action | Development agent | Pool integrator | Coordinator | Single-mode integrator |
|--------|-------------------|-----------------|-------------|------------------------|
| Edit/commit in the main worktree | blocked | blocked | allowed | allowed |
| `git push` to a protected branch | blocked | only via `pool-state.py lock run --` (and `integrate-pr.sh`) | only via `pool-state.py lock run --` | allowed |
| `git push --all/--mirror`, `gh pr merge` | blocked | blocked | blocked | allowed |
| herdr input commands (`pane run`, `send-keys`...) | blocked | allowed* | allowed* | allowed* |
| `herdr agent prompt` | only the coordinator and the pool (single mode: the integrator) | anyone | anyone | anyone |

\* Allowed by the guard because these roles start and message agents; the rule "never answer
another agent's dialog" stays a rule of their skills and prompts.

The guards stay guardrails, not a sandbox (README, Limitations): a script file is not
inspected, which is why `integrate-pr.sh` itself checks `CLAUDE_ROLE`, the worktree and the
claim.

## Failure modes

| Failure | What happens | Recovery |
|---------|--------------|----------|
| An integrator crashes **before or during the verification** | its claim stops heartbeating; its herdr agent disappears, so the claim is stale at once | another integrator re-claims the PR from the queue (`stale`); when the member is respawned, `integrate-pr.sh` aborts the merge left in its own worktree |
| A merged agent's worktree is never cleaned up (the dispatcher was down, the agent stayed busy) | its session keeps memory; the branch stays | `cleanup-worktree.sh --list` on the next pass finds it `ready` or tells why not |
| An integrator crashes **holding the merge lock** | the kernel releases the `flock` with the process | the next `lock run` proceeds; the push either happened (atomic on the remote) or not |
| An integrator crashes **after the push, before its verdict/report** | the PR is merged on GitHub (the head is in `<base>`), the claim goes stale, no plan report | the PR leaves the open queue by itself; the coordinator's catch-up step finds the merged PR without a report and ticks it; the author sees the merge on GitHub (no herdr verdict) |
| Two integrators claim the same PR | exactly one `mkdir` succeeds | the loser gets exit 3 and takes the next PR |
| Two integrators push at once | the lock serializes them; without it, the remote would reject the second as a non-fast-forward | the second one re-merges (and re-verifies unless only exempt paths moved) |
| `<base>` moves during a verification | detected under the lock | re-merge, push or re-verify (policy above); exit 7 after `max_reverify` |
| The head branch moves during a verification | the verified head is merged; the branch is **kept** (deleted only when PR head = remote head = merged head, with a lease on that commit) | the PR stays open with the new commits and comes back to the queue |
| The coordinator is down | integrators keep merging; reports accumulate; development agents' questions get no answer (the `pr` skill tells the user when the coordinator is not live) | on restart, `coordinate` reads pending reports and catches up merged PRs |
| Every integrator is down | `route` exits 1; announcements are not sent | the PRs wait in GitHub's queue; the coordinator's scale check spawns `min` members |
| herdr cannot be asked | claims are judged by age only; `route` finds nobody | nothing is merged twice: claims still hold until their TTL |
| The machine runs out of memory | every agent loses its turn | prevented by the resource budget below |

## Scaling

Scaling is a decision the coordinator takes in conversation, not a formula the plugin applies.
`integrator-pool.sh scale` changes nothing: it prints the facts (live members, their claims
and inactivity, claimable open PRs, development agents) and a rule of thumb, one integrator
per `scale_up_when_active_agents_gt` development agents within `[min, max]`. Development
agents are the live herdr agents in a linked worktree of this repository that is on a branch
(`agents-in-repo.py --dev-only`), idle ones included, since an agent waiting for a verdict
still means a PR in flight.

The coordinator then weighs:

- what the members say about their load: how long their current PR will take, and whether
  the queue is long;
- what the resource board says about the machine.

An integrator costs one session plus heavy-slot time. With every heavy slot busy, another
integrator only waits.

- **Scaling up** is `spawn <n>`. `max` is the one hard bound.
- **Scaling down** is `stop <n>`:
  - for a member that is idle with an empty queue (`scale` marks the ones inactive for
    `scale_down_idle_minutes`), or whose memory is needed elsewhere;
  - only when the member is `idle`/`done` and holds no claim;
  - only for workspaces `spawn` opened (recorded in `members/<name>.json`).

  The verify worktree is kept, so the next spawn reuses its installed dependencies.

## Parallel verification: what the project must provide

With several integrators, `scripts/check.sh`, `scripts/worktree-setup.sh` and
`scripts/verify-reset.sh` run at the same time in different worktrees. The project must make
them **parallel-safe**:

- No fixed ports: bind port 0, or inject the server instead of binding.
- Every database, container, cache or directory written outside the worktree is private to
  the run (a random name) or shared read-only; nothing one run wipes can be in use by another.
- `verify-reset.sh` resets only the state of its own worktree.
- Shared services (a database server) are started idempotently by name.

**granolax already satisfies it**:

- `compose.yaml` fixes the project name (`name: granolax`), so every worktree's
  `scripts/ensure-db.sh` (`docker compose up -d --wait db`) reaches the same PostgreSQL server
  on `127.0.0.1:55432`.
- `tests/plugins/db.py` gives each pytest session its own template database
  `granolax_test_<random>` (migrated once) and each test a fresh copy
  (`CREATE DATABASE ... TEMPLATE`), dropped afterwards; databases left by killed runs are
  dropped only when stamped more than 6 h ago **and** unused, so a run in another worktree is
  never disturbed.
- `tests/conftest.py` points `HOME` and the data directory into `tmp_path`.
- The serve tests inject uvicorn ("no port is bound").
- `scripts/worktree-setup.sh` installs into the worktree (`.venv`, `web/node_modules`).

What remains shared is CPU and memory. The machine-wide resource budget handles that.

## Resources: negotiated, with one hard floor

On 2026-11-09 the user's 24 GB machine ran out of memory, and every agent lost its turn. At
the time it was running about 20 development agents, several integrators, and checks in
parallel. A day later the resource board listed 47 live herdr agents across several projects.
Many were idle or done, and each still held its memory.

Resources are therefore **negotiated**, not computed. The coordinator is the arbiter, the
**resource board** is the shared sheet everyone reads, and only one thing is mechanical.

**The hard floor: heavy slots** (`resource-budget.py run`, about 150 lines). At most
`heavy_slots` heavy commands run at once on the machine, across every agent and project.

- `verify-merge.sh` runs `worktree-setup.sh` and `check.sh` through it; so does
  `new-worktree.sh` for `worktree-setup.sh`, and the `commit` and `pr` skills for the checks.
- It stays code because a conversation cannot stop a process that is already allocating
  memory. When memory is scarce, agents answer late or not at all.
- Slots are `flock`ed files in `~/.cache/multi-agent-herdr/resources/`, so a crashed holder
  frees its slot. A nested call (`$MULTI_AGENT_HERDR_SLOT` set) runs at once instead of
  deadlocking.
- Waiters poll every 2 s with no FIFO order: who goes first is the coordinator's call.

**The resource board** (`resource-board.sh`) is a human-readable Markdown sheet, machine-wide,
with one file per agent so nobody overwrites anybody.

- Before an agent starts something heavier or longer-lived than a normal check (a server, a
  container, a watcher, a benchmark, parallel subagents), it writes a note: what it runs, an
  estimated GB figure, and how long it expects to take. It clears the note when the thing
  stops.
- `show` prints:
  - memory, flagged **LOW** below `low_memory_gb`;
  - the live herdr agents against the machine's `sessions_guideline`;
  - who holds each heavy slot, and for how long;
  - every note, flagged **overdue** or **(gone)**;
  - the agents that look idle.
- `prune` drops the notes of agents that are no longer live.

**The protocol.** Every message carries the usual header and goes through the coordinator,
so 20 agents never talk all-to-all:

| Message | From -> to | Meaning |
|---------|------------|---------|
| `RESOURCE REQUEST: <what>, ~<GB> GB, ~<min> min, for <PR or task>` | any agent -> coordinator | "may I start this?" A long heavy-slot wait that blocks something urgent is a request too, never a reason to bypass the wrapper |
| `RESOURCE GO: <what>` | coordinator -> requester | start it, and note it on the board |
| `RESOURCE WAIT: <why>; ask again after <event>` | coordinator -> requester | deferred, with a concrete next step; possibly "run only the targeted tests" |
| `RESOURCE YIELD: <what>, because <why>` | coordinator -> an agent | pause or stop at a safe point and confirm (or explain why not); pool integrators finish the PR in progress and claim no new one |
| `SAVE MODE ON: <why>` / `SAVE MODE OFF` | coordinator -> the repository's agents | nothing new and heavy starts, and idle agents finish up; sent when memory is LOW or sessions are well over the guideline |

**The coordinator's priorities**, in order:

1. what unblocks a merge (an integrator's verification, an author fixing a bounce);
2. what the current phase of the plan needs;
3. everything else, first come first served.

Before each dispatch or spawn, it reads the board. When the board is over the guideline or
LOW, it does not start one more session: it tells the user which agents look idle and lets
them decide. Agents never close another agent's workspace, except a pool member through
`integrator-pool.sh stop`.

**The cost** of negotiating: every message wakes an agent (tokens, and a turn's worth of
memory). That is why the protocol is hub-and-spoke through the coordinator, and why an agent
asks only for what goes beyond a normal check. The normal check just waits for its slot.

Limits are per machine, in `~/.config/multi-agent-herdr/resources.json`, overriding defaults
derived from the RAM. Only `heavy_slots` is enforced; the other two are guidelines the board
shows and the coordinator weighs:

| RAM | `heavy_slots` (enforced) | `sessions_guideline` | `low_memory_gb` |
|-----|--------------------------|----------------------|-----------------|
| 16 GB | 1 | 8 | 1.6 |
| 24 GB | 2 | 12 | 2.4 |
| 32 GB | 3 | 16 | 3.2 |
| 64 GB | 7 | 32 | 6.4 |

The reasoning behind the defaults:

- About 8 GB stay reserved for the system, the editor and the Docker VM.
- Each Claude Code session takes 0.5-1.5 GB with its tools.
- A heavy check needs 3-6 GB at its peak (granolax: pytest with PostgreSQL copies, vitest
  with coverage, a Vite build).

So: sessions ≈ RAM / 2 and heavy slots ≈ (RAM − 8) / 8. Measure the project's own check
(peak RSS of `scripts/check.sh`, for example with `/usr/bin/time -l`) and adjust.

## Cleanup

A worktree whose branch was merged has done its job. Left behind, it keeps a Claude session,
that session's memory and its installed dependencies alive, and the branch list only grows.
So the one who dispatched the agent discards it after the merge: the integrator in single
mode, the coordinator in pool mode. That is the one who opened the workspace, so it may
close it. The flow:

1. The merged verdict tells the author its task is done: report to the user in one line,
   clear its resource-board note, and stop.
2. `cleanup-worktree.sh --list` shows every development worktree and its state: `ready`,
   `merged-agent-busy`, `merged-but-dirty` or `not-merged`.
3. `cleanup-worktree.sh <branch>` removes nothing unless every check passes:
   - GitHub has a merged PR from the branch into `<base>`, and the branch tip is contained in
     `origin/<base>`, so nothing was added after the merge. Ancestry alone is not enough: a
     branch dispatched a minute ago, with no commit yet, is also contained in the base.
   - The worktree has no uncommitted or untracked file.
   - Every agent in the worktree is `idle` or `done`.
   - Every pane of the workspace to close is inside the worktree.

   Then it:
   - closes the workspace;
   - runs `git worktree remove` (never `--force`);
   - deletes the local branch;
   - deletes the remote branch, only when it still points at the merged tip (with a lease
     on that commit);
   - clears the agents' board notes.
4. Exit 5 (the agent is still busy) means try again on the next pass. Exit 4 (uncommitted
   work) goes to the author or the user and is never discarded. A `not-merged` branch nobody
   works on is the user's call.

Pool members' verify worktrees are kept across `stop`, so the next spawn reuses their
dependencies. `integrator-pool.sh stop <n> --remove-worktree` discards one when the pool
shrinks for good.

## integrate-pr.sh

The merge itself is a script, not a sequence of commands an agent retypes. Each step is
gated on the previous one's exit code, and the exit code is the verdict (see its header for
the codes). It folds in the lessons of granolax's integration helper:

- **Stop on any conflict** except rows of an index table given with `--union-rows`
  (`union-rows.py`). The resolver keeps the rows of both sides and refuses two different rows
  with the same key: two PRs that took the same ADR number is a bounce, not a merge.
- **Abort and reset on a failed verification**: `git merge --abort`, then
  `verify-merge.sh --reset-only`, so the next PR starts clean. A `check.sh` that modifies
  tracked files counts as a failure.
- **Keep the branch when it moved during the verification.** The branch is deleted only when
  the PR's head, the remote branch and the merged head are the same commit and it is in
  `origin/<base>`.

  The delete carries `--force-with-lease=refs/heads/<B>:<head>`, which makes it conditional
  on that commit and closes the window between the check and the delete. It rewrites no
  history.

  Twice, a premature deletion closed a PR whose author had pushed during the verification.

It is used in both modes. In single mode it runs in the main worktree on the base branch.

## Open questions (policy, for the user)

1. **Integrators merge without the coordinator's say.** A green, reviewed PR lands as soon as
   its integrator is done. The coordinator only learns of it afterwards. Should merges that
   touch some areas (migrations, security, `CLAUDE.md`) wait for the coordinator or the user?
2. **The coordinator pushes plan commits to `<base>` directly** (under the merge lock, not
   through a PR). This matches what the single integrator did before. The alternative, a
   plan PR verified by the pool, costs a full verification per tick.
3. **Speculative batching** (verify A+B together) is not implemented, because the machine's
   memory is the bottleneck. Revisit on a bigger machine or with CI-hosted verification.
4. **`reverify_exempt_paths` defaults to `docs/phases/*`.** A project whose checks read the
   plan (a docs linter, link checks) must set it to `[]`.
5. **Scaling is the coordinator's judgment.** The rule of thumb counts every live
   development agent, idle ones included. Should a hard minimum or maximum ever be
   automatic, for example spawning `min` when every member died?
6. **Sessions are a guideline, not a limit.** Only heavy slots are enforced. Should the
   plugin refuse to start an agent when memory is LOW, instead of the coordinator asking
   the user?
7. **Hub-and-spoke negotiation through the coordinator** costs one coordinator turn per
   request. Integrators could instead settle push priority between themselves directly, at
   the price of more messages.
8. **Resource limits are defaults from the RAM, not measurements.** Should the board record
   the peak memory each heavy command actually used, to replace the agents' estimates?
