# shellcheck shell=bash
# Shell helper sourced by the multi-agent-herdr hooks (not a hook itself): plugin_enabled.
#
# plugin_enabled <repo root> succeeds when the project enables multi-agent-herdr, i.e. its
# `.claude/settings.local.json` or `.claude/settings.json` maps
# "multi-agent-herdr@claude-code-herdr" to `true` in `enabledPlugins`. The local file wins
# when it sets the key (as in Claude Code), so `false` there disables the guards. A missing
# or unparseable file counts as not setting it; same rule as enabled() in guard-main-bash.py.
# Needs jq.

plugin_enabled() {
    local file value
    for file in "$1/.claude/settings.local.json" "$1/.claude/settings.json"; do
        [[ -f "$file" ]] || continue
        value=$(jq -r --arg id "multi-agent-herdr@claude-code-herdr" \
            '.enabledPlugins[$id] | if . == null then empty else tostring end' \
            "$file" 2>/dev/null) || continue
        if [[ -n "$value" ]]; then
            [[ "$value" == true ]]
            return
        fi
    done
    return 1
}
