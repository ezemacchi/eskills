# Installs eskills in one step:
#
#   irm https://raw.githubusercontent.com/ezemacchi/eskills/main/bootstrap.ps1 | iex
#
# It clones (or updates) the kit's repository and runs its installer. It needs git and PowerShell 7, asks
# for no administrator rights, and downloads nothing but the repository. Read it before running it.
#
# Optional variables, set before running it:
#   ESKILLS_DIR    where the clone goes (default: %USERPROFILE%\eskills)
#   ESKILLS_AGENT  cursor (default) or claude (Claude Code)

$ErrorActionPreference = 'Stop'
$repoUrl = 'https://github.com/ezemacchi/eskills.git'
$dir = if ($env:ESKILLS_DIR) { $env:ESKILLS_DIR } else { Join-Path $env:USERPROFILE 'eskills' }
$agent = if ($env:ESKILLS_AGENT) { $env:ESKILLS_AGENT } else { 'cursor' }

function Stop-Bootstrap([string]$Message) {
    Write-Host $Message -ForegroundColor Yellow
    # Within "irm | iex" a script cannot exit the person's session; throwing stops it and leaves the window open.
    throw 'eskills was not installed.'
}

Write-Host "eskills: clone or update $repoUrl in $dir, then install the kit's skills for $agent."

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Stop-Bootstrap 'git is missing. Install it (winget install Git.Git), open a new terminal and run this again.' }
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) { Stop-Bootstrap 'PowerShell 7 is missing. Install it (winget install Microsoft.PowerShell), open a new terminal and run this again.' }
if ($agent -notin 'cursor', 'claude') { Stop-Bootstrap "ESKILLS_AGENT must be cursor or claude, not '$agent'." }

if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
    $origin = "$(& git -C $dir remote get-url origin 2>$null)".Trim()
    if ($origin -notmatch 'eskills(\.git)?/?$') { Stop-Bootstrap "$dir is a clone of something else ($origin). Set ESKILLS_DIR to another folder and run this again." }
    Write-Host "Updating the clone in $dir."
    & git -C $dir pull --ff-only --quiet
    if ($LASTEXITCODE -ne 0) { Stop-Bootstrap "Could not update $dir (git pull). Commit or move away your local changes there, then run this again." }
}
elseif ((Test-Path -LiteralPath $dir) -and @(Get-ChildItem -LiteralPath $dir -Force).Count) {
    Stop-Bootstrap "$dir exists and is not empty. Set ESKILLS_DIR to another folder and run this again."
}
else {
    Write-Host "Cloning into $dir."
    & git clone --quiet $repoUrl $dir
    if ($LASTEXITCODE -ne 0) { Stop-Bootstrap "Could not clone $repoUrl." }
}

& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'Install.ps1') -AgentHost $agent
if ($LASTEXITCODE -ne 0) { Stop-Bootstrap 'The installer stopped; its message is above.' }
Write-Host ''
Write-Host "Done. Restart $(if ($agent -eq 'claude') { 'Claude Code' } else { 'Cursor' }), open a new chat and run /setup: it asks for your project's pack (a zip your team gives you) and sets everything up." -ForegroundColor Green
