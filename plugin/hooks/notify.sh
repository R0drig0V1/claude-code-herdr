#!/bin/sh
# Stop / Notification hook: play a short sound and ring the terminal bell on the tab of the
# Claude session that fired it, so you can tell which of several sessions finished or needs
# attention. Part of the multi-agent-herdr plugin (unchanged from multi-agent 0.1.0;
# herdr's sidebar shows the same done/blocked states per workspace).
#
# Usage: notify.sh stop|attention
#
# - Sound per platform: macOS `afplay`; Linux `paplay`, `aplay` or `canberra-gtk-play` with the
#   freedesktop sound theme; Windows (Git Bash / MSYS / Cygwin) and WSL through
#   `powershell.exe`. Platforms with none of these stay silent.
# - Bell: hook children run without a controlling tty, so walk up the parent chain to the
#   first ancestor that has one (the claude process attached to the tab) and write BEL to it.
#   Terminal.app, iTerm2 and most Linux terminals then badge or flash that tab.
# - Opt out with CLAUDE_NOTIFY_SOUND=0 and/or CLAUDE_NOTIFY_BELL=0.
#
# Always exits 0 and never waits for the sound: a notification must not affect the session.

event="${1:-stop}"

play() {
    [ "${CLAUDE_NOTIFY_SOUND:-1}" = "0" ] && return
    windows=""
    case "$(uname -s 2>/dev/null)" in
        Darwin)
            [ "$event" = attention ] && name=Ping || name=Glass
            afplay "/System/Library/Sounds/$name.aiff" >/dev/null 2>&1 &
            return ;;
        MINGW*|MSYS*|CYGWIN*) windows=1 ;;
        Linux) grep -qi microsoft /proc/version 2>/dev/null && windows=1 ;;
    esac
    if [ -n "$windows" ]; then
        [ "$event" = attention ] && name=Exclamation || name=Asterisk
        # Play() is asynchronous: keep PowerShell alive long enough for the sound to finish.
        command -v powershell.exe >/dev/null 2>&1 && powershell.exe -NoProfile -Command \
            "[System.Media.SystemSounds]::$name.Play(); Start-Sleep -Milliseconds 700" \
            >/dev/null 2>&1 &
        return
    fi
    [ "$event" = attention ] && name=message || name=complete
    sound=""
    for dir in /usr/share/sounds/freedesktop/stereo /usr/share/sounds/gnome/default/alerts; do
        for ext in oga ogg wav; do
            if [ -f "$dir/$name.$ext" ]; then sound="$dir/$name.$ext"; break 2; fi
        done
    done
    if [ -n "$sound" ] && command -v paplay >/dev/null 2>&1; then
        paplay "$sound" >/dev/null 2>&1 &
    elif [ -n "$sound" ] && [ "${sound##*.}" = wav ] && command -v aplay >/dev/null 2>&1; then
        aplay -q "$sound" >/dev/null 2>&1 &
    elif command -v canberra-gtk-play >/dev/null 2>&1; then
        [ "$event" = attention ] && id=message-new-instant || id=complete
        canberra-gtk-play -i "$id" >/dev/null 2>&1 &
    fi
}

bell() {
    [ "${CLAUDE_NOTIFY_BELL:-1}" = "0" ] && return
    pid=$$
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
        t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        case "$t" in
            ""|"?"|"??") ;;
            *) if [ -w "/dev/$t" ]; then printf '\a' > "/dev/$t"; fi; return ;;
        esac
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
}

play
bell
exit 0
