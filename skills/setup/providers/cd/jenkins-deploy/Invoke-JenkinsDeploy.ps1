#Requires -Version 7
<#
.SYNOPSIS
    The cd capability on Jenkins: which version each environment runs, which branches are published,
    the last publishes, and which commit a version is. Reads Jenkins; never triggers anything.

.DESCRIPTION
    Values come from providers.jenkins-deploy.* in the configuration:
      root              the Jenkins address, for the message when it does not answer
      publish           the publish jobs: name -> url, branch, versionLike (a wildcard; '*' for the rest)
      publisher         the deployment job whose log lists every environment's version (optional)
      deployLog         regular expressions for that log's lines: instanceLine (named groups name and
                        version: an environment and the version it runs), targetLine (name: the
                        environment this run upgrades), runningLine (version: the upgrade finished on it)
      liveVersion       a regular expression with the named group version, matched against the address
                        an environment's liveUrl redirects to
      buildNameVersion  a regular expression with the named group version, matched against a publish
                        run's name
      versionParameter  the publish run parameter that holds the version it was given by hand
      chartUrl          the chart address, with {version}
      instances         the environments: name, liveUrl (optional), upgrade (auto or manual)
      instancesNote     a sentence for the person on how environments get upgraded
    A pattern left empty turns off what it reads. A version's git tag is delivery.tagPattern without
    its trailing '*', followed by the version (v1.4.2 for v*), as the delivery check reads tags.

    Commands (-Json prints the cd contract's shape, docs/contracts/cd.md in the kit):
      environments [-NoCommit]   the version each environment runs, the branch its versions come from,
                                 how it is upgraded, where the answer came from (the newest deployment
                                 run whose log lists the environments: "deploy-log"; the environment's
                                 own address: "live"), and the commit of that version (unless -NoCommit)
      targets                    the branches the publish jobs build, and the note on upgrades
      commit-of -Version <v>     the commit a version was built from: its tag in the code clone, else
                                 the successful publish run that published it
      publishes [-Runs 8]        the last successful run of each publish job among its last -Runs runs

.NOTES
    Exit codes: 0 ok, 1 bad input or an unexpected answer, 2 missing configuration, 3 Jenkins
    unreachable ("unreachable:", probably off the VPN).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('environments', 'targets', 'commit-of', 'publishes')]
    [string] $Command,
    [string] $Version,
    [int] $Runs = 8,
    [string] $Repo,
    [switch] $NoCommit,
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
$ProviderKey = 'providers.jenkins-deploy'
$Root = ([string](Get-KitValue $cfg "$ProviderKey.root" -Required)).TrimEnd('/')
$Publisher = Get-KitValue $cfg "$ProviderKey.publisher"
$ChartUrl = Get-KitValue $cfg "$ProviderKey.chartUrl"
$InstancesNote = [string](Get-KitValue $cfg "$ProviderKey.instancesNote")
$InstanceLine = [string](Get-KitValue $cfg "$ProviderKey.deployLog.instanceLine")
$TargetLine = [string](Get-KitValue $cfg "$ProviderKey.deployLog.targetLine")
$RunningLine = [string](Get-KitValue $cfg "$ProviderKey.deployLog.runningLine")
$LiveVersion = [string](Get-KitValue $cfg "$ProviderKey.liveVersion")
$BuildNameVersion = [string](Get-KitValue $cfg "$ProviderKey.buildNameVersion")
$VersionParameter = [string](Get-KitValue $cfg "$ProviderKey.versionParameter")
$TagPattern = [string](Get-KitValue $cfg 'delivery.tagPattern')
if (-not $TagPattern) { $TagPattern = 'v*' }
$TagPrefix = $TagPattern.TrimEnd('*')
$Publish = [ordered]@{}
foreach ($p in (Get-KitValue $cfg "$ProviderKey.publish" -Required).PSObject.Properties) { $Publish[$p.Name] = $p.Value }
$InstanceList = @(Get-KitValue $cfg "$ProviderKey.instances")
if (-not $Repo) { $Repo = Get-KitValue $cfg 'paths.codeRepo' -Path }
$HasClone = [bool]($Repo -and (Test-Path -LiteralPath (Join-Path $Repo '.git')))

function Invoke-Jenkins([string] $Url, [switch] $Text) {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        $code = curl.exe --globoff -sS -A 'Mozilla/5.0' --max-time 30 -o $tmp -w '%{http_code}' $Url 2>$null
        if (-not $code -or $code -eq '000') { Stop-Kit 3 "unreachable: Jenkins does not answer ($Root). You are probably not on the VPN." }
        if ($code -eq '404') { return $null }
        if ($code -ne '200') { Stop-Kit 1 "HTTP $code from $Url" }
        $body = [IO.File]::ReadAllText($tmp)
        if ($Text) { return $body }
        return $body | ConvertFrom-Json
    }
    finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

function Invoke-Git {
    $ErrorActionPreference = 'Continue'
    & git -C $Repo @args 2>$null
}

function ConvertTo-When($Ms) {
    if (-not $Ms) { return $null }
    [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Ms).ToString('o')
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

function Get-DisplayVersion([string] $Name) {
    if ($BuildNameVersion -and $Name -match $BuildNameVersion) { return $Matches['version'] }
    $null
}

# The publish job a version comes from: the first whose versionLike is not '*' and matches, else the '*' one.
function Get-PublishForVersion([string] $Ver) {
    $specific = @($Publish.GetEnumerator() | Where-Object { $_.Value.versionLike -and $_.Value.versionLike -ne '*' -and $Ver -like $_.Value.versionLike })
    if ($specific.Count) { return $specific[0].Key }
    $any = @($Publish.GetEnumerator() | Where-Object { $_.Value.versionLike -eq '*' })
    if ($any.Count) { return $any[0].Key }
    $null
}

# The version each instance runs: from the newest finished publisher log, which lists every instance
# before it upgrades one, and live from the address of any instance that has one (liveUrl).
function Get-InstanceVersions {
    $versions = [ordered]@{}
    $source = @{}
    if ($Publisher) {
        $runList = (Invoke-Jenkins "$($Publisher.TrimEnd('/'))/api/json?tree=builds[number,building,result,timestamp]{0,6}").builds
        # A run that failed before listing the instances has no versions in its log; use the newest that has them.
        foreach ($run in @($runList | Where-Object { -not $_.building -and $_.result })) {
            $log = Invoke-Jenkins "$($Publisher.TrimEnd('/'))/$($run.number)/consoleText" -Text
            $target = $null
            foreach ($line in ($log -split "`r?`n")) {
                if ($InstanceLine -and $line -match $InstanceLine) {
                    if (-not $versions.Contains($Matches['name'])) { $versions[$Matches['name']] = $Matches['version'] }
                }
                elseif ($TargetLine -and $line -match $TargetLine) { $target = $Matches['name'] }
                elseif ($target -and $RunningLine -and $line -match $RunningLine) { $versions[$target] = $Matches['version'] }
            }
            if (-not $versions.Count) { continue }
            foreach ($k in @($versions.Keys)) { $source[$k] = [pscustomobject]@{ kind = 'deploy-log'; ref = [string]$run.number; at = (ConvertTo-When $run.timestamp) } }
            break
        }
    }
    foreach ($i in $InstanceList) {
        if (-not $i.liveUrl -or -not $LiveVersion) { continue }
        $redirect = curl.exe -sS -k -A 'Mozilla/5.0' --max-time 20 -o NUL -w '%{redirect_url}' $i.liveUrl 2>$null
        if ($redirect -match $LiveVersion) {
            $versions[$i.name] = $Matches['version']
            $source[$i.name] = [pscustomobject]@{ kind = 'live'; ref = [string]$i.liveUrl; at = $null }
        }
    }
    foreach ($inst in $InstanceList) {
        $instName = [string]$inst.name
        $ver = $versions[$instName]
        $feedJob = if ($ver) { Get-PublishForVersion $ver } else { $null }
        [pscustomobject]@{
            name = $instName; version = $ver; branch = $(if ($feedJob) { $Publish[$feedJob].branch } else { $null })
            upgrade = $inst.upgrade; source = $source[$instName]
        }
    }
}

# The commit a published version was built from: its git tag, else the publish run with that version.
function Resolve-VersionCommit([string] $Ver) {
    if ($HasClone) {
        $sha = Invoke-Git rev-parse --verify --quiet "refs/tags/$TagPrefix$Ver^{commit}"
        if ($sha) { return "$sha".Trim() }
    }
    $jobName = Get-PublishForVersion $Ver
    if (-not $jobName) { return $null }
    $runList = (Invoke-Jenkins "$($Publish[$jobName].url.TrimEnd('/'))/api/json?tree=builds[displayName,result,actions[lastBuiltRevision[SHA1]]]{0,40}").builds
    $hit = $runList | Where-Object { $_.result -eq 'SUCCESS' -and (Get-DisplayVersion $_.displayName) -eq $Ver } | Select-Object -First 1
    if ($hit) { return (Get-Revision $hit).SHA1 }
    $null
}

function Format-SourceText($Source) {
    if (-not $Source) { return '' }
    if ($Source.kind -eq 'deploy-log') { return "publisher #$($Source.ref), $(if ($Source.at) { [DateTimeOffset]::Parse($Source.at).LocalDateTime.ToString('yyyy-MM-dd HH:mm') })" }
    if ($Source.kind -eq 'live') { return 'live from its address' }
    [string]$Source.ref
}

switch ($Command) {
    'environments' {
        $rows = @(Get-InstanceVersions | ForEach-Object {
                $_ | Add-Member -NotePropertyName commit -NotePropertyValue $(if (-not $NoCommit -and $_.version) { Resolve-VersionCommit $_.version } else { $null }) -PassThru
            })
        if ($Json) { ConvertTo-Json -InputObject $rows -Depth 5; break }
        if (-not @($rows | Where-Object version).Count) { 'instances: versions could not be read from the publisher log or the instance addresses.'; break }
        foreach ($r in $rows) {
            if (-not $r.version) { "$($r.name): version unknown."; continue }
            '{0,-7} {1} ({2})' -f "$($r.name):", $r.version, (Format-SourceText $r.source)
        }
        if ($InstancesNote) { "  $InstancesNote" }
    }

    'targets' {
        $out = [pscustomobject]@{ branches = @($Publish.Values | ForEach-Object { $_.branch } | Where-Object { $_ } | Select-Object -Unique); note = $InstancesNote }
        if ($Json) { $out | ConvertTo-Json -Depth 3; break }
        "Published branches: $($out.branches -join ', ')"
        if ($InstancesNote) { $InstancesNote }
    }

    'commit-of' {
        if (-not $Version) { Stop-Kit 1 'commit-of needs -Version.' }
        $out = [pscustomobject]@{ version = $Version; commit = (Resolve-VersionCommit $Version) }
        if ($Json) { $out | ConvertTo-Json; break }
        "$Version -> $(if ($out.commit) { $out.commit } else { 'commit not found' })"
    }

    'publishes' {
        $Runs = [Math]::Max($Runs, 1)
        $tree = "builds[number,result,building,timestamp,displayName,actions[lastBuiltRevision[SHA1],causes[shortDescription],parameters[name,value]]]{0,$Runs}"
        $list = @(foreach ($jobName in $Publish.Keys) {
                $jobUrl = $Publish[$jobName].url.TrimEnd('/')
                $runList = @((Invoke-Jenkins "$jobUrl/api/json?tree=$tree").builds)
                $ok = $runList | Where-Object { $_.result -eq 'SUCCESS' } | Select-Object -First 1
                $running = $runList | Where-Object building | Select-Object -First 1
                $ver = $null; $display = $null
                if ($ok) {
                    $display = Get-DisplayVersion $ok.displayName
                    $ver = if ($VersionParameter) { (($ok.actions | Where-Object { $_.parameters } | Select-Object -First 1).parameters | Where-Object name -eq $VersionParameter).value } else { $null }
                    if (-not $ver) { $ver = $display }
                }
                [pscustomobject]@{
                    job = $jobName; branch = $Publish[$jobName].branch; runs = $runList.Count
                    build = $(if ($ok) { $ok.number } else { $null }); version = $ver; displayVersion = $display
                    when = $(if ($ok) { Format-When $ok.timestamp } else { $null })
                    commit = $(if ($ok) { (Get-Revision $ok).SHA1 } else { $null })
                    cause = $(if ($ok) { ((($ok.actions | Where-Object { $_.causes } | Select-Object -First 1).causes | Select-Object -First 1).shortDescription) } else { $null })
                    url = $(if ($ok) { "$jobUrl/$($ok.number)/" } else { $null })
                    chart = $(if ($ok -and $ChartUrl -and $ver) { $ChartUrl.Replace('{version}', $ver) } else { $null })
                    publishingNow = $(if ($running) { $running.number } else { $null })
                }
            })
        if ($Json) { ConvertTo-Json -InputObject $list -Depth 4; break }
        foreach ($p in $list) {
            if (-not $p.build) { "$($p.job): no successful run in the last $($p.runs)."; continue }
            "$($p.job) ($($p.branch)): #$($p.build) $($p.version) $($p.when) at $($p.commit.Substring(0, 8))"
        }
    }
}
exit 0
