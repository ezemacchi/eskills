#Requires -Version 7
<#
.SYNOPSIS
    The repo capability for Bitbucket Server (REST 1.0): the person's pull requests, the checks on a
    commit, the quality report, the merge check, and the commit that merged a pull request.

.DESCRIPTION
    Reads only. The base address, the code repository (project and slug), the quality report key and
    the token variable come from the kit configuration (providers.bitbucket-server.*). The token is a
    personal access token read from that variable (process first, then the user's own) and sent only in
    a request header; it is never printed.

    Commands (-Json prints the repo contract's shape, docs/contracts/repo.md in the kit):
      prs [-State open|merged] [-Max 50]
                       the token owner's pull requests as author, in every repository. "primary" is
                       true for the configured code repository.
      prs -Role reviewer
                       the open pull requests that wait on the token owner's review: they are a
                       reviewer and have not approved ("myReview": none or needsWork).
      prs -Source <branch> [-State open|merged]
                       the pull requests from that branch into the configured code repository, by
                       anyone.
      checks -Commit <sha>
                       the builds the CI reported on that commit. "pullRequestBuild" marks a build of
                       a pull-request job (Jenkins names them .../PR-<n>).
      quality -Commit <sha> -Repo <slug> -Project <key>
                       the quality report (providers.bitbucket-server.sonarReportKey), or null when the
                       commit has none or no report key is configured.
      mergeable -Pr <id> -Repo <slug> -Project <key>
                       whether the pull request can merge, whether it conflicts, and what vetoes its
                       merge (the short message, and the detailed one in vetoDetails).
      merge-commit -Pr <id> -Target <branch[,branch]> [-Clone <folder>]
                       the commit that merged the pull request into one of the branches, from the
                       clone's history (paths.codeRepo unless -Clone): Bitbucket writes "Pull request
                       #<n>: ..." or "Merge pull request #<n> in ...". Needs no token; does not fetch.

.NOTES
    Exit codes: 0 ok, 1 bad input or an unexpected answer, 2 missing configuration, token or clone,
    3 Bitbucket refused the token ("refused:") or could not be reached ("unreachable:").
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('prs', 'checks', 'quality', 'mergeable', 'merge-commit')]
    [string] $Command,
    [ValidateSet('open', 'merged')]
    [string] $State = 'open',
    [ValidateSet('author', 'reviewer')]
    [string] $Role = 'author',
    [string] $Source,
    [int] $Max = 50,
    [string] $Commit,
    [string] $Pr,
    [string] $Repo,
    [string] $Project,
    [string] $Target,
    [string] $Clone,
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

$cfg = Get-KitConfig
$ProviderKey = 'providers.bitbucket-server'

function Out-Result($Value) {
    if ($Json) { ConvertTo-Json -InputObject $Value -Depth 6; return }
    $Value | Format-List | Out-String -Width 160
}

if ($Command -eq 'merge-commit') {
    if ($Pr -notmatch '^\d+$') { Stop-Kit 1 "-Pr must be the pull request's number, got '$Pr'." }
    $targets = @("$Target" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $targets.Count) { Stop-Kit 1 'merge-commit needs -Target: the branch or branches the pull request went into.' }
    if (-not $Clone) { $Clone = Get-KitValue $cfg 'paths.codeRepo' -Path }
    if (-not $Clone -or -not (Test-Path -LiteralPath (Join-Path $Clone '.git'))) { Stop-Kit 2 "merge-commit reads git history and needs a clone of the code repository (paths.codeRepo is '$Clone'). Set it with /setup." }
    $refs = @($targets | ForEach-Object { "origin/$_" })
    $ErrorActionPreference = 'Continue'
    $line = & git -C $Clone log @refs --format='%H %s' --grep "Pull request #$($Pr):" --grep "Merge pull request #$Pr in " 2>$null | Select-Object -First 1
    $ErrorActionPreference = 'Stop'
    $found = if ($line) { "$line" } else { '' }
    $sha = if ($found.Length -ge 40) { $found.Substring(0, 40) } else { $null }
    $into = $null
    if ($sha) {
        foreach ($t in $targets) {
            & git -C $Clone merge-base --is-ancestor $sha "origin/$t" 2>$null
            if ($LASTEXITCODE -eq 0) { $into = $t; break }
        }
    }
    Out-Result ([pscustomobject]@{ pr = [int]$Pr; commit = $sha; target = $into; subject = $(if ($sha) { $found.Substring(41) } else { $null }) })
    exit 0
}

$Base = ([string](Get-KitValue $cfg "$ProviderKey.base" -Required)).TrimEnd('/')
$MainRepo = [string](Get-KitValue $cfg "$ProviderKey.repo" -Required)
$SonarKey = [string](Get-KitValue $cfg "$ProviderKey.sonarReportKey")
$QualityName = [string](Get-KitValue $cfg "$ProviderKey.qualityName")
$TokenVar = [string](Get-KitValue $cfg "$ProviderKey.tokenVar" -Required)
if ($Base -notmatch '^https://[^\s]+$') { Stop-Kit 1 "$ProviderKey.base '$Base' is not an https address." }
$token = Get-KitEnv $TokenVar
if (-not $token) { Stop-Kit 2 "No Bitbucket token: set the user variable $TokenVar (a personal access token with read access). /setup explains how." }

# The token goes only in a request header, never on a command line or to a file. $AllowMissing turns a
# 404 into $null (a commit with no report).
function Invoke-Bb([string]$ApiPath, [switch]$AllowMissing) {
    try { Invoke-RestMethod -Uri "$Base$ApiPath" -Headers @{ Authorization = "Bearer $token"; Accept = 'application/json' } -TimeoutSec 30 }
    catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($status -in 401, 403) { Stop-Kit 3 "refused: Bitbucket refused the token in $TokenVar ($status)." }
        if ($status -eq 0) { Stop-Kit 3 'unreachable: cannot reach Bitbucket (VPN?).' }
        if ($AllowMissing) { return $null }
        Stop-Kit 1 "Unexpected answer from Bitbucket ($status) for $(($ApiPath -split '\?')[0])."
    }
}

function ConvertTo-CheckState([string]$Raw) {
    switch ($Raw) { 'SUCCESSFUL' { return 'success' } 'FAILED' { return 'failed' } 'INPROGRESS' { return 'running' } }
    $Raw
}

function ConvertTo-PullRequest($Raw, [string]$MyReview) {
    $slug = [string]$Raw.toRef.repository.slug
    $item = [ordered]@{
        id = $Raw.id; title = [string]$Raw.title; link = [string]$Raw.links.self[0].href
        repo = $slug; project = [string]$Raw.toRef.repository.project.key; primary = ($slug -eq $MainRepo)
        source = [string]$Raw.fromRef.displayId; target = [string]$Raw.toRef.displayId; latestCommit = [string]$Raw.fromRef.latestCommit
        author = $(if ($Raw.author.user.displayName) { [string]$Raw.author.user.displayName } else { [string]$Raw.author.user.name })
        updated = $(if ($Raw.updatedDate) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Raw.updatedDate).ToString('o') } else { $null })
        reviewers = @($Raw.reviewers | Where-Object { $_ } | ForEach-Object {
                [pscustomobject]@{ name = [string]$_.user.displayName; state = $(switch ([string]$_.status) { 'APPROVED' { 'approved' } 'NEEDS_WORK' { 'needsWork' } default { 'none' } }) }
            })
        closedAt = $(if ($Raw.closedDate) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Raw.closedDate).ToString('o') } else { $null })
    }
    if ($MyReview) { $item.myReview = $MyReview }
    [pscustomobject]$item
}

function Get-PageValues($Page) {
    if ($null -eq $Page -or -not $Page.PSObject.Properties['values']) { Stop-Kit 1 'Unexpected answer from Bitbucket for the pull request list.' }
    @($Page.values | Where-Object { $_ })
}

switch ($Command) {
    'prs' {
        $Max = [Math]::Min([Math]::Max($Max, 1), 100)
        if ($Source -and $Role -eq 'reviewer') { Stop-Kit 1 'prs takes -Source or -Role reviewer, not both.' }
        if ($Role -eq 'reviewer' -and $PSBoundParameters.ContainsKey('State') -and $State -ne 'open') { Stop-Kit 1 'prs -Role reviewer lists open pull requests only.' }
        $list = @(if ($Source) {
            # Any author: the code repository's pull requests whose source is that branch.
            $MainProject = [string](Get-KitValue $cfg "$ProviderKey.project" -Required)
            $branchRef = [uri]::EscapeDataString("refs/heads/$Source")
            @(Get-PageValues (Invoke-Bb "/rest/api/1.0/projects/$MainProject/repos/$MainRepo/pull-requests?direction=OUTGOING&at=$branchRef&state=$($State.ToUpperInvariant())&limit=$Max") |
                ForEach-Object { ConvertTo-PullRequest $_ $null })
        }
        elseif ($Role -eq 'reviewer') {
            # The dashboard answers for the token's owner: still unapproved, or marked needs work.
            $seen = @{}
            @(foreach ($pair in @(@('UNAPPROVED', 'none'), @('NEEDS_WORK', 'needsWork'))) {
                    foreach ($raw in (Get-PageValues (Invoke-Bb "/rest/api/1.0/dashboard/pull-requests?role=REVIEWER&state=OPEN&participantStatus=$($pair[0])&limit=$Max"))) {
                        $id = "$($raw.toRef.repository.project.key)/$($raw.toRef.repository.slug)/$($raw.id)"
                        if ($seen[$id]) { continue }
                        $seen[$id] = $true
                        ConvertTo-PullRequest $raw $pair[1]
                    }
                })
        }
        else {
            @(Get-PageValues (Invoke-Bb "/rest/api/1.0/dashboard/pull-requests?role=AUTHOR&state=$($State.ToUpperInvariant())&limit=$Max") |
                ForEach-Object { ConvertTo-PullRequest $_ $null })
        })
        if ($Json) { ConvertTo-Json -InputObject $list -Depth 6; break }
        if (-not $list.Count) { 'No pull requests.'; break }
        foreach ($p in $list) { "#$($p.id) | $($p.repo) | $($p.source) -> $($p.target) | $($p.title) | $($p.link)" }
    }

    'checks' {
        if ($Commit -notmatch '^[0-9a-f]{7,40}$') { Stop-Kit 1 "-Commit must be a commit hash, got '$Commit'." }
        $page = Invoke-Bb "/rest/build-status/1.0/commits/$Commit"
        $list = @($page.values | Where-Object { $_ } | ForEach-Object {
                [pscustomobject]@{
                    key = [string]$_.key; state = (ConvertTo-CheckState ([string]$_.state)); url = [string]$_.url
                    build = $(if ([string]$_.url -match '/(\d+)/display/redirect') { $Matches[1] } else { $null })
                    pullRequestBuild = ([string]$_.key -match '/PR-\d+$')
                }
            })
        if ($Json) { ConvertTo-Json -InputObject $list -Depth 4; break }
        foreach ($c in $list) { "$($c.state) | $($c.key) | $($c.url)" }
    }

    'quality' {
        if ($Commit -notmatch '^[0-9a-f]{7,40}$') { Stop-Kit 1 "-Commit must be a commit hash, got '$Commit'." }
        if (-not $Repo -or -not $Project) { Stop-Kit 1 'quality needs -Repo (the slug) and -Project (the key), as prs prints them.' }
        $report = if ($SonarKey) { Invoke-Bb "/rest/insights/1.0/projects/$Project/repos/$Repo/commits/$Commit/reports/$SonarKey" -AllowMissing } else { $null }
        $out = if ($report) {
            [pscustomobject]@{
                result = $(switch ([string]$report.result) { 'PASS' { 'pass' } 'FAIL' { 'fail' } default { [string]$report.result } })
                name = $(if ($QualityName) { $QualityName } else { [string]$report.title })
                link = [string]$report.link
                details = @(@("$($report.details)" -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^Quality Gate' }) |
                        ForEach-Object { $_ -replace '^[^\p{L}\p{N}]+\s*', '' })
            }
        } else { $null }
        if ($Json) { ConvertTo-Json -InputObject $out -Depth 4; break }
        if ($null -eq $out) { 'No quality report.' } else { "$($out.name): $($out.result) | $($out.details -join '; ') | $($out.link)" }
    }

    'mergeable' {
        if ($Pr -notmatch '^\d+$') { Stop-Kit 1 "-Pr must be the pull request's number, got '$Pr'." }
        if (-not $Repo -or -not $Project) { Stop-Kit 1 'mergeable needs -Repo (the slug) and -Project (the key), as prs prints them.' }
        $m = Invoke-Bb "/rest/api/1.0/projects/$Project/repos/$Repo/pull-requests/$Pr/merge"
        $out = [pscustomobject]@{
            canMerge = [bool]$m.canMerge; conflicted = [bool]$m.conflicted
            vetoes = @($m.vetoes | Where-Object { $_ } | ForEach-Object { [string]$_.summaryMessage })
            vetoDetails = @($m.vetoes | Where-Object { $_ } | ForEach-Object { [string]$_.detailedMessage })
        }
        if ($Json) { ConvertTo-Json -InputObject $out -Depth 3; break }
        "can merge: $($out.canMerge); conflicted: $($out.conflicted)$(if ($out.vetoes.Count) { "; vetoes: $($out.vetoes -join '; ')" })"
    }
}
exit 0
