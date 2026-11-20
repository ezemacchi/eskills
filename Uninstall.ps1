#Requires -Version 7
<#
.SYNOPSIS
    Removes the kit from an agent: its skills and its write guard's entries. Keeps the person's
    configuration and state unless -RemoveData.

.DESCRIPTION
    Only what the kit installed is touched:
      - skill folders with the kit's .kit marker and the installer's record (.kit-installed.json), under
        this kit's name or an earlier one. They are moved to <kit folder>\backup\uninstall-<time>\, since
        they may hold the person's edits (with -RemoveData they are deleted);
      - the hook entries that run the kit's guard (hooks\<kit name>\...) in the agent's hooks file, which
        is copied to <hooks file>.before-uninstall first. Every other entry is kept;
      - with -RemoveData, the person's folder for the kit (%LOCALAPPDATA%\<kit name>, or <KIT>_HOME): each
        project's configuration and state, the default project, and the installer's backups, and the
        folders of the kit's earlier names.
    The guard's own folder (hooks\<kit name>\) is left in place: the agent keeps running what it loaded
    until it restarts, and a missing script would block it. Delete it after restarting. The kit's clone
    (this folder, with its packs\) is not touched either.

    Skills of the person's own that the installer moved aside (same name as a kit skill) stay in the
    backup folder it named; the summary lists them.

.PARAMETER AgentHost
    cursor (default) or claude: sets the default skills folder and hooks file.

.PARAMETER Target
    The skills folder. Default: the agent's, under the user's profile.

.PARAMETER HooksFile
    The hooks file. Default: the agent's.

.PARAMETER RemoveData
    Also delete the person's folder for the kit: configurations, state, backups.

.PARAMETER List
    Say what would be removed, and change nothing.

.EXAMPLE
    pwsh -NoProfile -File .\Uninstall.ps1 -List
#>
[CmdletBinding()]
param(
    [ValidateSet('cursor', 'claude')]
    [string] $AgentHost = 'cursor',
    [string] $Target,
    [string] $HooksFile,
    [switch] $RemoveData,
    [switch] $List
)

$ErrorActionPreference = 'Stop'
$defaults = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $PSScriptRoot 'skills\setup\defaults\config.json') | ConvertFrom-Json
$kitName = [string]$defaults.kit.name
$hostPlaces = $defaults.kit.agentHosts.$AgentHost
if (-not $Target) { $Target = Join-Path $env:USERPROFILE ([string]$hostPlaces.skills) }
if (-not $HooksFile) { $HooksFile = Join-Path $env:USERPROFILE ([string]$hostPlaces.hooksFile) }
$prefix = $kitName.ToUpperInvariant() -replace '[^A-Z0-9]', '_'
$kitRoot = [Environment]::GetEnvironmentVariable("${prefix}_HOME", 'Process')
if (-not $kitRoot) { $kitRoot = Join-Path $env:LOCALAPPDATA $kitName }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$utf8 = New-Object System.Text.UTF8Encoding $false

# The kit's skill folders, under this name or an earlier one.
$folders = @(Get-ChildItem -LiteralPath $Target -Directory -ErrorAction SilentlyContinue | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName '.kit') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $_.FullName '.kit-installed.json') -PathType Leaf)
    })
$names = @(@($folders | ForEach-Object { (Get-Content -Raw -LiteralPath (Join-Path $_.FullName '.kit')).Trim() }) + $kitName | Where-Object { $_ } | Sort-Object -Unique)
$markers = @($names | ForEach-Object { "\hooks\$_\" })
function Test-KitCommand([string]$Text) {
    foreach ($m in $markers) { if ($Text.IndexOf($m, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true } }
    $false
}

# The hooks file without the kit's entries (Cursor: an entry per event; Claude Code: groups of handlers).
$hooksPath = [IO.Path]::GetFullPath($HooksFile)
$current = $null
$removedEntries = 0
if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
    try { $current = Get-Content -Raw -Encoding utf8 -LiteralPath $hooksPath | ConvertFrom-Json } catch { $current = $false }
}
if ($current -and $current.PSObject.Properties['hooks'] -and $current.hooks -is [Management.Automation.PSCustomObject]) {
    foreach ($eventProp in @($current.hooks.PSObject.Properties)) {
        $entries = @($eventProp.Value)
        $kept = @($entries | Where-Object {
                if ($AgentHost -eq 'claude') { -not @($_.hooks | Where-Object { Test-KitCommand "$($_.command) $(@($_.args) -join ' ')" }).Count }
                else { -not (Test-KitCommand "$($_.command)") }
            })
        $removedEntries += $entries.Count - $kept.Count
        if ($kept.Count) { $current.hooks | Add-Member -NotePropertyName $eventProp.Name -NotePropertyValue $kept -Force }
        else { $current.hooks.PSObject.Properties.Remove($eventProp.Name) }
    }
}
$hookFolders = @($names | ForEach-Object { Join-Path (Split-Path -Parent $hooksPath) "hooks\$_" } | Where-Object { Test-Path -LiteralPath $_ })
$dataFolders = @(@($kitRoot) + @($names | Where-Object { $_ -ne $kitName } | ForEach-Object { Join-Path (Split-Path -Parent $kitRoot) $_ }) | Where-Object { Test-Path -LiteralPath $_ })
# Skill folders the installer moved aside (the person's own, or a kit skill it no longer ships): <name>-<time>.
$setAside = @(foreach ($d in $dataFolders) { Get-ChildItem -LiteralPath (Join-Path $d 'backup') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(?!uninstall-|manual-).+-\d{8}-\d{6}$' } | ForEach-Object { $_.FullName } })

$backupDir = Join-Path $kitRoot "backup\uninstall-$stamp"
Write-Host "Kit: $kitName$(if ($names.Count -gt 1) { " (also installed as: $(@($names | Where-Object { $_ -ne $kitName }) -join ', '))" })"
Write-Host "Skills to remove from ${Target}: $(if ($folders.Count) { ($folders | ForEach-Object { $_.Name }) -join ', ' } else { 'none' })$(if ($folders.Count -and -not $RemoveData) { " (moved to $backupDir)" })"
if ($current -eq $false) { Write-Host "Hook entries: $hooksPath is not valid JSON; it is left as it is. Remove the kit's entries (hooks\$kitName\) by hand." }
else { Write-Host "Hook entries to remove from ${hooksPath}: $removedEntries$(if ($removedEntries) { " (the file is copied to $hooksPath.before-uninstall first)" })" }
if ($hookFolders.Count) { Write-Host "Left in place until the agent restarts (delete them afterwards): $($hookFolders -join ', ')" }
if ($RemoveData) { Write-Host "Your data to delete: $(if ($dataFolders.Count) { $dataFolders -join ', ' } else { 'none' })" }
else { Write-Host "Your configuration and state are kept: $(if ($dataFolders.Count) { $dataFolders -join ', ' } else { 'none found' }) (add -RemoveData to delete them)." }
if ($setAside.Count) { Write-Host "Skill folders the installer had moved aside, which may be your own: $($setAside -join ', ')$(if ($RemoveData) { ' (deleted with your data: copy them out first if you want them)' } else { ' (copy back the ones you want)' })" }
if ($List) { Write-Host 'Nothing was changed (-List).'; exit 0 }

foreach ($f in $folders) {
    if ($RemoveData) { Remove-Item -LiteralPath $f.FullName -Recurse -Force }
    else {
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        Move-Item -LiteralPath $f.FullName -Destination (Join-Path $backupDir $f.Name)
    }
}
if ($current -and $removedEntries) {
    Copy-Item -LiteralPath $hooksPath -Destination "$hooksPath.before-uninstall" -Force
    [IO.File]::WriteAllText("$hooksPath.tmp", ($current | ConvertTo-Json -Depth 20), $utf8)
    Move-Item -LiteralPath "$hooksPath.tmp" -Destination $hooksPath -Force
}
if ($RemoveData) { foreach ($d in $dataFolders) { Remove-Item -LiteralPath $d -Recurse -Force } }
Write-Host "Removed. Restart $(if ($AgentHost -eq 'claude') { 'Claude Code' } else { 'Cursor' }). The kit's clone ($PSScriptRoot) can be deleted too; its packs\ folder holds your project packs."
