<#
.SYNOPSIS
    The ci capability for Jenkins: read-only questions about builds (providers.jenkins.*).

.DESCRIPTION
    Commands:
      status   -Pr <n> | -Branch <name> | -Job <named job>   result, commit, failed or running stages, link
      stages   -Pr <n> | -Branch <name> | -Job <named job>   every stage with its duration
      tail     -Pr <n> | -Branch <name> | -Job <named job>   end of the console log (-Lines)
      find     -Branch <name>      which pull-request jobs built that branch
      ping                         is Jenkins reachable

    Pull-request and branch builds are children of providers.jenkins.multibranch; named jobs (a
    release job, for example) are providers.jenkins.jobs, name -> address. status, find and ping take
    -Json (the ci contract's shape, docs/contracts/ci.md in the kit): other skills read that, never the
    text. -Branch matches a pull-request job by its branch, else by the branch's commit in the code
    clone (paths.codeRepo, or -Repo), because jobs built in merge mode report origin/PR-<n>.

.NOTES
    Exit codes: 0 ok, 1 not found or bad input, 2 missing configuration, 3 Jenkins unreachable
    ("unreachable:", probably off the VPN). Never triggers, rebuilds, or aborts anything.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('status', 'stages', 'tail', 'find', 'ping')]
    [string] $Command,
    [int] $Pr,
    [string] $Branch,
    [string] $Job,
    [int] $Build,
    [int] $Lines = 80,
    [string] $Repo,
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
$Root = ([string](Get-KitValue $cfg 'providers.jenkins.root' -Required)).TrimEnd('/')
$Multi = ([string](Get-KitValue $cfg 'providers.jenkins.multibranch' -Required)).TrimEnd('/')
$BluePipeline = Get-KitValue $cfg 'providers.jenkins.blueOceanPipeline'
$VersionParameter = [string](Get-KitValue $cfg 'providers.jenkins.versionParameter')
$QuickFailureHint = [string](Get-KitValue $cfg 'providers.jenkins.quickFailureHint')
$Jobs = [ordered]@{}
$configuredJobs = Get-KitValue $cfg 'providers.jenkins.jobs'
if ($configuredJobs) { foreach ($p in $configuredJobs.PSObject.Properties) { $Jobs[$p.Name] = [string]$p.Value } }
if (-not $Repo) { $Repo = Get-KitValue $cfg 'paths.codeRepo' -Path }
if ($Job -and -not $Jobs.Contains($Job)) { Stop-Kit 1 "Unknown -Job '$Job'. The configuration has: $(@($Jobs.Keys) -join ', ')." }

function Invoke-Jenkins([string] $Url, [switch] $Raw) {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        $code = curl.exe --globoff -sS -A 'Mozilla/5.0' --max-time 30 -o $tmp -w '%{http_code}' $Url 2>$null
        if (-not $code -or $code -eq '000') { Stop-Kit 3 "unreachable: Jenkins does not answer ($Root). You are probably not on the VPN." }
        if ($code -eq '404') { return $null }
        if ($code -ne '200') { Stop-Kit 1 "HTTP $code from $Url" }
        $body = [IO.File]::ReadAllText($tmp)
        if ($Raw) { return $body }
        return $body | ConvertFrom-Json
    }
    finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

function Invoke-Git {
    # Windows PowerShell turns git's stderr warnings into terminating errors under Stop.
    $ErrorActionPreference = 'Continue'
    & git -C $Repo @args 2>$null
}

function Format-When($Ms) {
    if (-not $Ms) { return $null }
    [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Ms).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
}

function Get-Revision($BuildJson) {
    $rev = $BuildJson.actions | Where-Object { $_.lastBuiltRevision } | Select-Object -First 1
    if ($rev) { return $rev.lastBuiltRevision }
    $null
}

# A named job's runs may carry their version in the display name, "<build>_<version>".
function Get-DisplayVersion([string] $Name) {
    if ($Name -match '^\d+_(.+)$') { return $Matches[1] }
    $null
}

function Get-PrJobs {
    $tree = 'jobs[name,color,displayName,lastBuild[number,result,building,actions[lastBuiltRevision[SHA1,branch[name]]]]]'
    $all = Invoke-Jenkins "$Multi/api/json?tree=$tree"
    foreach ($j in $all.jobs) {
        $rev = Get-Revision $j.lastBuild
        [pscustomobject]@{
            Name   = $j.name
            Title  = $j.displayName
            Color  = $j.color
            Result = $j.lastBuild.result
            Branch = if ($rev) { ($rev.branch | Select-Object -First 1).name -replace '^origin/', '' } else { $null }
            Sha    = if ($rev) { $rev.SHA1 } else { $null }
        }
    }
}

function Find-JobsForBranch([string] $Name) {
    $jobList = @(Get-PrJobs | Where-Object { $_.Name -like 'PR-*' })
    $hits = @($jobList | Where-Object { $_.Branch -eq $Name })
    if ($hits.Count -eq 0 -and $Repo -and (Test-Path -LiteralPath (Join-Path $Repo '.git'))) {
        # PR jobs built in merge mode report their branch as origin/PR-<n>; match on the commit instead.
        $sha = Invoke-Git rev-parse --verify --quiet "origin/$Name"
        if ($sha) { $hits = @($jobList | Where-Object { $_.Sha -eq $sha }) }
    }
    $hits
}

function Resolve-Target {
    if ($Job) { return [pscustomobject]@{ Url = $Jobs[$Job].TrimEnd('/'); Child = $null; Label = $Job } }
    if ($Pr) { return [pscustomobject]@{ Url = "$Multi/job/PR-$Pr"; Child = "PR-$Pr"; Label = "PR-$Pr" } }
    if ($Branch) {
        $hits = @(Find-JobsForBranch $Branch)
        $open = @($hits | Where-Object { $_.Color -ne 'disabled' })
        $pick = if ($open.Count) { $open[-1] } elseif ($hits.Count) { $hits[-1] } else { $null }
        if ($pick) { return [pscustomobject]@{ Url = "$Multi/job/$($pick.Name)"; Child = $pick.Name; Label = "$($pick.Name) ($Branch)" } }
        $enc = [uri]::EscapeDataString([uri]::EscapeDataString($Branch))
        return [pscustomobject]@{ Url = "$Multi/job/$enc"; Child = $Branch; Label = "branch job $Branch (no PR job found)" }
    }
    Stop-Kit 1 "Pass -Pr <n>, -Branch <name>, or -Job $(@($Jobs.Keys) -join '|')."
}

function Get-BuildUrl($Target) {
    if ($Build) { return "$($Target.Url)/$Build" }
    $last = Invoke-Jenkins "$($Target.Url)/api/json?tree=lastBuild[number]"
    if (-not $last -or -not $last.lastBuild) { Stop-Kit 1 "No job or no builds for $($Target.Label)." }
    "$($Target.Url)/$($last.lastBuild.number)"
}

function Get-Link($Target, [int] $Number) {
    if ($Target.Child -and $BluePipeline) {
        return "$Root/blue/organizations/jenkins/$BluePipeline/detail/$([uri]::EscapeDataString($Target.Child))/$Number/pipeline"
    }
    "$($Target.Url)/$Number/"
}

function Get-Stages([string] $BuildUrl) {
    $wf = Invoke-Jenkins "$BuildUrl/wfapi/describe"
    if (-not $wf) { return $null }
    @($wf.stages | ForEach-Object { [pscustomobject]@{ name = $_.name; status = $_.status; minutes = [math]::Round($_.durationMillis / 60000, 1) } })
}

function Get-StatusData {
    $t = Resolve-Target
    $url = Get-BuildUrl $t
    $b = Invoke-Jenkins "$url/api/json?tree=number,result,building,timestamp,duration,displayName,actions[lastBuiltRevision[SHA1],causes[shortDescription],parameters[name,value]]"
    if (-not $b) { Stop-Kit 1 "No such build: $url" }
    $rev = Get-Revision $b
    $cause = (($b.actions | Where-Object { $_.causes } | Select-Object -First 1).causes | Select-Object -First 1).shortDescription
    $version = $null
    if (-not $t.Child) {
        $params = ($b.actions | Where-Object { $_.parameters } | Select-Object -First 1).parameters
        if ($VersionParameter) { $version = ($params | Where-Object name -eq $VersionParameter).value }
        if (-not $version) { $version = Get-DisplayVersion $b.displayName }
    }
    $quick = (-not $b.building -and $b.result -eq 'FAILURE' -and $b.duration -lt 60000)
    [pscustomobject]@{
        target       = $t.Label
        build        = $b.number
        result       = $(if ($b.building) { 'RUNNING' } else { $b.result })
        started      = Format-When $b.timestamp
        minutes      = [math]::Round($b.duration / 60000, 1)
        commit       = $(if ($rev) { $rev.SHA1 } else { $null })
        cause        = $cause
        version      = $version
        stages       = Get-Stages $url
        quickFailure = $(if ($quick) { $(if ($QuickFailureHint) { $QuickFailureHint } else { 'Failed in under a minute.' }) } else { $null })
        link         = Get-Link $t $b.number
    }
}

function Write-StageLines($Stages, [switch] $NotPassedOnly) {
    if ($null -eq $Stages) { '  (no stage data)'; return }
    $shown = if ($NotPassedOnly) { @($Stages | Where-Object { $_.status -ne 'SUCCESS' }) } else { @($Stages) }
    if ($NotPassedOnly) { "  stages: $(@($Stages).Count - $shown.Count) of $(@($Stages).Count) passed; the rest:" }
    foreach ($s in $shown) { '  {0,-12} {1,6:N1} min  {2}' -f $s.status, $s.minutes, $s.name }
}

switch ($Command) {
    'ping' {
        $null = Invoke-Jenkins "$Root/api/json?tree=mode"
        if ($Json) { [pscustomobject]@{ reachable = $true; root = $Root } | ConvertTo-Json; break }
        "Jenkins reachable at $Root"
    }

    'status' {
        $d = Get-StatusData
        if ($Json) { $d | ConvertTo-Json -Depth 6; break }
        "$($d.target) build #$($d.build): $($d.result) (started $($d.started), $($d.minutes) min)"
        if ($d.commit) { "  commit $($d.commit.Substring(0, 8))" }
        if ($d.cause) { "  cause  $($d.cause)" }
        if ($d.version) { "  version $($d.version)" }
        if ($d.result -ne 'SUCCESS') { Write-StageLines $d.stages -NotPassedOnly }
        if ($d.quickFailure) { "  $($d.quickFailure)" }
        "  $($d.link)"
    }

    'stages' { $t = Resolve-Target; Write-StageLines (Get-Stages (Get-BuildUrl $t)) }

    'tail' {
        $t = Resolve-Target
        $text = Invoke-Jenkins "$(Get-BuildUrl $t)/consoleText" -Raw
        ($text -split "`r?`n") | Select-Object -Last $Lines
    }

    'find' {
        if (-not $Branch) { Stop-Kit 1 'find needs -Branch.' }
        $hits = @(Find-JobsForBranch $Branch)
        if ($Json) { ConvertTo-Json -InputObject @($hits | ForEach-Object { [pscustomobject]@{ job = $_.Name; open = ($_.Color -ne 'disabled'); result = $_.Result; title = $_.Title } }) -Depth 4; break }
        if (-not $hits.Count) { Stop-Kit 1 "No PR job built $Branch." }
        foreach ($h in $hits) {
            $state = if ($h.Color -eq 'disabled') { 'closed' } else { 'open' }
            '{0,-8} {1,-7} last={2,-8} {3}' -f $h.Name, $state, $h.Result, $h.Title
        }
    }
}
exit 0
