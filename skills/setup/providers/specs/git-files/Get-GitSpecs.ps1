<#
.SYNOPSIS
    Syncs a specification clone safely and lists the spec files for one story.

.PARAMETER Story
    Any text that holds the story's code: the code itself, a ticket summary, or a link to a spec
    file. The project's code is providers.git-files.codePattern.

.DESCRIPTION
    The clone is paths.specsRepo in the kit configuration. Everything about the repository's layout
    is configuration (providers.git-files):
      branch          the branch the specs live on
      root            the folder that holds the specs
      codePattern     a regular expression that finds the story's code; its named groups are the
                      parts of the code, used in the templates below
      codeHelp        how the code looks, for the message when none is found
      upper, pad,     how each part is written before it fills a template: upper-cased, padded with
      aliases         zeros to a width, or replaced (an alias is matched ignoring case)
      folderTemplate  the folder to list, from {root} and the parts
      fileTemplate    how the story's file names start, from the parts
      kinds           in order, the kind of each file, from a regular expression on its path
                      (match, and optionally exclude); a file no kind matches is 'other'
    Pulls only when the clone is on that branch with no local changes. Otherwise fetches and lists
    files as origin/<branch>:<path>, readable with git -C <clone> show origin/<branch>:<path>.

.EXAMPLE
    Get-GitSpecs.ps1 <story code>
    Get-GitSpecs.ps1 -Check

.NOTES
    Exit codes: 0 found (or -Check passed), 1 no files matched or bad input, 2 no clone configured.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Story,
    [string] $Clone,
    [switch] $Check,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

# kit-config:start (identical in every kit script; Test-Kit.ps1 checks it)
function Stop-Kit([int]$Code, [string]$Message) { [Console]::Error.WriteLine($Message); exit $Code }

function Merge-KitObject($Base, $Over) {
    if ($Base -isnot [Management.Automation.PSCustomObject] -or $Over -isnot [Management.Automation.PSCustomObject]) {
        if ($Over -is [array]) { return , $Over }
        return $Over
    }
    $out = [pscustomobject]@{}
    foreach ($p in $Base.PSObject.Properties) { $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    foreach ($p in $Over.PSObject.Properties) {
        $v = if ($out.PSObject.Properties[$p.Name]) { Merge-KitObject $out.($p.Name) $p.Value } else { $p.Value }
        $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $v -Force
    }
    $out
}

function Get-KitName {
    if ($script:kitName) { return $script:kitName }
    $dir = $PSScriptRoot
    while ($dir) {
        $marker = Join-Path $dir '.kit'
        if (Test-Path -LiteralPath $marker -PathType Leaf) { $script:kitName = (Get-Content -Raw -LiteralPath $marker).Trim(); return $script:kitName }
        $up = Split-Path -Parent $dir
        if ($up -eq $dir) { break }
        $dir = $up
    }
    Stop-Kit 2 "No .kit file in a folder above $PSScriptRoot. Reinstall the kit."
}

# Windows only for now: Get-KitHome, Get-KitEnv and Set-KitEnv are what a macOS or Linux port changes.
function Get-KitHome { Join-Path $env:LOCALAPPDATA (Get-KitName) }

# Read from the process first, then from the user's own: a program started before the variable was set does not have it.
function Get-KitEnv([string]$Name, [switch]$Saved) {
    if (-not $Name) { return $null }
    if ($Saved) { return [Environment]::GetEnvironmentVariable($Name, 'User') }
    $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'User') }
    $v
}

function Set-KitEnv([string]$Name, [string]$Value) { [Environment]::SetEnvironmentVariable($Name, $Value, 'User') }

function Get-KitConfigVar { ((Get-KitName).ToUpperInvariant() -replace '[^A-Z0-9]', '_') + '_CONFIG' }

function Get-KitConfigPath {
    $override = [Environment]::GetEnvironmentVariable((Get-KitConfigVar), 'Process')
    if ($override) { return $override }
    Join-Path (Get-KitHome) 'config.json'
}

function Read-KitJson([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { Stop-Kit 2 "Missing $File. Run /setup." }
    try { Get-Content -Raw -Encoding utf8 -LiteralPath $File | ConvertFrom-Json } catch { Stop-Kit 2 "$File is not valid JSON. Run /setup." }
}

function Get-KitConfig {
    $user = Read-KitJson (Get-KitConfigPath)
    if (-not $user.PSObject.Properties['kit'] -or -not $user.kit.defaultsFile) { Stop-Kit 2 "$(Get-KitConfigPath) does not name kit.defaultsFile. Run /setup." }
    $cfg = Read-KitJson $user.kit.defaultsFile
    if ($user.kit.PSObject.Properties['packFile'] -and $user.kit.packFile) { $cfg = Merge-KitObject $cfg (Read-KitJson $user.kit.packFile) }
    $cfg = Merge-KitObject $cfg $user
    if ($cfg.version -ne 2) { Stop-Kit 2 "The configuration is version $($cfg.version); these scripts read version 2. Run /setup." }
    $cfg
}

function Get-KitValue($Config, [string]$Name, [switch]$Required, [switch]$Path) {
    $v = $Config
    foreach ($part in $Name -split '\.') {
        if ($null -eq $v -or $v -isnot [Management.Automation.PSCustomObject] -or -not $v.PSObject.Properties[$part]) { $v = $null; break }
        $v = $v.$part
    }
    if ($Required -and ($null -eq $v -or ($v -is [string] -and -not $v))) { Stop-Kit 2 "The configuration has no value for '$Name'. Run /setup." }
    if ($Path -and $v -is [string]) { $v = [Environment]::ExpandEnvironmentVariables($v.Replace('{kitHome}', (Get-KitHome))) }
    $v
}

# A team file (people, notes, a template, a guide): the project pack's copy when it has one, else the kit's.
function Get-KitTeamFile($Config, [string]$Relative) {
    if ($Config.kit.PSObject.Properties['packFile'] -and $Config.kit.packFile) {
        $packed = Join-Path (Split-Path -Parent $Config.kit.packFile) $Relative
        if (Test-Path -LiteralPath $packed -PathType Leaf) { return $packed }
    }
    Join-Path (Split-Path -Parent $Config.kit.defaultsFile) $Relative
}

function Test-KitCapability($Config, [string]$Name) {
    $c = Get-KitValue $Config "capabilities.$Name"
    [bool]($null -ne $c -and $c.provider -and $c.enabled -ne $false)
}
# kit-config:end

$cfg = Get-KitConfig
if (-not $Clone) { $Clone = Get-KitValue $cfg 'paths.specsRepo' -Path }
$ProviderKey = 'providers.git-files'
$SpecBranch = Get-KitValue $cfg "$ProviderKey.branch" -Required
$SpecRoot = ([string](Get-KitValue $cfg "$ProviderKey.root" -Required)).Trim('/')
$CodePattern = [string](Get-KitValue $cfg "$ProviderKey.codePattern" -Required)
$CodeHelp = [string](Get-KitValue $cfg "$ProviderKey.codeHelp")
if (-not $CodeHelp) { $CodeHelp = 'a story code' }
$Upper = @(Get-KitValue $cfg "$ProviderKey.upper" | Where-Object { $_ })
$Pad = Get-KitValue $cfg "$ProviderKey.pad"
$Aliases = Get-KitValue $cfg "$ProviderKey.aliases"
$FolderTemplate = [string](Get-KitValue $cfg "$ProviderKey.folderTemplate" -Required)
$FileTemplate = [string](Get-KitValue $cfg "$ProviderKey.fileTemplate" -Required)
$Kinds = @(Get-KitValue $cfg "$ProviderKey.kinds" | Where-Object { $_ })
$specsEntry = @(Get-KitValue $cfg 'repos') | Where-Object { $_.path -eq 'paths.specsRepo' } | Select-Object -First 1
$Host_ = if ($specsEntry -and $specsEntry.cloneUrl) { ([uri]$specsEntry.cloneUrl).Host } else { 'the specification server' }

if (-not $Clone -or -not (Test-Path -LiteralPath (Join-Path $Clone '.git'))) {
    Stop-Kit 2 "No specification clone (paths.specsRepo is '$Clone'). Set it with /setup, which can also clone it."
}

function Invoke-Git {
    # Windows PowerShell turns git's stderr warnings into terminating errors under Stop.
    $ErrorActionPreference = 'Continue'
    & git -C $Clone @args 2>$null
}

if ($Check) {
    $origin = Invoke-Git remote get-url origin
    if ($Json) { [pscustomobject]@{ clone = $Clone; origin = "$origin"; branch = "$(Invoke-Git branch --show-current)" } | ConvertTo-Json; exit 0 }
    "Specification clone $Clone (origin $origin)"
    exit 0
}

if (-not $Story) { Stop-Kit 1 'Pass a story code, slug or spec link, or -Check.' }
if ($Story -notmatch $CodePattern) { Stop-Kit 1 "Cannot find $CodeHelp in '$Story'." }
$codeMatch = $Matches.Clone()

# Each named part of the code as the templates use it: an alias when one matches (ignoring case),
# else upper-cased when listed in upper; then padded with zeros when listed in pad.
$parts = @{ root = $SpecRoot }
foreach ($name in ([regex]$CodePattern).GetGroupNames() | Where-Object { $_ -notmatch '^\d+$' }) {
    $value = [string]$codeMatch[$name]
    $alias = if ($Aliases -and $Aliases.PSObject.Properties[$name]) { $Aliases.$name.PSObject.Properties | Where-Object { $_.Name -ieq $value } | Select-Object -First 1 } else { $null }
    if ($alias) { $value = [string]$alias.Value }
    elseif ($name -in $Upper) { $value = $value.ToUpper() }
    if ($Pad -and $Pad.PSObject.Properties[$name]) { $value = "{0:D$([int]$Pad.$name)}" -f [int]$value }
    $parts[$name] = $value
}
function Expand-SpecTemplate([string]$Template) {
    [regex]::Replace($Template, '\{(\w+)\}', { param($m) [string]$parts[$m.Groups[1].Value] })
}
$folder = Expand-SpecTemplate $FolderTemplate
$prefix = Expand-SpecTemplate $FileTemplate

$branch = Invoke-Git branch --show-current
$dirty = Invoke-Git status --porcelain
$ref = 'HEAD'
$note = $null

if ($branch -eq $SpecBranch -and -not $dirty) {
    Invoke-Git pull --ff-only --quiet origin $SpecBranch | Out-Null
    if ($LASTEXITCODE -ne 0) { $note = "Could not reach $Host_ (VPN?). Local copy may be out of date." }
}
else {
    Invoke-Git fetch --quiet origin $SpecBranch | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $ref = "origin/$SpecBranch"
        $note = "Clone is on '$branch' or has local changes; not pulled. Read files with: git -C $Clone show origin/${SpecBranch}:<path>"
    }
    else { $note = "Could not reach $Host_ (VPN?) and the clone is not clean $SpecBranch. Local copy may be out of date." }
}

$head = Invoke-Git log -1 --format='%h %cd' --date=short $ref
$files = @(Invoke-Git ls-tree -r --name-only $ref $folder | Where-Object { (Split-Path $_ -Leaf) -like "$prefix*" })

if (-not $files.Count) {
    $msg = "No spec files for $prefix under $folder at $ref ($head)."
    if ($note) { $msg += " $note" }
    Stop-Kit 1 $msg
}

function Format-Path([string] $p) {
    if ($ref -ne 'HEAD') { return "${ref}:$p" }
    (Join-Path $Clone $p) -replace '\\', '/'
}

$listed = @{}
$rows = [Collections.Generic.List[object]]::new()
foreach ($k in $Kinds) {
    $match = [string]$k.match
    $exclude = [string]$k.exclude
    foreach ($h in @($files | Where-Object { $_ -match $match -and (-not $exclude -or $_ -notmatch $exclude) } | Sort-Object)) {
        $rows.Add([pscustomobject]@{ kind = [string]$k.kind; path = (Format-Path $h) })
        $listed[$h] = $true
    }
}
foreach ($f in $files | Where-Object { -not $listed[$_] }) { $rows.Add([pscustomobject]@{ kind = 'other'; path = (Format-Path $f) }) }

if ($Json) {
    [pscustomobject]@{ clone = $Clone; ref = $ref; head = $head; note = $note; files = $rows.ToArray() } | ConvertTo-Json -Depth 4
    exit 0
}
"specifications $ref $head"
foreach ($r in $rows) { '{0,-15} {1}' -f $r.kind, $r.path }
if ($note) { $note }
exit 0
