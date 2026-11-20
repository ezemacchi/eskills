#Requires -Version 7
<#
.SYNOPSIS
    Delivery: whether each environment has a ticket's change or a merged pull request, and if not,
    from which version it will. Engine logic over git and the cd and repo providers.

.DESCRIPTION
    Commands:
      ticket -Key <KEY>        branches named after the ticket, its commits on each target branch (the
                               branches the cd provider publishes), the first version tag with it, the
                               last publish of each target, and each environment's verdict
      deployed -Pr <n> | -Commit <sha>
                               whether a merged pull request (its merge commit, from the repo provider)
                               or a commit is in the last publish of each target and in each environment

    Git runs in the code clone (paths.codeRepo, or -Repo); a partial clone without files is enough.
    The cd provider gives the target branches (targets), each environment's version, branch and the
    commit of that version (environments), and the last publishes (publishes). A ticket's commits are
    those whose message names the key with word boundaries; the key must look like the board's keys
    (providerInfo.board.keyPattern). The first version is the oldest tag matching delivery.tagPattern
    (default v*) that contains the newest commit, without the pattern's prefix.

    -Json prints docs/contracts/delivery.md's shape; other skills read that, never the text.

.NOTES
    Exit codes: 0 ok, 1 bad input, 2 missing configuration or clone (or the cd capability is off),
    3 a provider's service could not be reached.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('ticket', 'deployed')]
    [string] $Command,
    [string] $Key,
    [int] $Pr,
    [string] $Commit,
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
if (-not (Test-KitCapability $cfg 'cd')) { Stop-Kit 2 'Delivery needs the cd capability (environments and versions), which is off. /setup turns it on.' }
$cdScript = [string](Get-KitValue $cfg 'scripts.cd')
if (-not $cdScript -or -not (Test-Path -LiteralPath $cdScript -PathType Leaf)) { Stop-Kit 2 'The cd provider has no script recorded (scripts.cd). Run /setup (init).' }
$repoScript = if (Test-KitCapability $cfg 'repo') { [string](Get-KitValue $cfg 'scripts.repo') } else { $null }
$boardInfo = Get-KitValue $cfg 'providerInfo.board'
$keyPattern = if ($boardInfo -and $boardInfo.keyPattern) { [string]$boardInfo.keyPattern } else { '^\S+$' }
$tagPattern = [string](Get-KitValue $cfg 'delivery.tagPattern')
if (-not $tagPattern) { $tagPattern = 'v*' }
$tagPrefix = $tagPattern.TrimEnd('*')
if (-not $Repo) { $Repo = Get-KitValue $cfg 'paths.codeRepo' -Path }

function Invoke-Provider([string]$Script, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $lines = & pwsh -NoProfile -File $Script @Arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $err = (@($lines | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' ').Trim()
    $out = @($lines | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n"
    if ($code -eq 3) { Stop-Kit 3 $(if ($err) { $err } else { 'unreachable: a provider could not reach its service.' }) }
    if ($code -eq 2) { Stop-Kit 2 $(if ($err) { $err } else { 'A provider is not configured. Run /setup.' }) }
    if ($code -ne 0) { Stop-Kit 1 $(if ($err) { $err } else { "A provider failed ($code)." }) }
    if (-not $out.Trim()) { return $null }
    $out | ConvertFrom-Json
}

function Invoke-Git {
    # Windows PowerShell turns git's stderr warnings into terminating errors under Stop.
    $ErrorActionPreference = 'Continue'
    & git -C $Repo @args 2>$null
}

function Assert-Repo {
    if (-not $Repo -or -not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) {
        Stop-Kit 2 "This command reads git history and needs a clone of the code repository (paths.codeRepo is '$Repo'). Set it with /setup, or pass -Repo."
    }
}

$script:targetInfo = $null
function Get-Targets {
    if ($null -eq $script:targetInfo) { $script:targetInfo = Invoke-Provider $cdScript @('targets', '-Json') }
    @($script:targetInfo.branches | Where-Object { $_ })
}

$script:publishCache = @{}
function Get-Publishes([int]$Runs) {
    if (-not $script:publishCache.ContainsKey($Runs)) { $script:publishCache[$Runs] = @(Invoke-Provider $cdScript @('publishes', '-Runs', [string]$Runs, '-Json') | Where-Object { $_ }) }
    $script:publishCache[$Runs]
}

# Whether a commit is in each environment. $Sha is one commit, or a hashtable branch -> commit: an
# environment is checked against the commit of the branch its versions come from.
function Get-InstanceVerdicts($Sha) {
    foreach ($i in @(Invoke-Provider $cdScript @('environments', '-Repo', $Repo, '-Json') | Where-Object { $_ })) {
        $verdict = $null
        if ($i.version) {
            $against = $Sha
            if ($Sha -is [hashtable]) {
                $from = $i.branch
                $against = if ($from -and $Sha[$from]) { $Sha[$from] } else { @($Sha.Values)[0] }
            }
            $verdict = if (-not $i.commit) { 'UNKNOWN' } else {
                Invoke-Git merge-base --is-ancestor $against $i.commit
                if ($LASTEXITCODE -eq 0) { 'IN' } else { 'NOT_IN' }
            }
        }
        [pscustomobject]@{ name = $i.name; version = $i.version; verdict = $verdict; source = $i.source; branch = $i.branch }
    }
}

# The author of the newest commit that is not a merge, so a ticket's developer is not whoever merged it.
function Get-Author([string[]] $LogArgs) {
    $line = Invoke-Git log -1 --no-merges --format='%an%x09%ae' @LogArgs | Select-Object -First 1
    if (-not $line) { return $null }
    $parts = "$line".Split("`t")
    [pscustomobject]@{ name = $parts[0]; email = $(if ($parts.Count -gt 1) { $parts[1] } else { $null }) }
}

function Format-SourceText($Source) {
    if (-not $Source) { return '' }
    if ($Source.kind -eq 'deploy-log') { return "deployment #$($Source.ref)$(if ($Source.at) { ', ' + [DateTimeOffset]::Parse($Source.at).LocalDateTime.ToString('yyyy-MM-dd HH:mm') })" }
    if ($Source.kind -eq 'live') { return 'live from its address' }
    [string]$Source.ref
}

function Write-InstanceLines($Rows) {
    $rows = @($Rows)
    if (-not @($rows | Where-Object version).Count) { 'environments: their versions could not be read.'; return }
    $words = @{ IN = 'IN'; NOT_IN = 'NOT in'; UNKNOWN = 'UNKNOWN (version commit not found) for' }
    foreach ($r in $rows) {
        if (-not $r.version) { "$($r.name): version unknown."; continue }
        if ($r.verdict) { '{0,-7} {1} {2} ({3})' -f "$($r.name):", $words[$r.verdict], $r.version, (Format-SourceText $r.source) }
        else { '{0,-7} {1} ({2})' -f "$($r.name):", $r.version, (Format-SourceText $r.source) }
    }
    if ($script:targetInfo -and $script:targetInfo.note) { "  $($script:targetInfo.note)" }
}

function Get-DeployedData {
    Assert-Repo
    $targets = Get-Targets
    Invoke-Git fetch --quiet origin @targets | Out-Null
    $target = $Commit
    $merged = $true
    if (-not $target) {
        if (-not $Pr) { Stop-Kit 1 'deployed needs -Pr <n> or -Commit <sha>.' }
        if (-not $repoScript) { Stop-Kit 2 'deployed -Pr finds the merge commit through the repo capability, which is off. Pass -Commit <sha>, or turn repo on with /setup.' }
        $found = Invoke-Provider $repoScript @('merge-commit', '-Pr', [string]$Pr, '-Target', ($targets -join ','), '-Clone', $Repo, '-Json')
        if (-not $found -or -not $found.commit) { $merged = $false } else { $target = [string]$found.commit }
    }
    $publishes = @()
    $instances = @()
    if ($target) {
        $publishes = @(foreach ($p in (Get-Publishes 6)) {
                if (-not $p.build) { [pscustomobject]@{ job = $p.job; verdict = $null; note = "no successful publish in the last $($p.runs) runs" }; continue }
                Invoke-Git merge-base --is-ancestor $target $p.commit
                $in = ($LASTEXITCODE -eq 0)
                [pscustomobject]@{
                    job = $p.job; branch = $p.branch; verdict = $(if ($in) { 'IN' } else { 'NOT_IN' })
                    build = $p.build; version = $p.version; when = $p.when; commit = $p.commit
                    cause = $p.cause
                    url = $p.url
                    chart = $(if ($in -and $p.chart) { $p.chart } else { $null })
                    publishingNow = $p.publishingNow
                }
            })
        $instances = @(Get-InstanceVerdicts $target)
    }
    [pscustomobject]@{ pr = $(if ($Pr) { $Pr } else { $null }); commit = $target; merged = $merged; publishes = $publishes; instances = $instances }
}

function Get-TicketData {
    if (-not $Key -or $Key -notmatch $keyPattern) { Stop-Kit 1 "ticket needs -Key, a ticket key ($keyPattern)." }
    Assert-Repo
    $targets = Get-Targets
    Invoke-Git fetch --quiet --tags origin @targets | Out-Null

    $branches = @(Invoke-Git branch -r --list "origin/*$Key*" | ForEach-Object { $_.Trim() } | ForEach-Object {
            $b = $_
            $notOn = [ordered]@{}
            foreach ($t in $targets) { $notOn[$t] = [int](Invoke-Git rev-list --count "origin/$t..$b") }
            [pscustomobject]@{ name = $b; notOn = [pscustomobject]$notOn; author = (Get-Author @($b)) }
        })

    $newestOn = @{}
    # Word-bounded so PROJ-50 does not match PROJ-502.
    $keyGrep = "(^|[^0-9A-Za-z-])$([regex]::Escape($Key))([^0-9]|$)"
    $onTargets = @(foreach ($t in $targets) {
            $hits = @(Invoke-Git log "origin/$t" --format='%H %cs %s' -E --grep $keyGrep)
            if (-not $hits.Count) { [pscustomobject]@{ branch = $t; commits = 0 }; continue }
            $newest = $hits[0].Split(' ')[0]
            $newestOn[$t] = $newest
            $tag = Invoke-Git tag --contains $newest --sort=creatordate --list $tagPattern | Select-Object -First 1
            $pub = $null
            $p = @(Get-Publishes 8) | Where-Object { $_.branch -eq $t } | Select-Object -First 1
            if ($p) {
                $pub = if (-not $p.build) { [pscustomobject]@{ job = $p.job; verdict = $null; note = "no successful run in the last $($p.runs)" } } else {
                    Invoke-Git merge-base --is-ancestor $newest $p.commit
                    [pscustomobject]@{
                        job = $p.job; verdict = $(if ($LASTEXITCODE -eq 0) { 'IN' } else { 'NOT_IN' })
                        version = $p.displayVersion; build = $p.build; when = $p.when
                    }
                }
            }
            [pscustomobject]@{
                branch = $t; commits = $hits.Count; newest = $newest; newestDate = $hits[0].Substring(41, 10)
                newestSubject = $hits[0].Substring(52); firstTag = $tag; publish = $pub
                author = (Get-Author @("origin/$t", '-E', '--grep', $keyGrep))
            }
        })

    $instances = if ($newestOn.Count) { @(Get-InstanceVerdicts $newestOn) } else { @() }
    # The first version an environment will run with the change: the first tag on the branch it takes versions from.
    foreach ($i in $instances) {
        $feed = $onTargets | Where-Object { $i.branch -and $_.branch -eq $i.branch -and $_.firstTag } | Select-Object -First 1
        $i | Add-Member -NotePropertyName firstVersion -NotePropertyValue $(if ($feed) { $(if ($tagPrefix -and $feed.firstTag.StartsWith($tagPrefix)) { $feed.firstTag.Substring($tagPrefix.Length) } else { $feed.firstTag }) } else { $null })
    }
    [pscustomobject]@{ key = $Key; branches = $branches; targets = $onTargets; instances = $instances }
}

switch ($Command) {
    'deployed' {
        $d = Get-DeployedData
        if ($Json) { $d | ConvertTo-Json -Depth 6; break }
        if (-not $d.merged) { "PR #$Pr is not merged into $((Get-Targets) -join ' or '), so it cannot be in any publish."; break }
        if ($Pr) { "PR #$Pr merge commit: $($d.commit.Substring(0, 8))" }
        foreach ($p in $d.publishes) {
            if (-not $p.verdict) { "$($p.job): $($p.note)."; continue }
            $word = if ($p.verdict -eq 'IN') { 'IN' } else { 'NOT in' }
            "$($p.job): $word last publish build #$($p.build) (version $($p.version), $($p.cause), $($p.when)) at $($p.commit.Substring(0, 8))"
            if ($p.verdict -eq 'IN') { "  $($p.url)"; if ($p.chart) { "  chart $($p.chart)" } }
            if ($p.publishingNow) { "  build #$($p.publishingNow) is publishing now (not published yet)." }
        }
        Write-InstanceLines $d.instances
    }

    'ticket' {
        $d = Get-TicketData
        if ($Json) { $d | ConvertTo-Json -Depth 6; break }
        foreach ($b in $d.branches) {
            $parts = @($b.notOn.PSObject.Properties | ForEach-Object { "$($_.Value) not on $($_.Name)" })
            if ($parts.Count) { $parts[0] = $parts[0] -replace '^(\d+) ', '$1 commit(s) ' }
            "branch $($b.name): $($parts -join ', ')"
        }
        foreach ($t in $d.targets) {
            if (-not $t.commits) { "$($t.branch): no commit mentions $Key."; continue }
            $tagText = if ($t.firstTag) { "first tag with it $($t.firstTag)" } else { 'in no tag yet' }
            "$($t.branch): $($t.commits) commit(s), newest $($t.newest.Substring(0, 8)) $($t.newestDate) $($t.newestSubject); $tagText"
            if ($t.publish) {
                if (-not $t.publish.verdict) { "  $($t.publish.job): $($t.publish.note)." }
                else {
                    $word = if ($t.publish.verdict -eq 'IN') { 'IN' } else { 'NOT in' }
                    "  $($t.publish.job): $word last publish $($t.publish.version) (#$($t.publish.build), $($t.publish.when))"
                }
            }
        }
        if (@($d.instances).Count) { Write-InstanceLines $d.instances }
        elseif (-not $d.branches.Count) { "No branch or commit mentions $Key." }
    }
}
exit 0
