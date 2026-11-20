<#
.SYNOPSIS
    Builds a Microsoft Teams link that opens a 1:1 chat with the message already in the compose box,
    and opens it or copies it. Nothing is ever sent: the user presses Send in Teams.

.DESCRIPTION
    The chat capability for Microsoft Teams. The tenant and the chat address come from the kit
    configuration (providers.teams.*). People come from the team's file (kit.teamPeople, from the
    project pack) and the user's own additions (paths.myPeople), which win for the same alias. -To
    takes an alias from those tables or an e-mail address. -Json prints the chat contract's shape
    (docs/contracts/chat.md in the kit); prefilled is always true, because a Teams link carries the
    message into the compose box.

    Commands:
      link (default)   -To <alias|email> -Message <text> | -MessageFile <path>
                       [-Open] opens the chat in Teams, [-Copy] puts the link on the clipboard.
                       With neither, prints the link (for scripts; a terminal breaks a long one).
      people           the people file's table: alias, email, language, what they are asked about

.EXAMPLE
    New-TeamsMessageLink.ps1 -To dana -MessageFile $env:TEMP\msg-dana.txt -Open

.NOTES
    Exit codes: 0 ok, 1 bad input (unknown person, empty message, the user himself), 2 missing configuration.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('link', 'people')]
    [string] $Command = 'link',
    [string] $To,
    [string] $Message,
    [string] $MessageFile,
    [switch] $Open,
    [switch] $Copy,
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
    if ($user.kit.PSObject.Properties['packFile'] -and $user.kit.packFile) {
        $cfg = Merge-KitObject $cfg (Read-KitJson $user.kit.packFile)
        # The person's role: the pack's roles\<user.role>.json, read between the pack and the person.
        $role = if ($user.PSObject.Properties['user'] -and $user.user -is [Management.Automation.PSCustomObject] -and $user.user.PSObject.Properties['role']) { [string]$user.user.role } else { '' }
        $roleFile = if ($role -match '^[A-Za-z0-9_-]+$') { Join-Path (Split-Path -Parent $user.kit.packFile) "roles\$role.json" } else { '' }
        if ($roleFile -and (Test-Path -LiteralPath $roleFile -PathType Leaf)) { $cfg = Merge-KitObject $cfg (Read-KitJson $roleFile) }
    }
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
$TenantId = Get-KitValue $cfg 'providers.teams.tenantId' -Required
$ChatUrl = ([string](Get-KitValue $cfg 'providers.teams.chatUrl' -Required)).TrimEnd('/')
$MaxLength = [int](Get-KitValue $cfg 'providers.teams.maxLinkLength')
$TeamPeople = Get-KitTeamFile $cfg (Get-KitValue $cfg 'kit.teamPeople' -Required)
$MyPeople = Get-KitValue $cfg 'paths.myPeople' -Path
$Self = [string](Get-KitValue $cfg 'user.email')
if (-not (Test-Path -LiteralPath $TeamPeople)) { Stop-Kit 2 "The kit's people file is missing: $TeamPeople. Reinstall the kit." }

# Each file's table: | `alias` | email | language | asked about |. The user's own file wins for the same alias.
$byAlias = [ordered]@{}
foreach ($source in @(@('team', $TeamPeople), @('mine', $MyPeople))) {
    if (-not $source[1] -or -not (Test-Path -LiteralPath $source[1])) { continue }
    foreach ($row in Get-Content -Encoding utf8 -LiteralPath $source[1]) {
        if ($row -match '^\|\s*`([^`]+)`\s*\|\s*([^|\s]+@[^|\s]+)\s*\|\s*([^|]*)\|\s*([^|]*)\|') {
            $byAlias[$Matches[1].ToLower()] = [pscustomobject]@{
                alias = $Matches[1].ToLower(); email = $Matches[2]; language = $Matches[3].Trim(); askedAbout = $Matches[4].Trim()
                you = [bool]($Self -and $Matches[2] -ieq $Self); source = $source[0]
            }
        }
    }
}
$people = @($byAlias.Values)

if ($Command -eq 'people') {
    if ($Json) { ConvertTo-Json -InputObject ([pscustomobject]@{ teamFile = $TeamPeople; myFile = $MyPeople; people = $people }) -Depth 3; exit 0 }
    foreach ($p in $people) { "{0,-10} {1,-40} {2,-8} {3}{4}" -f $p.alias, $p.email, $p.language, $p.askedAbout, $(if ($p.you) { '  (you)' } elseif ($p.source -eq 'mine') { '  (your file)' } else { '' }) }
    "Profiles: $TeamPeople"
    if ($MyPeople -and (Test-Path -LiteralPath $MyPeople)) { "Your additions: $MyPeople" }
    exit 0
}

if (-not $To) { Stop-Kit 1 'link needs -To <alias or e-mail>.' }
$match = $people | Where-Object { $_.alias -eq $To.ToLower() } | Select-Object -First 1
$email = if ($match) { $match.email } else { $To }
if ($email -notmatch '^[^@\s]+@[^@\s]+$') { Stop-Kit 1 "'$To' is not an e-mail address or a known alias ($(@($people | ForEach-Object { $_.alias }) -join ', '))." }
if ($Self -and $email -ieq $Self) { Stop-Kit 1 "'$To' is you ($Self); a chat with yourself is not a message to anyone." }

if ([bool]$Message -eq [bool]$MessageFile) { Stop-Kit 1 'Pass exactly one of -Message or -MessageFile.' }
if ($MessageFile) {
    if (-not (Test-Path -LiteralPath $MessageFile -PathType Leaf)) { Stop-Kit 1 "No such file: $MessageFile" }
    $Message = Get-Content -Raw -Encoding utf8 -LiteralPath $MessageFile
}
$Message = ([string]$Message).Replace("`r`n", "`n").Trim()
if (-not $Message) { Stop-Kit 1 'The message is empty.' }

$url = '{0}?tenantId={1}&users={2}&message={3}' -f $ChatUrl, $TenantId, [uri]::EscapeDataString($email), [uri]::EscapeDataString($Message)
$warning = if ($MaxLength -and $url.Length -gt $MaxLength) { "The link is $($url.Length) characters; Teams may cut it. Shorten the message." } else { $null }

$opened = $false
$copied = $false
if ($Open) { Start-Process $url; $opened = $true }
if ($Copy) { Set-Clipboard -Value $url; $copied = $true }

$name = if ($match) { $match.alias } else { $email }
if ($Json) {
    [pscustomobject]@{ to = $name; email = $email; prefilled = $true; opened = $opened; copied = $copied; length = $url.Length; warning = $warning; url = $url } | ConvertTo-Json
    exit 0
}
if ($warning) { [Console]::Error.WriteLine($warning) }
if ($opened) { "Opened a Teams chat with $name ($email); the message is in the compose box. Nothing was sent." }
if ($copied) { "Copied the link for a chat with $name ($email) to the clipboard ($($url.Length) characters)." }
if (-not $opened -and -not $copied) { $url }
exit 0
