#Requires -Version 7
<#
.SYNOPSIS
    Exports the kit for publication: the tracked files only, with no git history, under its public
    name, then scans the copy for company data and secrets. Publishes nothing.

.DESCRIPTION
    Copies every file git tracks (git ls-files) to -Destination, which must not exist or be empty;
    the .git folder and its history are not copied. In the copy, the kit's working name (kit.name in
    skills/setup/defaults/config.json) becomes -Name everywhere, and its test variable
    <NAME>_CONFIG with it; each .kit file says -Name.

    Then it scans every file of the copy for -Patterns (GUIDs, e-mail addresses outside the invented
    domains, token shapes, private keys) and, with -Pack, for the patterns of the projects the kit
    was built for: each pack's publish.scanPatterns (its company, hosts and names). The packs' lint
    patterns are not used here: they keep configuration values out of the kit's files, and public
    addresses in the kit's defaults are fine to publish. A line holding one of -AllowLines is reported as allowed instead of as
    a finding. Exit 1 when a finding remains, so the copy is not published until each one is looked
    at.

    It does not run git init, add a remote, or push: whoever publishes does that, after the license
    and the approval to publish are settled.

.EXAMPLE
    pwsh -NoProfile -File .\tools\Export-Public.ps1 -Destination C:\exports\team-skills -Name team-skills -Pack ..\my-project-pack
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Destination,
    [Parameter(Mandatory)] [ValidatePattern('^[a-z][a-z0-9-]+$')] [string] $Name,
    [string[]] $Pack = @(),
    [string[]] $Patterns = @(
        '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
        '[A-Za-z0-9._%+-]+@(?!example\.invalid|acme\.invalid)[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
        'ATATT[A-Za-z0-9_-]{10,}', 'ghp_[A-Za-z0-9]{20,}', 'xox[abp]-[A-Za-z0-9-]{10,}', 'BBDC-[A-Za-z0-9+/]{20,}',
        '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    ),
    [string[]] $AllowLines = @('00000000-0000-0000-0000-000000000000')
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$defaults = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $repo 'skills\setup\defaults\config.json') | ConvertFrom-Json
$oldName = [string]$defaults.kit.name
$oldVar = ($oldName.ToUpperInvariant() -replace '[^A-Z0-9]', '_') + '_CONFIG'
$newVar = ($Name.ToUpperInvariant() -replace '[^A-Z0-9]', '_') + '_CONFIG'

$Destination = [IO.Path]::GetFullPath($Destination)
if ((Test-Path -LiteralPath $Destination) -and @(Get-ChildItem -LiteralPath $Destination -Force).Count) { Write-Host "Not exported: $Destination is not empty."; exit 1 }

$files = @(& git -C $repo ls-files)
if ($LASTEXITCODE -ne 0 -or -not $files.Count) { Write-Host "Not exported: git ls-files failed in $repo."; exit 1 }
$utf8 = [Text.UTF8Encoding]::new($false)
$textExtensions = '.ps1', '.md', '.json', '.txt', '.yml', '.yaml', ''
foreach ($rel in $files) {
    $from = Join-Path $repo $rel
    $to = Join-Path $Destination $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
    $ext = [IO.Path]::GetExtension($rel)
    if ((Split-Path -Leaf $rel) -eq '.kit') { [IO.File]::WriteAllText($to, $Name, $utf8); continue }
    if ($ext -in $textExtensions) {
        $text = [IO.File]::ReadAllText($from)
        [IO.File]::WriteAllText($to, $text.Replace($oldName, $Name).Replace($oldVar, $newVar), $utf8)
    }
    else { Copy-Item -LiteralPath $from -Destination $to }
}

$scanPatterns = [Collections.Generic.List[string]]::new()
foreach ($p in $Patterns) { $scanPatterns.Add($p) }
foreach ($packFolder in $Pack) {
    $packJson = Join-Path ([IO.Path]::GetFullPath($packFolder)) 'pack.json'
    if (-not (Test-Path -LiteralPath $packJson -PathType Leaf)) { Write-Host "Not scanned: no pack.json in $packFolder."; exit 1 }
    $packCfg = Get-Content -Raw -Encoding utf8 -LiteralPath $packJson | ConvertFrom-Json
    foreach ($p in @($packCfg.publish.scanPatterns | Where-Object { $_ })) {
        if (-not $scanPatterns.Contains([string]$p)) { $scanPatterns.Add([string]$p) }
    }
}

$findings = [Collections.Generic.List[string]]::new()
$allowed = [Collections.Generic.List[string]]::new()
foreach ($file in Get-ChildItem -LiteralPath $Destination -Recurse -File) {
    $rel = [IO.Path]::GetRelativePath($Destination, $file.FullName)
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
        $n++
        foreach ($pattern in $scanPatterns) {
            $m = [regex]::Match($line, $pattern)
            if (-not $m.Success) { continue }
            $where = "${rel}:$n  $($m.Value)"
            if (@($AllowLines | Where-Object { $line.Contains($_) }).Count) { $allowed.Add($where) } else { $findings.Add($where) }
        }
    }
}

"Exported $($files.Count) files to $Destination as '$Name' ($oldName -> $Name, $oldVar -> $newVar). No git history; nothing published."
if ($allowed.Count) { "Allowed ($($allowed.Count)):"; $allowed | ForEach-Object { "  $_" } }
if ($findings.Count) { "Findings ($($findings.Count)) to look at before publishing:"; $findings | ForEach-Object { "  $_" }; exit 1 }
'No findings.'
exit 0
