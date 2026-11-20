#Requires -Version 7
<#
.SYNOPSIS
    A fake provider for every contract (board, repo, ci, cd, chat) with fixed data, so the engine can
    be run and tested without any account. Test-Kit.ps1 -Fake uses it; so can whoever writes a new
    provider, to compare shapes.

.DESCRIPTION
    The data is a small invented project, FAKE: tickets FAKE-1 to FAKE-6, a test FAKE-T1, an open pull
    request 7 and a merged one 6, environments qa (1.1.0, upgraded by hand) and staging (1.2.0). The
    git-based answers (merge-commit, a version's commit, the last publish's commit) read the code
    clone (paths.codeRepo), which Test-Kit.ps1 -Fake builds with commits and tags that match:

      v1.0.0  initial
      v1.1.0  FAKE-1
              FAKE-2
      v1.2.0  FAKE-5
              (feature/FAKE-3, not on main) FAKE-3

    Writes (comment, edit-comment, transition) change nothing; they answer as the contract says and
    add a line to the write log in paths.stateDir. link never opens or copies anything and answers
    prefilled false, so the chat skill's fallback is exercised.

.NOTES
    Exit codes as every provider: 0 ok, 1 bad input, 2 missing configuration.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('me', 'view', 'issue', 'comments', 'comment', 'edit-comment', 'transition', 'discover', 'notes',
        'prs', 'checks', 'quality', 'mergeable', 'merge-commit',
        'status', 'stages', 'tail', 'find', 'ping',
        'environments', 'targets', 'commit-of', 'publishes',
        'people', 'link')]
    [string] $Command = 'link',
    [string] $Key,
    [string] $Id,
    [string] $To,
    [string] $Body,
    [string] $BodyFile,
    [string] $CommentId,
    [string] $State = 'open',
    [string] $Commit,
    [string] $Pr,
    [string] $Repo,
    [string] $Project,
    [string] $Target,
    [string] $Clone,
    [string] $Branch,
    [string] $Job,
    [string] $Version,
    [string] $Message,
    [string] $MessageFile,
    [int] $Max = 50,
    [int] $Runs = 8,
    [int] $Days = 180,
    [switch] $NoCommit,
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
if (-not $Clone) { $Clone = Get-KitValue $cfg 'paths.codeRepo' -Path }

function Out-Contract($Value) {
    if ($Json) { ConvertTo-Json -InputObject $Value -Depth 8 } else { $Value | Format-List | Out-String -Width 160 }
}

function Get-Sha([string]$Ref) {
    if (-not $Clone -or -not (Test-Path -LiteralPath (Join-Path $Clone '.git'))) { return $null }
    $ErrorActionPreference = 'Continue'
    $sha = & git -C $Clone rev-parse --verify --quiet "$Ref^{commit}" 2>$null
    if ($sha) { "$sha".Trim() } else { $null }
}

function Get-ShaByMessage([string]$Text) {
    if (-not $Clone -or -not (Test-Path -LiteralPath (Join-Path $Clone '.git'))) { return $null }
    $ErrorActionPreference = 'Continue'
    $line = & git -C $Clone log origin/main --format='%H' --grep $Text 2>$null | Select-Object -First 1
    if ($line) { "$line".Trim() } else { $null }
}

$now = [DateTimeOffset]::Now
$tickets = [ordered]@{
    'FAKE-1' = [pscustomobject]@{ title = 'Single sign-on for the login page'; type = 'Story'; status = 'In Review'; statusCategory = 'inProgress'; assignee = 'Dana Dev'; links = @([pscustomobject]@{ type = 'Tests'; direction = 'inward'; label = 'is tested by'; key = 'FAKE-T1'; kind = 'Test'; status = 'Draft'; statusCategory = 'todo'; title = 'Sign in with the company account' }) }
    'FAKE-2' = [pscustomobject]@{ title = 'Crash when saving an empty form'; type = 'Bug'; status = 'Ready for Test'; statusCategory = 'inProgress'; assignee = 'Dana Dev'; links = @() }
    'FAKE-3' = [pscustomobject]@{ title = 'Monthly report'; type = 'Story'; status = 'In Progress'; statusCategory = 'inProgress'; assignee = 'Fake Person'; links = @() }
    'FAKE-4' = [pscustomobject]@{ title = 'Export button on the list'; type = 'Story'; status = 'Ready for Test'; statusCategory = 'inProgress'; assignee = 'Dana Dev'; links = @([pscustomobject]@{ type = 'Relates'; direction = 'outward'; label = 'relates to'; key = 'FAKE-5'; kind = 'Bug'; status = 'Done'; statusCategory = 'done'; title = 'Export fails with many rows' }) }
    'FAKE-5' = [pscustomobject]@{ title = 'Export fails with many rows'; type = 'Bug'; status = 'Done'; statusCategory = 'done'; assignee = 'Dana Dev'; links = @() }
    'FAKE-6' = [pscustomobject]@{ title = 'Write the user guide'; type = 'Task'; status = 'To Do'; statusCategory = 'todo'; assignee = 'Fake Person'; links = @() }
    'FAKE-T1' = [pscustomobject]@{ title = 'Sign in with the company account'; type = 'Test'; status = 'Draft'; statusCategory = 'todo'; assignee = 'Fake Person'; links = @() }
}
$viewKeys = @('FAKE-1', 'FAKE-2', 'FAKE-3', 'FAKE-4', 'FAKE-6')

function Get-Ticket([string]$TicketKey) {
    $t = $tickets[$TicketKey]
    if (-not $t) { Stop-Kit 1 "The fake board has no ticket $TicketKey." }
    $t
}

function Write-FakeWriteLog([string]$Action, [string]$TargetStatus = '', [string]$NewCommentId = '') {
    $logDir = Get-KitValue $cfg 'paths.stateDir' -Path
    if (-not $logDir) { return }
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $entry = [ordered]@{ at = (Get-Date).ToString('o'); key = $Key; action = $Action; to = $TargetStatus; commentId = $NewCommentId }
    Add-Content -LiteralPath (Join-Path $logDir 'fake-writes.jsonl') -Value ($entry | ConvertTo-Json -Compress) -Encoding utf8
}

function Get-BodyText {
    if ([bool]$Body -eq [bool]$BodyFile) { Stop-Kit 1 'Pass exactly one of -Body or -BodyFile.' }
    $text = if ($BodyFile) { Get-Content -Raw -Encoding utf8 -LiteralPath $BodyFile } else { $Body }
    if (-not "$text".Trim()) { Stop-Kit 1 'The comment is empty.' }
    "$text".Trim()
}

switch ($Command) {
    # --- board -------------------------------------------------------------------------------------
    'me' { Out-Contract ([pscustomobject]@{ id = 'fake-1'; name = 'Fake Person'; email = 'fake.person@example.invalid'; active = $true }) }
    'notes' { "# Fake project notes`n`nTickets FAKE-<n>. Tests are tickets of type Test, linked with ""is tested by""." }
    'view' {
        $views = @(Get-KitValue $cfg 'board.views')
        $v = $views | Where-Object { $_.id -eq $Id } | Select-Object -First 1
        if (-not $v) { Stop-Kit 1 "No saved view '$Id'." }
        $cols = @(if ($v.fields) { $v.fields } else { 'summary', 'status' })
        $rows = @(foreach ($k in $viewKeys) {
                $t = $tickets[$k]
                $row = [ordered]@{ key = $k; link = "fake://board/$k" }
                foreach ($c in $cols) {
                    $row[$c] = switch ($c) {
                        'summary' { $t.title } 'status' { $t.status } 'assignee' { $t.assignee } 'priority' { 'Medium' }
                        'updated' { $now.AddDays(-1).ToString('o') } 'created' { $now.AddDays(-20).ToString('o') } default { '' }
                    }
                }
                if ($cols -contains 'status') { $row.statusCategory = $t.statusCategory }
                [pscustomobject]$row
            })
        Out-Contract ([pscustomobject]@{ id = $v.id; title = $v.title; more = $false; issues = $rows })
    }
    'issue' {
        $t = Get-Ticket $Key
        Out-Contract ([pscustomobject]@{
                key = $Key; link = "fake://board/$Key"; title = $t.title; type = $t.type; status = $t.status; statusCategory = $t.statusCategory
                priority = 'Medium'; assignee = $t.assignee; reporter = 'Fake Person'; labels = @(); parent = $null
                updated = $now.AddDays(-1).ToString('o'); created = $now.AddDays(-20).ToString('o'); comments = 0; description = ''; links = @($t.links)
            })
    }
    'comments' { $null = Get-Ticket $Key; Out-Contract @() }
    'comment' {
        $null = Get-Ticket $Key; $null = Get-BodyText
        Write-FakeWriteLog 'comment' '' 'fake-c1'
        Out-Contract ([pscustomobject]@{ id = 'fake-c1'; key = $Key; link = "fake://board/$Key#fake-c1"; duplicate = $false })
    }
    'edit-comment' {
        $null = Get-Ticket $Key; $null = Get-BodyText
        Write-FakeWriteLog 'edit-comment' '' $CommentId
        Out-Contract ([pscustomobject]@{ id = $CommentId; key = $Key; link = "fake://board/$Key#$CommentId"; changed = $true })
    }
    'transition' {
        $t = Get-Ticket $Key
        if (-not $To) { Stop-Kit 1 'transition needs -To.' }
        if ($t.status -ieq $To) { Stop-Kit 1 "$Key is already in '$($t.status)'; nothing changed." }
        Write-FakeWriteLog 'transition' $To
        Out-Contract ([pscustomobject]@{ key = $Key; from = $t.status; to = $To; transition = "Move to $To"; comment = $null; commentDuplicate = $false })
    }
    'discover' {
        Out-Contract ([pscustomobject]@{
                me = [pscustomobject]@{ id = 'fake-1'; name = 'Fake Person'; email = 'fake.person@example.invalid' }
                accountId = 'fake-1'; days = $Days
                projects = @([pscustomobject]@{
                        key = 'FAKE'; name = 'Fake project'
                        types = @([pscustomobject]@{ name = 'Story'; count = 3 }, [pscustomobject]@{ name = 'Bug'; count = 2 }, [pscustomobject]@{ name = 'Test'; count = 1 })
                        statuses = @('To Do|todo', 'In Progress|inProgress', 'In Review|inProgress', 'Ready for Test|inProgress', 'Done|done' | ForEach-Object { $s = $_ -split '\|'; [pscustomobject]@{ name = $s[0]; category = $s[1] } })
                        boards = @([pscustomobject]@{ id = 1; name = 'Fake board'; type = 'scrum' })
                    })
            })
    }

    # --- repo --------------------------------------------------------------------------------------
    'prs' {
        $list = if ($State -eq 'merged') {
            @([pscustomobject]@{ id = 6; title = 'FAKE-2 Crash when saving an empty form'; link = 'fake://repo/pull/6'; repo = 'demo'; project = 'DEMO'; primary = $true; source = 'fix/FAKE-2-save-crash'; target = 'main'; latestCommit = (Get-ShaByMessage 'FAKE-2'); reviewers = @([pscustomobject]@{ name = 'Robin Reviewer'; state = 'approved' }); closedAt = $now.AddDays(-1).ToString('o') })
        }
        else {
            @([pscustomobject]@{ id = 7; title = 'FAKE-3 Monthly report'; link = 'fake://repo/pull/7'; repo = 'demo'; project = 'DEMO'; primary = $true; source = 'feature/FAKE-3-monthly-report'; target = 'main'; latestCommit = (Get-Sha 'origin/feature/FAKE-3-monthly-report'); reviewers = @([pscustomobject]@{ name = 'Robin Reviewer'; state = 'needsWork' }); closedAt = $null })
        }
        Out-Contract @($list)
    }
    'checks' { Out-Contract @([pscustomobject]@{ key = 'demo/PR-7'; state = 'failed'; url = 'fake://ci/job/PR-7/3/display/redirect'; build = '3'; pullRequestBuild = $true }) }
    'quality' { Out-Contract ([pscustomobject]@{ result = 'fail'; name = 'Quality'; link = 'fake://quality/demo'; details = @('Coverage 41% is below 80%') }) }
    'mergeable' { Out-Contract ([pscustomobject]@{ conflicted = $false; vetoes = @() }) }
    'merge-commit' {
        $sha = if ($Pr -eq '6') { Get-ShaByMessage 'FAKE-2' } else { $null }
        Out-Contract ([pscustomobject]@{ pr = [int]$Pr; commit = $sha; target = $(if ($sha) { 'main' } else { $null }); subject = $(if ($sha) { 'FAKE-2 save crash' } else { $null }) })
    }

    # --- ci ----------------------------------------------------------------------------------------
    'ping' { Out-Contract ([pscustomobject]@{ reachable = $true; root = 'fake://ci' }) }
    'status' {
        Out-Contract ([pscustomobject]@{
                target = $(if ($Pr) { "PR-$Pr" } elseif ($Branch) { $Branch } else { 'main' }); build = 3; result = 'FAILURE'; started = $now.AddHours(-2).ToString('yyyy-MM-dd HH:mm'); minutes = 12.5
                commit = (Get-Sha 'origin/feature/FAKE-3-monthly-report'); cause = 'Branch event'; version = $null
                stages = @([pscustomobject]@{ name = 'Build'; status = 'SUCCESS'; minutes = 4.1 }, [pscustomobject]@{ name = 'Test'; status = 'FAILED'; minutes = 8.4 })
                quickFailure = $null; link = 'fake://ci/job/PR-7/3/'
            })
    }
    'stages' { '  SUCCESS        4.1 min  Build'; '  FAILED         8.4 min  Test' }
    'tail' { 'Tests run: 120, Failures: 1'; 'FAILED: ReportTests.MonthTotals' }
    'find' { Out-Contract @([pscustomobject]@{ job = 'PR-7'; open = $true; result = 'FAILURE'; title = 'FAKE-3 Monthly report (#7)' }) }

    # --- cd ----------------------------------------------------------------------------------------
    'targets' { Out-Contract ([pscustomobject]@{ branches = @('main'); note = 'Staging takes every release; qa is upgraded by hand.' }) }
    'environments' {
        Out-Contract @(
            [pscustomobject]@{ name = 'qa'; version = '1.1.0'; branch = 'main'; upgrade = 'manual'; source = [pscustomobject]@{ kind = 'deploy-log'; ref = '42'; at = $now.AddHours(-3).ToString('o') }; commit = $(if ($NoCommit) { $null } else { Get-Sha 'refs/tags/v1.1.0' }) }
            [pscustomobject]@{ name = 'staging'; version = '1.2.0'; branch = 'main'; upgrade = 'auto'; source = [pscustomobject]@{ kind = 'live'; ref = 'fake://staging'; at = $null }; commit = $(if ($NoCommit) { $null } else { Get-Sha 'refs/tags/v1.2.0' }) }
        )
    }
    'commit-of' { Out-Contract ([pscustomobject]@{ version = $Version; commit = (Get-Sha "refs/tags/v$Version") }) }
    'publishes' {
        Out-Contract @([pscustomobject]@{
                job = 'release'; branch = 'main'; runs = $Runs; build = 12; version = '1.2.0'; displayVersion = '1.2.0'; when = $now.AddHours(-4).ToString('yyyy-MM-dd HH:mm')
                commit = (Get-Sha 'refs/tags/v1.2.0'); cause = 'Timer'; url = 'fake://ci/job/release/12/'; chart = $null; publishingNow = $null
            })
    }

    # --- chat --------------------------------------------------------------------------------------
    'people' {
        Out-Contract ([pscustomobject]@{
                teamFile = 'fake'; myFile = $null
                people = @(
                    [pscustomobject]@{ alias = 'dana'; email = 'dana.dev@example.invalid'; language = 'English'; askedAbout = 'the code of FAKE tickets'; you = $false; source = 'team' }
                    [pscustomobject]@{ alias = 'fake'; email = 'fake.person@example.invalid'; language = 'English'; askedAbout = 'tests'; you = $true; source = 'team' }
                )
            })
    }
    'link' {
        if (-not $To) { Stop-Kit 1 'link needs -To <alias or e-mail>.' }
        if ([bool]$Message -eq [bool]$MessageFile) { Stop-Kit 1 'Pass exactly one of -Message or -MessageFile.' }
        $email = if ($To -eq 'dana') { 'dana.dev@example.invalid' } elseif ($To -match '@') { $To } else { Stop-Kit 1 "'$To' is not an e-mail address or a known alias (dana)." }
        Out-Contract ([pscustomobject]@{ to = $To; email = $email; prefilled = $false; opened = $false; copied = $false; length = 0; warning = $null; url = "fake://chat/$To" })
    }
}
exit 0
