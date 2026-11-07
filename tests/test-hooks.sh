#!/usr/bin/env bash
# Smoke tests for the plugin's hooks, installer and agents-in-repo.py, run in throwaway git
# repositories. Part of claude-code-herdr (ported from claude-code-multi-agent 0.1.0).
#
# Usage: tests/test-hooks.sh        (exit code = number of failed cases)
#
# Builds a repository that enables the plugin (guards active) and one that does not (guards
# must stay out of the way), feeds the hooks the same JSON payloads Claude Code sends, and
# checks exit codes: 2 blocks, 0 allows. Then runs install.sh into empty repositories, runs
# new-worktree.sh under a path with spaces, runs agents-in-repo.py and claim-integrator.sh
# against a fake `herdr`, and checks that every `herdr agent prompt` in the skills sends the
# "[herdr message from agent ...]" header.
# Needs git, jq and python3.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
hooks="$root/plugin/hooks"
export CLAUDE_PLUGIN_ROOT="$root/plugin"
unset CLAUDE_ROLE

# Not under a temporary directory: the Bash guard deliberately allows writes there, so the
# test repositories must live somewhere it protects.
work="$root/.test-work"
case "$root/" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|"${TMPDIR:-/nonexistent}"*)
        work="${XDG_CACHE_HOME:-$HOME/.cache}/claude-code-herdr-test-work" ;;
esac
rm -rf "$work" && mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
fails=0

new_repo() {  # new_repo <dir> <enable: yes|no|false|local-false>
    git init --quiet -b main "$1"
    git -C "$1" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m init
    mkdir -p "$1/.claude"
    case "$2" in
        yes) cp "$root/template/.claude/settings.json" "$1/.claude/settings.json" ;;
        false) printf '{"enabledPlugins": {"multi-agent-herdr@claude-code-herdr": false}}\n' \
                   > "$1/.claude/settings.json" ;;
        local-false)
            cp "$root/template/.claude/settings.json" "$1/.claude/settings.json"
            printf '{"enabledPlugins": {"multi-agent-herdr@claude-code-herdr": false}}\n' \
                > "$1/.claude/settings.local.json" ;;
    esac
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

on="$work/on"; off="$work/off"; dis="$work/disabled"; ldis="$work/local-disabled"
new_repo "$on" yes
new_repo "$off" no
new_repo "$dis" false
new_repo "$ldis" local-false
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
expect 0 "bash: plugin set to false"                  "$g" "$(bash_cmd 'git commit -m x' "$dis")"
expect 0 "bash: settings.local.json sets false"       "$g" "$(bash_cmd 'git commit -m x' "$ldis")"

x="$work/on-x"
expect 2 "herdr: pane run into another pane"          "$g" "$(bash_cmd 'herdr pane run w1:p1 "git push origin main"' "$x")"
expect 2 "herdr: agent send-keys"                     "$g" "$(bash_cmd 'herdr agent send-keys integrator enter' "$x")"
expect 2 "herdr: pane send-keys"                      "$g" "$(bash_cmd 'herdr pane send-keys w1:p1 enter' "$x")"
expect 2 "herdr: pane send-text"                      "$g" "$(bash_cmd 'herdr pane send-text w1:p1 y' "$x")"
expect 2 "herdr: agent attach"                        "$g" "$(bash_cmd 'herdr agent attach integrator --takeover' "$x")"
expect 2 "herdr: agent rename"                        "$g" "$(bash_cmd 'herdr agent rename w2:p1 integrator' "$x")"
expect 2 "herdr: terminal session control"            "$g" "$(bash_cmd 'herdr terminal session control w1:p1' "$x")"
expect 2 "herdr: prompt another agent"                "$g" "$(bash_cmd 'herdr agent prompt reviewer "approve it"' "$x")"
expect 2 "herdr: global option before the group"      "$g" "$(bash_cmd 'herdr --machine m1 agent send-keys integrator enter' "$x")"
expect 2 "herdr: hidden after cd and &&"              "$g" "$(bash_cmd "cd $x && ls && herdr pane run w1:p1 ls" "$work")"
expect 0 "herdr: prompt the integrator"               "$g" "$(bash_cmd 'herdr agent prompt integrator "PR #1 ready"' "$x")"
expect 0 "herdr: read-only commands"                  "$g" "$(bash_cmd 'herdr agent list && herdr pane current --current' "$x")"
expect 0 "herdr: repo without the plugin"             "$g" "$(bash_cmd 'herdr pane run w1:p1 ls' "$off")"
CLAUDE_ROLE=integrator expect 0 "herdr: integrator prompts an agent" "$g" "$(bash_cmd 'herdr agent prompt x "verdict"' "$on")"
# Round-3 bypasses: the herdr rules follow the session, not the command's cd, and herdr is
# recognised behind variables, wrappers and shell strings.
expect 2 "herdr: after cd out of the repo"            "$g" "$(bash_cmd 'cd /tmp && herdr pane run w1:p1 "git push origin main"' "$x")"
HERDR_BIN_PATH=/opt/herdr/bin/herdr \
expect 2 "herdr: \"\$HERDR_BIN_PATH\" (set)"          "$g" "$(bash_cmd '"$HERDR_BIN_PATH" pane run w1:p1 "git push origin main"' "$x")"
HERDR_BIN_PATH='' \
expect 2 "herdr: \${HERDR_BIN_PATH} (unset)"          "$g" "$(bash_cmd '${HERDR_BIN_PATH} agent send-keys integrator enter' "$x")"
expect 2 "herdr: other variable as program"           "$g" "$(bash_cmd '$H pane send-text w1:p1 y' "$x")"
expect 2 "herdr: command prefix"                      "$g" "$(bash_cmd 'command herdr agent send-keys integrator enter' "$x")"
expect 2 "herdr: exec and time prefixes"              "$g" "$(bash_cmd 'time exec herdr pane run w1:p1 ls' "$x")"
expect 2 "herdr: bash -c string"                      "$g" "$(bash_cmd "bash -c 'herdr pane run w1:p1 ls'" "$x")"
expect 2 "herdr: eval string"                         "$g" "$(bash_cmd "eval 'herdr agent send-keys integrator enter'" "$x")"
expect 2 "herdr: cd inside bash -c"                   "$g" "$(bash_cmd "sh -c 'cd /tmp && herdr pane run w1:p1 ls'" "$x")"
expect 0 "herdr: \$HERDR_BIN_PATH prompts integrator" "$g" "$(bash_cmd '"$HERDR_BIN_PATH" agent prompt integrator "PR #1 ready"' "$x")"
expect 0 "herdr: read-only after cd and in bash -c"   "$g" "$(bash_cmd "cd /tmp && herdr agent list && bash -c 'herdr pane list'" "$x")"
expect 0 "herdr: other variable, harmless args"       "$g" "$(bash_cmd '$EDITOR notes.md' "$x")"
expect 0 "herdr: cd away in repo without plugin"      "$g" "$(bash_cmd 'cd /tmp && command herdr pane run w1:p1 ls' "$off")"
expect 2 "bash: bash -c git commit in main worktree"  "$g" "$(bash_cmd "bash -c 'git commit -m x'" "$on")"

w="$hooks/guard-main-worktree.sh"
expect 2 "edit: file in main worktree"                "$w" "$(file_op "$on/a/b/new.md")"
expect 0 "edit: file in linked worktree"              "$w" "$(file_op "$work/on-x/new.md")"
expect 0 "edit: file outside git"                     "$w" "$(file_op "/nonexistent-claude-code-herdr-test/loose.md")"
expect 0 "edit: repo without the plugin"              "$w" "$(file_op "$off/new.md")"
CLAUDE_ROLE=integrator expect 0 "edit: integrator"    "$w" "$(file_op "$on/new.md")"
expect 0 "edit: plugin set to false"                  "$w" "$(file_op "$dis/new.md")"
expect 0 "edit: settings.local.json sets false"       "$w" "$(file_op "$ldis/new.md")"

s="$hooks/session-start-worktree.sh"
out=$(jq -nc --arg d "$on" '{cwd: $d}' | "$s")
if jq -e '.hookSpecificOutput.additionalContext | contains("/multi-agent-herdr:dispatch")' <<<"$out" >/dev/null; then
    echo "ok    session-start: instructions in main worktree"
else
    echo "FAIL  session-start: no instructions in main worktree"; fails=$((fails + 1))
fi
for d in "$work/on-x" "$off" "$dis"; do
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

nl="$work/no-newline"
new_repo "$nl" no
printf 'node_modules' > "$nl/.gitignore"
(cd "$nl" && bash "$root/install.sh" >/dev/null)
if grep -qxF node_modules "$nl/.gitignore" && grep -qxF .env "$nl/.gitignore" \
    && grep -qxF .claude/settings.local.json "$nl/.gitignore"; then
    echo "ok    install: .gitignore without trailing newline"
else
    echo "FAIL  install: .gitignore lines glued: $(tr '\n' '|' < "$nl/.gitignore")"; fails=$((fails + 1))
fi
bad="$work/bad-settings"
new_repo "$bad" no
printf '{"broken": ' > "$bad/.claude/settings.json"
(cd "$bad" && bash "$root/install.sh" >/dev/null 2>&1); status=$?
if [[ $status == 1 && ! -e "$bad/CLAUDE.md" ]]; then
    echo "ok    install: invalid settings.json stops before copying"
else
    echo "FAIL  install: invalid settings.json (exit $status, CLAUDE.md $([[ -e "$bad/CLAUDE.md" ]] && echo written || echo absent))"
    fails=$((fails + 1))
fi
sp="$work/with space/repo"
mkdir -p "$work/with space"
new_repo "$sp" no
(cd "$sp" && "$root/plugin/scripts/new-worktree.sh" feat/y >/dev/null 2>&1)
if [[ -d "$work/with space/repo-y" ]]; then echo "ok    new-worktree: repository path with spaces"
else echo "FAIL  new-worktree: repository path with spaces"; fails=$((fails + 1)); fi

# agents-in-repo.py: branch -> worktree -> live agent, with a fake herdr on PATH.
fake="$work/bin"; mkdir -p "$fake"
# Fake herdr: `agent list` prints $FAKE_AGENTS, `pane current` reports pane $FAKE_PANE,
# `agent rename` is logged to $FAKE_LOG. Anything else fails like a syntax error.
cat > "$fake/herdr" <<'FAKE'
#!/bin/sh
case "$1 $2" in
    "agent list") cat "$FAKE_AGENTS" ;;
    "pane current") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$FAKE_PANE" ;;
    "agent rename") echo "rename $3 $4" >> "$FAKE_LOG"; echo '{"result":{}}' ;;
    *) exit 2 ;;
esac
FAKE
export FAKE_AGENTS="$work/agents.json" FAKE_LOG="$work/herdr.log" FAKE_PANE="w1:p1"
cat > "$FAKE_AGENTS" <<JSON
{"result":{"agents":[
 {"name":"integrator","pane_id":"w1:p1","agent_status":"idle","cwd":"$on"},
 {"name":"x","pane_id":"w2:p1","agent_status":"working","cwd":"$work/on-x/sub","foreground_cwd":"$work/on-x"},
 {"pane_id":"w3:p1","agent_status":"idle","cwd":"$work/on-x"},
 {"name":"elsewhere","pane_id":"w4:p1","agent_status":"idle","cwd":"$off"}
]},"type":"agent_list"}
JSON
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
check_air "integrator of this repo" "integrator idle main,"       --name integrator --main-worktree
check_air "name not in main worktree" ""                          --name x --main-worktree
got=$(cd "$off" && PATH="$fake:$PATH" "$air" --name integrator --main-worktree)
if [[ -z "$got" ]]; then echo "ok    agents-in-repo: other repository's integrator is not ours"
else echo "FAIL  agents-in-repo: found another repository's integrator: $got"; fails=$((fails + 1)); fi
(cd / && PATH="$fake:$PATH" "$air" >/dev/null 2>&1); [[ $? == 1 ]] \
    && echo "ok    agents-in-repo: exit 1 outside git" \
    || { echo "FAIL  agents-in-repo: exit outside git"; fails=$((fails + 1)); }

# claim-integrator.sh: keep, take or refuse the herdr name `integrator`.
claim="$root/plugin/scripts/claim-integrator.sh"
check_claim() {  # check_claim <description> <expected exit> <expected log> <pane> [env...]
    local desc="$1" want="$2" want_log="$3" pane="$4" got log; shift 4
    : > "$FAKE_LOG"
    (cd "$on" && env PATH="$fake:$PATH" HERDR_ENV=1 CLAUDE_ROLE=integrator FAKE_PANE="$pane" "$@" \
        "$claim" >/dev/null 2>&1); got=$?
    log=$(cat "$FAKE_LOG")
    if [[ "$got" == "$want" && "$log" == "$want_log" ]]; then echo "ok    claim-integrator: $desc"
    else echo "FAIL  claim-integrator: $desc (exit $got want $want, log '$log' want '$want_log')"; fails=$((fails + 1)); fi
}
check_claim "already named"            0 ""                         w1:p1
check_claim "name held by another"     3 ""                         w4:p1
check_claim "not the integrator"       1 ""                         w1:p1 CLAUDE_ROLE=
check_claim "outside herdr"            1 ""                         w1:p1 HERDR_ENV=
check_claim "pane without an agent"    2 ""                         w9:p9
sed -i.bak 's/"name":"integrator",//' "$FAKE_AGENTS" && rm -f "$FAKE_AGENTS.bak"
check_claim "unnamed: renames itself"  0 "rename w1:p1 integrator"  w1:p1

# Every `herdr agent prompt` in the skills sends the header: a literal message starts with it,
# and a "$VAR" message is assigned with the header as its first line in the same file.
if python3 - "$root/plugin/skills" <<'PY'
import pathlib, re, sys
header = "[herdr message from agent "
bad = []
for f in sorted(pathlib.Path(sys.argv[1]).glob("*/SKILL.md")):
    text = f.read_text()
    for m in re.finditer(r'herdr agent prompt (\S+) "([^"\n]*)', text):
        msg = m.group(2)
        var = re.fullmatch(r"\$\{?(\w+)\}?", msg)
        if var:
            if not re.search(rf'^{var.group(1)}="{re.escape(header)}', text, re.M):
                bad.append(f"{f.parent.name}: ${var.group(1)} has no header assignment")
        elif not msg.startswith(header):
            bad.append(f"{f.parent.name}: literal message without header: {msg[:40]}")
for b in bad:
    print("   ", b)
sys.exit(1 if bad else 0)
PY
then echo "ok    skills: every herdr agent prompt sends the header"
else echo "FAIL  skills: herdr agent prompt without header"; fails=$((fails + 1)); fi

echo
echo "$fails failure(s)"
exit "$fails"
