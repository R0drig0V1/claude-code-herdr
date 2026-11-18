#!/usr/bin/env bash
# Smoke tests for the plugin's hooks, installer and agents-in-repo.py, run in throwaway git
# repositories. Part of claude-code-herdr (ported from claude-code-multi-agent 0.1.0).
#
# Usage: tests/test-hooks.sh        (exit code = number of failed cases)
#
# Builds a repository that enables the plugin (guards active) and one that does not (guards
# must stay out of the way), feeds the hooks the same JSON payloads Claude Code sends, and
# checks exit codes: 2 blocks, 0 allows. Then runs install.sh into empty repositories, runs
# new-worktree.sh under a path with spaces, runs agents-in-repo.py, claim-integrator.sh and the
# SessionStart hook that runs it (session-start-integrator.sh) against a fake `herdr` and a
# scripted claim-integrator.sh, and checks that every `herdr agent prompt` in the skills sends the
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
# Ordinary commands that used to get through (adversarial review, 2026-11-18).
x="$work/on-x"
expect 2 "bash: comment line before a push"            "$g" "$(bash_cmd $'# publish\ngit push origin HEAD:main' "$x")"
expect 2 "bash: comment line before a commit"          "$g" "$(bash_cmd $'# save the work\ngit commit -m x' "$on")"
expect 2 "bash: # inside a word is not a comment"      "$g" "$(bash_cmd 'echo issue#12; git commit -m x' "$on")"
expect 0 "bash: trailing comment with a quote"         "$g" "$(bash_cmd "git status # don't commit" "$on")"
expect 0 "bash: # inside quotes"                       "$g" "$(bash_cmd "echo 'a # b' && git status" "$on")"
expect 2 "bash: line continuation"                     "$g" "$(bash_cmd $'git \\\ncommit -m x' "$on")"
expect 2 "bash: subshell"                              "$g" "$(bash_cmd '(git commit -m x)' "$on")"
expect 2 "bash: subshell with cd into main"            "$g" "$(bash_cmd "(cd $on && git commit -m x)" "$x")"
expect 0 "bash: subshell with cd out of main"          "$g" "$(bash_cmd "(cd $x && git commit -m x)" "$on")"
expect 2 "bash: cd in a subshell does not leak"        "$g" "$(bash_cmd "(cd $x); git commit -m x" "$on")"
expect 2 "bash: brace group"                           "$g" "$(bash_cmd '{ git commit -m x; }' "$on")"
expect 2 "bash: brace group with cd"                   "$g" "$(bash_cmd "{ cd $on && git commit -m x; }" "$x")"
expect 2 "bash: if/then"                               "$g" "$(bash_cmd 'if true; then git commit -m x; fi' "$on")"
expect 2 "bash: negation"                              "$g" "$(bash_cmd '! git commit -m x' "$on")"
expect 2 "bash: for/do"                                "$g" "$(bash_cmd 'for f in a b; do rm $f; done' "$on")"
expect 2 "bash: command substitution"                  "$g" "$(bash_cmd 'echo $(git commit -m x)' "$on")"
expect 0 "bash: harmless command substitution"         "$g" "$(bash_cmd 'x=$(git rev-parse HEAD); echo "$x"' "$on")"
expect 2 "bash: git --no-pager commit"                 "$g" "$(bash_cmd 'git --no-pager commit -m x' "$on")"
expect 2 "bash: git -P commit"                         "$g" "$(bash_cmd 'git -P commit -m x' "$on")"
expect 0 "bash: git --no-pager log"                    "$g" "$(bash_cmd 'git --no-pager log -1' "$on")"
expect 2 "bash: git --no-pager push to main"           "$g" "$(bash_cmd 'git --no-pager push origin HEAD:main' "$x")"
expect 2 "bash: git -C main --no-pager commit"         "$g" "$(bash_cmd "git -C $on --no-pager commit -m x" "$x")"
expect 2 "bash: git --git-dir/--work-tree of main"     "$g" "$(bash_cmd "git --git-dir=$on/.git --work-tree=$on commit -m x" "$x")"
expect 2 "bash: bash -lc"                              "$g" "$(bash_cmd "bash -lc 'git commit -m x'" "$on")"
expect 2 "bash: gh -R o/r pr merge"                    "$g" "$(bash_cmd 'gh -R o/r pr merge 3' "$x")"
expect 2 "bash: cd to a variable set in the command"   "$g" "$(bash_cmd "MAIN=$on; cd \"\$MAIN\" && git commit -m x" "$x")"
expect 2 "bash: push to a variable set in the command" "$g" "$(bash_cmd 'B=main; git push origin HEAD:$B' "$x")"
expect 2 "bash: push to heads/main"                    "$g" "$(bash_cmd 'git push origin HEAD:heads/main' "$x")"
expect 2 "bash: bare git push in the main worktree"    "$g" "$(bash_cmd 'git push' "$on")"
expect 0 "bash: git push of the branch in a worktree"  "$g" "$(bash_cmd 'git push -u origin HEAD' "$x")"
expect 0 "bash: commit message with parens and #"      "$g" "$(bash_cmd 'git commit -m "fix(scope): x (#12)"' "$x")"
# A heredoc's body is data, its opening line is not.
expect 0 "bash: heredoc body in the main worktree"     "$g" "$(bash_cmd $'cat <<\'M\'\ngit commit -m x\nM' "$on")"
expect 0 "bash: heredoc body with # and a quote"       "$g" "$(bash_cmd $'git commit -F - <<\'M\'\nfix: # don\'t\nM' "$x")"
expect 2 "bash: redirect after the heredoc opener"     "$g" "$(bash_cmd $'cat <<\'M\' > src.py\nbody\nM' "$on")"
expect 2 "bash: command after the heredoc opener"      "$g" "$(bash_cmd $'python3 - <<\'M\' && git commit -m x\nprint(1)\nM' "$on")"
expect 2 "bash: pipe after the heredoc opener"         "$g" "$(bash_cmd $'cat <<M | tee notes.md\nbody\nM' "$on")"
# File writers are judged by their target, also from a linked worktree.
expect 2 "bash: rm of a main path from a worktree"     "$g" "$(bash_cmd "rm -rf $on/src" "$x")"
expect 2 "bash: cp into main from a worktree"          "$g" "$(bash_cmd "cp a.txt $on/a.txt" "$x")"
expect 2 "bash: sed -i of a main file from a worktree" "$g" "$(bash_cmd "sed -i '' s/a/b/ $on/README.md" "$x")"
expect 2 "bash: tee into main from a worktree"         "$g" "$(bash_cmd "echo hi | tee $on/f.txt" "$x")"
expect 2 "bash: settings.local.json of main"           "$g" "$(bash_cmd "cp s.json $on/.claude/settings.local.json" "$x")"
expect 0 "bash: rm inside the worktree"                "$g" "$(bash_cmd 'rm -rf build' "$x")"
expect 0 "bash: cp inside the worktree"                "$g" "$(bash_cmd "cp a.txt $x/b.txt" "$x")"
# A repository whose path holds a space is guarded like any other.
spg="$work/sp ace/repo"; mkdir -p "$work/sp ace"; new_repo "$spg" yes
expect 2 "bash: commit, repository path with a space"  "$g" "$(bash_cmd 'git commit -m x' "$spg")"
expect 2 "bash: push main, path with a space"          "$g" "$(bash_cmd 'git push origin HEAD:main' "$spg")"
expect 2 "edit: repository path with a space"          "$hooks/guard-main-worktree.sh" "$(file_op "$spg/new.md")"
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
expect 0 "herdr: prompt the integrator"               "$g" "$(bash_cmd 'herdr agent prompt integrator-on "PR #1 ready"' "$x")"
expect 2 "herdr: prompt the old default name"       "$g" "$(bash_cmd 'herdr agent prompt integrator "PR #1 ready"' "$x")"
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
expect 0 "herdr: \$HERDR_BIN_PATH prompts integrator" "$g" "$(bash_cmd '"$HERDR_BIN_PATH" agent prompt integrator-on "PR #1 ready"' "$x")"
expect 0 "herdr: read-only after cd and in bash -c"   "$g" "$(bash_cmd "cd /tmp && herdr agent list && bash -c 'herdr pane list'" "$x")"
expect 0 "herdr: other variable, harmless args"       "$g" "$(bash_cmd '$EDITOR notes.md' "$x")"
expect 0 "herdr: cd away in repo without plugin"      "$g" "$(bash_cmd 'cd /tmp && command herdr pane run w1:p1 ls' "$off")"
expect 2 "bash: bash -c git commit in main worktree"  "$g" "$(bash_cmd "bash -c 'git commit -m x'" "$on")"
expect 0 "bash: push to dev without settings"         "$g" "$(bash_cmd 'git push origin HEAD:dev' "$x")"
expect 0 "bash: push a feature branch"                "$g" "$(bash_cmd 'git push -u origin HEAD' "$x")"

# .claude/multi-agent-herdr.json: an integration branch, another integrator name, extra
# protected patterns and another worktree prefix (scripts/project-config.py).
cfg="$work/cfg"
new_repo "$cfg" yes
cat > "$cfg/.claude/multi-agent-herdr.json" <<'JSON'
{"$comment": "test", "base_branch": "dev", "integrator_name": "integrador",
 "protected_branches": ["promote/*"], "worktree_prefix": "chat-"}
JSON
git -C "$cfg" branch dev
git -C "$cfg" worktree add --quiet -b feat/z "$work/cfg-z"
z="$work/cfg-z"
expect 2 "settings: push HEAD:dev"                    "$g" "$(bash_cmd 'git push origin HEAD:dev' "$z")"
expect 2 "settings: push +HEAD:refs/heads/dev"        "$g" "$(bash_cmd 'git push origin +HEAD:refs/heads/dev' "$z")"
expect 2 "settings: push main stays protected"        "$g" "$(bash_cmd 'git push origin main' "$z")"
expect 2 "settings: push a protected pattern"         "$g" "$(bash_cmd 'git push origin HEAD:promote/2026-11' "$z")"
expect 2 "settings: push --all"                       "$g" "$(bash_cmd 'git push --all origin' "$z")"
expect 0 "settings: push the feature branch"          "$g" "$(bash_cmd 'git push -u origin feat/z' "$z")"
expect 0 "settings: prompt the configured integrator" "$g" "$(bash_cmd 'herdr agent prompt integrador "PR #1 ready"' "$z")"
expect 2 "settings: prompt the default name"          "$g" "$(bash_cmd 'herdr agent prompt integrator "PR #1 ready"' "$z")"
CLAUDE_ROLE=integrator expect 0 "settings: integrator pushes dev" "$g" "$(bash_cmd 'git push origin dev' "$cfg")"

pc="$root/plugin/scripts/project-config.py"
check_pc() {  # check_pc <description> <dir> <key> <expected output>
    local got
    got=$(cd "$2" && "$pc" "$3" 2>/dev/null)
    if [[ "$got" == "$4" ]]; then echo "ok    project-config: $1"
    else echo "FAIL  project-config: $1 (got '$got', want '$4')"; fails=$((fails + 1)); fi
}
check_pc "default base_branch"          "$on"  base_branch main
check_pc "default integrator_name"      "$on"  integrator_name integrator-on
check_pc "default worktree_prefix"      "$on"  worktree_prefix on-
check_pc "default protected_branches"   "$on"  protected_branches ""
check_pc "configured base_branch"       "$z"   base_branch dev
check_pc "configured integrator_name"   "$z"   integrator_name integrador
check_pc "configured protected_branches" "$z"  protected_branches "promote/*"
bad_cfg="$work/bad-cfg"
new_repo "$bad_cfg" yes
for json in '{"base_brnch": "dev"}' '{"integrator_name": "Integrador"}' '{"base_branch": "a..b"}' \
            '{"protected_branches": "main"}' '[]' '{"base_branch": '; do
    printf '%s\n' "$json" > "$bad_cfg/.claude/multi-agent-herdr.json"
    (cd "$bad_cfg" && "$pc" >/dev/null 2>&1); status=$?
    if [[ $status == 1 ]]; then echo "ok    project-config: rejects $json"
    else echo "FAIL  project-config: accepted $json (exit $status)"; fails=$((fails + 1)); fi
done
(cd "$on" && "$pc" no_such_key >/dev/null 2>&1); [[ $? == 2 ]] \
    && echo "ok    project-config: unknown key asked exits 2" \
    || { echo "FAIL  project-config: unknown key asked"; fails=$((fails + 1)); }
# An invalid file must not open the guards: the defaults still protect main.
expect 2 "settings: invalid file, main still protected" "$g" "$(bash_cmd 'git push origin HEAD:main' "$bad_cfg")"
expect 2 "settings: invalid file, main worktree guarded" "$g" "$(bash_cmd 'git commit -m x' "$bad_cfg")"

# verify-merge.sh: the exit code is the verdict, and no check.sh means no verdict.
vm="$root/plugin/scripts/verify-merge.sh"
verify() {  # verify <want exit> <description>: run verify-merge.sh in $on as the integrator would
    local got
    (cd "$on" && "$vm" >/dev/null 2>&1); got=$?
    if [[ "$got" == "$1" ]]; then echo "ok    verify-merge: $2"
    else echo "FAIL  verify-merge: $2 (exit $got, want $1)"; fails=$((fails + 1)); fi
}
verify 1 "no scripts/check.sh fails"
mkdir -p "$on/scripts"; printf '#!/bin/sh\nexit 0\n' > "$on/scripts/check.sh"
verify 1 "check.sh without the executable bit fails"
chmod +x "$on/scripts/check.sh"
verify 0 "passing check.sh"
if (cd "$on" && "$vm" 2>/dev/null | tail -n 1 | grep -qx "VERIFY OK"); then echo "ok    verify-merge: prints VERIFY OK"
else echo "FAIL  verify-merge: no VERIFY OK line"; fails=$((fails + 1)); fi
printf '#!/bin/sh\nexit 3\n' > "$on/scripts/check.sh"
verify 3 "failing check.sh gives its exit code"
(cd "$work/on-x" && "$vm" >/dev/null 2>&1); [[ $? == 2 ]] \
    && echo "ok    verify-merge: refuses a linked worktree" \
    || { echo "FAIL  verify-merge: ran in a linked worktree"; fails=$((fails + 1)); }
rm -rf "$on/scripts"
# The two guards agree on what "enabled" means: only the boolean true.
strq="$work/string-true"; new_repo "$strq" no
printf '{"enabledPlugins": {"multi-agent-herdr@claude-code-herdr": "true"}}\n' > "$strq/.claude/settings.json"
expect 0 "bash: enabledPlugins \"true\" string is not enabled" "$g" "$(bash_cmd 'git commit -m x' "$strq")"
expect 0 "edit: enabledPlugins \"true\" string is not enabled" "$hooks/guard-main-worktree.sh" "$(file_op "$strq/new.md")"

w="$hooks/guard-main-worktree.sh"
expect 2 "edit: file in main worktree"                "$w" "$(file_op "$on/a/b/new.md")"
expect 0 "edit: file in linked worktree"              "$w" "$(file_op "$work/on-x/new.md")"
expect 0 "edit: file outside git"                     "$w" "$(file_op "/nonexistent-claude-code-herdr-test/loose.md")"
expect 0 "edit: repo without the plugin"              "$w" "$(file_op "$off/new.md")"
CLAUDE_ROLE=integrator expect 0 "edit: integrator"    "$w" "$(file_op "$on/new.md")"
expect 0 "edit: plugin set to false"                  "$w" "$(file_op "$dis/new.md")"
expect 0 "edit: settings.local.json sets false"       "$w" "$(file_op "$ldis/new.md")"

s="$hooks/session-start.sh"
rules="$root/plugin/context/workflow.md"
rules_rel=.claude/multi-agent-herdr-workflow.md
ctx() { jq -nc --arg d "$1" '{cwd: $d}' | "$s" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
has() {  # has <name> <text> <must contain> [<must not contain>]
    if grep -qF -- "$3" <<<"$2" && { [[ -z "${4:-}" ]] || ! grep -qF -- "$4" <<<"$2"; }; then
        echo "ok    session-start: $1"
    else
        echo "FAIL  session-start: $1: $2"; fails=$((fails + 1))
    fi
}
silent() {  # silent <name> <dir>
    local out
    out=$(jq -nc --arg d "$2" '{cwd: $d}' | "$s")
    if [[ -z "$out" ]]; then echo "ok    session-start: $1"
    else echo "FAIL  session-start: $1: $out"; fails=$((fails + 1)); fi
}
# Main worktree without the rules file: both the rules note and the main-worktree instructions.
out=$(ctx "$on")
has "main worktree, rules missing: instructions" "$out" "/multi-agent-herdr:dispatch"
has "main worktree, rules missing: rules note" "$out" "$rules_rel is missing"
cp "$rules" "$on/$rules_rel"
has "main worktree, rules current: no rules note" "$(ctx "$on")" "/multi-agent-herdr:dispatch" "Tell the user once"
CLAUDE_ROLE=integrator silent "integrator, rules current" "$on"
echo "local change" >> "$on/$rules_rel"
CLAUDE_ROLE=integrator has "integrator, rules differ" "$(CLAUDE_ROLE=integrator ctx "$on")" \
    "differs from the installed" "MAIN worktree"
rm -f "$on/$rules_rel"
# A linked worktree is told only when its copy is neither the plugin's nor the base branch's:
# it cannot fix the base branch from there, and never gets the main-worktree instructions.
x="$work/on-x"
silent "linked worktree, rules missing here and on the base branch" "$x"
mkdir -p "$x/.claude" && echo "stale rules" > "$x/$rules_rel"
git -C "$x" add "$rules_rel" && git -C "$x" -c user.email=t@t -c user.name=t commit --quiet -m rules
git -C "$x" update-ref refs/remotes/origin/main HEAD
silent "linked worktree, stale copy is the base branch's" "$x"
echo "local change" >> "$x/$rules_rel"
has "linked worktree, copy differs from plugin and base" "$(ctx "$x")" "differs from the installed" "MAIN worktree"
rm -f "$x/$rules_rel"
has "linked worktree, rules deleted but on the base branch" "$(ctx "$x")" "$rules_rel is missing" "MAIN worktree"
cp "$rules" "$x/$rules_rel"
silent "linked worktree, rules current" "$x"
git -C "$x" update-ref -d refs/remotes/origin/main
git -C "$x" -c user.email=t@t -c user.name=t reset --quiet --hard HEAD~1
for d in "$off" "$dis"; do silent "repo without the plugin ($(basename "$d"))" "$d"; done

if CLAUDE_NOTIFY_SOUND=0 CLAUDE_NOTIFY_BELL=0 "$hooks/notify.sh" stop; then
    echo "ok    notify: exits 0"
else
    echo "FAIL  notify: non-zero exit"; fails=$((fails + 1))
fi

# install.sh also drives the claude and herdr CLIs. The tests never reach the real ones: fakes
# come first on PATH for the rest of the file, with their state in files under $ibin/state
# (installed: the plugin is installed; install-exit: exit code of `plugin install`;
# integration: the `claude:` line of `herdr integration status`; log: every mutating call).
ibin="$work/install-bin"; ist="$ibin/state"; mkdir -p "$ist"
cat > "$ibin/claude" <<'FAKE'
#!/usr/bin/env bash
st="$(dirname "$0")/state"
case "$*" in
    "plugin list --json")
        if [[ -e "$st/installed" ]]; then echo '[{"id":"multi-agent-herdr@claude-code-herdr","scope":"project"}]'
        else echo '[]'; fi ;;
    "plugin marketplace add "*) echo "$*" >> "$st/log" ;;
    "plugin install "*)
        echo "$*" >> "$st/log"
        code=$(cat "$st/install-exit" 2>/dev/null || echo 0)
        [[ "$code" == 0 ]] && touch "$st/installed"
        exit "$code" ;;
    *) exit 64 ;;
esac
FAKE
cat > "$ibin/herdr" <<'FAKE'
#!/usr/bin/env bash
st="$(dirname "$0")/state"
case "$*" in
    --version) echo "herdr 0.9.5" ;;
    "integration status") echo "pi: not installed (x)"; cat "$st/integration" 2>/dev/null || echo "claude: current (v11) (x)" ;;
    "integration install claude") echo "$*" >> "$st/log"; echo "claude: current (v11) (x)" > "$st/integration" ;;
    *) exit 64 ;;
esac
FAKE
chmod +x "$ibin/claude" "$ibin/herdr"
PATH="$ibin:$PATH"
ireset() { rm -f "$ist"/*; }
check() {  # check <name> <condition exit status> [<detail on failure>]
    if [[ "$2" == 0 ]]; then echo "ok    install: $1"
    else echo "FAIL  install: $1${3:+: $3}"; fails=$((fails + 1)); fi
}

target="$work/target"
new_repo "$target" no
(cd "$target" && bash "$root/install.sh" >/dev/null) || { echo "FAIL  install: exit $?"; fails=$((fails + 1)); }
for f in CLAUDE.md scripts/check.sh scripts/integrator.sh .claude/prompts/integrator.md .claude/settings.json \
         .claude/multi-agent-herdr.json .claude/multi-agent-herdr-workflow.md; do
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
if cmp -s "$rules" "$target/$rules_rel" && grep -qxF "@$rules_rel" "$target/CLAUDE.md"; then
    echo "ok    install: workflow rules copied and imported by CLAUDE.md"
else
    echo "FAIL  install: workflow rules or import missing"; fails=$((fails + 1))
fi
if grep -qF "= $rules_rel (up to date)" <<<"$second" && [[ $(grep -cxF "@$rules_rel" "$target/CLAUDE.md") == 1 ]]; then
    echo "ok    install: second run leaves current rules and the import alone"
else
    echo "FAIL  install: second run rules/import: $second"; fails=$((fails + 1))
fi
echo "stale" > "$target/$rules_rel"
out=$(cd "$target" && bash "$root/install.sh" --dry-run)
if grep -qF "updated to the plugin's version" <<<"$out" && [[ "$(cat "$target/$rules_rel")" == stale ]]; then
    echo "ok    install: --dry-run reports stale rules without writing"
else
    echo "FAIL  install: --dry-run stale rules: $out"; fails=$((fails + 1))
fi
(cd "$target" && bash "$root/install.sh" >/dev/null)
if cmp -s "$rules" "$target/$rules_rel"; then echo "ok    install: stale rules brought up to date"
else echo "FAIL  install: stale rules kept"; fails=$((fails + 1)); fi
# A CLAUDE.md from an older install, without the import (and no trailing newline).
legacy="$work/legacy-claude"
new_repo "$legacy" no
printf '# CLAUDE.md\n\n## Multi-agent workflow\nold rules' > "$legacy/CLAUDE.md"
out=$(cd "$legacy" && bash "$root/install.sh")
(cd "$legacy" && bash "$root/install.sh" >/dev/null)
if grep -qF "appended @$rules_rel" <<<"$out" && grep -qxF "old rules" "$legacy/CLAUDE.md" \
    && [[ $(grep -cxF "@$rules_rel" "$legacy/CLAUDE.md") == 1 ]]; then
    echo "ok    install: appends the import once to an existing CLAUDE.md"
else
    echo "FAIL  install: import into existing CLAUDE.md: $(tr '\n' '|' < "$legacy/CLAUDE.md")"; fails=$((fails + 1))
fi
printf '{"model": "opus"}\n' > "$target/.claude/settings.json"
(cd "$target" && bash "$root/install.sh" >/dev/null)
if jq -e '.model == "opus" and .enabledPlugins["multi-agent-herdr@claude-code-herdr"]' \
    "$target/.claude/settings.json" >/dev/null; then
    echo "ok    install: merges an existing settings.json"
else
    echo "FAIL  install: settings.json merge"; fails=$((fails + 1))
fi

# A project that still enables the old multi-agent plugin: install.sh turns it off (both
# plugins' guards would run otherwise), says so, and a second run changes nothing.
old="$work/old-plugin"
new_repo "$old" no
printf '{"enabledPlugins": {"multi-agent@claude-code-multi-agent": true}, "model": "opus"}\n' \
    > "$old/.claude/settings.json"
out=$(cd "$old" && bash "$root/install.sh")
if jq -e '.enabledPlugins["multi-agent@claude-code-multi-agent"] == false
          and .enabledPlugins["multi-agent-herdr@claude-code-herdr"] == true and .model == "opus"' \
    "$old/.claude/settings.json" >/dev/null && grep -q 'disabled multi-agent@claude-code-multi-agent' <<<"$out"; then
    echo "ok    install: disables the old multi-agent plugin and says so"
else
    echo "FAIL  install: old plugin still enabled or not reported: $(jq -c .enabledPlugins "$old/.claude/settings.json")"
    fails=$((fails + 1))
fi
before=$(cat "$old/.claude/settings.json")
out=$(cd "$old" && bash "$root/install.sh")
if [[ "$(cat "$old/.claude/settings.json")" == "$before" ]] && grep -q 'already enables multi-agent-herdr' <<<"$out" \
    && ! grep -q 'disabled multi-agent@' <<<"$out"; then
    echo "ok    install: second run with the old plugin off changes nothing"
else
    echo "FAIL  install: second run with the old plugin off: $out"; fails=$((fails + 1))
fi
# The new plugin already on, the old one too (settings written by hand): only the old one changes.
printf '{"enabledPlugins": {"multi-agent@claude-code-multi-agent": true, "multi-agent-herdr@claude-code-herdr": true}}\n' \
    > "$old/.claude/settings.json"
out=$(cd "$old" && bash "$root/install.sh" --dry-run)
if jq -e '.enabledPlugins["multi-agent@claude-code-multi-agent"] == true' "$old/.claude/settings.json" >/dev/null \
    && grep -q 'disabled multi-agent@claude-code-multi-agent' <<<"$out"; then
    echo "ok    install: --dry-run reports the old plugin without writing"
else
    echo "FAIL  install: --dry-run with the old plugin: $out"; fails=$((fails + 1))
fi
(cd "$old" && bash "$root/install.sh" >/dev/null)
if jq -e '.enabledPlugins == {"multi-agent@claude-code-multi-agent": false, "multi-agent-herdr@claude-code-herdr": true}' \
    "$old/.claude/settings.json" >/dev/null; then
    echo "ok    install: both enabled by hand, the old one is turned off"
else
    echo "FAIL  install: both enabled by hand: $(jq -c .enabledPlugins "$old/.claude/settings.json")"; fails=$((fails + 1))
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
# The plugin through the claude CLI: installed once, reported, never fatal.
ireset
pl="$work/plugin-cli"; new_repo "$pl" no
out=$(cd "$pl" && bash "$root/install.sh")
grep -qF "installed (project scope)" <<<"$out" \
    && grep -qxF "plugin install multi-agent-herdr@claude-code-herdr --scope project" "$ist/log" \
    && grep -qxF "plugin marketplace add R0drig0V1/claude-code-herdr" "$ist/log" \
    && ! grep -qF "claude plugin install" <<<"$out"
check "installs the plugin with the claude CLI" $? "$out"
out=$(cd "$pl" && bash "$root/install.sh")
grep -qF "already installed" <<<"$out" && [[ $(grep -c "^plugin install" "$ist/log") == 1 ]]
check "second run does not install the plugin again" $? "$out"
ireset
out=$(cd "$pl" && bash "$root/install.sh" --no-plugin)
grep -qF "skipped (--no-plugin)" <<<"$out" && grep -qF "claude plugin install" <<<"$out" && [[ ! -e "$ist/log" ]]
check "--no-plugin skips the CLI and prints the commands" $? "$out"
out=$(cd "$pl" && bash "$root/install.sh" --dry-run)
grep -qF "would be installed" <<<"$out" && [[ ! -e "$ist/log" ]]
check "--dry-run does not call the claude CLI" $? "$out"
echo 1 > "$ist/install-exit"
out=$(cd "$pl" && bash "$root/install.sh"); status=$?
[[ $status == 0 ]] && grep -qF "NOT installed: the claude CLI refused" <<<"$out" && grep -qF "claude plugin install" <<<"$out"
check "a refused plugin install is reported, not fatal" $? "exit $status: $out"

# herdr's Claude integration: asked on the terminal, installed only on yes.
ireset; touch "$ist/installed"
echo "claude: not installed (x)" > "$ist/integration"
out=$(cd "$pl" && MULTI_AGENT_HERDR_TTY=/dev/null bash "$root/install.sh" 2>/dev/null)
grep -qF "Run: herdr integration install claude" <<<"$out" && [[ ! -e "$ist/log" ]]
check "integration missing, no answer: command printed" $? "$out"
echo n > "$work/answer"
out=$(cd "$pl" && MULTI_AGENT_HERDR_TTY="$work/answer" bash "$root/install.sh" 2>/dev/null)
grep -qF "Run: herdr integration install claude" <<<"$out" && [[ ! -e "$ist/log" ]]
check "integration missing, answer no: not installed" $? "$out"
echo y > "$work/answer"
out=$(cd "$pl" && MULTI_AGENT_HERDR_TTY="$work/answer" bash "$root/install.sh" --dry-run 2>/dev/null)
asked=0; [[ -e "$ist/log" ]] && asked=1
check "integration missing, --dry-run: not asked" $asked "$out"
out=$(cd "$pl" && MULTI_AGENT_HERDR_TTY="$work/answer" bash "$root/install.sh" 2>/dev/null)
grep -qF -- "-> installed" <<<"$out" && grep -qxF "integration install claude" "$ist/log" \
    && ! grep -qF "Run: herdr integration" <<<"$out"
check "integration missing, answer yes: installed" $? "$out"
# No herdr and no claude on PATH: reported, with the steps.
ireset
out=$(cd "$pl" && PATH=/usr/bin:/bin bash "$root/install.sh")
grep -qF "herdr: NOT installed" <<<"$out" && grep -qF "Install herdr" <<<"$out" \
    && grep -qF "claude is not on PATH" <<<"$out"
check "no herdr and no claude: reported with next steps" $? "$out"
ireset; touch "$ist/installed"

# Never through a symbolic link or outside the repository.
ln="$work/links"; new_repo "$ln" no
mkdir -p "$work/outside"
ln -s "$work/outside/CLAUDE.md" "$ln/CLAUDE.md"
ln -s "$work/outside" "$ln/scripts"
out=$(cd "$ln" && bash "$root/install.sh")
[[ -z "$(ls -A "$work/outside")" ]] && grep -qF "! CLAUDE.md: NOT written" <<<"$out" \
    && grep -qF "! scripts/check.sh: NOT written" <<<"$out" && [[ -f "$ln/.claude/settings.json" ]]
check "refuses to write through symbolic links" $? "$(ls -A "$work/outside") / $out"
arr="$work/array-settings"; new_repo "$arr" no
printf '[]\n' > "$arr/.claude/settings.json"
(cd "$arr" && bash "$root/install.sh" >/dev/null 2>&1); status=$?
stopped=1; [[ $status == 1 && ! -e "$arr/CLAUDE.md" ]] && stopped=0
check "settings.json that is not an object stops before copying" $stopped "exit $status"
out=$(bash "$root/install.sh" --help)
grep -qF "Needs git and bash" <<<"$out" && grep -qF -- "--no-plugin" <<<"$out" && ! grep -q '^#' <<<"$out"
check "--help prints the whole header" $? "$out"
sp="$work/with space/repo"
mkdir -p "$work/with space"
new_repo "$sp" no
(cd "$sp" && "$root/plugin/scripts/new-worktree.sh" feat/y >/dev/null 2>&1)
if [[ -d "$work/with space/repo-y" ]]; then echo "ok    new-worktree: repository path with spaces"
else echo "FAIL  new-worktree: repository path with spaces"; fails=$((fails + 1)); fi
# With settings: ../chat-<name>, cut from the base branch (dev has a commit main lacks).
git -C "$cfg" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m "dev only" >/dev/null
git -C "$cfg" branch -f dev HEAD && git -C "$cfg" reset --quiet --hard HEAD~1
(cd "$cfg" && "$root/plugin/scripts/new-worktree.sh" feat/w >/dev/null 2>&1)
if [[ -d "$work/chat-w" ]] && [[ "$(git -C "$work/chat-w" rev-parse HEAD)" == "$(git -C "$cfg" rev-parse dev)" ]]; then
    echo "ok    new-worktree: worktree_prefix and base_branch"
else
    echo "FAIL  new-worktree: worktree_prefix and base_branch"; fails=$((fails + 1))
fi
(cd "$bad_cfg" && "$root/plugin/scripts/new-worktree.sh" feat/v >/dev/null 2>&1); status=$?
if [[ $status != 0 ]] && ! git -C "$bad_cfg" rev-parse --verify --quiet feat/v >/dev/null; then
    echo "ok    new-worktree: invalid settings stop before creating anything"
else
    echo "FAIL  new-worktree: invalid settings (exit $status)"; fails=$((fails + 1))
fi

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
 {"name":"integrator-on","pane_id":"w1:p1","agent_status":"idle","cwd":"$on"},
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
check_air "all agents of the repo"  "integrator-on idle main,x working feat/x,"
check_air "author of feat/x"        "x working feat/x,"           --branch feat/x
check_air "excluding the integrator" "x working feat/x,"          --exclude integrator-on
check_air "branch with no agent"    ""                            --branch fix/none
check_air "integrator of this repo" "integrator-on idle main,"    --name integrator-on --main-worktree
check_air "name not in main worktree" ""                          --name x --main-worktree
got=$(cd "$off" && PATH="$fake:$PATH" "$air" --name integrator-on --main-worktree)
if [[ -z "$got" ]]; then echo "ok    agents-in-repo: other repository's integrator is not ours"
else echo "FAIL  agents-in-repo: found another repository's integrator: $got"; fails=$((fails + 1)); fi
(cd / && PATH="$fake:$PATH" "$air" >/dev/null 2>&1); [[ $? == 1 ]] \
    && echo "ok    agents-in-repo: exit 1 outside git" \
    || { echo "FAIL  agents-in-repo: exit outside git"; fails=$((fails + 1)); }

# claim-integrator.sh: keep, take or refuse the herdr name `integrator-on` (the default of
# the repository `on`).
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
sed -i.bak 's/"name":"integrator-on",//' "$FAKE_AGENTS" && rm -f "$FAKE_AGENTS.bak"
check_claim "unnamed: renames itself"  0 "rename w1:p1 integrator-on" w1:p1
# With settings, the name comes from integrator_name.
: > "$FAKE_LOG"
(cd "$cfg" && env PATH="$fake:$PATH" HERDR_ENV=1 CLAUDE_ROLE=integrator FAKE_PANE=w1:p1 \
    "$claim" >/dev/null 2>&1); status=$?
if [[ $status == 0 && "$(cat "$FAKE_LOG")" == "rename w1:p1 integrador" ]]; then
    echo "ok    claim-integrator: configured integrator_name"
else
    echo "FAIL  claim-integrator: configured name (exit $status, log '$(cat "$FAKE_LOG")')"; fails=$((fails + 1))
fi

# On a clash, claim-integrator.sh says how to fix it (a unique integrator_name). The
# "unnamed" case above removed the holder's name: give it back first.
sed -i.bak 's/"pane_id":"w1:p1"/"name":"integrator-on","pane_id":"w1:p1"/' "$FAKE_AGENTS" && rm -f "$FAKE_AGENTS.bak"
msg=$(cd "$on" && env PATH="$fake:$PATH" HERDR_ENV=1 CLAUDE_ROLE=integrator FAKE_PANE=w4:p1 \
    "$claim" 2>&1 >/dev/null)
if [[ "$msg" == *integrator_name* && "$msg" == *multi-agent-herdr.json* ]]; then
    echo "ok    claim-integrator: a clash explains the integrator_name fix"
else
    echo "FAIL  claim-integrator: clash message without the fix: $msg"; fails=$((fails + 1))
fi

# session-start-integrator.sh: the SessionStart hook that claims the name. A fake plugin root
# holds a scripted claim-integrator.sh: one exit code per call from $FAKE_CLAIM_CODES (the last
# repeats), $FAKE_CLAIM_MSG on stderr, an optional $FAKE_CLAIM_SLEEP, and one line per call
# (its cwd) in $FAKE_CLAIM_LOG. The hook must not wait for herdr: every case returns within 3 s,
# well before the scripted 5-s claim of the slow case ends (the hook itself waits ~0.8 s; the
# bound leaves room for a shared CI runner, where jq, git and Python start slowly).
fake_root="$work/fake-plugin"; mkdir -p "$fake_root/scripts"
ln -s "$root/plugin/scripts/project-config.py" "$fake_root/scripts/project-config.py"
cat > "$fake_root/scripts/claim-integrator.sh" <<'FAKE'
#!/bin/sh
pwd >> "$FAKE_CLAIM_LOG"
[ -n "${FAKE_CLAIM_SLEEP:-}" ] && sleep "$FAKE_CLAIM_SLEEP"
n=$(wc -l < "$FAKE_CLAIM_LOG")
code=$(echo "$FAKE_CLAIM_CODES" | awk -v n="$n" '{ print (n <= NF) ? $n : $NF }')
echo "$FAKE_CLAIM_MSG" >&2
exit "$code"
FAKE
chmod +x "$fake_root/scripts/claim-integrator.sh"
ssi="$hooks/session-start-integrator.sh"
now() { python3 -c 'import time; print(time.time())'; }
ss_out=""; ss_calls=0
run_ssi() {  # run_ssi <case> <cwd> [env...]: sets ss_out and ss_calls; fails if slow or non-zero
    local case="$1" dir="$2" t0 t1 status; shift 2
    export FAKE_CLAIM_LOG="$work/claim-$case.log"; : > "$FAKE_CLAIM_LOG"
    t0=$(now)
    ss_out=$(jq -nc --arg d "$dir" '{cwd: $d, hook_event_name: "SessionStart", source: "startup"}' \
        | env PATH="$fake:$PATH" CLAUDE_PLUGIN_ROOT="$fake_root" HERDR_ENV=1 CLAUDE_ROLE=integrator \
              FAKE_CLAIM_CODES=0 FAKE_CLAIM_MSG="" "$@" "$ssi" 2>/dev/null); status=$?
    t1=$(now)
    sleep 0.1   # let a fast worker log its call
    ss_calls=$(wc -l < "$FAKE_CLAIM_LOG" | tr -d ' ')
    if [[ $status != 0 ]] || python3 -c "import sys; sys.exit(not ($t1 - $t0 > 3))"; then
        echo "FAIL  session-start-integrator: $case (exit $status, $(python3 -c "print(round($t1 - $t0, 2))") s)"
        fails=$((fails + 1)); return 1
    fi
}
ctx() { jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$ss_out" 2>/dev/null; }
check_ssi() {  # check_ssi <description> <condition...>
    local desc="$1"; shift
    if "$@"; then echo "ok    session-start-integrator: $desc"
    else echo "FAIL  session-start-integrator: $desc (calls $ss_calls, output '$ss_out')"; fails=$((fails + 1)); fi
}
silent_no_claim() { [[ -z "$ss_out" && "$ss_calls" == 0 ]]; }

run_ssi role-unset "$on" CLAUDE_ROLE= && check_ssi "no claim when CLAUDE_ROLE is unset" silent_no_claim
run_ssi no-herdr "$on" HERDR_ENV= && check_ssi "no claim outside herdr" silent_no_claim
run_ssi linked "$work/on-x" && check_ssi "no claim in a linked worktree" silent_no_claim
run_ssi no-plugin "$off" && check_ssi "no claim in a repo without the plugin" silent_no_claim
: > "$work/claim-subagent.log"
ss_out=$(jq -nc --arg d "$on" '{cwd: $d, agent_id: "a1", hook_event_name: "SessionStart"}' \
    | env PATH="$fake:$PATH" CLAUDE_PLUGIN_ROOT="$fake_root" HERDR_ENV=1 CLAUDE_ROLE=integrator \
          FAKE_CLAIM_CODES=0 FAKE_CLAIM_LOG="$work/claim-subagent.log" "$ssi" 2>/dev/null)
ss_calls=$(wc -l < "$work/claim-subagent.log" | tr -d ' ')
check_ssi "no claim for a subagent" silent_no_claim

run_ssi exit0 "$on" FAKE_CLAIM_CODES=0
claimed_in=$(cat "$FAKE_CLAIM_LOG")
check_ssi "exit 0: one line naming the agent, claimed from the main worktree" \
    bash -c '[[ "$1" == "You are the herdr agent integrator-on"* && $(wc -l <<<"$1") == *1 \
              && "$2" == 1 && "$3" -ef "$4" ]]' _ "$(ctx)" "$ss_calls" "$claimed_in" "$on"
run_ssi exit3 "$on" FAKE_CLAIM_CODES=3 \
    FAKE_CLAIM_MSG="the herdr name 'integrator-on' is held by pane w4:p1 (cwd $off)"
check_ssi "exit 3: names the holder and says to ask the user" \
    bash -c '[[ "$1" == *"already holds"* && "$1" == *"pane w4:p1"* && "$1" == *"ask"*"user"* ]]' _ "$(ctx)"
run_ssi exit1 "$on" FAKE_CLAIM_CODES=1 FAKE_CLAIM_MSG="invalid .claude/multi-agent-herdr.json"
check_ssi "other failure: short warning, session continues" \
    bash -c '[[ "$1" == *warning* && "$1" == *"exit 1"* && "$1" == *invalid* ]]' _ "$(ctx)"
run_ssi slow "$on" FAKE_CLAIM_SLEEP=5
check_ssi "slow herdr: returns before the 5-s claim ends, reports it still running" \
    bash -c '[[ "$1" == *"still running"* ]]' _ "$(ctx)"
run_ssi retry "$on" FAKE_CLAIM_CODES="2 0" FAKE_CLAIM_MSG="no herdr agent detected in pane w1:p1"
check_ssi "agent not detected yet: says it retries in the background" \
    bash -c '[[ "$1" == *"background retry"* ]]' _ "$(ctx)"
sleep 2.5
calls=$(wc -l < "$work/claim-retry.log" | tr -d ' ')
[[ "$calls" == 2 ]] && echo "ok    session-start-integrator: the background retry claims the name (2 calls)" \
    || { echo "FAIL  session-start-integrator: background retry made $calls call(s), want 2"; fails=$((fails + 1)); }

# End to end with the real claim-integrator.sh and the fake herdr: an unnamed agent in the
# integrator's pane is renamed at session start.
sed -i.bak 's/"name":"integrator-on",//' "$FAKE_AGENTS" && rm -f "$FAKE_AGENTS.bak"
: > "$FAKE_LOG"
ss_out=$(jq -nc --arg d "$on" '{cwd: $d, hook_event_name: "SessionStart", source: "resume"}' \
    | env PATH="$fake:$PATH" HERDR_ENV=1 CLAUDE_ROLE=integrator FAKE_PANE=w1:p1 "$ssi" 2>/dev/null)
sleep 0.2
if [[ "$(cat "$FAKE_LOG")" == "rename w1:p1 integrator-on" && "$(ctx)" == *"herdr agent integrator-on"* ]]; then
    echo "ok    session-start-integrator: real claim renames the unnamed agent"
else
    echo "FAIL  session-start-integrator: real claim (log '$(cat "$FAKE_LOG")', output '$ss_out')"; fails=$((fails + 1))
fi
sed -i.bak 's/"pane_id":"w1:p1"/"name":"integrator-on","pane_id":"w1:p1"/' "$FAKE_AGENTS" && rm -f "$FAKE_AGENTS.bak"

# The default integrator name: project-config.py computes it, template/scripts/integrator.sh
# repeats the rule in Bash; both must agree, and match herdr's name rule.
names="$work/names"; mkdir -p "$names"
for dir in "Astro-SimCLR" "MC SDDP" "tesis.master" "___" "UPPER_case-9" \
           "a-very-long-repository-name-that-overflows" "x--y..z"; do
    case "$dir" in
        Astro-SimCLR) want=integrator-astro-simclr ;;
        "MC SDDP") want=integrator-mc-sddp ;;
        tesis.master) want=integrator-tesis-master ;;
        ___) want=integrator ;;
        UPPER_case-9) want=integrator-upper_case-9 ;;
        a-very-long-repository-name-that-overflows) want=integrator-a-very-long-repositor ;;
        x--y..z) want=integrator-x--y-z ;;
    esac
    repo="$names/$dir"
    new_repo "$repo" no
    mkdir -p "$repo/scripts" && cp "$root/template/scripts/integrator.sh" "$repo/scripts/"
    py=$("$pc" --root "$repo" integrator_name 2>&1)
    sh=$(HERDR_ENV=1 "$repo/scripts/integrator.sh" --print-name 2>&1)
    if [[ "$py" == "$want" && "$sh" == "$want" && "$want" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
        echo "ok    default integrator_name: '$dir' -> $want"
    else
        echo "FAIL  default integrator_name: '$dir' (python '$py', bash '$sh', want '$want')"
        fails=$((fails + 1))
    fi
done
# An explicit integrator_name wins in integrator.sh too.
printf '{"integrator_name": "integrador"}\n' > "$names/Astro-SimCLR/.claude/multi-agent-herdr.json"
sh=$(HERDR_ENV=1 "$names/Astro-SimCLR/scripts/integrator.sh" --print-name 2>&1)
[[ "$sh" == integrador ]] && echo "ok    integrator.sh: configured integrator_name wins" \
    || { echo "FAIL  integrator.sh: configured name ignored (got '$sh')"; fails=$((fails + 1)); }

# Skills keep shell code free of the tokens Claude Code substitutes with the arguments ($0,
# $ARGUMENTS in a code block, ...): tests/check-skill-substitutions.py.
if python3 "$root/tests/check-skill-substitutions.py" "$root/plugin/skills"; then
    echo "ok    skills: no argument placeholder in shell code"
else
    echo "FAIL  skills: argument placeholder that Claude Code would substitute"; fails=$((fails + 1))
fi
mkdir -p "$work/skills-bad/x"
# The line that broke in dispatch (before worktree-of.sh).
cat > "$work/skills-bad/x/SKILL.md" <<'MD'
```bash
WT=$(git worktree list --porcelain | awk -v b="branch refs/heads/$BRANCH" '/^worktree /{p=substr($0,10)} $0==b{print p}')
```
MD
if ! python3 "$root/tests/check-skill-substitutions.py" "$work/skills-bad" >/dev/null 2>&1; then
    echo "ok    skills: the check rejects an awk \$0 in a skill"
else
    echo "FAIL  skills: the check accepted an awk \$0"; fails=$((fails + 1))
fi
# worktree-of.sh: the dispatch skill's branch -> worktree lookup (path with spaces).
got=$(cd "$sp" && "$root/plugin/scripts/worktree-of.sh" feat/y)
if [[ "$got" == "$(cd "$work/with space/repo-y" && pwd -P)" || "$got" == "$work/with space/repo-y" ]]; then
    echo "ok    worktree-of: path of a branch's worktree"
else
    echo "FAIL  worktree-of: got '$got'"; fails=$((fails + 1))
fi
(cd "$sp" && "$root/plugin/scripts/worktree-of.sh" feat/none >/dev/null 2>&1); [[ $? == 1 ]] \
    && echo "ok    worktree-of: exit 1 for a branch without a worktree" \
    || { echo "FAIL  worktree-of: branch without a worktree"; fails=$((fails + 1)); }

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
