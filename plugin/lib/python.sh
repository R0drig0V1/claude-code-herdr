# shellcheck shell=sh
# Shell helper sourced by the multi-agent-herdr launcher and scripts (not run directly):
# find_python and py_run, so the plugin's Python scripts run on macOS, Linux and Windows.
#
# The scripts' `#!/usr/bin/env python3` shebang is not enough everywhere: Windows (Git Bash)
# has no exec bit and often no `python3` (the python.org installer provides `python` and the
# `py` launcher; `python3` may be the Microsoft Store alias, which only prints a hint). So the
# interpreter is chosen by running it:
#
# - find_python sets PY to the first of $MULTI_AGENT_HERDR_PYTHON, python3, python, py that
#   runs and is Python 3.9 or newer; it returns 1 when none does. The result is cached in PY.
# - py_run <script.py> [args...] runs a script with it, or prints an error and returns 127.
#
# POSIX sh compatible: also sourced by the bash scripts.

find_python() {
    [ -n "${PY:-}" ] && return 0
    for _py in ${MULTI_AGENT_HERDR_PYTHON:+"$MULTI_AGENT_HERDR_PYTHON"} python3 python py; do
        command -v "$_py" >/dev/null 2>&1 || continue
        if "$_py" -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1; then
            PY=$_py
            return 0
        fi
    done
    return 1
}

py_run() {
    if ! find_python; then
        echo "multi-agent-herdr: Python 3.9+ not found (tried python3, python, py;" \
            "set MULTI_AGENT_HERDR_PYTHON to override)" >&2
        return 127
    fi
    "$PY" "$@"
}
