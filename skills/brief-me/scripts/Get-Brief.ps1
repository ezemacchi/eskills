#Requires -Version 7
<#
.SYNOPSIS
    The person's brief: their saved Jira views and the sections the configuration lists, written with
    the brief template in their language.

.DESCRIPTION
    Sections come from brief.sections, in order. One with "requires" shows only when that configuration
    value is true, and one with "capabilities" only when each of those capabilities is on
    (capabilities.<name> has a provider and is not "enabled": false). Section types:
      attention     what needs the person: tickets the instance testers use already has or still
                    lacks, pull-request problems, services that could not be reached
      changes       tickets that appeared in, left, or changed status in a view since the last brief
      views         one block per saved view (board.views), or only the ids in the section's "views"
      instances     the version each instance runs
      pullRequests  the person's open pull requests: Jenkins, Sonar, review, merge check, behind target
      merged        the person's pull requests merged in the last brief.mergedDays days, and which
                    instances have each
      worktrees     the worktrees of the code clone: target, ahead and behind, pushed, uncommitted

    For an issue whose status is in its view's qaCheckStatuses ("*" for every status), and when the cd
    capability is on, it asks the cd script (ticket -Json) whether delivery.qaEnvironment has the
    change and, if not, from which version it will. When the issue has no commits of its own it checks the issues linked to it with a
    link type in brief.followLinks (the ticket that fixed a reported bug). An answer is remembered while that
    instance runs the same version; a "not yet" for brief.qaCacheMinutes. A view with
    "linkedTests": true also counts each issue's linked tests by status.

    Texts come from the brief template: the team's (kit.templates.brief, in user.language) with the
    person's own (paths.templates.brief) on top, whose texts win.

    Commands:
      brief (default)  prints the brief, and writes brief.md and brief.json to paths.stateDir.
                       -Json prints the JSON instead.
      qa -Key <KEY>    the instance check for one ticket. -Fresh ignores the remembered answer.
      check            reads the configuration and the template and prints what the brief would use
                       (JSON). No network, no writes. Test-Kit.ps1 runs it.

    Writes only to paths.stateDir, plus git fetch in the code clone when a pull-request or worktree
    section is on. The code host's token is read from the variable providers.<repo provider>.tokenVar
    and never printed.

.NOTES
    Exit codes: 0 ok, 1 bad input, 2 missing configuration or credentials, 3 written, but Jira, Jenkins
    or Bitbucket could not be reached (the brief says which).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('brief', 'qa', 'check')]
    [string] $Command = 'brief',
    [string] $Key,
    [switch] $Fresh,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding

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

# The person's roles in order: user.role holds one name, several separated by commas, or a list.
function Get-KitRoles($User) {
    if (-not ($User.PSObject.Properties['user'] -and $User.user -is [Management.Automation.PSCustomObject] -and $User.user.PSObject.Properties['role'])) { return }
    foreach ($entry in @($User.user.role)) {
        foreach ($name in ([string]$entry -split ',')) { $name = $name.Trim(); if ($name -match '^[A-Za-z0-9_-]+$') { $name } }
    }
}

# Several roles as one layer: the first role's value wins, except lists whose items all have an id,
# which add the later roles' items with an id not seen yet.
function Join-KitRole($First, $Next) {
    $out = [pscustomobject]@{}
    foreach ($p in $First.PSObject.Properties) { $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    foreach ($p in $Next.PSObject.Properties) {
        if (-not $out.PSObject.Properties[$p.Name]) { $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value; continue }
        $mine = $out.($p.Name)
        if ($mine -is [Management.Automation.PSCustomObject] -and $p.Value -is [Management.Automation.PSCustomObject]) { $out.($p.Name) = Join-KitRole $mine $p.Value }
        elseif ($mine -is [array] -and $p.Value -is [array] -and -not @(@($mine) + @($p.Value) | Where-Object { $_ -isnot [Management.Automation.PSCustomObject] -or -not $_.PSObject.Properties['id'] }).Count) {
            $seen = @($mine | ForEach-Object { [string]$_.id })
            $out.($p.Name) = @($mine) + @($p.Value | Where-Object { [string]$_.id -notin $seen })
        }
    }
    $out
}

function Get-KitConfig {
    $user = Read-KitJson (Get-KitConfigPath)
    if (-not $user.PSObject.Properties['kit'] -or -not $user.kit.defaultsFile) { Stop-Kit 2 "$(Get-KitConfigPath) does not name kit.defaultsFile. Run /setup." }
    $cfg = Read-KitJson $user.kit.defaultsFile
    if ($user.kit.PSObject.Properties['packFile'] -and $user.kit.packFile) {
        $cfg = Merge-KitObject $cfg (Read-KitJson $user.kit.packFile)
        # The person's roles: the pack's roles\<name>.json for each, read between the pack and the person.
        $roleLayer = $null
        foreach ($role in @(Get-KitRoles $user)) {
            $roleFile = Join-Path (Split-Path -Parent $user.kit.packFile) "roles\$role.json"
            if (-not (Test-Path -LiteralPath $roleFile -PathType Leaf)) { continue }
            $roleLayer = if ($null -eq $roleLayer) { Read-KitJson $roleFile } else { Join-KitRole $roleLayer (Read-KitJson $roleFile) }
        }
        if ($null -ne $roleLayer) { $cfg = Merge-KitObject $cfg $roleLayer }
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

# kit-template:start (identical in every kit script that writes from a template; Test-Kit.ps1 checks it)
function Read-KitSnippets([string]$File) {
    $found = [ordered]@{}
    if (-not $File -or -not (Test-Path -LiteralPath $File -PathType Leaf)) { return $found }
    $current = $null
    $buffer = [Collections.Generic.List[string]]::new()
    foreach ($textLine in Get-Content -Encoding utf8 -LiteralPath $File) {
        if ($textLine -match '^<!--\s*@([A-Za-z0-9_.-]+)\s*-->\s*$') {
            if ($current) { $found[$current] = ($buffer -join "`n").Trim([char[]]"`r`n") }
            $current = $Matches[1]
            $buffer.Clear()
        }
        elseif ($current) { $buffer.Add($textLine) }
    }
    if ($current) { $found[$current] = ($buffer -join "`n").Trim([char[]]"`r`n") }
    $found
}

function Get-KitTemplate($Config, [string]$Name) {
    $pattern = [string](Get-KitValue $Config "kit.templates.$Name" -Required)
    $teamFile = $null
    foreach ($lang in @([string](Get-KitValue $Config 'user.language'), [string](Get-KitValue $Config 'kit.templateFallback')) | Where-Object { $_ }) {
        $candidate = Get-KitTeamFile $Config $pattern.Replace('{language}', $lang)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $teamFile = $candidate; break }
    }
    if (-not $teamFile) { Stop-Kit 2 "The kit's $Name template ($pattern) is missing. Reinstall the kit." }
    $team = Read-KitSnippets $teamFile
    $mineFile = Get-KitValue $Config "paths.templates.$Name" -Path
    $mine = Read-KitSnippets $mineFile
    $merged = [ordered]@{}
    foreach ($n in $team.Keys) { $merged[$n] = $team[$n] }
    foreach ($n in $mine.Keys) { if ($team.Contains($n)) { $merged[$n] = $mine[$n] } }
    [pscustomobject]@{
        name = $Name; team = $teamFile; mine = $(if ($mine.Count) { $mineFile } else { $null }); minePath = $mineFile
        snippets = $merged; unknown = @($mine.Keys | Where-Object { -not $team.Contains($_) })
    }
}

function Format-KitText($Template, [string]$Name, [hashtable]$Values = @{}) {
    if (-not $Template.snippets.Contains($Name)) { Stop-Kit 1 "The $($Template.name) template ($($Template.team)) has no text '@$Name'. Reinstall the kit." }
    $fill = { param($m) $found = $Values[$m.Groups[1].Value]; if ($null -eq $found) { '' } else { [string]$found } }.GetNewClosure()
    [regex]::Replace([string]$Template.snippets[$Name], '\{\{([A-Za-z0-9_]+)\}\}', [Text.RegularExpressions.MatchEvaluator]$fill)
}
# kit-template:end

$cfg = Get-KitConfig
$tpl = Get-KitTemplate $cfg 'brief'
# The services' names ({{board}}, {{repo}}, {{quality}}, {{checks}}) are filled in every text that does
# not set them itself.
$script:serviceNames = @{}
function Phrase([string]$Name, [hashtable]$Values = @{}) {
    foreach ($n in $script:serviceNames.Keys) { if (-not $Values.ContainsKey($n)) { $Values[$n] = $script:serviceNames[$n] } }
    Format-KitText $tpl $Name $Values
}
# kit-texts (names built from data, which Test-Kit.ps1 cannot find as Phrase calls): why.noClone why.unreachable why.noVersion why.versionCommit why.error check.IN check.NOT_IN check.NONE check.UNKNOWN view.unreachable view.badJql changes.status changes.new changes.gone changes.newMany changes.goneMany verdict.green verdict.running verdict.failed verdict.attention verdict.noBuild from.openPr from.mergedPr attention.qaReady attention.qaWaiting attention.qaNone attention.qaUnknown merged.in merged.notIn merged.unknown

$culture = try { [Globalization.CultureInfo]::GetCultureInfo((Phrase 'format.culture')) } catch { [Globalization.CultureInfo]::InvariantCulture }
$boardProvider = [string](Get-KitValue $cfg 'capabilities.board.provider')
$repoProvider = [string](Get-KitValue $cfg 'capabilities.repo.provider')
$cdProvider = [string](Get-KitValue $cfg 'capabilities.cd.provider')
$hasCd = Test-KitCapability $cfg 'cd'
$boardInfo = Get-KitValue $cfg 'providerInfo.board'
if ($null -eq $boardInfo) { Stop-Kit 2 'The configuration does not describe the board provider (providerInfo.board). Run /setup (init).' }
$boardName = if ($boardInfo.displayName) { [string]$boardInfo.displayName } else { $boardProvider }
$boardLink = [string]$boardInfo.link
$keyPattern = if ($boardInfo.keyPattern) { [string]$boardInfo.keyPattern } else { '^\S+$' }
$boardScript = [string](Get-KitValue $cfg 'scripts.board' -Required)
$cdScript = if ($hasCd) { [string](Get-KitValue $cfg 'scripts.cd' -Required) } else { $null }
$hasRepo = Test-KitCapability $cfg 'repo'
$repoInfo = Get-KitValue $cfg 'providerInfo.repo'
$repoName = if ($repoInfo -and $repoInfo.displayName) { [string]$repoInfo.displayName } else { $repoProvider }
$repoScript = if ($hasRepo) { [string](Get-KitValue $cfg 'scripts.repo') } else { $null }
$repoTokenVar = [string](@($repoInfo.credentials | Where-Object { $_ -and $_.secret }) | Select-Object -First 1).variable
$ciInfo = Get-KitValue $cfg 'providerInfo.ci'
$script:serviceNames = @{
    board   = $boardName
    repo    = $repoName
    quality = $(if ($repoInfo -and $repoInfo.names -and $repoInfo.names.quality) { [string]$repoInfo.names.quality } else { 'quality' })
    checks  = $(if ($ciInfo -and $ciInfo.displayName) { [string]$ciInfo.displayName } else { 'CI' })
}
foreach ($kitScript in @($boardScript, $cdScript, $repoScript, $deliveryScript | Where-Object { $_ })) {
    if (-not (Test-Path -LiteralPath $kitScript -PathType Leaf)) { Stop-Kit 2 "Missing kit script $kitScript. Run /setup (init)." }
}
$testType = [string](Get-KitValue $cfg 'board.testIssueType')
$script:instanceList = @()
$qaName = [string](Get-KitValue $cfg 'delivery.qaEnvironment')
$deliveryScript = if ($hasCd) { [string](Get-KitValue $cfg 'scripts.delivery') } else { $null }
$cdInfo = Get-KitValue $cfg 'providerInfo.cd'
$cdName = if ($cdInfo -and $cdInfo.displayName) { [string]$cdInfo.displayName } else { $cdProvider }
$script:serviceNames.cd = $cdName
$qaCacheMinutes = [int](Get-KitValue $cfg 'brief.qaCacheMinutes')
$followLinks = @(Get-KitValue $cfg 'brief.followLinks' | Where-Object { $_ })
$followMax = [int](Get-KitValue $cfg 'brief.followMax')

$stateDir = [string](Get-KitValue $cfg 'paths.stateDir' -Required -Path)
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$statePath = Join-Path $stateDir 'brief-state.json'
$briefState = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $briefState = Get-Content -Raw -Encoding utf8 -LiteralPath $statePath | ConvertFrom-Json -AsHashtable } catch { $briefState = $null }
}
if ($briefState -isnot [Collections.IDictionary]) { $briefState = @{} }
foreach ($part in 'views', 'qa', 'deployed') { if ($briefState[$part] -isnot [Collections.IDictionary]) { $briefState[$part] = @{} } }
foreach ($oldKey in @($briefState.qa.Keys)) {
    $oldAt = $briefState.qa[$oldKey].at
    if (-not $oldAt -or ((Get-Date) - [datetime]$oldAt).TotalDays -gt 30) { $briefState.qa.Remove($oldKey) }
}
# Written beside the file and renamed over it, so a reader or a second run sees the old file or the new
# one, never half of one.
function Save-KitFile([string]$Path, [string]$Text) {
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $Text, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($tmp, $Path, $true)
}
function Save-BriefState { Save-KitFile $statePath ((ConvertTo-Json -InputObject $briefState -Depth 10) + [Environment]::NewLine) }

# --- Running the other kit scripts (their -Json output only) ---------------------------------------

function ConvertTo-KitResult($Lines, [int]$ExitCode) {
    $errText = @($Lines | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' '
    $outText = @($Lines | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n"
    $parsed = $null
    if ($ExitCode -eq 0 -and $outText.Trim()) { try { $parsed = $outText | ConvertFrom-Json -NoEnumerate } catch { $parsed = $null } }
    [pscustomobject]@{ code = $ExitCode; data = $parsed; err = $errText.Trim() }
}

function Invoke-KitScript([string]$Script, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $lines = & pwsh -NoProfile -File $Script @Arguments 2>&1
    ConvertTo-KitResult $lines $LASTEXITCODE
}

# Several calls of one script at once (Jira reads only: they do not share a git clone). Results keep the calls' order.
function Invoke-KitParallel([string]$Script, $Calls) {
    $list = @($Calls)
    if (-not $list.Count) { return }
    $raw = @($list | ForEach-Object -ThrottleLimit 6 -Parallel {
            $ErrorActionPreference = 'Continue'
            $callArgs = [string[]]$_.args
            $lines = & pwsh -NoProfile -File $using:Script @callArgs 2>&1
            [pscustomobject]@{ index = $_.index; code = $LASTEXITCODE; lines = @($lines) }
        })
    $raw | Sort-Object index | ForEach-Object { ConvertTo-KitResult $_.lines $_.code }
}

$problems = [ordered]@{}
function Add-Problem([string]$Service, [string]$Kind) { if (-not $problems.Contains($Service)) { $problems[$Service] = $Kind } }
function Get-BoardProblem($Result) { if ($Result.err -match '(?i)^refused:|refused') { 'refused' } else { 'unreachable' } }
function Get-TicketLink([string]$TicketKey) { if ($boardLink) { $boardLink.Replace('{key}', $TicketKey) } else { $TicketKey } }

# --- Instances and the check for the instance testers use ---------------------------------------------

$script:instanceRows = $null
$script:qaVersion = $null
$script:jenkinsDown = $false
$script:noClone = $false

function Read-Instances {
    $versionsResult = Invoke-KitScript $cdScript @('environments', '-NoCommit', '-Json')
    if ($versionsResult.code -eq 3) { $script:jenkinsDown = $true; Add-Problem $cdName 'unreachable'; return }
    if ($versionsResult.code -ne 0 -or $null -eq $versionsResult.data) { return }
    $script:instanceRows = @($versionsResult.data)
    $script:instanceList = @($script:instanceRows | ForEach-Object { [pscustomobject]@{ name = $_.name; upgrade = $_.upgrade } })
    if (-not $script:qaName -and $script:instanceList.Count) { $script:qaName = [string]$script:instanceList[0].name }
    $qaRow = @($script:instanceRows) | Where-Object { $_.name -eq $qaName } | Select-Object -First 1
    if ($qaRow) { $script:qaVersion = $qaRow.version }
}

$issueCache = @{}
function Get-IssueData([string]$TicketKey) {
    if ($issueCache.ContainsKey($TicketKey)) { return $issueCache[$TicketKey] }
    $issueResult = Invoke-KitScript $boardScript @('issue', '-Key', $TicketKey, '-Json')
    if ($issueResult.code -eq 3) { Add-Problem $boardName (Get-BoardProblem $issueResult) }
    $issueCache[$TicketKey] = $issueResult.data
    $issueResult.data
}

function Get-Links($Issue) { @($Issue.links | Where-Object { $_ -and $_.key }) }

function Get-TestCounts($Issue) {
    $tests = @(Get-Links $Issue | Where-Object { $testType -and $_.kind -eq $testType })
    $byStatus = [ordered]@{}
    foreach ($group in ($tests | Group-Object status | Sort-Object Count -Descending)) { $byStatus[$group.Name] = $group.Count }
    [pscustomobject]@{ total = $tests.Count; byStatus = [pscustomobject]$byStatus }
}

function ConvertTo-VersionKey([string]$Text) {
    $parsedVersion = $null
    if ($Text -and [version]::TryParse(($Text -replace '-.*$', ''), [ref]$parsedVersion)) { return $parsedVersion }
    [version]'0.0'
}

# Who developed it: the newest author on a branch named after the ticket, else on a target branch.
function Get-Developer($Results) {
    foreach ($one in $Results) { foreach ($b in @($one.branches)) { if ($b.author -and $b.author.name) { return $b.author } } }
    foreach ($one in $Results) { foreach ($t in @($one.targets)) { if ($t.author -and $t.author.name) { return $t.author } } }
    $null
}

function Get-QaVerdict([string]$TicketKey) {
    $check = [ordered]@{
        key = $TicketKey; link = (Get-TicketLink $TicketKey); instance = $qaName; version = $script:qaVersion
        verdict = 'UNKNOWN'; why = 'error'; firstVersion = $null; branch = $null; via = @(); alsoIn = @()
        developer = $null; cached = $false; at = (Get-Date).ToString('o')
    }
    if ($script:jenkinsDown) { $check.why = 'unreachable'; return [pscustomobject]$check }
    if ($script:noClone) { $check.why = 'noClone'; return [pscustomobject]$check }
    if (-not $script:qaVersion) { $check.why = 'noVersion'; return [pscustomobject]$check }

    $hit = $briefState.qa[$TicketKey]
    if (-not $Fresh -and $hit -is [Collections.IDictionary] -and $hit.version -eq $script:qaVersion -and $hit.at) {
        $ageMinutes = ((Get-Date) - [datetime]$hit.at).TotalMinutes
        if ($hit.verdict -eq 'IN' -or $ageMinutes -lt $qaCacheMinutes) {
            foreach ($field in @($check.Keys)) { if ($hit.Contains($field)) { $check[$field] = $hit[$field] } }
            $check.via = @($check.via)
            $check.alsoIn = @($check.alsoIn)
            $check.cached = $true
            return [pscustomobject]$check
        }
    }

    $results = [Collections.Generic.List[object]]::new()
    $first = Invoke-KitScript $deliveryScript @('ticket', '-Key', $TicketKey, '-Json')
    if ($first.code -eq 2) { $script:noClone = $true; $check.why = 'noClone'; return [pscustomobject]$check }
    if ($first.code -eq 3) { $script:jenkinsDown = $true; Add-Problem $cdName 'unreachable'; $check.why = 'unreachable'; return [pscustomobject]$check }
    if ($first.code -ne 0 -or $null -eq $first.data) { return [pscustomobject]$check }
    if ($first.data.instances) { $results.Add($first.data) }
    else {
        $issue = Get-IssueData $TicketKey
        $linked = @(if ($issue) {
                Get-Links $issue | Where-Object { $_.type -in $followLinks -and -not ($testType -and $_.kind -eq $testType) } |
                    ForEach-Object { $_.key } | Select-Object -Unique | Select-Object -First $followMax
            })
        foreach ($linkedKey in $linked) {
            $more = Invoke-KitScript $deliveryScript @('ticket', '-Key', $linkedKey, '-Json')
            if ($more.code -eq 3) { $script:jenkinsDown = $true; Add-Problem $cdName 'unreachable'; $check.why = 'unreachable'; return [pscustomobject]$check }
            if ($more.code -eq 0 -and $more.data -and $more.data.instances) { $results.Add($more.data); $check.via += $linkedKey }
        }
    }

    if (-not $results.Count) { $check.verdict = 'NONE'; $check.why = $null }
    else {
        $rows = @(foreach ($one in $results) {
                $inst = @($one.instances) | Where-Object { $_.name -eq $qaName } | Select-Object -First 1
                [pscustomobject]@{ data = $one; inst = $inst }
            })
        $notIn = @($rows | Where-Object { $_.inst -and $_.inst.verdict -eq 'NOT_IN' })
        $unsure = @($rows | Where-Object { -not $_.inst -or $_.inst.verdict -notin 'IN', 'NOT_IN' })
        $pick = if ($notIn.Count) { $notIn | Sort-Object { ConvertTo-VersionKey $_.inst.firstVersion } -Descending | Select-Object -First 1 }
        elseif ($unsure.Count) { $unsure[0] } else { $rows[0] }
        $check.verdict = if ($notIn.Count) { 'NOT_IN' } elseif ($unsure.Count) { 'UNKNOWN' } else { 'IN' }
        $check.why = if ($check.verdict -ne 'UNKNOWN') { $null } elseif ($pick.inst -and $pick.inst.version) { 'versionCommit' } else { 'noVersion' }
        if ($pick.inst) { $check.version = $pick.inst.version; $check.firstVersion = $pick.inst.firstVersion; $check.branch = $pick.inst.branch }
        $check.alsoIn = @(@($rows[0].data.instances) | Where-Object { $_.name -ne $qaName -and $_.verdict -eq 'IN' } | ForEach-Object { $_.name })
        $check.developer = Get-Developer $results
    }
    if ($check.verdict -ne 'UNKNOWN' -or $check.why -eq 'versionCommit') {
        $entry = @{}
        foreach ($name in $check.Keys) { $entry[$name] = $check[$name] }
        $briefState.qa[$TicketKey] = $entry
    }
    [pscustomobject]$check
}

function Get-Arrives($Check) {
    if ($Check.firstVersion) { return Phrase 'arrives.version' @{ firstVersion = $Check.firstVersion } }
    if ($Check.branch) { return Phrase 'arrives.branch' @{ branch = $Check.branch } }
    Phrase 'arrives.unknown'
}

function Get-Via($Check) {
    if ($Check.via) { Phrase 'qa.via' @{ keys = (@($Check.via) -join ', ') } } else { '' }
}

function Get-Why($Check) { Phrase "why.$(if ($Check.why) { $Check.why } else { 'error' })" }

function Format-QaCell($Check) {
    switch ($Check.verdict) {
        'IN' { return Phrase 'qa.IN' @{ version = $Check.version; via = (Get-Via $Check) } }
        'NOT_IN' { return Phrase 'qa.NOT_IN' @{ version = $Check.version; arrives = (Get-Arrives $Check); via = (Get-Via $Check) } }
        'NONE' { return Phrase 'qa.NONE' }
        'SKIPPED' { return Phrase 'qa.skipped' }
    }
    Phrase 'qa.UNKNOWN' @{ why = (Get-Why $Check) }
}

function Format-Tests($Counts) {
    if (-not $Counts.total) { return Phrase 'tests.none' }
    $parts = @($Counts.byStatus.PSObject.Properties | ForEach-Object { Phrase 'tests.status' @{ count = $_.Value; status = $_.Name } })
    Phrase 'tests.counts' @{ total = $Counts.total; byStatus = ($parts -join ', ') }
}

function Format-When($Value) {
    if (-not $Value) { return '' }
    try { ([datetime]$Value).ToString((Phrase 'format.when'), $culture) } catch { [string]$Value }
}

function Format-Day($Value) {
    $day = [datetime]::MinValue
    if ($Value -is [datetime]) { $day = $Value }
    elseif (-not [datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$day)) { return [string]$Value }
    $day.ToString((Phrase 'format.date'), $culture)
}

function Format-Cell($Text) { ([string]$Text -replace '\r?\n', ' ' -replace '\|', '\|').Trim() }

# --- qa: one ticket ----------------------------------------------------------------------------------

if ($Command -eq 'qa') {
    if ($Key -notmatch $keyPattern) { Stop-Kit 1 "-Key is not a $boardName key ($keyPattern), got '$Key'." }
    if (-not $hasCd) { Stop-Kit 2 'The instance check needs the cd capability (environments and versions), which is off. /setup turns it on.' }
    Read-Instances
    $one = Get-QaVerdict $Key
    Save-BriefState
    if ($Json) { $one | ConvertTo-Json -Depth 6 }
    else {
        Phrase "check.$($one.verdict)" @{
            key = $one.key; link = $one.link; instance = $one.instance; version = $one.version
            via = (Get-Via $one); arrives = (Get-Arrives $one); why = $(if ($one.verdict -eq 'UNKNOWN') { Get-Why $one })
        }
    }
    exit $(if ($one.why -eq 'unreachable') { 3 } elseif ($one.why -eq 'noClone') { 2 } else { 0 })
}

# --- brief: which sections ---------------------------------------------------------------------------

$knownTypes = 'attention', 'changes', 'views', 'instances', 'pullRequests', 'merged', 'worktrees'
$sections = @(Get-KitValue $cfg 'brief.sections' | Where-Object { $_ })
if (-not $sections.Count) { Stop-Kit 2 'The configuration has no brief.sections. Run /setup.' }
$active = @($sections | Where-Object {
        $section = $_
        (-not $section.requires -or (Get-KitValue $cfg ([string]$section.requires)) -eq $true) -and
        -not @($section.capabilities | Where-Object { $_ -and -not (Test-KitCapability $cfg $_) }).Count
    })
foreach ($section in $active) {
    if ($section.type -notin $knownTypes) { Stop-Kit 1 "brief.sections has an unknown type '$($section.type)'. Known: $($knownTypes -join ', ')." }
}
$wants = @{}
foreach ($section in $active) { $wants[[string]$section.type] = $true }

# --- Views -------------------------------------------------------------------------------------------

$allViews = @(Get-KitValue $cfg 'board.views' | Where-Object { $_ })
if (-not $allViews.Count) { Stop-Kit 2 'No saved views (board.views). Run /setup, step 6.' }

if ($Command -eq 'check') {
    $tokenVarName = $repoTokenVar
    $needsToken = $wants.pullRequests -or $wants.merged
    [pscustomobject]@{
        sections = @($active | ForEach-Object { [string]$_.type })
        views = @($allViews | ForEach-Object { [string]$_.id })
        qaInstance = $qaName
        qaChecks = @($allViews | Where-Object { $_.qaCheckStatuses } | ForEach-Object { [string]$_.id })
        stateDir = $stateDir
        bitbucketToken = $(if (-not $needsToken) { 'not needed' } elseif ($tokenVarName -and (Get-KitEnv $tokenVarName)) { 'set' } else { 'missing' })
        template = [pscustomobject]@{ team = $tpl.team; mine = $tpl.mine; minePath = $tpl.minePath; unknown = $tpl.unknown }
    } | ConvertTo-Json -Depth 4
    exit 0
}
$calls = [Collections.Generic.List[object]]::new()
for ($n = 0; $n -lt $allViews.Count; $n++) { $calls.Add([pscustomobject]@{ index = $n; args = @('view', '-Id', [string]$allViews[$n].id, '-Json') }) }
$viewResults = @(Invoke-KitParallel $boardScript $calls)

$viewData = [Collections.Generic.List[object]]::new()
for ($n = 0; $n -lt $allViews.Count; $n++) {
    $vdef = $allViews[$n]
    $vres = $viewResults[$n]
    if ($vres.code -eq 2) { Stop-Kit 2 $(if ($vres.err) { $vres.err } else { 'Jira is not set up. Run /setup.' }) }
    $entry = [ordered]@{
        id = [string]$vdef.id; title = [string]$vdef.title
        fields = @(if ($vdef.fields) { $vdef.fields } else { 'summary', 'status' })
        qaCheckStatuses = @($vdef.qaCheckStatuses | Where-Object { $_ }); linkedTests = ($vdef.linkedTests -eq $true)
        ok = $false; problem = $null; more = $false; issues = @()
    }
    if ($vres.code -eq 3) { Add-Problem $boardName (Get-BoardProblem $vres); $entry.problem = 'unreachable' }
    elseif ($vres.code -ne 0 -or $null -eq $vres.data) { $entry.problem = 'badJql' }
    else { $entry.ok = $true; $entry.more = [bool]$vres.data.more; $entry.issues = @($vres.data.issues | Where-Object { $_ }) }
    $viewData.Add([pscustomobject]$entry)
}

$testKeys = @($viewData | Where-Object { $_.ok -and $_.linkedTests } | ForEach-Object { $_.issues } | ForEach-Object { $_.key } | Select-Object -Unique)
if ($testKeys.Count) {
    $calls = [Collections.Generic.List[object]]::new()
    for ($n = 0; $n -lt $testKeys.Count; $n++) { $calls.Add([pscustomobject]@{ index = $n; args = @('issue', '-Key', $testKeys[$n], '-Json') }) }
    $issueResults = @(Invoke-KitParallel $boardScript $calls)
    for ($n = 0; $n -lt $testKeys.Count; $n++) {
        if ($issueResults[$n].code -eq 3) { Add-Problem $boardName (Get-BoardProblem $issueResults[$n]) }
        $issueCache[$testKeys[$n]] = $issueResults[$n].data
    }
}
foreach ($view in $viewData) {
    foreach ($row in $view.issues) {
        $counts = if ($view.linkedTests -and $issueCache[$row.key]) { Get-TestCounts $issueCache[$row.key] } else { $null }
        $row | Add-Member -NotePropertyName tests -NotePropertyValue $counts -Force
    }
}

$needQa = $hasCd -and @($viewData | Where-Object { $_.ok -and @($_.qaCheckStatuses).Count }).Count -gt 0
if ($hasCd -and ($needQa -or $wants.instances -or $wants.merged)) { Read-Instances }
$qaMax = [int](Get-KitValue $cfg 'brief.qaCheckMax')
if ($qaMax -lt 1) { $qaMax = 10 }
$qaDone = [ordered]@{}
$qaSkippedKeys = [ordered]@{}
foreach ($view in $viewData) {
    $statuses = @($view.qaCheckStatuses)
    foreach ($row in $view.issues) {
        $check = $null
        if ($hasCd -and $statuses.Count -and ($statuses -contains '*' -or $statuses -contains $row.status)) {
            if ($qaDone.Contains($row.key)) { $check = $qaDone[$row.key] }
            elseif ($qaDone.Count -ge $qaMax) { $qaSkippedKeys[$row.key] = $true; $check = [pscustomobject]@{ key = $row.key; verdict = 'SKIPPED' } }
            else { $check = Get-QaVerdict $row.key; $qaDone[$row.key] = $check }
        }
        $row | Add-Member -NotePropertyName qa -NotePropertyValue $check -Force
    }
}

# --- Changes since the last brief --------------------------------------------------------------------

$lastBrief = $briefState.lastBrief
$changes = [Collections.Generic.List[object]]::new()
$nextViews = @{}
foreach ($view in $viewData) {
    if (-not $view.ok) { continue }
    $current = [ordered]@{}
    foreach ($row in $view.issues) { $current[$row.key] = $row.status }
    $nextViews[$view.id] = $current
    $before = $briefState.views[$view.id]
    if (-not $lastBrief -or $before -isnot [Collections.IDictionary]) { continue }
    foreach ($row in $view.issues) {
        $was = $before[$row.key]
        $kind = if ($null -eq $was) { 'new' } elseif ($was -ne $row.status) { 'status' } else { $null }
        if (-not $kind) { continue }
        $row | Add-Member -NotePropertyName change -NotePropertyValue $kind -Force
        $changes.Add([pscustomobject]@{ viewId = $view.id; view = $view.title; key = $row.key; link = $row.link; kind = $kind; from = $was; to = $row.status })
    }
    if (-not $view.more) {
        foreach ($goneKey in @($before.Keys)) {
            if (-not $current.Contains($goneKey)) {
                $changes.Add([pscustomobject]@{ viewId = $view.id; view = $view.title; key = $goneKey; link = (Get-TicketLink $goneKey); kind = 'gone'; from = $before[$goneKey]; to = $null })
            }
        }
    }
}

# --- Pull requests, merged pull requests and worktrees (only when a section asks) ---------------------

$repoDir = [string](Get-KitValue $cfg 'paths.codeRepo' -Path)
$hasClone = [bool]($repoDir -and (Test-Path -LiteralPath (Join-Path $repoDir '.git')))
$wantsBitbucket = [bool]($repoScript -and ($wants.pullRequests -or $wants.merged -or $wants.worktrees))
$bbVar = $repoTokenVar
$prState = $null
$openPrs = @()
$mergedPrs = @()
$prItems = @()
$mergedItems = @()
$worktreeItems = @()
$publishBranches = @()
if ($hasCd -and $wants.merged -and -not $script:jenkinsDown) {
    $targetsResult = Invoke-KitScript $cdScript @('targets', '-Json')
    if ($targetsResult.code -eq 3) { $script:jenkinsDown = $true; Add-Problem $cdName 'unreachable' }
    elseif ($targetsResult.code -eq 0 -and $targetsResult.data) { $publishBranches = @($targetsResult.data.branches | Where-Object { $_ }) }
}
$mergedDays = [int](Get-KitValue $cfg 'brief.mergedDays')
if ($mergedDays -lt 1) { $mergedDays = 7 }

function Invoke-RepoGit([string]$Dir, [string[]]$GitArgs) {
    $ErrorActionPreference = 'Continue'
    $gitOut = & git -C $Dir @GitArgs 2>$null
    [pscustomobject]@{ code = $LASTEXITCODE; lines = @($gitOut | ForEach-Object { "$_" }) }
}

function Get-GitCount([string]$Dir, [string]$Range) {
    $counted = Invoke-RepoGit $Dir @('rev-list', '--count', $Range)
    if ($counted.code -ne 0 -or -not $counted.lines.Count) { return $null }
    [int]$counted.lines[0]
}

if ($wantsBitbucket) {
    # After the provider says the service refused or did not answer, the rest of this brief does not ask it.
    $script:repoDown = $false
    function Invoke-Repo([string[]]$Arguments) {
        if ($script:repoDown) { return $null }
        $result = Invoke-KitScript $repoScript $Arguments
        if ($result.code -eq 3) { $script:repoDown = $true; return $null }
        if ($result.code -ne 0) { return $null }
        $result.data
    }

    if ($hasClone) {
        $fetched = Invoke-RepoGit $repoDir @('fetch', 'origin', '--prune', '--quiet')
        if ($fetched.code -ne 0) { Add-Problem $repoName 'unreachable' }
    }

    $openResult = Invoke-KitScript $repoScript @('prs', '-State', 'open', '-Json')
    if ($openResult.code -eq 2) { $prState = 'noToken' }
    elseif ($openResult.code -eq 3 -and (Get-BoardProblem $openResult) -eq 'refused') { $prState = 'refused'; $script:repoDown = $true; Add-Problem $repoName 'refused' }
    elseif ($openResult.code -ne 0) { $prState = 'unreachable'; $script:repoDown = $true; Add-Problem $repoName 'unreachable' }
    else {
        $prState = 'ok'
        $openPrs = @($openResult.data | Where-Object { $_ })
        $mergedPrs = @(Invoke-Repo @('prs', '-State', 'merged', '-Json') | Where-Object { $_ })
    }

    if ($wants.pullRequests -or $wants.worktrees) {
        $prItems = @(foreach ($pr in $openPrs) {
                $sha = [string]$pr.latestCommit
                $proj = [string]$pr.project
                $slug = [string]$pr.repo
                $target = [string]$pr.target
                $source = [string]$pr.source
                $item = [ordered]@{ id = $pr.id; title = $pr.title; link = $pr.link; source = $source; target = $target; repo = $slug; primary = [bool]$pr.primary }
                if ($wants.pullRequests) {
                    $checks = @(Invoke-Repo @('checks', '-Commit', $sha, '-Json') | Where-Object { $_ })
                    $build = $checks | Where-Object { $_.pullRequestBuild } | Select-Object -First 1
                    if (-not $build) { $build = $checks | Select-Object -First 1 }
                    $item.jenkins = if ($build) { [string]$build.state } else { $null }
                    $item.jenkinsUrl = if ($build) { [string]$build.url } else { $null }
                    $item.build = if ($build) { $build.build } else { $null }
                    $report = Invoke-Repo @('quality', '-Commit', $sha, '-Repo', $slug, '-Project', $proj, '-Json')
                    $item.sonar = if ($report) { [string]$report.result } else { $null }
                    $item.sonarUrl = if ($report) { [string]$report.link } else { $null }
                    $item.sonarWhy = if ($report) { @($report.details) -join '; ' } else { $null }
                    $mergeInfo = Invoke-Repo @('mergeable', '-Pr', [string]$pr.id, '-Repo', $slug, '-Project', $proj, '-Json')
                    $item.mergeChecked = [bool]$mergeInfo
                    $item.conflicted = [bool]($mergeInfo -and $mergeInfo.conflicted)
                    $item.vetoes = @(if ($mergeInfo) { $mergeInfo.vetoes })
                    $reviewers = @($pr.reviewers | Where-Object { $_ })
                    $item.reviewers = $reviewers.Count
                    $item.approved = @($reviewers | Where-Object state -eq 'approved').Count
                    $item.needsWork = @($reviewers | Where-Object state -eq 'needsWork' | ForEach-Object { $_.name })
                    $item.behind = $null
                    if ($pr.primary -and $hasClone) {
                        $ancestor = Invoke-RepoGit $repoDir @('merge-base', '--is-ancestor', "origin/$target", "origin/$source")
                        if ($ancestor.code -eq 1) { $item.behind = Get-GitCount $repoDir "origin/$source..origin/$target" }
                    }
                    $item.verdict = if ($item.jenkins -eq 'failed' -or $item.conflicted) { 'failed' }
                    elseif ($item.jenkins -eq 'running') { 'running' }
                    elseif (-not $item.jenkins) { 'noBuild' }
                    elseif ($item.jenkins -eq 'success' -and $item.sonar -ne 'fail' -and -not $item.behind) { 'green' }
                    else { 'attention' }
                }
                [pscustomobject]$item
            })
    }

    if ($wants.merged) {
        $mergedMax = [int](Get-KitValue $cfg 'brief.mergedMax')
        if ($mergedMax -lt 1) { $mergedMax = 10 }
        $cutoff = [DateTimeOffset]::Now.AddDays(-$mergedDays)
        $recent = @($mergedPrs | Where-Object { $_.closedAt -and [DateTimeOffset]::Parse([string]$_.closedAt) -ge $cutoff -and $_.primary -and $_.target -in $publishBranches })
        $script:mergedMore = [Math]::Max(0, $recent.Count - $mergedMax)
        $runningNow = @{}
        foreach ($inst in @($script:instanceRows)) { if ($inst) { $runningNow[$inst.name] = $inst.version } }
        # An instance's answer for a merged pull request changes only when that instance runs another version.
        $mergedItems = @(foreach ($pr in ($recent | Select-Object -First $mergedMax)) {
                $prKey = [string]$pr.id
                $known = $briefState.deployed[$prKey]
                if ($known -isnot [Collections.IDictionary]) { $known = @{} }
                $item = [ordered]@{ id = $pr.id; title = $pr.title; link = $pr.link; target = $pr.target; closed = $pr.closedAt; status = 'ok'; instances = @() }
                $reusable = @(foreach ($def in $instanceList) {
                        $seen = $known[$def.name]
                        if ($seen -is [Collections.IDictionary] -and ($seen.verdict -eq 'IN' -or ($runningNow[$def.name] -and $seen.instanceVersion -eq $runningNow[$def.name]))) {
                            [pscustomobject]@{ name = $def.name; verdict = $seen.verdict; version = $runningNow[$def.name] }
                        }
                    })
                if ($instanceList.Count -and $reusable.Count -eq $instanceList.Count) { $item.instances = $reusable }
                elseif (-not $hasCd) { $item.instances = @() }
                elseif (-not $hasClone) { $item.status = 'noClone' }
                elseif ($script:jenkinsDown) { $item.instances = $reusable }
                else {
                    $deployed = Invoke-KitScript $deliveryScript @('deployed', '-Pr', $prKey, '-Json')
                    if ($deployed.code -eq 3) { $script:jenkinsDown = $true; Add-Problem $cdName 'unreachable'; $item.instances = $reusable }
                    elseif ($deployed.code -eq 0 -and $deployed.data) {
                        if (-not $deployed.data.merged) { $item.status = 'notFound' }
                        else {
                            $item.instances = @($deployed.data.instances | ForEach-Object { [pscustomobject]@{ name = $_.name; verdict = $_.verdict; version = $_.version } })
                            foreach ($inst in $item.instances) {
                                if ($inst.verdict -in 'IN', 'NOT_IN') { $known[$inst.name] = @{ verdict = $inst.verdict; instanceVersion = $inst.version } }
                            }
                            $briefState.deployed[$prKey] = $known
                        }
                    }
                }
                [pscustomobject]$item
            })
        $recentIds = @($recent | ForEach-Object { [string]$_.id })
        foreach ($oldId in @($briefState.deployed.Keys)) { if ($oldId -notin $recentIds) { $briefState.deployed.Remove($oldId) } }
    }
}

if ($wants.worktrees -and $hasClone) {
    $porcelain = (Invoke-RepoGit $repoDir @('worktree', 'list', '--porcelain')).lines
    $trees = [Collections.Generic.List[object]]::new()
    $tree = $null
    foreach ($wl in $porcelain) {
        if ($wl -match '^worktree (.+)$') { $tree = [ordered]@{ path = $Matches[1]; branch = $null }; $trees.Add($tree) }
        elseif ($wl -match '^branch refs/heads/(.+)$' -and $tree) { $tree.branch = $Matches[1] }
    }
    $mainPath = ((Resolve-Path -LiteralPath $repoDir).Path.TrimEnd('\', '/')) -replace '\\', '/'
    $mergedByBranch = @{}
    foreach ($pr in $mergedPrs) { if (-not $mergedByBranch[$pr.source]) { $mergedByBranch[$pr.source] = $pr } }
    $worktreeItems = @(foreach ($w in $trees) {
            if ((($w.path -replace '\\', '/').TrimEnd('/')) -ieq $mainPath) { continue }
            $item = [ordered]@{ name = (Split-Path -Leaf $w.path); path = $w.path; branch = $w.branch; exists = (Test-Path -LiteralPath $w.path) }
            if (-not $item.exists -or -not $w.branch) { [pscustomobject]$item; continue }
            $openPr = $prItems | Where-Object { $_.source -eq $w.branch -and $_.primary } | Select-Object -First 1
            $donePr = $mergedByBranch[$w.branch]
            $item.target = if ($openPr) { $openPr.target } elseif ($donePr) { $donePr.target } else { $null }
            $item.targetFrom = if ($openPr) { 'openPr' } elseif ($donePr) { 'mergedPr' } else { $null }
            $item.prId = if ($openPr) { $openPr.id } elseif ($donePr) { $donePr.id } else { $null }
            if ($item.target) {
                $item.ahead = Get-GitCount $w.path "origin/$($item.target)..HEAD"
                $item.behind = Get-GitCount $w.path "HEAD..origin/$($item.target)"
            }
            $item.hasRemote = (Invoke-RepoGit $w.path @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$($w.branch)")).code -eq 0
            $item.unpushed = if ($item.hasRemote) { Get-GitCount $w.path "origin/$($w.branch)..HEAD" } else { $null }
            $item.dirty = @((Invoke-RepoGit $w.path @('status', '--porcelain')).lines | Where-Object { $_ }).Count
            [pscustomobject]$item
        })
}

# --- What matters ------------------------------------------------------------------------------------

$attention = [Collections.Generic.List[object]]::new()
function Add-Attention([string]$Kind, [string]$Text, [string]$TicketKey = $null) { $attention.Add([pscustomobject]@{ kind = $Kind; key = $TicketKey; text = $Text }) }

foreach ($service in $problems.Keys) {
    if ($problems[$service] -eq 'refused') { Add-Attention 'refused' (Phrase 'attention.refused' @{ service = $service }) }
    else { Add-Attention 'unreachable' (Phrase 'attention.unreachable' @{ service = $service }) }
}
if ($script:noClone) { Add-Attention 'noClone' (Phrase 'attention.noClone') }
if ($wantsBitbucket -and $prState -eq 'noToken') { Add-Attention 'noBitbucketToken' (Phrase 'attention.noBitbucketToken' @{ variable = $bbVar }) }

$qaRows = [ordered]@{}
foreach ($view in $viewData) { foreach ($row in $view.issues) { if ($row.qa -and $row.qa.verdict -ne 'SKIPPED' -and -not $qaRows.Contains($row.key)) { $qaRows[$row.key] = $row } } }
foreach ($verdict in 'IN', 'NOT_IN', 'NONE', 'UNKNOWN') {
    foreach ($row in @($qaRows.Values | Where-Object { $_.qa.verdict -eq $verdict })) {
        if ($verdict -eq 'UNKNOWN' -and $row.qa.why -in 'unreachable', 'noClone') { continue }
        $values = @{
            key = $row.key; link = $row.link; summary = $row.summary; status = $row.status; instance = $row.qa.instance
            version = $row.qa.version; arrives = (Get-Arrives $row.qa); why = $(if ($verdict -eq 'UNKNOWN') { Get-Why $row.qa })
        }
        $name = @{ IN = 'attention.qaReady'; NOT_IN = 'attention.qaWaiting'; NONE = 'attention.qaNone'; UNKNOWN = 'attention.qaUnknown' }[$verdict]
        Add-Attention "qa-$verdict" (Phrase $name $values) $row.key
    }
}
if ($qaSkippedKeys.Count) { Add-Attention 'qaSkipped' (Phrase 'attention.qaSkipped' @{ max = $qaMax; count = $qaSkippedKeys.Count; instance = $qaName }) }
if ($changes.Count) { Add-Attention 'changes' (Phrase 'attention.changes' @{ count = $changes.Count }) }
foreach ($pr in $prItems) {
    if (-not $pr.PSObject.Properties['verdict']) { continue }
    $values = @{ id = $pr.id; title = $pr.title; target = $pr.target; why = $pr.sonarWhy; behind = $pr.behind }
    if ($pr.jenkins -eq 'failed') { Add-Attention 'prFailed' (Phrase 'attention.prFailed' $values) }
    if ($pr.conflicted) { Add-Attention 'prConflict' (Phrase 'attention.prConflict' $values) }
    if ($pr.sonar -eq 'fail') { Add-Attention 'prSonar' (Phrase 'attention.prSonar' $values) }
    if ($pr.behind) { Add-Attention 'prStale' (Phrase 'attention.prStale' $values) }
    if (@($pr.needsWork).Count) { Add-Attention 'prNeedsWork' (Phrase 'attention.prNeedsWork' $values) }
}
foreach ($w in $worktreeItems) { if ($w.unpushed) { Add-Attention 'unpushed' (Phrase 'attention.unpushed' @{ name = $w.name; count = $w.unpushed }) } }

# --- Writing the sections ----------------------------------------------------------------------------

function Format-ViewBody($View) {
    if (-not $View.ok) { return Phrase "view.$($View.problem)" @{ board = $boardName } }
    if (-not @($View.issues).Count) { return Phrase 'view.empty' }
    $showQa = @($View.qaCheckStatuses).Count -gt 0
    $heads = @(Phrase 'column.key')
    foreach ($field in $View.fields) { $heads += $(if ($tpl.snippets.Contains("field.$field")) { Phrase "field.$field" } else { $field }) }
    if ($showQa) { $heads += Phrase 'column.qa' @{ instance = $qaName } }
    if ($View.linkedTests) { $heads += Phrase 'column.tests' }
    $tableLines = [Collections.Generic.List[string]]::new()
    $tableLines.Add('| ' + (($heads | ForEach-Object { Format-Cell $_ }) -join ' | ') + ' |')
    $tableLines.Add('|' + (@($heads | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($row in $View.issues) {
        $cells = @("[$($row.key)]($($row.link))")
        foreach ($field in $View.fields) {
            $value = $row.$field
            $cells += $(if ($field -in 'updated', 'created') { Format-Day $value } else { Format-Cell $value })
        }
        if ($showQa) { $cells += $(if ($row.qa) { Format-Cell (Format-QaCell $row.qa) } else { Format-Cell (Phrase 'qa.notAsked') }) }
        if ($View.linkedTests) { $cells += $(if ($row.tests) { Format-Cell (Format-Tests $row.tests) } else { '' }) }
        $tableLines.Add('| ' + ($cells -join ' | ') + ' |')
    }
    if ($View.more) { $tableLines.Add(''); $tableLines.Add((Phrase 'view.more' @{ count = @($View.issues).Count; board = $boardName })) }
    $tableLines -join "`n"
}

function Format-ChangesBody {
    if (-not $lastBrief) { return Phrase 'changes.first' }
    $changeLines = [Collections.Generic.List[string]]::new()
    $changeLines.Add((Phrase 'changes.since' @{ when = (Format-When $lastBrief) }))
    if (-not $changes.Count) { $changeLines.Add((Phrase 'changes.none')); return $changeLines -join "`n" }
    foreach ($group in ($changes | Group-Object viewId)) {
        $viewTitle = $group.Group[0].view
        foreach ($kind in 'status', 'new', 'gone') {
            $some = @($group.Group | Where-Object kind -eq $kind)
            if (-not $some.Count) { continue }
            if ($kind -ne 'status' -and $some.Count -gt 3) {
                $changeLines.Add((Phrase "changes.$($kind)Many" @{ count = $some.Count; view = $viewTitle; keys = (($some | ForEach-Object { $_.key }) -join ', ') }))
                continue
            }
            foreach ($c in $some) {
                $changeLines.Add((Phrase "changes.$kind" @{ key = $c.key; link = $c.link; view = $viewTitle; status = $(if ($kind -eq 'gone') { $c.from } else { $c.to }); from = $c.from; to = $c.to }))
            }
        }
    }
    $changeLines -join "`n"
}

# Where an environment's version came from (the cd contract's source: kind, ref, at).
function Format-Source($Source) {
    if (-not $Source) { return '' }
    if ($Source.kind -eq 'deploy-log') {
        $runWhen = if ($Source.at) { [DateTimeOffset]::Parse([string]$Source.at).LocalDateTime.ToString((Phrase 'format.dateTime'), $culture) } else { '' }
        return Phrase 'source.publisher' @{ build = $Source.ref; when = $runWhen }
    }
    if ($Source.kind -eq 'live') { return Phrase 'source.live' }
    [string]$Source.ref
}

function Format-InstancesBody {
    if ($null -eq $script:instanceRows) { return Phrase 'instances.unreachable' }
    $instLines = foreach ($inst in $script:instanceRows) {
        if (-not $inst.version) { Phrase 'instances.unknown' @{ name = $inst.name }; continue }
        $def = $instanceList | Where-Object { $_.name -eq $inst.name } | Select-Object -First 1
        $upgrade = if ($def -and $def.upgrade -and $tpl.snippets.Contains("instances.upgrade.$($def.upgrade)")) { Phrase "instances.upgrade.$($def.upgrade)" } else { '' }
        Phrase 'instances.line' @{
            name = $inst.name; version = $inst.version; source = (Format-Source $inst.source); upgrade = $upgrade
            qa = $(if ($inst.name -eq $qaName) { Phrase 'instances.qa' } else { '' })
        }
    }
    @($instLines) -join "`n"
}

function Get-BitbucketProblemLine {
    switch ($prState) {
        'noToken' { return Phrase 'pr.noToken' @{ variable = $bbVar } }
        'refused' { return Phrase 'pr.refused' @{ variable = $bbVar } }
        'unreachable' { return Phrase 'pr.unreachable' }
    }
    $null
}

function Format-PullRequestsBody {
    $problemLine = Get-BitbucketProblemLine
    if ($problemLine) { return $problemLine }
    if (-not $prItems.Count) { return Phrase 'pr.none' }
    $blocks = foreach ($pr in $prItems) {
        $prLines = [Collections.Generic.List[string]]::new()
        $prLines.Add((Phrase 'pr.head' @{
                    id = $pr.id; link = $pr.link; title = $pr.title; target = $pr.target; verdict = (Phrase "verdict.$($pr.verdict)")
                    repo = $(if (-not $pr.primary) { Phrase 'pr.repo' @{ repo = $pr.repo } } else { '' })
                }))
        $state = switch ($pr.jenkins) { 'success' { Phrase 'jenkins.ok' } 'failed' { Phrase 'jenkins.failed' } 'running' { Phrase 'jenkins.running' } $null { Phrase 'jenkins.none' } default { Phrase 'jenkins.other' @{ state = $pr.jenkins } } }
        $prLines.Add((Phrase 'pr.jenkins' @{
                    state = $state; build = $(if ($pr.build) { Phrase 'jenkins.build' @{ n = $pr.build } } else { '' })
                    link = $(if ($pr.jenkinsUrl) { Phrase 'jenkins.link' @{ url = $pr.jenkinsUrl } } else { '' })
                }))
        $sonarText = switch ($pr.sonar) {
            'pass' { Phrase 'sonar.pass' }
            'fail' { Phrase 'sonar.fail' @{ why = $pr.sonarWhy } }
            $null { $(if ($pr.jenkins -eq 'running') { Phrase 'sonar.pending' } else { Phrase 'sonar.none' }) }
            default { [string]$pr.sonar }
        }
        $prLines.Add((Phrase 'pr.sonar' @{ text = $sonarText; link = $(if ($pr.sonarUrl) { Phrase 'sonar.link' @{ url = $pr.sonarUrl } } else { '' }) }))
        $reviewText = if (-not $pr.reviewers) { Phrase 'review.none' } else { Phrase 'review.count' @{ approved = $pr.approved; total = $pr.reviewers } }
        if (@($pr.needsWork).Count) { $reviewText += Phrase 'review.needsWork' @{ who = (@($pr.needsWork) -join ', ') } }
        $prLines.Add((Phrase 'pr.review' @{ text = $reviewText }))
        $mergeText = if (-not $pr.mergeChecked) { Phrase 'merge.unknown' } elseif ($pr.conflicted) { Phrase 'merge.conflict' @{ target = $pr.target } } elseif (@($pr.vetoes).Count) { Phrase 'merge.vetoed' @{ why = (@($pr.vetoes) -join '; ') } } else { Phrase 'merge.ok' }
        $prLines.Add((Phrase 'pr.merge' @{ text = $mergeText }))
        if ($pr.primary -and $hasClone) {
            $branchText = if ($pr.behind) { Phrase 'branch.behind' @{ behind = $pr.behind; target = $pr.target } } else { Phrase 'branch.upToDate' @{ target = $pr.target } }
            $prLines.Add((Phrase 'pr.branch' @{ text = $branchText }))
        }
        $prLines -join "`n"
    }
    @($blocks) -join "`n`n"
}

function Format-MergedBody {
    $problemLine = Get-BitbucketProblemLine
    if ($problemLine) { return $problemLine }
    if (-not $mergedItems.Count) { return Phrase 'merged.none' @{ branches = ($publishBranches -join ', '); days = $mergedDays } }
    $mergedLines = foreach ($m in $mergedItems) {
        if ($m.status -eq 'notFound') { Phrase 'merged.notFound' @{ id = $m.id; link = $m.link; title = $m.title }; continue }
        if ($m.status -eq 'noClone') { Phrase 'merged.noClone'; continue }
        $where = @(foreach ($inst in $m.instances) {
                $which = if ($inst.verdict -eq 'IN') { 'merged.in' } elseif ($inst.verdict -eq 'NOT_IN') { 'merged.notIn' } else { 'merged.unknown' }
                Phrase $which @{ name = $inst.name }
            }) -join ', '
        Phrase 'merged.line' @{
            id = $m.id; link = $m.link; title = $m.title; target = $m.target; instances = $where
            when = ([DateTimeOffset]::Parse([string]$m.closed).LocalDateTime.ToString((Phrase 'format.date'), $culture))
        }
    }
    $mergedLines = @($mergedLines | Select-Object -Unique)
    if ($script:mergedMore) { $mergedLines += Phrase 'merged.more' @{ count = $script:mergedMore } }
    $mergedLines -join "`n"
}

function Format-WorktreesBody {
    if (-not $hasClone) { return Phrase 'worktree.noClone' }
    if (-not $worktreeItems.Count) { return Phrase 'worktree.none' }
    $treeLines = foreach ($w in $worktreeItems) {
        if (-not $w.exists) { Phrase 'worktree.missing' @{ name = $w.name }; continue }
        if (-not $w.branch) { Phrase 'worktree.detached' @{ name = $w.name }; continue }
        $parts = [Collections.Generic.List[string]]::new()
        if ($w.target) {
            $parts.Add((Phrase 'worktree.target' @{ target = $w.target; from = (Phrase "from.$($w.targetFrom)" @{ id = $w.prId }) }))
            if ($null -ne $w.ahead) { $parts.Add((Phrase 'worktree.ahead' @{ count = $w.ahead })) }
            $parts.Add($(if ($w.behind) { Phrase 'worktree.behind' @{ count = $w.behind; target = $w.target } } else { Phrase 'worktree.upToDate' @{ target = $w.target } }))
        }
        else { $parts.Add((Phrase 'worktree.noTarget')) }
        if ($w.hasRemote) { $parts.Add($(if ($w.unpushed) { Phrase 'worktree.unpushed' @{ count = $w.unpushed } } else { Phrase 'worktree.pushed' })) }
        else { $parts.Add((Phrase 'worktree.neverPushed')) }
        $parts.Add($(if ($w.dirty) { Phrase 'worktree.dirty' @{ count = $w.dirty } } else { Phrase 'worktree.clean' }))
        Phrase 'worktree.line' @{ name = $w.name; branch = $w.branch; parts = ($parts -join ' · ') }
    }
    @($treeLines) -join "`n"
}

$rendered = [Collections.Generic.List[string]]::new()
foreach ($section in $active) {
    switch ([string]$section.type) {
        'attention' {
            $body = if ($attention.Count) { @($attention | ForEach-Object { Phrase 'attention.item' @{ text = $_.text } }) -join "`n" } else { Phrase 'attention.none' }
            $rendered.Add((Phrase 'section' @{ title = (Phrase 'title.attention'); body = $body }))
        }
        'changes' { $rendered.Add((Phrase 'section' @{ title = (Phrase 'title.changes'); body = (Format-ChangesBody) })) }
        'views' {
            $only = @($section.views | Where-Object { $_ })
            foreach ($view in $viewData) {
                if ($only.Count -and $view.id -notin $only) { continue }
                $rendered.Add((Phrase 'section' @{ title = $view.title; body = (Format-ViewBody $view) }))
            }
        }
        'instances' { $rendered.Add((Phrase 'section' @{ title = (Phrase 'title.instances'); body = (Format-InstancesBody) })) }
        'pullRequests' { $rendered.Add((Phrase 'section' @{ title = (Phrase 'title.pullRequests'); body = (Format-PullRequestsBody) })) }
        'merged' { $rendered.Add((Phrase 'section' @{ title = (Phrase 'title.merged' @{ days = $mergedDays }); body = (Format-MergedBody) })) }
        'worktrees' { $rendered.Add((Phrase 'section' @{ title = (Phrase 'title.worktrees'); body = (Format-WorktreesBody) })) }
    }
}

$now = Get-Date
$markdown = Phrase 'brief' @{
    user = [string](Get-KitValue $cfg 'user.name'); date = (Format-When $now)
    sections = ($rendered -join "`n`n")
}
$markdown = ($markdown -replace '(\r?\n){3,}', "`n`n").Trim() + "`n"

$mdPath = Join-Path $stateDir 'brief.md'
$jsonPath = Join-Path $stateDir 'brief.json'
$brief = [ordered]@{
    generated = $now.ToString('o'); previous = $lastBrief; language = [string](Get-KitValue $cfg 'user.language')
    user = [string](Get-KitValue $cfg 'user.name')
    qaInstance = [pscustomobject]@{ name = $qaName; version = $script:qaVersion }
    problems = @($problems.Keys | ForEach-Object { [pscustomobject]@{ service = $_; kind = $problems[$_] } })
    attention = @($attention)
    changes = @($changes)
    views = @($viewData)
    instances = @(if ($script:instanceRows) {
            $script:instanceRows | ForEach-Object {
                $inst = $_
                $def = $instanceList | Where-Object { $_.name -eq $inst.name } | Select-Object -First 1
                [pscustomobject]@{ name = $inst.name; version = $inst.version; source = $inst.source; upgrade = $(if ($def) { $def.upgrade }); usedByQa = ($inst.name -eq $qaName) }
            }
        })
    pullRequests = $(if ($wants.pullRequests) { @($prItems) } else { $null })
    merged = $(if ($wants.merged) { @($mergedItems) } else { $null })
    worktrees = $(if ($wants.worktrees) { @($worktreeItems) } else { $null })
    bitbucket = $prState
    template = [pscustomobject]@{ team = $tpl.team; mine = $tpl.mine; minePath = $tpl.minePath; unknown = $tpl.unknown }
    files = [pscustomobject]@{ markdown = $mdPath; json = $jsonPath }
}
$briefJson = ConvertTo-Json -InputObject ([pscustomobject]$brief) -Depth 12
Save-KitFile $mdPath $markdown
Save-KitFile $jsonPath ($briefJson + [Environment]::NewLine)

if (-not $problems.Contains($boardName)) {
    foreach ($viewId in $nextViews.Keys) { $briefState.views[$viewId] = $nextViews[$viewId] }
    $briefState.lastBrief = $now.ToString('o')
}
Save-BriefState

if ($Json) { $briefJson } else { $markdown }
exit $(if ($problems.Count) { 3 } else { 0 })
