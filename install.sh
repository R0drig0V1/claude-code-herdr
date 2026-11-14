#!/usr/bin/env bash
# Install the multi-agent-herdr workflow into the git repository of the current directory.
#
# Part of claude-code-herdr (ported from claude-code-multi-agent 0.1.0's install.sh; only the
# repository, plugin id and next steps differ).
#
# Usage (from inside the target repository):
#   curl -fsSL https://raw.githubusercontent.com/R0drig0V1/claude-code-herdr/main/install.sh | bash
#   bash /path/to/claude-code-herdr/install.sh [--dry-run] [--force] [--yes] [--no-herdr]
# On Windows, run it from Git Bash, or use install.ps1 from PowerShell (it calls this script).
#
# What it does:
# - Copies the project-owned files of template/ (CLAUDE.md, scripts/check.sh,
#   scripts/integrator.sh, .claude/prompts/integrator.md, docs/ indexes) into the repository.
#   Existing files are kept and listed, unless --force.
# - Enables the plugin for the project in .claude/settings.json: copied when absent, merged
#   with jq when present (the snippet is printed when jq is missing). An enabled old
#   multi-agent@claude-code-multi-agent plugin, which this one replaces, is set to false there:
#   both plugins' guards would run otherwise.
# - Appends the missing .gitignore lines, and `*.sh text eol=lf` to .gitattributes.
# - Installs herdr when it is missing, after asking (--yes: without asking; --no-herdr or
#   MULTI_AGENT_HERDR_SKIP_HERDR=1: never), with herdr's official installer for the platform:
#   https://herdr.dev/install.sh on macOS and Linux, https://herdr.dev/install.ps1 through
#   powershell.exe on Windows (Git Bash). Then offers `herdr integration install claude`.
#   Without a terminal to ask on, it only prints the command.
# The plugin itself (skills, agents, hooks, worktree and verify scripts) is not copied: Claude
# Code installs it from the marketplace the settings point at, and updates it from there.
#
# Needs git and bash (Git Bash on Windows); jq to merge an existing settings.json; curl
# (macOS, Linux) or PowerShell (Windows) to install herdr.
set -euo pipefail

REPO_URL="https://github.com/R0drig0V1/claude-code-herdr.git"
MARKETPLACE="claude-code-herdr"
PLUGIN="multi-agent-herdr@${MARKETPLACE}"
OLD_PLUGIN="multi-agent@claude-code-multi-agent"   # the plugin this one replaces

dry_run=false
force=false
assume_yes=false
skip_herdr=false
[[ "${MULTI_AGENT_HERDR_SKIP_HERDR:-}" == 1 ]] && skip_herdr=true
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=true ;;
        --force) force=true ;;
        --yes|-y) assume_yes=true ;;
        --no-herdr) skip_herdr=true ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true; exit 0 ;;
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

# .gitignore and .gitattributes lines.
added=()
append_line() {  # append_line <file name> <line>: add it unless the file already has it
    local file="$target/$1" line="$2"
    grep -qxF "$line" "$file" 2>/dev/null && return
    added+=("$1: $line")
    $dry_run && return
    # A last line without its newline would be glued to ours ("node_modules.env").
    if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
        printf '\n' >> "$file"
    fi
    printf '%s\n' "$line" >> "$file"
}
append_line .gitignore ".claude/settings.local.json"
append_line .gitignore ".env"
# The workflow's shell scripts must keep LF line endings in Windows checkouts
# (core.autocrlf=true): a CRLF shebang line breaks them in Git Bash.
append_line .gitattributes "*.sh text eol=lf"

# herdr itself: the official installer of the platform, only after the user agrees.
confirm() {  # confirm <question>: --yes, or a "y" typed on the terminal (also under curl | bash)
    $assume_yes && return 0
    local answer
    printf '%s [y/N] ' "$1" 2>/dev/null >/dev/tty || return 1
    read -r answer 2>/dev/null </dev/tty || return 1
    [[ "$answer" == [yY]* ]]
}
herdr_note=""
setup_herdr() {
    local shown os
    # install.ps1 handles herdr itself and passes its outcome here, to print with the rest.
    if [[ -n "${MULTI_AGENT_HERDR_HERDR_NOTE:-}" ]]; then
        herdr_note=$MULTI_AGENT_HERDR_HERDR_NOTE
        return
    fi
    if command -v herdr >/dev/null 2>&1; then
        herdr_note="found ($(herdr --version 2>/dev/null | head -n 1))"
        return
    fi
    os=$(uname -s 2>/dev/null)
    case "$os" in
        MINGW*|MSYS*|CYGWIN*)
            shown='powershell -ExecutionPolicy Bypass -c "irm https://herdr.dev/install.ps1 | iex"' ;;
        Darwin|Linux) shown='curl -fsSL https://herdr.dev/install.sh | sh' ;;
        *) herdr_note="not found; no installer for $os, see https://herdr.dev/docs/install/"
           return ;;
    esac
    if $skip_herdr; then herdr_note="not found (skipped); install it with: $shown"; return; fi
    if $dry_run; then herdr_note="not found; would offer: $shown"; return; fi
    if ! confirm "herdr is not installed. Install it now with: $shown ?"; then
        herdr_note="not found; install it with: $shown"
        return
    fi
    local status=0
    case "$os" in
        MINGW*|MSYS*|CYGWIN*)
            powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
                "irm https://herdr.dev/install.ps1 | iex" || status=$? ;;
        *) curl -fsSL https://herdr.dev/install.sh | sh || status=$? ;;
    esac
    if [[ $status -ne 0 ]]; then
        herdr_note="installer failed (exit $status); see https://herdr.dev/docs/install/"
        return
    fi
    # The installer's directory may not be on this shell's PATH yet.
    hash -r
    if ! command -v herdr >/dev/null 2>&1; then
        herdr_note="installed; open a new terminal so herdr is on PATH, then run /multi-agent-herdr:setup"
        return
    fi
    herdr_note="installed ($(herdr --version 2>/dev/null | head -n 1))"
    if confirm "Install herdr's Claude Code integration (herdr integration install claude)?"; then
        herdr integration install claude >/dev/null 2>&1 \
            && herdr_note+="; Claude integration installed" \
            || herdr_note+="; 'herdr integration install claude' failed: rerun it by hand"
    fi
}
setup_herdr

$dry_run && echo "dry run: nothing was written" && echo
echo "multi-agent-herdr workflow -> $target"
for f in ${copied[@]+"${copied[@]}"}; do echo "  + $f"; done
for f in ${skipped[@]+"${skipped[@]}"}; do echo "  = $f (exists, kept; --force to overwrite)"; done
[[ -n "$settings_note" ]] && echo "  ~ .claude/settings.json: $settings_note"
for l in ${added[@]+"${added[@]}"}; do echo "  + $l"; done
echo "  ~ herdr: $herdr_note"
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
