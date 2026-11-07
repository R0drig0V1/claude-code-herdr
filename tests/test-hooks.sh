#!/usr/bin/env bash
# Smoke tests for the plugin's hooks, installer and agents-in-repo.py, run in throwaway git
# repositories. Part of claude-code-herdr (ported from claude-code-multi-agent 0.1.0).
#
# Usage: tests/test-hooks.sh        (exit code = number of failed cases)
#
# Builds a repository that enables the plugin (guards active) and one that does not (guards
# must stay out of the way), feeds the hooks the same JSON payloads Claude Code sends, and
# checks exit codes: 2 blocks, 0 allows. Then runs install.sh twice into an empty repository,
# and runs agents-in-repo.py against a fake `herdr` that prints a fixed `agent list`.
# Needs git, jq and python3.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
hooks="$root/plugin/hooks"
export CLAUDE_PLUGIN_ROOT="$root/plugin"
unset CLAUDE_ROLE

# Not under a temporary directory: the Bash guard deliberately allows writes there, so the
# test repositories must live somewhere it protects.
work="$root/.test-work"
rm -rf "$work" && mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
fails=0

new_repo() {  # new_repo <dir> <enable: yes|no>
    git init --quiet -b main "$1"
    git -C "$1" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m init
    if [[ "$2" == yes ]]; then
        mkdir -p "$1/.claude"
        cp "$root/template/.claude/settings.json" "$1/.claude/settings.json"
    fi
}

expect() {  # expect <code> <description> <hook> <json>
    local want="$1" desc="$2" hook="$3" json="$4" got
    printf '%s' "$json" | "$hook" >/dev/null 2>&1
    got=$?
    if [[ "$got" == "$want" ]]; then
        echo "ok    $desc"
    else
        echo "FAIL  $desc (exit $got, want $want)"
        fails=$((fails + 1))
    fi
}

bash_cmd() { jq -nc --arg c "$1" --arg d "$2" '{tool_input: {command: $c}, cwd: $d}'; }
file_op() { jq -nc --arg f "$1" '{tool_input: {file_path: $f}}'; }

on="$work/on"; off="$work/off"
new_repo "$on" yes
new_repo "$off" no
git -C "$on" worktree add --quiet -b feat/x "$work/on-x"

g="$hooks/guard-main-bash.py"
expect 2 "bash: git commit in main worktree"          "$g" "$(bash_cmd 'git commit -m x' "$on")"
expect 2 "bash: redirect into main worktree"          "$g" "$(bash_cmd 'echo hi > f.txt' "$on")"
expect 2 "bash: cd + rm into main worktree"           "$g" "$(bash_cmd "cd $on && rm -rf src" "$work")"
expect 2 "bash: uv run ruff format"                   "$g" "$(bash_cmd 'uv run ruff format .' "$on")"
expect 2 "bash: pnpm install"                         "$g" "$(bash_cmd 'pnpm install' "$on")"
expect 2 "bash: gh pr merge from a worktree"          "$g" "$(bash_cmd 'gh pr merge 3' "$work/on-x")"
expect 2 "bash: push to main from a worktree"         "$g" "$(bash_cmd 'git push origin HEAD:main' "$work/on-x")"
expect 0 "bash: read-only commands"                   "$g" "$(bash_cmd 'ls -la && git status && git log -1' "$on")"
expect 0 "bash: write to /tmp"                        "$g" "$(bash_cmd 'echo hi > /tmp/x.txt' "$on")"
expect 0 "bash: commit in a linked worktree"          "$g" "$(bash_cmd 'git commit -m x' "$work/on-x")"
expect 0 "bash: heredoc body is data"                 "$g" "$(bash_cmd $'git -C '"$work/on-x"$' commit -F - <<\'M\'\nrm -rf /\nM' "$work")"
expect 0 "bash: repo without the plugin"              "$g" "$(bash_cmd 'git commit -m x && rm -rf src' "$off")"
expect 0 "bash: gh pr merge in repo without plugin"   "$g" "$(bash_cmd 'gh pr merge 3' "$off")"
CLAUDE_ROLE=integrator expect 0 "bash: integrator"    "$g" "$(bash_cmd 'git commit -m x' "$on")"

w="$hooks/guard-main-worktree.sh"
expect 2 "edit: file in main worktree"                "$w" "$(file_op "$on/a/b/new.md")"
expect 0 "edit: file in linked worktree"              "$w" "$(file_op "$work/on-x/new.md")"
expect 0 "edit: file outside git"                     "$w" "$(file_op "$work/loose.md")"
expect 0 "edit: repo without the plugin"              "$w" "$(file_op "$off/new.md")"
CLAUDE_ROLE=integrator expect 0 "edit: integrator"    "$w" "$(file_op "$on/new.md")"

s="$hooks/session-start-worktree.sh"
out=$(jq -nc --arg d "$on" '{cwd: $d}' | "$s")
if jq -e '.hookSpecificOutput.additionalContext | contains("/multi-agent-herdr:dispatch")' <<<"$out" >/dev/null; then
    echo "ok    session-start: instructions in main worktree"
else
    echo "FAIL  session-start: no instructions in main worktree"; fails=$((fails + 1))
fi
for d in "$work/on-x" "$off"; do
    out=$(jq -nc --arg d "$d" '{cwd: $d}' | "$s")
    if [[ -z "$out" ]]; then echo "ok    session-start: silent in $(basename "$d")"
    else echo "FAIL  session-start: output in $(basename "$d")"; fails=$((fails + 1)); fi
done

if CLAUDE_NOTIFY_SOUND=0 CLAUDE_NOTIFY_BELL=0 "$hooks/notify.sh" stop; then
    echo "ok    notify: exits 0"
else
    echo "FAIL  notify: non-zero exit"; fails=$((fails + 1))
fi

target="$work/target"
new_repo "$target" no
(cd "$target" && bash "$root/install.sh" >/dev/null) || { echo "FAIL  install: exit $?"; fails=$((fails + 1)); }
for f in CLAUDE.md scripts/check.sh scripts/integrator.sh .claude/prompts/integrator.md .claude/settings.json; do
    if [[ -f "$target/$f" ]]; then echo "ok    install: $f"
    else echo "FAIL  install: missing $f"; fails=$((fails + 1)); fi
done
[[ -x "$target/scripts/check.sh" ]] || { echo "FAIL  install: check.sh not executable"; fails=$((fails + 1)); }
echo "local edit" >> "$target/CLAUDE.md"
second=$(cd "$target" && bash "$root/install.sh")
if grep -q '= CLAUDE.md (exists' <<<"$second" && tail -1 "$target/CLAUDE.md" | grep -q 'local edit'; then
    echo "ok    install: second run keeps existing files"
else
    echo "FAIL  install: second run overwrote or did not report"; fails=$((fails + 1))
fi
printf '{"model": "opus"}\n' > "$target/.claude/settings.json"
(cd "$target" && bash "$root/install.sh" >/dev/null)
if jq -e '.model == "opus" and .enabledPlugins["multi-agent-herdr@claude-code-herdr"]' \
    "$target/.claude/settings.json" >/dev/null; then
    echo "ok    install: merges an existing settings.json"
else
    echo "FAIL  install: settings.json merge"; fails=$((fails + 1))
fi

# agents-in-repo.py: branch -> worktree -> live agent, with a fake herdr on PATH.
fake="$work/bin"; mkdir -p "$fake"
cat > "$fake/herdr" <<FAKE
#!/bin/sh
[ "\$1 \$2" = "agent list" ] || exit 2
cat <<'JSON'
{"result":{"agents":[
 {"name":"integrator","pane_id":"w1:p1","agent_status":"idle","cwd":"$on"},
 {"name":"x","pane_id":"w2:p1","agent_status":"working","cwd":"$work/on-x/sub","foreground_cwd":"$work/on-x"},
 {"pane_id":"w3:p1","agent_status":"idle","cwd":"$work/on-x"},
 {"name":"elsewhere","pane_id":"w4:p1","agent_status":"idle","cwd":"$off"}
]},"type":"agent_list"}
JSON
FAKE
chmod +x "$fake/herdr"
air="$root/plugin/scripts/agents-in-repo.py"
check_air() {  # check_air <description> <expected output> <args...>
    local desc="$1" want="$2" got; shift 2
    got=$(cd "$on" && PATH="$fake:$PATH" "$air" "$@" | cut -f1,3,4 | tr '\t\n' ' ,')
    if [[ "$got" == "$want" ]]; then echo "ok    agents-in-repo: $desc"
    else echo "FAIL  agents-in-repo: $desc (got '$got', want '$want')"; fails=$((fails + 1)); fi
}
check_air "all agents of the repo"  "integrator idle main,x working feat/x,"
check_air "author of feat/x"        "x working feat/x,"           --branch feat/x
check_air "excluding the integrator" "x working feat/x,"          --exclude integrator
check_air "branch with no agent"    ""                            --branch fix/none
(cd / && PATH="$fake:$PATH" "$air" >/dev/null 2>&1); [[ $? == 1 ]] \
    && echo "ok    agents-in-repo: exit 1 outside git" \
    || { echo "FAIL  agents-in-repo: exit outside git"; fails=$((fails + 1)); }

echo
echo "$fails failure(s)"
exit "$fails"
