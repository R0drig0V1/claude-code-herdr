# Install the multi-agent-herdr workflow into the git repository of the current directory,
# from Windows PowerShell or PowerShell 7. Part of claude-code-herdr.
#
# Usage (from inside the target repository):
#   irm https://raw.githubusercontent.com/R0drig0V1/claude-code-herdr/main/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/R0drig0V1/claude-code-herdr/main/install.ps1))) -Yes
#   powershell -ExecutionPolicy Bypass -File C:\path\to\claude-code-herdr\install.ps1 [-DryRun] [-Force] [-Yes] [-NoHerdr]
#
# What it does:
# - Checks git and Git Bash (Git for Windows). The plugin's hooks and scripts run in Git Bash,
#   the shell Claude Code uses on Windows; WSL's bash is never used.
#   MULTI_AGENT_HERDR_BASH=<path to bash.exe> overrides where Git Bash is looked for.
# - Installs herdr when it is missing, after asking (-Yes: without asking; -NoHerdr: never),
#   with herdr's official Windows installer (https://herdr.dev/install.ps1), then offers
#   `herdr integration install claude`.
# - Runs install.sh through Git Bash for the rest (template files, .claude/settings.json,
#   .gitignore), so both installers do exactly the same to the repository.
#
# Needs git (Git for Windows, which provides Git Bash); jq to merge an existing
# .claude/settings.json (winget install jqlang.jq).
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Yes,
    [switch]$NoHerdr
)

# Continue, not Stop: Windows PowerShell 5.1 turns a native command's stderr into a
# terminating error under Stop. Native exit codes are checked through $LASTEXITCODE.
$ErrorActionPreference = 'Continue'
$RepoUrl = 'https://github.com/R0drig0V1/claude-code-herdr.git'
$HerdrInstaller = 'https://herdr.dev/install.ps1'

# Never `exit`: under `irm | iex` it would close the user's PowerShell window. A throw stops
# the script (exit code 1 under -File) and leaves the session open.
function Fail([string]$Message) {
    throw "error: $Message"
}

function Confirm-Step([string]$Question) {
    if ($Yes) { return $true }
    $answer = Read-Host "$Question [y/N]"
    return $answer -match '^[yY]'
}

function Update-SessionPath {
    # Installers add to the user/machine PATH; pick it up without a new terminal.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail 'git not found: install Git for Windows (https://git-scm.com/download/win) and rerun'
}
$null = git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0) { Fail 'run this inside the git repository to set up' }

# Git Bash: next to git itself, never a bare `bash` (it can be WSL's System32\bash.exe).
# MULTI_AGENT_HERDR_BASH overrides the search (a non-default Git install, or tests).
$bash = $null
$gitRoot = Split-Path (Split-Path (Get-Command git).Source)
$candidates = @($env:MULTI_AGENT_HERDR_BASH, (Join-Path $gitRoot 'bin\bash.exe'))
if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'Git\bin\bash.exe' }
if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe' }
foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate)) { $bash = $candidate; break }
}
if (-not $bash) {
    Fail 'Git Bash not found: install Git for Windows (https://git-scm.com/download/win); the plugin runs in it'
}

# herdr
$herdrNote = ''
if (Get-Command herdr -ErrorAction SilentlyContinue) {
    $herdrNote = "found ($(herdr --version 2>$null | Select-Object -First 1))"
} elseif ($NoHerdr) {
    $herdrNote = "not found (skipped); install it with: irm $HerdrInstaller | iex"
} elseif ($DryRun) {
    $herdrNote = "not found; would offer: irm $HerdrInstaller | iex"
} elseif (Confirm-Step "herdr is not installed. Install it now with: irm $HerdrInstaller | iex ?") {
    try {
        Invoke-RestMethod $HerdrInstaller -ErrorAction Stop | Invoke-Expression
        Update-SessionPath
    } catch {
        Write-Host "herdr installer failed: $_" -ForegroundColor Yellow
        Write-Host "If endpoint security blocks it: curl.exe -fsSLo install.cmd https://herdr.dev/install.cmd && install.cmd && del install.cmd"
    }
    if (Get-Command herdr -ErrorAction SilentlyContinue) {
        $herdrNote = "installed ($(herdr --version 2>$null | Select-Object -First 1))"
        if (Confirm-Step "Install herdr's Claude Code integration (herdr integration install claude)?") {
            herdr integration install claude | Out-Null
            if ($LASTEXITCODE -eq 0) { $herdrNote += '; Claude integration installed' }
            else { $herdrNote += "; 'herdr integration install claude' failed: rerun it by hand" }
        }
    } else {
        $herdrNote = 'not installed; see https://herdr.dev/docs/install/'
    }
} else {
    $herdrNote = "not found; install it with: irm $HerdrInstaller | iex"
}

if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
    Write-Host 'note: jq not found; an existing .claude/settings.json will not be merged (winget install jqlang.jq)' -ForegroundColor Yellow
}

# Source of install.sh and template/: this script's checkout, or a fresh shallow clone.
$src = $null
$tmp = $null
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'template'))) {
    $src = $PSScriptRoot
} else {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("claude-code-herdr-" + [Guid]::NewGuid().ToString('N'))
    # core.autocrlf=false: install.sh and the template's scripts must keep LF line endings.
    git -c core.autocrlf=false clone --quiet --depth 1 $RepoUrl (Join-Path $tmp 'src')
    if ($LASTEXITCODE -ne 0) { Fail "could not clone $RepoUrl" }
    $src = Join-Path $tmp 'src'
}

try {
    $shArgs = @('--no-herdr')   # herdr was handled above; install.sh prints this note
    $env:MULTI_AGENT_HERDR_HERDR_NOTE = $herdrNote
    if ($DryRun) { $shArgs += '--dry-run' }
    if ($Force) { $shArgs += '--force' }
    $script = (Join-Path $src 'install.sh') -replace '\\', '/'
    & $bash $script @shArgs
    $status = $LASTEXITCODE
} finally {
    if ($tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
if ($status -ne 0) { Fail "install.sh failed (exit $status)" }
