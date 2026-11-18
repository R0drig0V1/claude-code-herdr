#!/usr/bin/env bash
# Install the multi-agent-herdr workflow into the git repository of the current directory.
#
# Part of claude-code-herdr (ported from claude-code-multi-agent 0.1.0's install.sh; only the
# repository, plugin id and next steps differ).
#
# Usage (from inside the target repository):
#   curl -fsSL https://raw.githubusercontent.com/R0drig0V1/claude-code-herdr/main/install.sh | bash
#   bash /path/to/claude-code-herdr/install.sh [--dry-run] [--force] [--no-plugin]
#
# What it does:
# - Copies the project-owned files of template/ (CLAUDE.md, scripts/check.sh,
#   scripts/integrator.sh, .claude/prompts/integrator.md, docs/ indexes) into the repository.
#   Existing files are kept and listed, unless --force.
# - Copies the plugin's workflow rules (plugin/context/workflow.md) to
#   .claude/multi-agent-herdr-workflow.md. That file is managed by the plugin: it is always
#   brought up to date (it is versioned, so the change shows in git), and CLAUDE.md imports it
#   with an `@.claude/multi-agent-herdr-workflow.md` line, appended when an existing CLAUDE.md
#   lacks it.
# - Enables the plugin for the project in .claude/settings.json: copied when absent, merged
#   with jq when present (the snippet is printed when jq is missing). An enabled old
#   multi-agent@claude-code-multi-agent plugin, which this one replaces, is set to false there:
#   both plugins' guards would run otherwise.
# - Appends the missing .gitignore lines.
# - Installs the plugin for the project with the claude CLI, when `claude` is on PATH and the
#   plugin is not installed yet (--no-plugin skips it; the commands are printed otherwise).
# - Checks what the workflow needs on this machine (jq, python3, gh, herdr and herdr's Claude
#   integration) and reports what is missing. It never installs herdr. When herdr is present
#   without its Claude integration, it asks before running `herdr integration install claude`
#   (the question is read from the terminal, so it also works piped from curl; without a
#   terminal the command is only printed).
# It never writes through a symbolic link or outside the repository: such files are reported
# and left alone.
# The plugin itself (skills, agents, hooks, worktree and verify scripts) is not copied: Claude
# Code installs it from the marketplace the settings point at, and updates it from there.
#
# Needs git and bash; jq to merge an existing settings.json.
set -euo pipefail

REPO_URL="https://github.com/R0drig0V1/claude-code-herdr.git"
MARKETPLACE="claude-code-herdr"
MARKETPLACE_REPO="R0drig0V1/claude-code-herdr"
PLUGIN="multi-agent-herdr@${MARKETPLACE}"
OLD_PLUGIN="multi-agent@claude-code-multi-agent"   # the plugin this one replaces

dry_run=false
force=false
install_plugin=true
tty=${MULTI_AGENT_HERDR_TTY:-/dev/tty}   # where questions are asked (the tests point it at a file)
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --force) force=true ;;
        --no-plugin) install_plugin=false ;;
        -h|--help)  # the header comment, up to the first line that is not a comment
            sed -n '2,/^[^#]/{/^#/!d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

target=$(git rev-parse --show-toplevel 2>/dev/null) \
    || { echo "error: run this inside the git repository to set up" >&2; exit 1; }

# Source of the template: this script's own checkout, or a fresh shallow clone when piped.
src=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    # Only this repository's checkout: a project may have a template/ directory of its own.
    [[ -f "$here/template/CLAUDE.md" && -f "$here/plugin/context/workflow.md" ]] && src="$here"
fi
if [[ -z "$src" ]]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    git clone --quiet --depth 1 "$REPO_URL" "$tmp/src"
    src="$tmp/src"
fi

# An existing .claude/settings.json must be valid JSON before anything is copied: the merge
# below would otherwise abort halfway, after the template files were written.
settings="$target/.claude/settings.json"
if [[ -e "$settings" ]] && command -v jq >/dev/null 2>&1 \
    && ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
    echo "error: $settings is not a JSON object; fix it and rerun (nothing was written)" >&2
    exit 1
fi

# Never write through a symbolic link or outside the repository: a tracked link (CLAUDE.md ->
# somewhere else, scripts/ -> another directory) would send the files there.
target_real=$(cd "$target" && pwd -P)
refused=()
safe() {  # safe <relative path>: succeeds when writing $target/<path> stays inside the repository
    local rel="$1" dir real
    dir=$(dirname "$target/$rel")
    while [[ ! -d "$dir" ]]; do dir=$(dirname "$dir"); done
    real=$(cd "$dir" && pwd -P)
    if [[ -L "$target/$rel" ]] || [[ "$real" != "$target_real" && "$real" != "$target_real"/* ]]; then
        refused+=("$rel"); return 1
    fi
}

copied=() skipped=()
do_copy() {  # do_copy <relative path>
    local rel="$1" dest="$target/$1"
    safe "$rel" || return 0
    if [[ -e "$dest" ]] && ! $force; then
        # CLAUDE.md is kept too, but may get the import line appended (reported separately).
        skipped+=("$rel"); return
    fi
    copied+=("$rel")
    $dry_run && return
    mkdir -p "$(dirname "$dest")"
    cp -p "$src/template/$rel" "$dest"
}

while IFS= read -r rel; do
    [[ "$rel" == ".claude/settings.json" ]] && continue
    do_copy "$rel"
done < <(cd "$src/template" && find . -type f | sed 's|^\./||' | sort)

# Workflow rules managed by the plugin: always the plugin's current version, never "kept".
WORKFLOW_REL=".claude/multi-agent-herdr-workflow.md"
IMPORT_LINE="@$WORKFLOW_REL"
workflow_note=""
if ! safe "$WORKFLOW_REL"; then
    workflow_note="NOT written (symbolic link or outside the repository)"
elif [[ ! -e "$target/$WORKFLOW_REL" ]]; then
    workflow_note="added"
elif ! cmp -s "$src/plugin/context/workflow.md" "$target/$WORKFLOW_REL"; then
    workflow_note="updated to the plugin's version"
fi
if [[ -n "$workflow_note" && "$workflow_note" != NOT* ]] && ! $dry_run; then
    mkdir -p "$target/.claude"
    cp "$src/plugin/context/workflow.md" "$target/$WORKFLOW_REL"
fi
# CLAUDE.md must import it. A CLAUDE.md written before this file existed gets the line
# appended (its old "Plan and workflow" / "Multi-agent workflow" sections are now duplicates:
# /multi-agent-herdr:setup offers to remove them).
import_note=""
if [[ -f "$target/CLAUDE.md" && ! -L "$target/CLAUDE.md" ]] && ! grep -qxF "$IMPORT_LINE" "$target/CLAUDE.md"; then
    import_note="appended $IMPORT_LINE (remove the old workflow sections it duplicates; /multi-agent-herdr:setup helps)"
    if ! $dry_run; then
        [[ -s "$target/CLAUDE.md" && -n "$(tail -c 1 "$target/CLAUDE.md")" ]] && printf '\n' >> "$target/CLAUDE.md"
        printf '\n%s\n' "$IMPORT_LINE" >> "$target/CLAUDE.md"
    fi
fi

# .claude/settings.json: enable the marketplace and the plugin for the project, and turn the
# old plugin off. "Enabled" means enabledPlugins maps the plugin id to true (a `false` entry
# is merged to true). The old plugin is set to false, not removed, so the file records the
# switch; a rerun finds it false and changes nothing.
settings_note=""
if [[ ! -e "$settings" && ! -L "$settings" ]]; then
    do_copy ".claude/settings.json"
elif ! safe ".claude/settings.json"; then
    settings_note="NOT changed (symbolic link or outside the repository): add the keys below by hand"
elif command -v jq >/dev/null 2>&1; then
    enabled() { jq -e --arg id "$1" '.enabledPlugins[$id] == true' "$settings" >/dev/null; }
    settings_note="merged the marketplace and plugin into it"
    enabled "$PLUGIN" && settings_note="already enables $PLUGIN"
    if enabled "$OLD_PLUGIN"; then
        settings_note+="; disabled $OLD_PLUGIN (replaced by $PLUGIN)"
    fi
    if ! $dry_run && [[ "$settings_note" != "already enables $PLUGIN" ]]; then
        merged=$(jq -s --arg old "$OLD_PLUGIN" \
            '(.[0] * .[1]) | if .enabledPlugins[$old] == true then .enabledPlugins[$old] = false else . end' \
            "$settings" "$src/template/.claude/settings.json")
        printf '%s\n' "$merged" > "$settings"
    fi
else
    settings_note="NOT changed (jq missing): add the keys below by hand"
fi
# settings.local.json is the user's own file: warn, do not edit it.
local_settings="$target/.claude/settings.local.json"
if [[ -f "$local_settings" ]] && command -v jq >/dev/null 2>&1 \
    && jq -e --arg id "$OLD_PLUGIN" '.enabledPlugins[$id] == true' "$local_settings" >/dev/null 2>&1; then
    settings_note+="${settings_note:+; }WARNING: .claude/settings.local.json still enables $OLD_PLUGIN: set it to false"
fi

# .gitignore lines.
gitignore="$target/.gitignore"
added=()
for line in ".claude/settings.local.json" ".env"; do
    safe ".gitignore" || break
    if ! grep -qxF "$line" "$gitignore" 2>/dev/null; then
        added+=("$line")
        $dry_run && continue
        # A last line without its newline would be glued to ours ("node_modules.env").
        if [[ -s "$gitignore" && -n "$(tail -c 1 "$gitignore")" ]]; then
            printf '\n' >> "$gitignore"
        fi
        printf '%s\n' "$line" >> "$gitignore"
    fi
done

# The plugin itself, through the claude CLI. "Installed" is any scope: a user-scope install is
# enabled for this project by .claude/settings.json.
plugin_note=""
if ! $install_plugin; then
    plugin_note="skipped (--no-plugin)"
elif ! command -v claude >/dev/null 2>&1; then
    plugin_note="NOT installed: claude is not on PATH"
elif command -v jq >/dev/null 2>&1 \
    && claude plugin list --json 2>/dev/null | jq -e --arg id "$PLUGIN" 'any(.[]; .id == $id)' >/dev/null 2>&1; then
    plugin_note="already installed"
elif $dry_run; then
    plugin_note="would be installed with the claude CLI (project scope)"
else
    (cd "$target" && claude plugin marketplace add "$MARKETPLACE_REPO") >/dev/null 2>&1 || true
    if (cd "$target" && claude plugin install "$PLUGIN" --scope project) >/dev/null 2>&1; then
        plugin_note="installed (project scope)"
    else
        plugin_note="NOT installed: the claude CLI refused"
    fi
fi

# What the workflow needs on this machine. Nothing here is installed without asking.
missing=()
for tool in jq python3 gh; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
herdr_note="" integration_cmd=""
if ! command -v herdr >/dev/null 2>&1; then
    herdr_note="NOT installed: curl -fsSL https://herdr.dev/install.sh | sh   (https://herdr.dev/tui/docs/install/), then: herdr integration install claude"
else
    herdr_note=$(herdr --version 2>/dev/null | head -n 1)
    integration=$(herdr integration status 2>/dev/null | sed -n 's/^claude: //p' | head -n 1)
    case "$integration" in
        current*) herdr_note+=", Claude integration current" ;;
        *)
            integration_cmd="herdr integration install claude"
            herdr_note+=", Claude integration ${integration:-unknown}"
            answer=""
            if ! $dry_run && [[ -r "$tty" ]] && { [[ -t 1 ]] || [[ -n "${MULTI_AGENT_HERDR_TTY:-}" ]]; }; then
                printf 'herdr has no current Claude integration (it writes a hook under ~/.claude/hooks/).\nRun "%s" now? [y/N] ' \
                    "$integration_cmd" >&2
                read -r answer < "$tty" || answer=""
            fi
            if [[ "$answer" == [yY]* ]] && herdr integration install claude >/dev/null 2>&1; then
                herdr_note+=" -> installed"; integration_cmd=""
            fi ;;
    esac
fi

$dry_run && echo "dry run: nothing was written" && echo
echo "multi-agent-herdr workflow -> $target"
for f in ${copied[@]+"${copied[@]}"}; do echo "  + $f"; done
for f in ${skipped[@]+"${skipped[@]}"}; do echo "  = $f (exists, kept; --force to overwrite)"; done
if [[ -n "$workflow_note" ]]; then echo "  ~ $WORKFLOW_REL: $workflow_note"
else echo "  = $WORKFLOW_REL (up to date)"; fi
[[ -n "$import_note" ]] && echo "  ~ CLAUDE.md: $import_note"
[[ -n "$settings_note" ]] && echo "  ~ .claude/settings.json: $settings_note"
for l in ${added[@]+"${added[@]}"}; do echo "  + .gitignore: $l"; done
for f in ${refused[@]+"${refused[@]}"}; do
    echo "  ! $f: NOT written (symbolic link or outside the repository)"
done
if [[ "$settings_note" == NOT* ]]; then
    echo
    cat "$src/template/.claude/settings.json"
fi
echo
echo "This machine:"
echo "  plugin $PLUGIN: $plugin_note"
echo "  herdr: $herdr_note"
if [[ ${#missing[@]} -gt 0 ]]; then echo "  missing tools: ${missing[*]}"; fi

echo
echo "Next steps:"
n=1
step() { echo "  $n. $1"; n=$((n + 1)); }
if [[ "$herdr_note" == NOT* ]]; then step "Install herdr: see the herdr line above."
elif [[ -n "$integration_cmd" ]]; then step "Run: $integration_cmd"; fi
if [[ ${#missing[@]} -gt 0 ]]; then step "Install: ${missing[*]}"; fi
case "$plugin_note" in
    NOT*|skipped*|would*)
        step "Install the plugin (or open Claude Code in the repository and accept its offer):
       claude plugin marketplace add $MARKETPLACE_REPO
       claude plugin install $PLUGIN --scope project" ;;
esac
step "Fill in the TODOs of CLAUDE.md, put your lint/type/test commands in scripts/check.sh,
     and commit these files on the base branch."
step "Inside herdr, launch the integrator with scripts/integrator.sh and start development
     agents from it with /multi-agent-herdr:dispatch <type>/<name> <task>."
echo
echo "Rerun this installer, or run /multi-agent-herdr:setup, to check the setup again later."
if [[ "$settings_note" == *"$OLD_PLUGIN"* ]]; then
    echo "This plugin replaces $OLD_PLUGIN: uninstall it if you no longer use it elsewhere."
fi
