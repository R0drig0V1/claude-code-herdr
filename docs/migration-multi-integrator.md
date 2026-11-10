<!--
Checklist for moving an existing multi-agent-herdr project (granolax as the worked example)
from one integrator to pool mode: a coordinator plus N integrators (docs/multi-integrator.md).
-->

# Migrating a project to pool mode (checklist)

Pool mode is opt-in, and upgrading the plugin alone changes nothing: a project without an
`integrators` setting keeps one integrator. The steps below switch a project over. They use
granolax as the example. The plugin does not edit the project; the project's own integrator
(or the user) makes these changes on `main`.

## Before you switch

- [ ] **Upgrade the plugin** to 0.2.0 or later (`claude plugin marketplace update
      claude-code-herdr`, then update `multi-agent-herdr`). Restart the sessions that should
      pick up the new hooks: hooks and skills load when a session starts.
- [ ] **Set the machine's resource budget** (one file per computer, shared by every project):
      `~/.config/multi-agent-herdr/resources.json`. For granolax's 24 GB machine the defaults
      are `{"heavy_slots": 2, "sessions_guideline": 12, "low_memory_gb": 2.4}` (only
      `heavy_slots` is enforced). `resource-board.sh show` is the live sheet; on 2026-11-09
      it listed 47 live herdr agents. Close the panes of agents that are `done` before switching: they still
      hold memory.
- [ ] **Check that `scripts/check.sh` is parallel-safe**: no fixed ports, and no shared state
      that one run wipes under another (docs/multi-integrator.md, "Parallel verification").
      granolax already is: `compose.yaml` fixes `name: granolax` (one shared PostgreSQL),
      `tests/plugins/db.py` uses random `granolax_test_*` databases per run and per test, and
      the serve tests bind no port. Nothing to change.
- [ ] **Drop the ad-hoc check lock.** Agents currently run `/usr/bin/lockf -k
      /tmp/granolax-check.lock scripts/check.sh` by hand. The plugin now does this
      machine-wide (`verify-merge.sh`, `new-worktree.sh`, and the `commit` and `pr` skills
      run the checks through `resource-budget.py run`). Remove the instruction from
      briefs, prompts and `CLAUDE.md` once every session runs the new plugin. Until then,
      both locks coexist harmlessly.
- [ ] **Disk**: each integrator gets its own verify worktree (`../granolax-integrator-<n>`)
      with its own `.venv` and `web/node_modules`, installed once by `scripts/worktree-setup.sh`
      and kept across stops.
- [ ] **Let the current integrator finish** the PR it is merging. Note the open PRs: they
      stay in GitHub's queue, and the pool picks them up.

## Files in granolax

- [ ] `.claude/multi-agent-herdr.json`: add the pool. A starting point for 20 agents:

      ```json
      {
        "$comment": "...",
        "base_branch": "main",
        "protected_branches": [],
        "integrators": {"min": 1, "max": 3, "scale_up_when_active_agents_gt": 5}
      }
      ```

      The names become `coordinator-granolax` and `integrator-granolax-1` .. `-3`. Keep
      `docs/phases/*` as the exempt path (the default) unless a check reads the plan.
- [ ] `scripts/integrator.sh`: replace it with the plugin's `template/scripts/integrator.sh`.
      granolax's copy predates the SessionStart claim, and the new one refuses to launch in
      pool mode.
- [ ] `scripts/coordinator.sh`: new, from `template/scripts/coordinator.sh`, made executable
      with `chmod +x`.
- [ ] `.claude/prompts/coordinator.md`: new, from `template/.claude/prompts/coordinator.md`.
      Add granolax's own rules (privacy rules P1-P6, ADR policy) where the coordinator
      decides scope.
- [ ] `.claude/prompts/integrator.md`: merge in the template's "Pool mode" paragraph and the
      two changed bullets (`docs/phases/` belongs to the coordinator; preconditions in your
      own verify worktree). Keep granolax's project-specific attack checklist.
- [ ] `CLAUDE.md`, "Multi-agent workflow", following the template:
  - the main worktree belongs to the coordinator;
  - `docs/phases/` belongs to the coordinator;
  - PRs are announced to the pool;
  - questions go to the coordinator;
  - verdicts come from the integrator that handled the PR;
  - `scripts/check.sh` must stay parallel-safe.

  Add `scripts/coordinator.sh` to "Layout" and "Commands".
- [ ] ADR index conflicts: the pool's integrators resolve rows added to
      `docs/decisions/README.md` with
      `integrate-pr.sh <N> --union-rows docs/decisions/README.md`, the plugin's version of
      granolax's `--resolve-adr-index`. Mention it in `.claude/prompts/integrator.md`. Retire
      the scratchpad `integrate-pr.sh`.
- [ ] Optional ADR in `docs/decisions/` recording the switch to pool mode and the chosen
      limits.

## Switching over

1. [ ] Merge the file changes above into `main` (through the current integrator, or by hand).
2. [ ] The user stops the single integrator session (`integrator-granolax`) and closes its
       pane. In pool mode its name is not used, and its role in the main worktree belongs to
       the coordinator.
3. [ ] In a herdr pane of the main worktree, run `scripts/coordinator.sh`. The SessionStart
       hook names it `coordinator-granolax`.
4. [ ] In the coordinator, run `/multi-agent-herdr:coordinate`. It checks the preconditions,
       reads the resource board, looks at `integrator-pool.sh scale` (with 20 development
       agents and the settings above it suggests 3 integrators) and spawns as many as the
       queue and the machine justify, and reads pending reports.
       Answer any folder-trust dialog of a new integrator workspace yourself; agents never
       answer them.
5. [ ] Tell the running development agents about the change. The coordinator sends each one a
       herdr message: "announce PRs with /multi-agent-herdr:pr (it routes to the pool), send
       questions to coordinator-granolax, and before anything heavier than the normal check
       note it on the resource board and send a RESOURCE REQUEST to coordinator-granolax". The guard blocks prompts to the old name
       `integrator-granolax` in pool mode, so an agent that still uses it fails safely and is
       told why.
6. [ ] Watch the first merges: `integrator-pool.sh list` (members, claims, idleness),
       `pool-state.py claims`, `pool-state.py lock status`, `resource-board.sh show`.

## Rolling back

1. [ ] Stop the pool members: `integrator-pool.sh stop <n>` for each idle member. It refuses
       members that are working or hold a claim. Wait for them to finish.
2. [ ] Remove `integrators` (and `coordinator_name`) from `.claude/multi-agent-herdr.json` on
       `main`.
3. [ ] Stop the coordinator and launch `scripts/integrator.sh` in the main worktree. The
       verify worktrees can stay (`git worktree remove ../granolax-integrator-<n>` when no
       longer wanted).
