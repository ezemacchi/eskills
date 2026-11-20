<#
.SYNOPSIS
    Reads Jira with the user's own API token. The only writes are adding or editing the user's own
    comment and moving an issue to another status; it never creates issues or edits their fields.

.DESCRIPTION
    Every value (site, API address, project, board, field ids, credential variable names, comment
    signature, saved views) comes from the kit configuration (/setup). The token is read from the
    variable the configuration names, from the process or the user's variables, and is never printed,
    echoed, or put on a command line.

    Commands:
      me                       who the token belongs to
      search -Jql <jql>        issues; -Fields lists the columns (default summary,status,priority)
      view -Id <id>            runs a saved view (board.views in the configuration; its query is
                               JQL); no -Id lists them
      issue -Key <KEY>         one issue: fields, story points, sprint, epic, links, description.
                               Linked tests are listed first.
      comments -Key <KEY>      every comment, oldest first
      changelog -Key <KEY>     the full history, oldest first
      transitions -Key <KEY>   the moves Jira offers from the current status (lists only)
      sprints                  active and future sprints of the board
      user -Query <email|name> accountId and name, for mentioning someone as [~accountid:<id>]
      footprint [-Days <n>] [-AccountId <id>]
                               what the person works on: issues as assignee and as reporter,
                               counted by project, type and status
      statuses [-Project <P>]  the statuses of each issue type in the project
      boards [-Project <P>]    the boards of the project
      discover [-Days <n>]     for /setup: who the token is, and each project the person worked in
                               (plus the configured one) with its issue types counted, its statuses
                               and their category (todo, inProgress, done), and its boards
      notes                    prints the team's project notes (shipped with the kit), then the
                               user's own (paths.myNotes) when that file exists
      comment -Key <KEY> -BodyFile <path> | -Body <text>
                               adds one comment, signed on a line of its own at the end. Refuses
                               when the issue already has that exact comment.
      edit-comment -Key <KEY> -CommentId <id> -BodyFile <path> | -Body <text>
                               replaces the text of one of the token owner's own comments.
      transition -Key <KEY> -To <status> [-BodyFile <path> | -Body <text>]
                               moves the issue to that status. The move is chosen by the status it
                               leads to (what follows -> in transitions), not by its name; it refuses
                               when no move or several moves lead there, when the only one is an
                               "(admin)" move, or when the issue is already in that status. With a
                               body, posts it as a signed comment after the move. A field Jira
                               requires for the move is reported with Jira's own message.

    Every successful write (comment, edit-comment, transition) adds one line to the local log
    paths.stateDir\<providers.jira-cloud.writeLog>: time, ticket, action, target status and comment id.

    -Json prints the board contract's shape (docs/contracts/board.md in the kit) for me, view, issue,
    comments, comment, edit-comment, transition and discover; other skills read only that. -Raw
    prints Jira's own JSON for me, search, issue, comments, changelog, transitions, sprints, user,
    statuses, boards, comment and edit-comment, for a field the contract leaves out. search,
    changelog, transitions, sprints, user, statuses and boards are Jira's own commands: their -Json is
    Jira's JSON too.

.NOTES
    Exit codes: 0 ok, 1 bad input or unexpected answer, 2 missing configuration or credentials,
    3 cannot reach Jira (VPN?) or the account was refused.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('me', 'search', 'view', 'issue', 'comments', 'changelog', 'transitions', 'sprints', 'user', 'footprint', 'statuses', 'boards', 'discover', 'notes', 'comment', 'edit-comment', 'transition')]
    [string] $Command,
    [string] $Key,
    [string] $To,
    [string] $Id,
    [string] $CommentId,
    [string] $Query,
    [string] $Body,
    [string] $BodyFile,
    [string] $Jql,
    [string] $Fields = 'summary,status,priority',
    [int] $Max = 50,
    [int] $Days = 180,
    [string] $AccountId,
    [string] $Project,
    [string] $ApiBase,
    [switch] $Json,
    [switch] $Raw
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
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            $script:kitName = (Get-Content -Raw -LiteralPath $marker).Trim()
            $script:kitSkillsRoot = Split-Path -Parent $dir
            return $script:kitName
        }
        $up = Split-Path -Parent $dir
        if ($up -eq $dir) { break }
        $dir = $up
    }
    Stop-Kit 2 "No .kit file in a folder above $PSScriptRoot. Reinstall the kit."
}

# The folder that holds the installed skills: the parent of the skill whose .kit names the kit.
function Get-KitSkillsRoot { [void](Get-KitName); $script:kitSkillsRoot }

function Get-KitVarPrefix { (Get-KitName).ToUpperInvariant() -replace '[^A-Z0-9]', '_' }

# Windows only for now: Get-KitRoot, Get-KitEnv and Set-KitEnv are what a macOS or Linux port changes.
# The kit's folder for the person: %LOCALAPPDATA%\<kit name>, or the folder in <KIT>_HOME.
function Get-KitRoot {
    $over = [Environment]::GetEnvironmentVariable((Get-KitVarPrefix) + '_HOME', 'Process')
    if ($over) { return $over }
    Join-Path $env:LOCALAPPDATA (Get-KitName)
}

# Read from the process first, then from the user's own: a program started before the variable was set does not have it.
function Get-KitEnv([string]$Name, [switch]$Saved) {
    if (-not $Name) { return $null }
    if ($Saved) { return [Environment]::GetEnvironmentVariable($Name, 'User') }
    $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'User') }
    $v
}

function Set-KitEnv([string]$Name, [string]$Value) { [Environment]::SetEnvironmentVariable($Name, $Value, 'User') }

function Get-KitConfigVar { (Get-KitVarPrefix) + '_CONFIG' }

# The project pack in use, among those installed in setup\packs: the one <KIT>_PACK names; else the one
# whose repositories (repos[].name) include the git repository of the current folder; else the person's
# default (defaultPack in settings.json, in the kit's folder); else the only one. $null without packs.
# When several are installed and none of that applies it stops, unless -Quiet (then $null).
function Get-KitPack([switch]$Quiet) {
    if (-not $script:kitPackKnown) {
        $script:kitPackKnown = $true
        $script:kitPack = $null
        $script:kitPackFrom = 'none'
        $packsDir = Join-Path (Get-KitSkillsRoot) 'setup\packs'
        $script:kitPacks = @(Get-ChildItem -LiteralPath $packsDir -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'pack.json') -PathType Leaf } | ForEach-Object { $_.Name })
        if ($script:kitPacks.Count) {
            $forced = [Environment]::GetEnvironmentVariable((Get-KitVarPrefix) + '_PACK', 'Process')
            $origin = ''
            if (-not $forced) {
                $here = try { $PWD.ProviderPath } catch { '' }
                if ($here) { $origin = "$(& git -C $here remote get-url origin 2>$null)".Trim() }
            }
            $settingsFile = Join-Path (Get-KitRoot) 'settings.json'
            $default = if (Test-Path -LiteralPath $settingsFile -PathType Leaf) { try { [string](Get-Content -Raw -Encoding utf8 -LiteralPath $settingsFile | ConvertFrom-Json).defaultPack } catch { '' } } else { '' }
            if ($forced) {
                if ($forced -notin $script:kitPacks) { Stop-Kit 2 "$((Get-KitVarPrefix) + '_PACK') names '$forced', which is not installed ($($script:kitPacks -join ', '))." }
                $script:kitPack = $forced; $script:kitPackFrom = 'variable'
            }
            if (-not $script:kitPack -and $origin) {
                foreach ($name in $script:kitPacks) {
                    $packValues = try { Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $packsDir "$name\pack.json") | ConvertFrom-Json } catch { $null }
                    $mine = @($packValues.repos | Where-Object { $_ -and $_.name -and $origin -match "[/:]$([regex]::Escape([string]$_.name))(\.git)?/?$" })
                    if ($mine.Count) { $script:kitPack = $name; $script:kitPackFrom = 'repository'; break }
                }
            }
            if (-not $script:kitPack -and $default -and $default -in $script:kitPacks) { $script:kitPack = $default; $script:kitPackFrom = 'default' }
            if (-not $script:kitPack -and $script:kitPacks.Count -eq 1) { $script:kitPack = $script:kitPacks[0]; $script:kitPackFrom = 'only' }
            if (-not $script:kitPack) { $script:kitPackFrom = 'unchosen' }
        }
    }
    if ($script:kitPackFrom -eq 'unchosen' -and -not $Quiet) {
        Stop-Kit 2 "This folder is not in a repository of any installed project ($($script:kitPacks -join ', ')) and no default is chosen. Work from a project's repository, or choose a default with /setup."
    }
    $script:kitPack
}

# The person's files for the project in use: <kit folder>\<pack>, or the kit folder without packs.
# With -Quiet, $null while the project is not chosen.
function Get-KitHome([switch]$Quiet) {
    $pack = Get-KitPack -Quiet:$Quiet
    if ($pack) { return Join-Path (Get-KitRoot) $pack }
    if ($script:kitPackFrom -eq 'unchosen') { return $null }
    Get-KitRoot
}

function Get-KitConfigPath([switch]$Quiet) {
    $override = [Environment]::GetEnvironmentVariable((Get-KitConfigVar), 'Process')
    if ($override) { return $override }
    $folder = Get-KitHome -Quiet:$Quiet
    if (-not $folder) { return $null }
    Join-Path $folder 'config.json'
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
$ProviderKey = 'providers.jira-cloud'
$Site = ([string](Get-KitValue $cfg "$ProviderKey.site" -Required)).TrimEnd('/')
if (-not $ApiBase) { $ApiBase = Get-KitValue $cfg "$ProviderKey.apiBase" -Required }
$ApiBase = $ApiBase.TrimEnd('/')
$EmailVar = Get-KitValue $cfg "$ProviderKey.emailVar" -Required
$TokenVar = Get-KitValue $cfg "$ProviderKey.tokenVar" -Required
$Board = Get-KitValue $cfg "$ProviderKey.board"
$TestType = Get-KitValue $cfg 'board.testIssueType'
$Signature = [string](Get-KitValue $cfg 'board.commentSignature')
$FieldIds = Get-KitValue $cfg "$ProviderKey.fields" -Required
if (-not $Project) { $Project = Get-KitValue $cfg "$ProviderKey.project" }

if ($Site -notmatch '^https://[^/\s]+$') { Stop-Kit 1 "$ProviderKey.site '$Site' is not an https address." }
if ($ApiBase -notmatch '^https://[^\s]+$') { Stop-Kit 1 "API address '$ApiBase' is not an https address." }

if ($Command -eq 'notes') {
    $team = Get-KitTeamFile $cfg (Get-KitValue $cfg 'kit.teamNotes' -Required)
    if (-not (Test-Path -LiteralPath $team)) { Stop-Kit 2 "The kit's project notes are missing: $team. Reinstall the kit." }
    Get-Content -Raw -Encoding utf8 -LiteralPath $team
    $mine = Get-KitValue $cfg 'paths.myNotes' -Path
    if ($mine -and (Test-Path -LiteralPath $mine)) {
        "`n# My notes ($mine)`n"
        Get-Content -Raw -Encoding utf8 -LiteralPath $mine
    }
    exit 0
}

$email = Get-KitEnv $EmailVar
$token = Get-KitEnv $TokenVar
if (-not $email -or -not $token) {
    Stop-Kit 2 "No Jira credentials: set the user variables $EmailVar (the account's e-mail) and $TokenVar (an Atlassian API token). /setup explains how."
}
if ($Command -in 'issue', 'comments', 'changelog', 'transitions', 'comment', 'edit-comment', 'transition') {
    if ($Key -notmatch '^[A-Z][A-Z0-9]+-\d+$') { Stop-Kit 1 "-Key must look like PROJ-123, got '$Key'." }
}
if ($Command -eq 'transition') {
    $To = "$To".Trim()
    if (-not $To) { Stop-Kit 1 'transition needs -To: the status to move to, as transitions shows it after ->.' }
    if ($Body -and $BodyFile) { Stop-Kit 1 'transition takes -Body or -BodyFile, not both.' }
}
if ($Command -eq 'search' -and -not $Jql) { Stop-Kit 1 'search needs -Jql.' }
if ($Command -eq 'user' -and -not $Query) { Stop-Kit 1 'user needs -Query (an e-mail or a name).' }
if (($Command -in @('statuses', 'boards')) -and -not $Project) { Stop-Kit 1 "$Command needs -Project, or $ProviderKey.project in the configuration." }
if ($Command -eq 'sprints' -and -not $Board) { Stop-Kit 2 "sprints needs $ProviderKey.board in the configuration." }
if ($Command -eq 'edit-comment' -and $CommentId -notmatch '^\d+$') { Stop-Kit 1 "-CommentId must be the comment's number, got '$CommentId'." }
if (($Command -in @('comment', 'edit-comment')) -or ($Command -eq 'transition' -and ($Body -or $BodyFile))) {
    if ([bool]$Body -eq [bool]$BodyFile) { Stop-Kit 1 'comment needs exactly one of -Body or -BodyFile.' }
    if ($BodyFile) {
        if (-not (Test-Path -LiteralPath $BodyFile -PathType Leaf)) { Stop-Kit 1 "No such file: $BodyFile" }
        $Body = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $BodyFile).Path, [Text.Encoding]::UTF8)
    }
    $Body = $Body.Trim()
    if (-not $Body) { Stop-Kit 1 'The comment is empty.' }
    if ($Signature) {
        $Body = ($Body -replace "\s*$([regex]::Escape($Signature))$", '').TrimEnd()
        if (-not $Body) { Stop-Kit 1 'The comment is empty.' }
        $Body = "$Body`n$Signature"
    }
}
$Max = [Math]::Min([Math]::Max($Max, 1), 1000)

$authHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${email}:${token}"))
$hasRespHeadersVar = (Get-Command Invoke-RestMethod).Parameters.ContainsKey('ResponseHeadersVariable')

function Get-HeaderValue($Headers, [string]$Name) {
    if ($null -eq $Headers) { return $null }
    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($k in $Headers.Keys) {
            if ($k -ieq $Name) { return ($Headers[$k] -join ',') }
        }
        return $null
    }
    $vals = $null
    if ($Headers.PSObject.Methods['TryGetValues'] -and $Headers.TryGetValues($Name, [ref]$vals)) {
        return ($vals -join ',')
    }
    try { return [string]$Headers[$Name] } catch { return $null }
}

# Jira's own explanation from an error answer: errorMessages plus one "field: message" per field.
function Get-JiraErrorText($ErrorRecord) {
    $detail = if ($ErrorRecord.ErrorDetails) { [string]$ErrorRecord.ErrorDetails.Message }
    if (-not $detail) { return $null }
    try { $parsed = $detail | ConvertFrom-Json } catch { return $null }
    $parts = [Collections.Generic.List[string]]::new()
    if ($parsed.PSObject.Properties['errorMessages']) { foreach ($m in @($parsed.errorMessages)) { if ($m) { $parts.Add([string]$m) } } }
    if ($parsed.PSObject.Properties['errors'] -and $parsed.errors) {
        foreach ($p in $parsed.errors.PSObject.Properties) { $parts.Add("$($p.Name): $($p.Value)") }
    }
    if (-not $parts.Count) { return $null }
    $parts -join ' | '
}

# One JSON line per successful write. The write already happened, so a log failure only warns.
function Write-JiraWriteLog([string]$Action, [string]$TargetStatus = '', [string]$NewCommentId = '') {
    try {
        $logDir = Get-KitValue $cfg 'paths.stateDir' -Path
        $logName = [string](Get-KitValue $cfg "$ProviderKey.writeLog")
        if (-not $logDir -or -not $logName) { return }
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        $entry = [ordered]@{ at = (Get-Date).ToString('o'); key = $Key; action = $Action; to = $TargetStatus; commentId = $NewCommentId }
        Add-Content -LiteralPath (Join-Path $logDir $logName) -Value ($entry | ConvertTo-Json -Compress) -Encoding utf8
    }
    catch { [Console]::Error.WriteLine("Done in Jira, but the local write log could not be updated: $($_.Exception.Message)") }
}

function Invoke-Api([string]$Method, [string]$Path, $Payload = $null) {
    $reqHeaders = @{
        Authorization = $authHeader
        Accept        = 'application/json'
    }
    $rh = $null
    $args = @{ Uri = "$ApiBase$Path"; Method = $Method; Headers = $reqHeaders; TimeoutSec = 30 }
    if ($hasRespHeadersVar) { $args.ResponseHeadersVariable = 'rh' }
    if ($null -ne $Payload) {
        $args.Body = [Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 6))
        $args.ContentType = 'application/json; charset=utf-8'
    }
    try {
        $res = Invoke-RestMethod @args
    } catch {
        $code = 0
        $loginReason = $null
        $jiraSays = Get-JiraErrorText $_
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            $loginReason = Get-HeaderValue $_.Exception.Response.Headers 'X-Seraph-LoginReason'
        }
        # Only the status goes into the message: never the request, which carries the token.
        if ($loginReason -match 'AUTHENTICATED_FAILED|AUTHENTICATION_DENIED') {
            Stop-Kit 3 "Jira refused the account in $EmailVar / $TokenVar (401)."
        }
        if ($code -in 401, 403) { Stop-Kit 3 "Jira refused the account in $EmailVar / $TokenVar ($code)." }
        $where = ($Path -split '\?')[0]
        if ($code -eq 404) { Stop-Kit 1 "Jira has no such item ($where)." }
        if ($code -eq 400) { Stop-Kit 1 "Jira rejected the request ($where): check the JQL or the parameters.$(if ($jiraSays) { " Jira says: $jiraSays" })" }
        if ($code -gt 0) { Stop-Kit 1 "Unexpected answer from Jira ($code) for $where." }
        Stop-Kit 3 'Cannot reach Jira (VPN?).'
    }
    if ((Get-HeaderValue $rh 'X-Seraph-LoginReason') -match 'AUTHENTICATED_FAILED|AUTHENTICATION_DENIED') {
        Stop-Kit 3 "Jira refused the account in $EmailVar / $TokenVar (401)."
    }
    $res
}

# Posts $Body as a comment on $Key unless the issue already has that exact text, so a retried run
# never posts it twice. Returns the comment (the new one, or the one already there) and which.
function Add-JiraComment {
    $existing = @(); $at = 0
    do {
        $page = Invoke-Api GET "/rest/api/2/issue/$Key/comment?startAt=$at&maxResults=100"
        if ($null -eq $page -or -not $page.PSObject.Properties['comments']) {
            Stop-Kit 1 "Unexpected answer from Jira for /rest/api/2/issue/$Key/comment."
        }
        $existing += @($page.comments); $at += @($page.comments).Count
    } while ($at -lt $page.total -and @($page.comments).Count -gt 0)
    $norm = {
        param($t)
        $t = ([string]$t -replace '\r\n', "`n").Trim()
        if ($Signature) { $t = ($t -replace "\s*$([regex]::Escape($Signature))$", '').TrimEnd() }
        $t
    }
    $dup = $existing | Where-Object { (& $norm $_.body) -eq (& $norm $Body) } | Select-Object -First 1
    if ($dup) { return [pscustomobject]@{ comment = $dup; duplicate = $true } }
    [pscustomobject]@{ comment = (Invoke-Api POST "/rest/api/2/issue/$Key/comment" @{ body = $Body }); duplicate = $false }
}

function Out-Value($v) {
    if ($null -eq $v) { return '' }
    if ($v -is [array]) { return (($v | ForEach-Object { Out-Value $_ }) -join ', ') }
    if ($v.PSObject.Properties['name'] -and $v.name) { return [string]$v.name }
    if ($v.PSObject.Properties['displayName'] -and $v.displayName) { return [string]$v.displayName }
    [string]$v
}

# Jira's status category keys (new, indeterminate, done) as the board contract's todo, inProgress, done.
function ConvertTo-StatusCategory($Status) {
    switch ([string]$Status.statusCategory.key) {
        'new' { return 'todo' }
        'indeterminate' { return 'inProgress' }
        'done' { return 'done' }
    }
    $null
}

function Get-IssueLinks($Fields) {
    foreach ($l in @($Fields.issuelinks | Where-Object { $_ })) {
        $outward = [bool]$l.outwardIssue
        $o = if ($outward) { $l.outwardIssue } else { $l.inwardIssue }
        [pscustomobject]@{
            type = [string]$l.type.name; direction = $(if ($outward) { 'outward' } else { 'inward' })
            label = [string]$(if ($outward) { $l.type.outward } else { $l.type.inward })
            key = [string]$o.key; kind = [string]$o.fields.issuetype.name; status = [string]$o.fields.status.name
            statusCategory = (ConvertTo-StatusCategory $o.fields.status); title = [string]$o.fields.summary
        }
    }
}

function ConvertTo-Comment($C) {
    [pscustomobject]@{ id = [string]$C.id; author = [string]$C.author.displayName; created = [string]$C.created; updated = [string]$C.updated; body = [string]$C.body }
}

function Search-Issues([string]$JqlText, [string[]]$Columns, [int]$Limit) {
    $found = [Collections.Generic.List[object]]::new(); $next = $null
    do {
        $req = @{ jql = $JqlText; fields = $Columns; maxResults = [Math]::Min($Limit - $found.Count, 100) }
        if ($next) { $req.nextPageToken = $next }
        $page = Invoke-Api POST '/rest/api/3/search/jql' $req
        if ($null -eq $page -or -not $page.PSObject.Properties['issues']) {
            Stop-Kit 1 'Unexpected answer from Jira for /rest/api/3/search/jql.'
        }
        foreach ($i in @($page.issues)) { $found.Add($i) }
        $next = $page.nextPageToken
    } while ($next -and $found.Count -lt $Limit)
    [pscustomobject]@{ Issues = $found.ToArray(); More = [bool]$next }
}

function Write-Issues($Result, [string[]]$Columns) {
    if ($Result.Issues.Count -eq 0) { 'No issues.'; return }
    foreach ($i in $Result.Issues) {
        $cells = foreach ($c in $Columns) { Out-Value $i.fields.$c }
        "$($i.key) | " + ($cells -join ' | ')
    }
    if ($Result.More) { "(more than $($Result.Issues.Count); raise -Max or narrow the JQL)" }
}

# {project} and {me} in a saved view's JQL. {me} is the configured account, so a view reads the same
# person's work whoever's token runs it; without one it is the token's owner.
function Expand-Jql([string]$Text) {
    $me = Get-KitValue $cfg 'user.boardAccountId'
    $meJql = if ($me) { "'$me'" } else { 'currentUser()' }
    $Text.Replace('{project}', [string]$Project).Replace('{me}', $meJql).Replace('{board}', [string]$Board)
}

switch ($Command) {
    'me' {
        $me = Invoke-Api GET '/rest/api/3/myself'
        if ($null -eq $me -or -not $me.PSObject.Properties['accountId']) { Stop-Kit 1 'Unexpected answer from Jira for /rest/api/3/myself.' }
        if ($Raw) { $me | ConvertTo-Json -Depth 4; break }
        if ($Json) { [pscustomobject]@{ id = [string]$me.accountId; name = [string]$me.displayName; email = [string]$me.emailAddress; active = [bool]$me.active } | ConvertTo-Json; break }
        "$($me.displayName) | $($me.emailAddress) | accountId $($me.accountId) | active $($me.active)"
    }

    'search' {
        $cols = @($Fields -split '\s*,\s*' | Where-Object { $_ })
        $r = Search-Issues $Jql $cols $Max
        if ($Json -or $Raw) { ConvertTo-Json -InputObject $r.Issues -Depth 8; break }
        Write-Issues $r $cols
    }

    'view' {
        $views = @(Get-KitValue $cfg 'board.views')
        if (-not $Id) {
            if (-not $views.Count) { 'No saved views. /setup proposes them.'; break }
            if ($Json) { ConvertTo-Json -InputObject $views -Depth 6; break }
            foreach ($v in $views) { "$($v.id) | $($v.title)" }
            break
        }
        $v = $views | Where-Object { $_.id -eq $Id } | Select-Object -First 1
        if (-not $v) { Stop-Kit 1 "No saved view '$Id'. Saved: $((@($views | ForEach-Object { $_.id })) -join ', ')." }
        $cols = @($v.fields)
        if (-not $cols.Count) { $cols = @('summary', 'status') }
        $limit = if ($v.max) { [int]$v.max } else { $Max }
        $viewJql = Expand-Jql $(if ($v.query) { $v.query } else { $v.jql })
        $r = Search-Issues $viewJql $cols $limit
        if ($Json) {
            [pscustomobject]@{
                id = $v.id; title = $v.title; jql = $viewJql; more = $r.More
                qaCheckStatuses = @($v.qaCheckStatuses)
                issues = @($r.Issues | ForEach-Object {
                        $i = $_
                        $row = [ordered]@{ key = $i.key; link = "$Site/browse/$($i.key)" }
                        foreach ($c in $cols) { $row[$c] = Out-Value $i.fields.$c }
                        if ($cols -contains 'status') { $row.statusCategory = ConvertTo-StatusCategory $i.fields.status }
                        [pscustomobject]$row
                    })
            } | ConvertTo-Json -Depth 6
            break
        }
        "$($v.title)"
        Write-Issues $r $cols
    }

    'issue' {
        $want = @('summary', 'status', 'issuetype', 'priority', 'assignee', 'reporter', 'labels', 'components', 'fixVersions', 'parent', 'description', 'issuelinks', 'comment', 'updated', 'created') +
            @($FieldIds.storyPoints, $FieldIds.sprint, $FieldIds.initialEstimation, $FieldIds.epicLink | Where-Object { $_ })
        $i = Invoke-Api GET "/rest/api/2/issue/$Key`?fields=$($want -join ',')"
        if ($null -eq $i -or -not $i.PSObject.Properties['fields']) {
            Stop-Kit 1 "Unexpected answer from Jira for /rest/api/2/issue/$Key."
        }
        if ($Raw) { $i | ConvertTo-Json -Depth 10; break }
        $f = $i.fields
        if ($Json) {
            [pscustomobject]@{
                key = [string]$i.key; link = "$Site/browse/$($i.key)"; title = [string]$f.summary; type = (Out-Value $f.issuetype)
                status = (Out-Value $f.status); statusCategory = (ConvertTo-StatusCategory $f.status); priority = (Out-Value $f.priority)
                assignee = (Out-Value $f.assignee); reporter = (Out-Value $f.reporter); labels = @($f.labels | Where-Object { $_ })
                parent = $(if ($f.parent) { [string]$f.parent.key } else { $null })
                updated = [string]$f.updated; created = [string]$f.created; comments = [int]$f.comment.total
                description = [string]$f.description; links = @(Get-IssueLinks $f)
            } | ConvertTo-Json -Depth 6
            break
        }
        "$($i.key) | $(Out-Value $f.issuetype) | $(Out-Value $f.status) | priority $(Out-Value $f.priority)"
        "Summary: $($f.summary)"
        "Link: $Site/browse/$($i.key)"
        "Assignee: $(Out-Value $f.assignee)   Reporter: $(Out-Value $f.reporter)"
        if ($f.parent) { "Epic/parent: $($f.parent.key) $($f.parent.fields.summary)" }
        elseif ($FieldIds.epicLink -and $f.($FieldIds.epicLink)) { "Epic: $($f.($FieldIds.epicLink))" }
        if ($FieldIds.sprint) {
            $sprint = @($f.($FieldIds.sprint) | ForEach-Object { "$($_.name) ($($_.state))" }) -join ', '
            "Sprint: $sprint"
        }
        $points = if ($FieldIds.storyPoints) { $f.($FieldIds.storyPoints) } else { $null }
        $initial = if ($FieldIds.initialEstimation) { $f.($FieldIds.initialEstimation) } else { $null }
        "Story points: $points   Initial estimation: $initial"
        "Labels: $(Out-Value $f.labels)"
        "Components: $(Out-Value $f.components)   Fix versions: $(Out-Value $f.fixVersions)"
        "Comments: $($f.comment.total)  (use the comments command to read them)"

        $links = @(Get-IssueLinks $f)
        $tests = @($links | Where-Object { $TestType -and $_.kind -eq $TestType })
        $others = @($links | Where-Object { -not ($TestType -and $_.kind -eq $TestType) })
        if ($tests.Count) {
            ''; "Linked tests ($($tests.Count)):"
            $tests | ForEach-Object { "  $($_.key) [$($_.status)] $($_.title)" }
        }
        if ($others.Count) {
            ''; 'Other links:'
            $others | ForEach-Object { "  $($_.label): $($_.key) ($($_.kind), $($_.status)) $($_.title)" }
        }
        ''; 'Description:'
        if ($f.description) { $f.description } else { '(none)' }
    }

    'comments' {
        $all = @(); $at = 0
        do {
            $page = Invoke-Api GET "/rest/api/2/issue/$Key/comment?orderBy=created&startAt=$at&maxResults=100"
            if ($null -eq $page -or -not $page.PSObject.Properties['comments']) {
                Stop-Kit 1 "Unexpected answer from Jira for /rest/api/2/issue/$Key/comment."
            }
            $all += @($page.comments); $at += @($page.comments).Count
        } while ($at -lt $page.total -and @($page.comments).Count -gt 0)
        if ($Raw) { ConvertTo-Json -InputObject $all -Depth 6; break }
        if ($Json) { ConvertTo-Json -InputObject @($all | ForEach-Object { ConvertTo-Comment $_ }) -Depth 4; break }
        if ($all.Count -eq 0) { 'No comments.'; break }
        foreach ($c in $all) {
            "--- $($c.author.displayName) | $([DateTimeOffset]::Parse($c.created).LocalDateTime.ToString('yyyy-MM-dd HH:mm'))"
            $c.body; ''
        }
    }

    'changelog' {
        $all = @(); $at = 0
        do {
            $page = Invoke-Api GET "/rest/api/3/issue/$Key/changelog?startAt=$at&maxResults=100"
            if ($null -eq $page -or -not $page.PSObject.Properties['values']) {
                Stop-Kit 1 "Unexpected answer from Jira for /rest/api/3/issue/$Key/changelog."
            }
            $all += @($page.values); $at += @($page.values).Count
        } while (-not $page.isLast -and @($page.values).Count -gt 0)
        if ($Json -or $Raw) { ConvertTo-Json -InputObject $all -Depth 8; break }
        foreach ($h in $all) {
            foreach ($it in $h.items) {
                "$([DateTimeOffset]::Parse($h.created).LocalDateTime.ToString('yyyy-MM-dd HH:mm')) | $($h.author.displayName) | $($it.field): '$($it.fromString)' -> '$($it.toString)'"
            }
        }
    }

    'transitions' {
        $t = Invoke-Api GET "/rest/api/3/issue/$Key/transitions"
        if ($null -eq $t -or -not $t.PSObject.Properties['transitions']) {
            Stop-Kit 1 "Unexpected answer from Jira for /rest/api/3/issue/$Key/transitions."
        }
        if ($Json -or $Raw) { $t | ConvertTo-Json -Depth 6; break }
        foreach ($x in $t.transitions) { "$($x.id) | $($x.name) -> $($x.to.name)" }
    }

    'sprints' {
        $s = Invoke-Api GET "/rest/agile/1.0/board/$Board/sprint?state=active,future&maxResults=50"
        if ($null -eq $s -or -not $s.PSObject.Properties['values']) {
            Stop-Kit 1 "Unexpected answer from Jira for /rest/agile/1.0/board/$Board/sprint."
        }
        if ($Json -or $Raw) { $s | ConvertTo-Json -Depth 5; break }
        foreach ($x in $s.values) { "$($x.id) | $($x.name) | $($x.state) | $($x.startDate) -> $($x.endDate)" }
    }

    'user' {
        $u = @(Invoke-Api GET "/rest/api/3/user/search?query=$([Uri]::EscapeDataString($Query))&maxResults=10" | Where-Object { $null -ne $_ -and $_.PSObject.Properties['accountId'] -and $_.accountId })
        if ($Json -or $Raw) { ConvertTo-Json -InputObject $u -Depth 4; break }
        if ($u.Count -eq 0) { 'No users.'; break }
        foreach ($x in $u) { "$($x.accountId) | $($x.displayName) | $($x.emailAddress) | mention [~accountid:$($x.accountId)]" }
    }

    'footprint' {
        if (-not $AccountId) { $AccountId = Get-KitValue $cfg 'user.boardAccountId' }
        if (-not $AccountId) { $AccountId = (Invoke-Api GET '/rest/api/3/myself').accountId }
        $Days = [Math]::Max($Days, 1)
        $roles = [ordered]@{}
        foreach ($role in 'assignee', 'reporter') {
            $r = Search-Issues "$role = '$AccountId' AND updated >= -$($Days)d ORDER BY updated DESC" @('project', 'issuetype', 'status') 1000
            $roles[$role] = [pscustomobject]@{
                total  = $r.Issues.Count
                capped = $r.More
                groups = @($r.Issues | Group-Object { "$($_.fields.project.key)|$($_.fields.issuetype.name)|$($_.fields.status.name)" } |
                        Sort-Object Count -Descending | ForEach-Object {
                            $p = $_.Name -split '\|'
                            [pscustomobject]@{ project = $p[0]; type = $p[1]; status = $p[2]; count = $_.Count }
                        })
            }
        }
        if ($Json) { [pscustomobject]@{ accountId = $AccountId; days = $Days; roles = [pscustomobject]$roles } | ConvertTo-Json -Depth 6; break }
        foreach ($role in $roles.Keys) {
            $x = $roles[$role]
            "As ${role}: $($x.total) issue(s) updated in the last $Days days$(if ($x.capped) { ' (first 1000 only)' })"
            foreach ($g in $x.groups) { '  {0,4}  {1} | {2} | {3}' -f $g.count, $g.project, $g.type, $g.status }
        }
    }

    'statuses' {
        $s = @(Invoke-Api GET "/rest/api/3/project/$([Uri]::EscapeDataString($Project))/statuses")
        if ($Json -or $Raw) { ConvertTo-Json -InputObject $s -Depth 6; break }
        foreach ($t in $s) { "$($t.name): $((@($t.statuses | ForEach-Object { $_.name })) -join ', ')" }
    }

    'boards' {
        $b = Invoke-Api GET "/rest/agile/1.0/board?projectKeyOrId=$([Uri]::EscapeDataString($Project))&maxResults=50"
        if ($null -eq $b -or -not $b.PSObject.Properties['values']) { Stop-Kit 1 'Unexpected answer from Jira for /rest/agile/1.0/board.' }
        if ($Json -or $Raw) { ConvertTo-Json -InputObject @($b.values) -Depth 5; break }
        foreach ($x in $b.values) { "$($x.id) | $($x.name) | $($x.type)" }
    }

    'discover' {
        $myself = Invoke-Api GET '/rest/api/3/myself'
        if (-not $AccountId) { $AccountId = Get-KitValue $cfg 'user.boardAccountId' }
        if (-not $AccountId) { $AccountId = [string]$myself.accountId }
        $Days = [Math]::Max($Days, 1)
        $worked = [ordered]@{}
        foreach ($role in 'assignee', 'reporter') {
            $r = Search-Issues "$role = '$AccountId' AND updated >= -$($Days)d ORDER BY updated DESC" @('project', 'issuetype') 1000
            foreach ($i in $r.Issues) {
                $pk = [string]$i.fields.project.key
                if (-not $worked.Contains($pk)) { $worked[$pk] = [pscustomobject]@{ name = [string]$i.fields.project.name; types = [ordered]@{} } }
                $tn = [string]$i.fields.issuetype.name
                $worked[$pk].types[$tn] = 1 + [int]$worked[$pk].types[$tn]
            }
        }
        if ($Project -and -not $worked.Contains($Project)) { $worked[$Project] = [pscustomobject]@{ name = $Project; types = [ordered]@{} } }
        $projects = foreach ($pk in $worked.Keys) {
            $escaped = [Uri]::EscapeDataString($pk)
            $byType = @(Invoke-Api GET "/rest/api/3/project/$escaped/statuses")
            $statuses = @($byType | ForEach-Object { $_.statuses } | Where-Object { $_ } | Group-Object name | ForEach-Object {
                    [pscustomobject]@{ name = $_.Name; category = (ConvertTo-StatusCategory $_.Group[0]) }
                })
            $boards = Invoke-Api GET "/rest/agile/1.0/board?projectKeyOrId=$escaped&maxResults=50"
            [pscustomobject]@{
                key = $pk; name = $worked[$pk].name
                types = @($worked[$pk].types.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [pscustomobject]@{ name = $_.Key; count = $_.Value } })
                statuses = $statuses
                boards = @($boards.values | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_.id; name = [string]$_.name; type = [string]$_.type } })
            }
        }
        $out = [pscustomobject]@{
            me = [pscustomobject]@{ id = [string]$myself.accountId; name = [string]$myself.displayName; email = [string]$myself.emailAddress }
            accountId = $AccountId; days = $Days; projects = @($projects)
        }
        if ($Json) { $out | ConvertTo-Json -Depth 6; break }
        "Token: $($out.me.name) ($($out.me.email)); work of account $AccountId in the last $Days days"
        foreach ($p in $out.projects) {
            ''; "$($p.key) ($($p.name))"
            "  types: $(@($p.types | ForEach-Object { "$($_.name) $($_.count)" }) -join ', ')"
            "  statuses: $(@($p.statuses | ForEach-Object { "$($_.name) [$($_.category)]" }) -join ', ')"
            "  boards: $(@($p.boards | ForEach-Object { "$($_.id) $($_.name)" }) -join ', ')"
        }
    }

    'edit-comment' {
        $old = Invoke-Api GET "/rest/api/2/issue/$Key/comment/$CommentId"
        $me = Invoke-Api GET '/rest/api/3/myself'
        if ($old.author.accountId -ne $me.accountId) {
            Stop-Kit 1 "Comment $CommentId on $Key is $($old.author.displayName)'s, not yours; nothing changed."
        }
        if ((([string]$old.body -replace '\r\n', "`n").Trim()) -eq $Body) {
            if ($Json) { [pscustomobject]@{ id = [string]$CommentId; key = $Key; link = "$Site/browse/$Key`?focusedCommentId=$CommentId"; changed = $false } | ConvertTo-Json; break }
            "no change: $Key comment $CommentId already reads that way"; break
        }
        $c = Invoke-Api PUT "/rest/api/2/issue/$Key/comment/$CommentId" @{ body = $Body }
        Write-JiraWriteLog 'edit-comment' '' ([string]$c.id)
        if ($Raw) { $c | ConvertTo-Json -Depth 6; break }
        if ($Json) { [pscustomobject]@{ id = [string]$c.id; key = $Key; link = "$Site/browse/$Key`?focusedCommentId=$($c.id)"; changed = $true } | ConvertTo-Json; break }
        "edited $Key comment $($c.id) | $Site/browse/$Key`?focusedCommentId=$($c.id)"
    }

    'comment' {
        $posted = Add-JiraComment
        if ($posted.duplicate) { Stop-Kit 1 "$Key already has this comment ($($posted.comment.id)); nothing posted." }
        $c = $posted.comment
        Write-JiraWriteLog 'comment' '' ([string]$c.id)
        if ($Raw) { $c | ConvertTo-Json -Depth 6; break }
        if ($Json) { [pscustomobject]@{ id = [string]$c.id; key = $Key; link = "$Site/browse/$Key`?focusedCommentId=$($c.id)"; duplicate = $false } | ConvertTo-Json; break }
        "ok $Key comment $($c.id) | $Site/browse/$Key`?focusedCommentId=$($c.id)"
    }

    'transition' {
        $issue = Invoke-Api GET "/rest/api/3/issue/$Key`?fields=status"
        $fromStatus = [string]$issue.fields.status.name
        if (-not $fromStatus) { Stop-Kit 1 "Unexpected answer from Jira for /rest/api/3/issue/$Key." }
        # Moves such as "Create Document" lead back to the current status; never pick one of those.
        if ($fromStatus -ieq $To) { Stop-Kit 1 "$Key is already in '$fromStatus'; nothing changed. To add the reason, use comment." }
        $offered = Invoke-Api GET "/rest/api/3/issue/$Key/transitions"
        if ($null -eq $offered -or -not $offered.PSObject.Properties['transitions']) {
            Stop-Kit 1 "Unexpected answer from Jira for /rest/api/3/issue/$Key/transitions."
        }
        $leadThere = @($offered.transitions | Where-Object { [string]$_.to.name -ieq $To })
        $usable = @($leadThere | Where-Object { [string]$_.name -notmatch '\(admin\)\s*$' })
        if (-not $leadThere.Count) {
            $targets = @($offered.transitions | ForEach-Object { [string]$_.to.name } | Where-Object { $_ -and $_ -ine $fromStatus } | Sort-Object -Unique)
            Stop-Kit 1 "$Key ($fromStatus) has no move to '$To'; nothing changed. It can move to: $(if ($targets.Count) { $targets -join ', ' } else { 'nothing' })."
        }
        if (-not $usable.Count) { Stop-Kit 1 "The only move from '$fromStatus' to '$To' is '$($leadThere[0].name)', an admin move; nothing changed." }
        if ($usable.Count -gt 1) { Stop-Kit 1 "Several moves lead from '$fromStatus' to '$To' ($((@($usable | ForEach-Object { $_.name })) -join ', ')); nothing changed. Do it in Jira." }
        $move = $usable[0]
        Invoke-Api POST "/rest/api/3/issue/$Key/transitions" @{ transition = @{ id = [string]$move.id } } | Out-Null
        $toStatus = [string]$move.to.name
        Write-JiraWriteLog 'transition' $toStatus
        $result = [ordered]@{ key = $Key; from = $fromStatus; to = $toStatus; transition = [string]$move.name; comment = $null; commentDuplicate = $false }
        if (-not $Json) { "moved $Key from '$fromStatus' to '$toStatus' ($($move.name)) | $Site/browse/$Key" }
        if ($Body) {
            $posted = Add-JiraComment
            $result.comment = [string]$posted.comment.id
            $result.commentDuplicate = $posted.duplicate
            if (-not $posted.duplicate) { Write-JiraWriteLog 'comment' $toStatus ([string]$posted.comment.id) }
            if (-not $Json) {
                if ($posted.duplicate) { "the reason was already there: comment $($posted.comment.id); nothing posted" }
                else { "ok $Key comment $($posted.comment.id) | $Site/browse/$Key`?focusedCommentId=$($posted.comment.id)" }
            }
        }
        if ($Json) { [pscustomobject]$result | ConvertTo-Json -Depth 4 }
    }
}
exit 0
