#!/usr/bin/env bash
# Install the multi-agent-herdr workflow into the git repository of the current directory.
#
# Part of claude-code-herdr (ported from claude-code-multi-agent 0.1.0's install.sh; only the
# repository, plugin id and next steps differ).
#
# Usage (from inside the target repository):
#   curl -fsSL https://raw.githubusercontent.com/R0drig0V1/claude-code-herdr/main/install.sh | bash
#   bash /path/to/claude-code-herdr/install.sh [--dry-run] [--force]
#
# What it does:
# - Copies the project-owned files of template/ (CLAUDE.md, scripts/check.sh,
#   scripts/integrator.sh, .claude/prompts/integrator.md, docs/ indexes) into the repository.
#   Existing files are kept and listed, unless --force.
# - Enables the plugin for the project in .claude/settings.json: copied when absent, merged
#   with jq when present (the snippet is printed when jq is missing). An enabled old
#   multi-agent@claude-code-multi-agent plugin, which this one replaces, is set to false there:
#   both plugins' guards would run otherwise.
# - Appends the missing .gitignore lines.
# The plugin itself (skills, agents, hooks, worktree and verify scripts) is not copied: Claude
# Code installs it from the marketplace the settings point at, and updates it from there.
#
# Needs git and bash; jq to merge an existing settings.json.
set -euo pipefail

REPO_URL="https://github.com/R0drig0V1/claude-code-herdr.git"
MARKETPLACE="claude-code-herdr"
PLUGIN="multi-agent-herdr@${MARKETPLACE}"
OLD_PLUGIN="multi-agent@claude-code-multi-agent"   # the plugin this one replaces

dry_run=false
force=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --force) force=true ;;
        -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

target=$(git rev-parse --show-toplevel 2>/dev/null) \
    || { echo "error: run this inside the git repository to set up" >&2; exit 1; }

# Source of the template: this script's own checkout, or a fresh shallow clone when piped.
src=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    [[ -d "$here/template" ]] && src="$here"
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
if [[ -e "$settings" ]] && command -v jq >/dev/null 2>&1 && ! jq empty "$settings" 2>/dev/null; then
    echo "error: $settings is not valid JSON; fix it and rerun (nothing was written)" >&2
    exit 1
fi

copied=() skipped=()
do_copy() {  # do_copy <relative path>
    local rel="$1" dest="$target/$1"
    if [[ -e "$dest" ]] && ! $force; then
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

# .claude/settings.json: enable the marketplace and the plugin for the project, and turn the
# old plugin off. "Enabled" means enabledPlugins maps the plugin id to true (a `false` entry
# is merged to true). The old plugin is set to false, not removed, so the file records the
# switch; a rerun finds it false and changes nothing.
settings_note=""
if [[ ! -e "$settings" ]]; then
    do_copy ".claude/settings.json"
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

$dry_run && echo "dry run: nothing was written" && echo
echo "multi-agent-herdr workflow -> $target"
for f in ${copied[@]+"${copied[@]}"}; do echo "  + $f"; done
for f in ${skipped[@]+"${skipped[@]}"}; do echo "  = $f (exists, kept; --force to overwrite)"; done
[[ -n "$settings_note" ]] && echo "  ~ .claude/settings.json: $settings_note"
for l in ${added[@]+"${added[@]}"}; do echo "  + .gitignore: $l"; done
if [[ "$settings_note" == NOT* ]]; then
    echo
    cat "$src/template/.claude/settings.json"
fi

cat <<EOF

Next steps:
  1. Fill in the TODOs of CLAUDE.md and put your lint/type/test commands in scripts/check.sh.
  2. Commit these files on main.
  3. Open Claude Code in the repository and trust the folder: it offers to install the
     plugin. Or install it explicitly:
       claude plugin marketplace add R0drig0V1/claude-code-herdr
       claude plugin install $PLUGIN --scope project
     This plugin replaces multi-agent@claude-code-multi-agent: the installer sets it to false
     in .claude/settings.json (by hand when jq is missing). Uninstall it if you no longer
     use it elsewhere.
  4. Inside herdr, run /multi-agent-herdr:setup once, launch the integrator with
     scripts/integrator.sh, and start development agents from it with
     /multi-agent-herdr:dispatch <type>/<name> <task>.
EOF
